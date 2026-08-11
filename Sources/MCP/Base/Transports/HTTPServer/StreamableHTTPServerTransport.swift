import Foundation
import Logging

/// A Streamable HTTP server transport for the per-request-metadata lifecycle.
///
/// Each JSON-RPC request or notification arrives in its own POST. A request
/// receives a direct JSON response unless the server emits a related notification
/// first, in which case the response becomes a request-scoped SSE stream. This
/// transport does not create sessions, a standalone GET stream, or replay state.
public actor StreamableHTTPServerTransport: Transport, HTTPContextProviding,
    RequestScopedSending, RequestCancellationRegistering
{
    public nonisolated let logger: Logger

    private struct ActiveRequest {
        let originalID: ID
        let stream: AsyncThrowingStream<Data, Swift.Error>
        let streamContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
        var initialResponse: CheckedContinuation<HTTPResponse, Never>?
        var isStreaming: Bool
    }

    private enum IncomingMessage {
        case request(id: ID, method: String, bodyVersion: String?)
        case notification(method: String, bodyVersion: String?)

        var id: ID? {
            if case .request(let id, _, _) = self { return id }
            return nil
        }

        var bodyVersion: String? {
            switch self {
            case .request(_, _, let version), .notification(_, let version):
                return version
            }
        }
    }

    private let validationPipeline: any HTTPRequestValidationPipeline
    private let supportedProtocolVersions: Set<String>

    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var activeRequests: [ID: ActiveRequest] = [:]
    private var httpRequestContexts: [ID: HTTPRequest] = [:]
    private var requestCancellationHandler: (@Sendable (ID) async -> Void)?
    private var started = false
    private var terminated = false

    /// Creates a per-request-metadata Streamable HTTP server transport.
    ///
    /// A custom validation pipeline replaces the default Origin, Accept, and
    /// Content-Type validators. Protocol-version presence, support, and agreement
    /// with request metadata are always enforced by the transport.
    public init(
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        logger: Logger? = nil
    ) {
        self.validationPipeline = validationPipeline ?? StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
        ])
        self.supportedProtocolVersions = [Version.perRequestMetadataVersion]
        self.logger = logger ?? Logger(
            label: "mcp.transport.http.server.per-request-metadata",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.incomingStream = stream
        self.incomingContinuation = continuation
    }

    // MARK: - Transport

    public func connect() async throws {
        guard !started else {
            throw MCPError.internalError("Transport already started")
        }
        started = true
        logger.debug("Per-request-metadata HTTP server transport started")
    }

    public func disconnect() async {
        await terminate()
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        incomingStream
    }

    public func send(_ data: Data) async throws {
        try await send(data, relatedTo: nil)
    }

    package func send(_ data: Data, relatedTo requestID: ID?) async throws {
        guard !terminated else {
            throw MCPError.connectionClosed
        }

        guard let kind = JSONRPCMessageKind(data: data) else {
            throw MCPError.invalidRequest("Could not classify outgoing JSON-RPC message")
        }

        switch kind {
        case .response:
            guard let responseID = Self.messageID(in: data) else {
                throw MCPError.invalidRequest("Outgoing response has an invalid id")
            }
            routeResponse(data, requestID: responseID)

        case .notification(let method):
            guard let requestID else {
                throw MCPError.invalidRequest(
                    "Per-request-metadata HTTP notifications must relate to an active request")
            }
            try routeNotification(data, requestID: requestID, method: method)

        case .request(_, let method):
            throw MCPError.invalidRequest(
                "Server request \(method) cannot be sent on a per-request HTTP response")
        }
    }

    // MARK: - HTTP handling

    /// Handles one framework-neutral request to the MCP endpoint.
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard !terminated else {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Transport has been terminated")
            )
        }

        guard request.method.uppercased() == "POST" else {
            return .error(
                statusCode: 405,
                .invalidRequest("Method Not Allowed"),
                extraHeaders: [HTTPHeaderName.allow: "POST"]
            )
        }

        let validationContext = HTTPValidationContext(
            httpMethod: "POST",
            sessionID: nil,
            isInitializationRequest: false,
            supportedProtocolVersions: supportedProtocolVersions
        )
        if let response = validationPipeline.validate(request, context: validationContext) {
            return response
        }

        guard let body = request.body, !body.isEmpty else {
            return makeErrorResponse(
                statusCode: 400,
                id: nil,
                error: .parseError("Empty request body")
            )
        }

        let message: IncomingMessage
        do {
            message = try Self.parseIncomingMessage(body)
        } catch let error as MCPError {
            return makeErrorResponse(statusCode: 400, id: nil, error: error)
        } catch {
            return makeErrorResponse(
                statusCode: 400,
                id: nil,
                error: .parseError(error.localizedDescription)
            )
        }

        if let versionError = validateProtocolVersion(request: request, message: message) {
            return versionError
        }

        switch message {
        case .notification:
            incomingContinuation.yield(body)
            return .accepted()

        case .request(let id, _, _):
            return await handleJSONRPCRequest(body, requestID: id, request: request)
        }
    }

    private func handleJSONRPCRequest(
        _ body: Data,
        requestID: ID,
        request: HTTPRequest
    ) async -> HTTPResponse {
        let routingID = makeRoutingID()
        guard let routedBody = try? Self.replacingMessageID(in: body, with: routingID) else {
            return makeErrorResponse(
                statusCode: 500,
                id: requestID,
                error: .internalError("Could not prepare request routing")
            )
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let (stream, streamContinuation) =
                    AsyncThrowingStream<Data, Swift.Error>.makeStream()
                streamContinuation.onTermination = { @Sendable [weak self] termination in
                    guard case .cancelled = termination else { return }
                    Task { await self?.cancelRequest(routingID) }
                }

                activeRequests[routingID] = ActiveRequest(
                    originalID: requestID,
                    stream: stream,
                    streamContinuation: streamContinuation,
                    initialResponse: continuation,
                    isStreaming: false
                )
                httpRequestContexts[routingID] = request
                incomingContinuation.yield(routedBody)
            }
        } onCancel: {
            Task { await self.cancelRequest(routingID) }
        }
    }

    // MARK: - Routing

    private func routeNotification(_ data: Data, requestID: ID, method: String) throws {
        guard var activeRequest = activeRequests[requestID] else {
            logger.debug(
                "No active response stream for notification",
                metadata: ["requestID": "\(requestID)", "method": "\(method)"]
            )
            return
        }

        if !activeRequest.isStreaming {
            activeRequest.isStreaming = true
            let initialResponse = activeRequest.initialResponse
            activeRequest.initialResponse = nil
            activeRequests[requestID] = activeRequest

            activeRequest.streamContinuation.yield(SSEEvent.message(data: data).formatted())
            initialResponse?.resume(returning: .stream(
                activeRequest.stream,
                headers: Self.sseHeaders
            ))
            return
        }

        activeRequest.streamContinuation.yield(SSEEvent.message(data: data).formatted())
    }

    private func routeResponse(_ data: Data, requestID: ID) {
        guard let activeRequest = activeRequests.removeValue(forKey: requestID) else {
            logger.debug(
                "No active HTTP request for response",
                metadata: ["requestID": "\(requestID)"]
            )
            return
        }
        httpRequestContexts.removeValue(forKey: requestID)
        guard let clientData = try? Self.replacingMessageID(
            in: data, with: activeRequest.originalID)
        else {
            activeRequest.streamContinuation.finish()
            activeRequest.initialResponse?.resume(returning: .error(
                statusCode: 500,
                .internalError("Could not restore the response id")
            ))
            return
        }

        if activeRequest.isStreaming {
            activeRequest.streamContinuation.yield(SSEEvent.message(data: clientData).formatted())
            activeRequest.streamContinuation.finish()
            return
        }

        activeRequest.streamContinuation.finish()
        let statusCode = Self.httpStatusCode(forJSONRPCResponse: clientData)
        let headers = [HTTPHeaderName.contentType: ContentType.json]
        if statusCode == 200 {
            activeRequest.initialResponse?.resume(returning: .data(clientData, headers: headers))
        } else {
            activeRequest.initialResponse?.resume(returning: .dataWithStatus(
                statusCode: statusCode,
                clientData,
                headers: headers
            ))
        }
    }

    private static let sseHeaders = [
        HTTPHeaderName.contentType: ContentType.sse,
        HTTPHeaderName.cacheControl: "no-cache, no-transform",
        HTTPHeaderName.xAccelBuffering: "no",
    ]

    private static func httpStatusCode(forJSONRPCResponse data: Data) -> Int {
        guard
            let value = try? JSONDecoder().decode(Value.self, from: data),
            let object = value.objectValue,
            let error = object["error"]?.objectValue,
            let code = error["code"]?.intValue
        else {
            return 200
        }

        switch code {
        case -32601:
            return 404
        case -32700, -32600,
            ProtocolErrorCode.headerMismatch,
            ProtocolErrorCode.missingRequiredClientCapability,
            ProtocolErrorCode.unsupportedProtocolVersion:
            return 400
        default:
            return 200
        }
    }

    // MARK: - Protocol validation

    private func validateProtocolVersion(
        request: HTTPRequest,
        message: IncomingMessage
    ) -> HTTPResponse? {
        guard let headerVersion = request.header(HTTPHeaderName.protocolVersion),
            !headerVersion.isEmpty
        else {
            return makeErrorResponse(
                statusCode: 400,
                id: message.id,
                error: .remote(
                    code: ProtocolErrorCode.headerMismatch,
                    message: "Missing MCP-Protocol-Version header",
                    data: nil
                )
            )
        }

        if let bodyVersion = message.bodyVersion, bodyVersion != headerVersion {
            return makeErrorResponse(
                statusCode: 400,
                id: message.id,
                error: .remote(
                    code: ProtocolErrorCode.headerMismatch,
                    message: "MCP-Protocol-Version header does not match request metadata",
                    data: nil
                )
            )
        }

        if case .request = message, message.bodyVersion == nil {
            return makeErrorResponse(
                statusCode: 400,
                id: message.id,
                error: .remote(
                    code: ProtocolErrorCode.headerMismatch,
                    message: "Request metadata is missing the protocol version",
                    data: nil
                )
            )
        }

        guard supportedProtocolVersions.contains(headerVersion) else {
            let data = try? Value(UnsupportedProtocolVersionData(
                supported: supportedProtocolVersions.sorted(by: >),
                requested: headerVersion
            ))
            return makeErrorResponse(
                statusCode: 400,
                id: message.id,
                error: .remote(
                    code: ProtocolErrorCode.unsupportedProtocolVersion,
                    message: "Unsupported protocol version",
                    data: data
                )
            )
        }

        return nil
    }

    private static func parseIncomingMessage(_ data: Data) throws -> IncomingMessage {
        let value: Value
        do {
            value = try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw MCPError.parseError("Invalid JSON")
        }

        guard let object = value.objectValue else {
            throw MCPError.invalidRequest(
                "Streamable HTTP requires one JSON-RPC request or notification object")
        }
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            throw MCPError.invalidRequest("JSON-RPC version must be 2.0")
        }
        guard let method = object["method"]?.stringValue, !method.isEmpty else {
            throw MCPError.invalidRequest(
                "Streamable HTTP clients must not POST JSON-RPC responses")
        }

        let bodyVersion = object["params"]?.objectValue?["_meta"]?
            .objectValue?[ProtocolMetadataKey.protocolVersion]?.stringValue

        guard let idValue = object["id"], !idValue.isNull else {
            return .notification(method: method, bodyVersion: bodyVersion)
        }
        if let id = id(from: idValue) {
            return .request(id: id, method: method, bodyVersion: bodyVersion)
        }
        throw MCPError.invalidRequest("JSON-RPC id must be a string or integer")
    }

    private static func messageID(in data: Data) -> ID? {
        guard
            let value = try? JSONDecoder().decode(Value.self, from: data),
            let idValue = value.objectValue?["id"]
        else {
            return nil
        }
        return id(from: idValue)
    }

    private static func replacingMessageID(in data: Data, with id: ID) throws -> Data {
        var value = try JSONDecoder().decode(Value.self, from: data)
        guard case .object(var object) = value else {
            throw MCPError.invalidRequest("JSON-RPC message must be an object")
        }
        switch id {
        case .string(let string):
            object["id"] = .string(string)
        case .number(let number):
            object["id"] = .int(number)
        }
        value = .object(object)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func id(from value: Value) -> ID? {
        if let string = value.stringValue { return .string(string) }
        if let number = value.intValue { return .number(number) }
        return nil
    }

    private func makeErrorResponse(
        statusCode: Int,
        id: ID?,
        error: MCPError
    ) -> HTTPResponse {
        guard let id else {
            return .error(statusCode: statusCode, error)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(AnyMethod.response(id: id, error: error)) else {
            return .error(statusCode: statusCode, error)
        }
        return .dataWithStatus(
            statusCode: statusCode,
            data,
            headers: [HTTPHeaderName.contentType: ContentType.json]
        )
    }

    // MARK: - Request context and cancellation

    public func httpRequestContext(for id: ID) -> HTTPRequest? {
        if let request = httpRequestContexts[id] {
            return request
        }
        guard let routingID = activeRequests.first(where: { $0.value.originalID == id })?.key
        else {
            return nil
        }
        return httpRequestContexts[routingID]
    }

    package func setRequestCancellationHandler(
        _ handler: (@Sendable (ID) async -> Void)?
    ) {
        requestCancellationHandler = handler
    }

    private func cancelRequest(_ requestID: ID) async {
        guard let activeRequest = activeRequests.removeValue(forKey: requestID) else {
            return
        }
        httpRequestContexts.removeValue(forKey: requestID)
        activeRequest.streamContinuation.finish()
        activeRequest.initialResponse?.resume(returning: .accepted())
        await requestCancellationHandler?(requestID)
    }

    private func makeRoutingID() -> ID {
        var id: ID
        repeat {
            id = .string("mcp-http-\(UUID().uuidString)")
        } while activeRequests[id] != nil
        return id
    }

    private func terminate() async {
        guard !terminated else { return }
        terminated = true

        let requests = activeRequests
        activeRequests.removeAll()
        httpRequestContexts.removeAll()
        for (_, request) in requests {
            request.streamContinuation.finish(throwing: MCPError.connectionClosed)
            request.initialResponse?.resume(returning: .error(
                statusCode: 500,
                .connectionClosed
            ))
        }

        requestCancellationHandler = nil
        incomingContinuation.finish()
        logger.debug("Per-request-metadata HTTP server transport terminated")
    }
}
