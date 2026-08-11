import Foundation
import Logging

#if !os(Linux)
    import EventSource
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private final class HTTPResponsePromise: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<HTTPURLResponse, Swift.Error>?
    private var continuation: CheckedContinuation<HTTPURLResponse, Swift.Error>?

    func value() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Result<HTTPURLResponse, Swift.Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private struct HTTPStreamingResponse: Sendable {
    let response: HTTPResponsePromise
    let body: AsyncThrowingStream<Data, Swift.Error>
}

/// Bridges URLSession delegate delivery to an async response stream on every supported platform.
private final class HTTPResponseStreamDelegate: NSObject, URLSessionDataDelegate,
    @unchecked Sendable
{
    private struct State {
        let response: HTTPResponsePromise
        let body: AsyncThrowingStream<Data, Swift.Error>.Continuation
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]

    func register(task: URLSessionDataTask) -> HTTPStreamingResponse {
        let response = HTTPResponsePromise()
        var bodyContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        let body = AsyncThrowingStream<Data, Swift.Error> { bodyContinuation = $0 }

        lock.lock()
        states[task.taskIdentifier] = State(
            response: response,
            body: bodyContinuation
        )
        lock.unlock()
        return HTTPStreamingResponse(response: response, body: body)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let state = states[dataTask.taskIdentifier]
        lock.unlock()

        guard let response = response as? HTTPURLResponse else {
            state?.response.resolve(.failure(MCPError.internalError("Invalid HTTP response")))
            completionHandler(.cancel)
            return
        }
        state?.response.resolve(.success(response))
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let continuation = states[dataTask.taskIdentifier]?.body
        lock.unlock()
        continuation?.yield(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Swift.Error)?
    ) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        if let error {
            state?.response.resolve(.failure(error))
            state?.body.finish(throwing: error)
        } else {
            state?.body.finish()
        }
    }
}

private struct RequestScopedSSEParser {
    private var buffer = Data()
    private var dataLines: [String] = []
    private var isFirstLine = true

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        return try drainLines(isFinal: false)
    }

    mutating func finish() throws -> [Data] {
        var messages = try drainLines(isFinal: true)
        if !buffer.isEmpty {
            let line = buffer
            buffer.removeAll(keepingCapacity: false)
            try process(line: line, messages: &messages)
        }
        dispatch(messages: &messages)
        return messages
    }

    private mutating func drainLines(isFinal: Bool) throws -> [Data] {
        var messages: [Data] = []
        while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            var delimiterEnd = newline
            if buffer[newline] == 0x0D {
                let next = buffer.index(after: newline)
                if next == buffer.endIndex, !isFinal { break }
                if next != buffer.endIndex, buffer[next] == 0x0A {
                    delimiterEnd = next
                }
            }
            let line = buffer[..<newline]
            buffer.removeSubrange(buffer.startIndex...delimiterEnd)
            try process(line: Data(line), messages: &messages)
        }
        return messages
    }

    private mutating func process(line: Data, messages: inout [Data]) throws {
        guard var line = String(data: line, encoding: .utf8) else {
            throw MCPError.invalidRequest("SSE response is not valid UTF-8")
        }
        if isFirstLine {
            isFirstLine = false
            if line.first == "\u{FEFF}" { line.removeFirst() }
        }
        if line.isEmpty {
            dispatch(messages: &messages)
            return
        }
        if line.hasPrefix(":") { return }

        let fieldAndValue = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard fieldAndValue.first == "data" else { return }
        var value = fieldAndValue.count == 2 ? String(fieldAndValue[1]) : ""
        if value.first == " " { value.removeFirst() }
        dataLines.append(value)
    }

    private mutating func dispatch(messages: inout [Data]) {
        guard !dataLines.isEmpty else { return }
        let message = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        messages.append(Data(message.utf8))
    }
}

// MARK: - Timeout Helpers

/// Error thrown when an operation times out
/// An implementation of the MCP Streamable HTTP transport protocol for clients.
///
/// The client selects initialization-based or per-request-metadata behavior through its
/// ``Client/ProtocolMode``. Initialization-based connections retain the HTTP session and
/// standalone event-stream behavior defined through protocol version 2025-11-25.
/// Per-request-metadata connections use one POST per message and scope any event stream to
/// that request, as required by protocol version 2026-07-28.
///
/// It supports:
/// - Sending JSON-RPC messages via HTTP POST requests
/// - Receiving responses via both direct JSON responses and SSE streams
/// - Session management and resumable standalone streams for initialization-based connections
/// - Request-scoped JSON and SSE responses for per-request-metadata connections
/// - Protocol-version routing through the `MCP-Protocol-Version` header
/// - Cross-platform request-scoped response streaming
///
/// For initialization-based connections, `streaming` controls whether the transport opens a
/// standalone SSE stream. Per-request-metadata connections ignore that option because each
/// request chooses JSON or request-scoped SSE through its HTTP response.
///
/// - Important: Initialization-based standalone SSE streams are not supported on Linux.
///   Request-scoped SSE responses are streamed on Linux and Apple platforms.
///
/// ## Example Usage
///
/// ```swift
/// import MCP
///
/// // Create a streaming HTTP transport with bearer token authentication
/// let transport = HTTPClientTransport(
///     endpoint: URL(string: "https://api.example.com/mcp")!,
///     requestModifier: { request in
///         var modifiedRequest = request
///         modifiedRequest.addValue("Bearer your-token-here", forHTTPHeaderField: "Authorization")
///         return modifiedRequest
///     }
/// )
///
/// // Initialize the client with streaming transport
/// let client = Client(name: "MyApp", version: "1.0.0")
/// try await client.connect(transport: transport)
///
/// // The transport will automatically handle SSE events
/// // and deliver them through the client's notification handlers
/// ```
public actor HTTPClientTransport: Transport, ProtocolLifecycleUpdating, RequestStreamCancelling {
    /// The server endpoint URL to connect to
    public let endpoint: URL
    private let session: URLSession
    private let requestSession: URLSession
    private let requestStreamDelegate: HTTPResponseStreamDelegate

    /// The session ID assigned by the server, used for maintaining state across requests
    public private(set) var sessionID: String?

    /// The negotiated protocol version to send in MCP-Protocol-Version header
    public var protocolVersion: String?

    /// Lifecycle-specific behavior selected by the client.
    private var protocolLifecycle: ProtocolLifecycle = .initializationBased

    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?

    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    /// Maximum time to wait for a session ID before proceeding with SSE connection
    public let sseInitializationTimeout: TimeInterval

    /// Closure to modify requests before they are sent
    private let requestModifier: (URLRequest) -> URLRequest

    /// Optional OAuth 2.1 authorizer.
    private let authorizer: (any HTTPClientAuthorizer)?

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var initialSessionIDSignalTask: Task<Void, Never>?
    private var initialSessionIDContinuation: CheckedContinuation<Void, Never>?

    /// The last event ID received from the server for SSE stream resumability
    private var lastEventID: String?

    /// The retry interval (in milliseconds) from the server's SSE `retry:` field
    private var retryInterval: Int = 3000  // Default 3000ms per SSE spec

    /// The underlying URLSession task for the active GET SSE stream.
    /// Used to trigger reconnection when a POST SSE stream closes without delivering data.
    private var activeGETSessionTask: URLSessionDataTask?

    /// Active request-scoped HTTP tasks, keyed by JSON-RPC request ID.
    private var activeRequestTasks: [ID: URLSessionDataTask] = [:]

    /// Cancellations received before the corresponding HTTP task is registered.
    private var pendingRequestCancellations: Set<ID> = []

    /// Serializes access to authorizers whose mutable state is transport-confined.
    private var authorizationTail: Task<Void, Never>?

    /// Creates a new HTTP transport client with the specified endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The server URL to connect to
    ///   - configuration: URLSession configuration to use for HTTP requests
    ///   - streaming: Whether initialization-based connections open a standalone SSE stream
    ///     (default: true). Per-request-metadata connections ignore this option.
    ///   - sseInitializationTimeout: Maximum time to wait for session ID before proceeding with SSE (default: 10 seconds)
    ///   - protocolVersion: The MCP protocol version to use (default: "2025-11-25")
    ///   - authorizer: Optional ``HTTPClientAuthorizer`` for automatic Bearer token acquisition and retries.
    ///   - requestModifier: Optional closure to customize requests before they are sent (default: no modification)
    ///   - logger: Optional logger instance for transport events
    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = true,
        sseInitializationTimeout: TimeInterval = 10,
        protocolVersion: String = Version.latestInitializationVersion,
        authorizer: (any HTTPClientAuthorizer)? = nil,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        let session = URLSession(configuration: configuration)
        self.init(
            endpoint: endpoint,
            session: session,
            streaming: streaming,
            sseInitializationTimeout: sseInitializationTimeout,
            protocolVersion: protocolVersion,
            authorizer: authorizer,
            requestModifier: requestModifier,
            logger: logger
        )
    }

    internal init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        sseInitializationTimeout: TimeInterval = 10,
        protocolVersion: String = Version.latestInitializationVersion,
        authorizer: (any HTTPClientAuthorizer)? = nil,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        let requestStreamDelegate = HTTPResponseStreamDelegate()
        self.endpoint = endpoint
        self.session = session
        self.requestStreamDelegate = requestStreamDelegate
        self.requestSession = URLSession(
            configuration: session.configuration,
            delegate: requestStreamDelegate,
            delegateQueue: nil
        )
        self.streaming = streaming
        self.sseInitializationTimeout = sseInitializationTimeout
        self.protocolVersion = protocolVersion
        self.requestModifier = requestModifier
        self.authorizer = authorizer

        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation

        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.http.client",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
    }

    // Setup the initial session ID signal
    private func setupInitialSessionIDSignal() {
        self.initialSessionIDSignalTask = Task {
            await withCheckedContinuation { continuation in
                self.initialSessionIDContinuation = continuation
            }
        }
    }

    // Trigger the initial session ID signal when a session ID is established
    private func triggerInitialSessionIDSignal() {
        if let continuation = self.initialSessionIDContinuation {
            continuation.resume()
            self.initialSessionIDContinuation = nil
            logger.debug("✓ Initial session ID signal triggered for SSE task")
        } else {
            logger.debug("✗ No continuation to trigger - signal already consumed or SSE task not waiting")
        }
    }

    /// Establishes connection with the transport
    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true

        setupInitialSessionIDSignal()

        if streaming, protocolLifecycle == .initializationBased {
            streamingTask = Task { await startListeningForServerEvents() }
        }

        logger.debug("HTTP transport connected")
    }

    /// Disconnects from the transport
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        streamingTask?.cancel()
        streamingTask = nil
        for task in activeRequestTasks.values {
            task.cancel()
        }
        activeRequestTasks = [:]
        pendingRequestCancellations = []

        session.invalidateAndCancel()
        requestSession.invalidateAndCancel()
        messageContinuation.finish()

        initialSessionIDSignalTask?.cancel()
        initialSessionIDSignalTask = nil
        initialSessionIDContinuation?.resume()
        initialSessionIDContinuation = nil

        logger.debug("HTTP clienttransport disconnected")
    }

    /// Updates the protocol version used for `MCP-Protocol-Version` headers on subsequent requests.
    public func updateNegotiatedProtocolVersion(_ version: String) {
        self.protocolVersion = version
    }

    package func updateProtocolLifecycle(
        _ lifecycle: ProtocolLifecycle,
        protocolVersion: String
    ) {
        self.protocolLifecycle = lifecycle
        self.protocolVersion = protocolVersion

        switch lifecycle {
        case .initializationBased:
            if isConnected, streaming, streamingTask == nil {
                streamingTask = Task { await startListeningForServerEvents() }
            }
        case .perRequestMetadata:
            streamingTask?.cancel()
            streamingTask = nil
            activeGETSessionTask?.cancel()
            activeGETSessionTask = nil
            sessionID = nil
            lastEventID = nil
        }
    }

    package func cancelRequestStream(id: ID) {
        if let task = activeRequestTasks[id] {
            task.cancel()
        } else {
            pendingRequestCancellations.insert(id)
        }
    }

    /// Sends data through an HTTP POST request
    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        if protocolLifecycle == .perRequestMetadata {
            try await sendPerRequestMetadata(data)
            return
        }

        if let authorizer {
            do {
                try authorizer.validateEndpointSecurity(for: endpoint)
            } catch {
                throw MCPError.internalError(
                    "Authorization flow failed: \(error.localizedDescription)"
                )
            }
        }

        if let authorizer {
            try? await authorizer.prepareAuthorization(for: endpoint, session: session)
        }

        var attempts = 0
        let operationKey = jsonRPCOperationKey(from: data)

        while true {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue(
                "\(ContentType.json), \(ContentType.sse)",
                forHTTPHeaderField: HTTPHeaderName.accept
            )
            request.addValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.contentType)
            request.httpBody = data

            if let protocolVersion = protocolVersion {
                request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
            }

            if let sessionID = sessionID {
                request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
            }

            if let authValue = authorizer?.authorizationHeader(for: endpoint) {
                request.setValue(authValue, forHTTPHeaderField: HTTPHeaderName.authorization)
            }

            request = requestModifier(request)

            do {
                #if os(Linux)
                    let (responseData, response) = try await session.data(for: request)
                    try await processResponse(response: response, data: responseData)
                #else
                    let (responseStream, response) = try await session.bytes(for: request)
                    try await processResponse(response: response, stream: responseStream)
                #endif
                return
            } catch let authError as HTTPAuthenticationChallengeError {
                guard let authorizer else {
                    throw mapAuthenticationChallengeError(authError)
                }
                guard attempts < authorizer.maxAuthorizationAttempts else {
                    throw mapAuthenticationChallengeError(authError)
                }

                let handled: Bool
                do {
                    handled = try await authorizer.handleChallenge(
                        statusCode: authError.statusCode,
                        headers: authError.headers,
                        endpoint: endpoint,
                        operationKey: operationKey,
                        session: session
                    )
                } catch {
                    throw MCPError.internalError(
                        "Authorization flow failed: \(error.localizedDescription)")
                }

                attempts += 1

                if handled { continue }

                throw mapAuthenticationChallengeError(authError)
            }
        }
    }

    private func sendPerRequestMetadata(_ data: Data) async throws {
        let messageKind = JSONRPCMessageKind(data: data)
        let requestID: ID?
        let isNotification: Bool
        switch messageKind {
        case .request:
            requestID = try JSONDecoder().decode(AnyRequest.self, from: data).id
            isNotification = false
        case .notification:
            requestID = nil
            isNotification = true
        case .response:
            throw MCPError.invalidRequest(
                "Per-request metadata HTTP clients must not send JSON-RPC responses")
        case nil:
            throw MCPError.invalidRequest(
                "Per-request metadata HTTP requires one JSON-RPC request or notification per POST")
        }

        let operationKey = jsonRPCOperationKey(from: data)
        let isDiscovery = operationKey == Discover.name
        let bodyProtocolVersion = try perRequestProtocolVersion(
            from: data, required: !isNotification)
        let requestProtocolVersion = bodyProtocolVersion ?? protocolVersion
        guard let requestProtocolVersion else {
            throw MCPError.invalidRequest(
                "Per-request metadata HTTP requires a protocol version for every POST")
        }

        var authorizationHeader: String?
        var maximumAuthorizationAttempts = 0
        if let authorizer {
            let endpoint = self.endpoint
            let requestSession = self.requestSession
            do {
                let authorization = try await withSerializedAuthorization {
                    try authorizer.validateEndpointSecurity(for: endpoint)
                    try? await authorizer.prepareAuthorization(
                        for: endpoint,
                        session: requestSession
                    )
                    return (
                        header: authorizer.authorizationHeader(for: endpoint),
                        maximumAttempts: authorizer.maxAuthorizationAttempts
                    )
                }
                authorizationHeader = authorization.header
                maximumAuthorizationAttempts = authorization.maximumAttempts
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw probeErrorIfNeeded(
                    .internalError("Authorization flow failed: \(error.localizedDescription)"),
                    isDiscovery: isDiscovery
                )
            }
        }

        var attempts = 0
        while true {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue(
                "\(ContentType.json), \(ContentType.sse)",
                forHTTPHeaderField: HTTPHeaderName.accept
            )
            request.setValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.contentType)
            request.httpBody = data
            request.setValue(
                requestProtocolVersion,
                forHTTPHeaderField: HTTPHeaderName.protocolVersion
            )
            if let authValue = authorizationHeader {
                request.setValue(authValue, forHTTPHeaderField: HTTPHeaderName.authorization)
            }
            request = requestModifier(request)

            do {
                try await performPerRequestMetadataPOST(
                    request,
                    requestID: requestID,
                    isNotification: isNotification,
                    isDiscovery: isDiscovery
                )
                return
            } catch let authError as HTTPAuthenticationChallengeError {
                guard let authorizer else {
                    throw probeErrorIfNeeded(
                        mapAuthenticationChallengeError(authError),
                        isDiscovery: isDiscovery
                    )
                }
                guard attempts < maximumAuthorizationAttempts else {
                    throw probeErrorIfNeeded(
                        mapAuthenticationChallengeError(authError),
                        isDiscovery: isDiscovery
                    )
                }

                let challengeResult: (handled: Bool, authorizationHeader: String?)
                do {
                    let endpoint = self.endpoint
                    let requestSession = self.requestSession
                    let challengedAuthorizationHeader = authorizationHeader
                    challengeResult = try await withSerializedAuthorization {
                        let currentAuthorizationHeader =
                            authorizer.authorizationHeader(for: endpoint)
                        if currentAuthorizationHeader != challengedAuthorizationHeader {
                            return (true, currentAuthorizationHeader)
                        }
                        let handled = try await authorizer.handleChallenge(
                            statusCode: authError.statusCode,
                            headers: authError.headers,
                            endpoint: endpoint,
                            operationKey: operationKey,
                            session: requestSession
                        )
                        return (
                            handled,
                            authorizer.authorizationHeader(for: endpoint)
                        )
                    }
                } catch {
                    throw probeErrorIfNeeded(
                        .internalError("Authorization flow failed: \(error.localizedDescription)"),
                        isDiscovery: isDiscovery
                    )
                }

                attempts += 1
                if challengeResult.handled {
                    authorizationHeader = challengeResult.authorizationHeader
                    continue
                }
                throw probeErrorIfNeeded(
                    mapAuthenticationChallengeError(authError),
                    isDiscovery: isDiscovery
                )
            } catch let error as ProtocolLifecycleProbeError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                throw CancellationError()
            } catch let error as MCPError {
                throw probeErrorIfNeeded(error, isDiscovery: isDiscovery)
            } catch {
                let mapped = MCPError.internalError(
                    "HTTP request failed: \(error.localizedDescription)")
                throw probeErrorIfNeeded(mapped, isDiscovery: isDiscovery)
            }
        }
    }

    private func performPerRequestMetadataPOST(
        _ request: URLRequest,
        requestID: ID?,
        isNotification: Bool,
        isDiscovery: Bool
    ) async throws {
        if let requestID, pendingRequestCancellations.remove(requestID) != nil {
            throw CancellationError()
        }
        let task = requestSession.dataTask(with: request)
        let responseStream = requestStreamDelegate.register(task: task)
        if let requestID {
            activeRequestTasks[requestID] = task
        }
        defer {
            if let requestID, activeRequestTasks[requestID] === task {
                activeRequestTasks.removeValue(forKey: requestID)
            }
        }

        try await withTaskCancellationHandler {
            task.resume()
            let response = try await responseStream.response.value()
            do {
                try await processPerRequestMetadataResponse(
                    response,
                    body: responseStream.body,
                    requestID: requestID,
                    isNotification: isNotification,
                    isDiscovery: isDiscovery
                )
                task.cancel()
            } catch {
                task.cancel()
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func processPerRequestMetadataResponse(
        _ response: HTTPURLResponse,
        body: AsyncThrowingStream<Data, Swift.Error>,
        requestID: ID?,
        isNotification: Bool,
        isDiscovery: Bool
    ) async throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw HTTPAuthenticationChallengeError(
                statusCode: response.statusCode,
                headers: responseHeaders(from: response)
            )
        }

        if isNotification {
            guard response.statusCode == 202 else {
                throw MCPError.internalError(
                    "Notification POST returned HTTP \(response.statusCode) instead of 202")
            }
            return
        }

        let contentType = response.value(forHTTPHeaderField: HTTPHeaderName.contentType) ?? ""
        guard response.statusCode == 200 else {
            let data = try await collect(body)
            if let remoteError = decodedResponseError(from: data, requestID: requestID) {
                if isDiscovery {
                    if isRecognizedPerRequestMetadataError(
                        remoteError,
                        statusCode: response.statusCode
                    ) {
                        throw ProtocolLifecycleProbeError.inconclusive(remoteError)
                    }
                    if [400, 404, 405].contains(response.statusCode) {
                        throw ProtocolLifecycleProbeError.initializationBasedResponse
                    }
                    throw ProtocolLifecycleProbeError.inconclusive(remoteError)
                }
                messageContinuation.yield(data)
                return
            }
            if isDiscovery, [400, 404, 405].contains(response.statusCode) {
                throw ProtocolLifecycleProbeError.initializationBasedResponse
            }
            throw httpError(response.statusCode, contentType: contentType)
        }

        if hasContentType(contentType, ContentType.json) {
            let data = try await collect(body)
            try validatePerRequestResponse(data, requestID: requestID)
            messageContinuation.yield(data)
            return
        }
        if hasContentType(contentType, ContentType.sse) {
            try await processRequestScopedSSE(body, requestID: requestID)
            return
        }
        throw MCPError.internalError(
            "Unexpected content type for request response: \(contentType)")
    }

    private func processRequestScopedSSE(
        _ body: AsyncThrowingStream<Data, Swift.Error>,
        requestID: ID?
    ) async throws {
        var parser = RequestScopedSSEParser()
        for try await chunk in body {
            for message in try parser.append(chunk) {
                if try processRequestScopedMessage(message, requestID: requestID) {
                    return
                }
            }
        }
        for message in try parser.finish() {
            if try processRequestScopedMessage(message, requestID: requestID) {
                return
            }
        }
        throw MCPError.internalError(
            "Request-scoped SSE stream ended before its JSON-RPC response")
    }

    private func processRequestScopedMessage(_ data: Data, requestID: ID?) throws -> Bool {
        if let response = try? JSONDecoder().decode(AnyResponse.self, from: data) {
            guard let requestID, response.id == requestID else {
                throw MCPError.invalidRequest(
                    "Request-scoped SSE response ID does not match its HTTP request")
            }
            messageContinuation.yield(data)
            return true
        }
        if (try? JSONDecoder().decode(AnyRequest.self, from: data)) != nil {
            throw MCPError.invalidRequest(
                "Request-scoped SSE streams must not contain server requests")
        }
        guard (try? JSONDecoder().decode(AnyMessage.self, from: data)) != nil else {
            throw MCPError.invalidRequest(
                "Request-scoped SSE stream contains an invalid JSON-RPC message")
        }
        messageContinuation.yield(data)
        return false
    }

    private func validatePerRequestResponse(_ data: Data, requestID: ID?) throws {
        guard let response = try? JSONDecoder().decode(AnyResponse.self, from: data),
            let requestID,
            response.id == requestID
        else {
            throw MCPError.invalidRequest(
                "HTTP JSON response must contain the matching JSON-RPC response")
        }
    }

    private func decodedResponseError(from data: Data, requestID: ID?) -> MCPError? {
        guard let response = try? JSONDecoder().decode(AnyResponse.self, from: data),
            let requestID,
            response.id == requestID,
            case .failure(let error) = response.result
        else {
            return nil
        }
        return error
    }

    private func collect(_ body: AsyncThrowingStream<Data, Swift.Error>) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
        }
        return data
    }

    private func perRequestProtocolVersion(from data: Data, required: Bool) throws -> String? {
        guard case .object(let request) = try JSONDecoder().decode(Value.self, from: data),
            let parameters = request["params"]?.objectValue,
            let metadata = parameters["_meta"]?.objectValue,
            let version = metadata[ProtocolMetadataKey.protocolVersion]?.stringValue
        else {
            if required {
                throw MCPError.invalidRequest(
                    "Per-request metadata HTTP request is missing its protocol version")
            }
            return nil
        }
        return version
    }

    private func hasContentType(_ value: String, _ expected: String) -> Bool {
        value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(expected) == .orderedSame
    }

    private func httpError(_ statusCode: Int, contentType: String) -> MCPError {
        switch statusCode {
        case 400: return .internalError("Bad request")
        case 404: return .internalError("Endpoint or method not found")
        case 405: return .internalError("Method not allowed")
        case 408: return .internalError("Request timeout")
        case 429: return .internalError("Too many requests")
        case 500..<600: return .internalError("Server error: \(statusCode)")
        default:
            return .internalError(
                "Unexpected HTTP response: \(statusCode) (\(contentType))")
        }
    }

    private func probeErrorIfNeeded(
        _ error: MCPError,
        isDiscovery: Bool
    ) -> any Swift.Error {
        isDiscovery ? ProtocolLifecycleProbeError.inconclusive(error) : error
    }

    private func isRecognizedPerRequestMetadataError(
        _ error: MCPError,
        statusCode: Int
    ) -> Bool {
        if statusCode == 404, case .methodNotFound = error { return true }
        return error.code == ProtocolErrorCode.headerMismatch
            || error.code == ProtocolErrorCode.missingRequiredClientCapability
            || error.code == ProtocolErrorCode.unsupportedProtocolVersion
    }

    private func withSerializedAuthorization<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let preceding = authorizationTail
        let task = Task<Result, Swift.Error> {
            if let preceding { await preceding.value }
            try Task.checkCancellation()
            return try await operation()
        }
        authorizationTail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    #if os(Linux)
        private func processResponse(response: URLResponse, data: Data) async throws {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.contentType) ?? ""

            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            try processHTTPResponse(httpResponse, contentType: contentType)
            guard case 200..<300 = httpResponse.statusCode else { return }

            if contentType.contains(ContentType.sse) {
                logger.warning("SSE responses aren't fully supported on Linux")
                messageContinuation.yield(data)
            } else if contentType.contains(ContentType.json) {
                logger.trace("Received JSON response", metadata: ["size": "\(data.count)"])
                messageContinuation.yield(data)
            } else {
                logger.warning("Unexpected content type: \(contentType)")
            }
        }
    #else
        private func processResponse(response: URLResponse, stream: URLSession.AsyncBytes)
            async throws
        {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.contentType) ?? ""

            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            try processHTTPResponse(httpResponse, contentType: contentType)
            guard case 200..<300 = httpResponse.statusCode else { return }

            if contentType.contains(ContentType.sse) {
                logger.trace("Received SSE response, processing in streaming task")
                let hadData = try await self.processSSE(stream)

                if !hadData {
                    logger.debug("POST SSE stream closed without data, triggering GET reconnection")
                    self.activeGETSessionTask?.cancel()
                }
            } else if contentType.contains(ContentType.json) {
                var buffer = Data()
                for try await byte in stream {
                    buffer.append(byte)
                }
                logger.trace("Received JSON response", metadata: ["size": "\(buffer.count)"])
                messageContinuation.yield(buffer)
            } else {
                logger.warning("Unexpected content type: \(contentType)")
            }
        }
    #endif

    private func processHTTPResponse(_ response: HTTPURLResponse, contentType: String) throws {
        switch response.statusCode {
        case 200..<300:
            return

        case 400:
            throw MCPError.internalError("Bad request")

        case 401:
            throw HTTPAuthenticationChallengeError(
                statusCode: response.statusCode,
                headers: responseHeaders(from: response)
            )

        case 403:
            throw HTTPAuthenticationChallengeError(
                statusCode: response.statusCode,
                headers: responseHeaders(from: response)
            )

        case 404:
            if sessionID != nil {
                logger.warning("Session has expired")
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.internalError("Endpoint not found")

        case 405:
            if streaming {
                self.streamingTask?.cancel()
                throw MCPError.internalError("Server does not support streaming")
            }
            throw MCPError.internalError("Method not allowed")

        case 408:
            throw MCPError.internalError("Request timeout")

        case 429:
            throw MCPError.internalError("Too many requests")

        case 500..<600:
            throw MCPError.internalError("Server error: \(response.statusCode)")

        default:
            throw MCPError.internalError(
                "Unexpected HTTP response: \(response.statusCode) (\(contentType))")
        }
    }

    private func mapAuthenticationChallengeError(_ error: HTTPAuthenticationChallengeError) -> MCPError {
        switch error.statusCode {
        case 401:
            return MCPError.internalError("Authentication required")
        case 403:
            return MCPError.internalError("Access forbidden")
        default:
            return MCPError.internalError("HTTP authorization error: \(error.statusCode)")
        }
    }

    private func responseHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return headers
    }

    private func jsonRPCOperationKey(from data: Data) -> String? {
        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = jsonObject["method"] as? String
        else {
            return nil
        }

        let normalized = method.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// Receives data in an async sequence
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - SSE

    private func startListeningForServerEvents() async {
        #if os(Linux)
            if streaming {
                logger.warning(
                    "SSE streaming was requested but is not fully supported on Linux. SSE connection will not be attempted."
                )
            }
        #else
            guard isConnected else { return }

            if self.sessionID == nil, let signalTask = self.initialSessionIDSignalTask {
                logger.debug("⏳ Waiting for session ID to be set (timeout: \(self.sseInitializationTimeout)s)...")

                let startTime = Date()
                let timeout = self.sseInitializationTimeout
                do {
                    try await withThrowingTaskGroup { group in
                        group.addTask {
                            try await Task.sleep(for: .seconds(timeout))
                        }

                        group.addTask {
                            await signalTask.value
                        }

                        if let firstResult = try await group.next() {
                            group.cancelAll()
                            return firstResult
                        }
                    }
                } catch {
                    logger.warning("⏱️ Timeout waiting for session ID (\(timeout)s). SSE stream will proceed anyway.")
                }

                if self.sessionID != nil {
                    let elapsed = Date().timeIntervalSince(startTime)
                    logger.debug("✓ Session ID received after \(Int(elapsed * 1000))ms, proceeding with SSE connection")
                }
            } else {
                logger.debug("✓ Session ID already available, proceeding with SSE connection immediately")
            }

            var isFirstAttempt = true
            var attemptCount = 0

            logger.debug("🔄 Starting SSE retry loop", metadata: [
                "isConnected": "\(isConnected)",
                "isCancelled": "\(Task.isCancelled)"
            ])

            while isConnected && !Task.isCancelled {
                attemptCount += 1
                logger.debug("🔄 SSE retry loop iteration", metadata: [
                    "attempt": "\(attemptCount)",
                    "isFirstAttempt": "\(isFirstAttempt)"
                ])

                do {
                    if !isFirstAttempt {
                        let delayMs = self.retryInterval
                        logger.debug("⏳ Waiting before SSE reconnection", metadata: ["retryMs": "\(delayMs)"])
                        try await Task.sleep(for: .milliseconds(delayMs))
                        logger.debug("✓ Wait complete, reconnecting now")
                    }
                    isFirstAttempt = false

                    logger.debug("📡 Calling connectToEventStream (attempt #\(attemptCount))")

                    try await self.connectToEventStream()

                    logger.info("🔌 SSE stream closed gracefully, will reconnect", metadata: [
                        "attempt": "\(attemptCount)",
                        "willRetryAfter": "\(self.retryInterval)ms"
                    ])
                } catch {
                    if !Task.isCancelled {
                        logger.error("❌ SSE connection error (attempt #\(attemptCount)): \(error)")
                    } else {
                        logger.debug("⏹️ SSE task cancelled")
                    }
                }

                logger.debug("🔄 End of retry loop iteration", metadata: [
                    "isConnected": "\(isConnected)",
                    "isCancelled": "\(Task.isCancelled)",
                    "willContinue": "\(isConnected && !Task.isCancelled)"
                ])
            }

            logger.debug("⏹️ SSE retry loop exited", metadata: [
                "isConnected": "\(isConnected)",
                "isCancelled": "\(Task.isCancelled)",
                "totalAttempts": "\(attemptCount)"
            ])
        #endif
    }

    #if !os(Linux)
        private func connectToEventStream() async throws {
            guard isConnected else {
                logger.debug("⚠️ Skipping connectToEventStream - transport not connected")
                return
            }

            if let authorizer {
                do {
                    try authorizer.validateEndpointSecurity(for: endpoint)
                } catch {
                    throw MCPError.internalError(
                        "Authorization flow failed: \(error.localizedDescription)"
                    )
                }
            }

            if let authorizer {
                try? await authorizer.prepareAuthorization(for: endpoint, session: session)
            }

            logger.debug("🔌 Preparing SSE connection request")

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.addValue(ContentType.sse, forHTTPHeaderField: HTTPHeaderName.accept)
            request.addValue("no-cache", forHTTPHeaderField: HTTPHeaderName.cacheControl)

            if let protocolVersion = protocolVersion {
                request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
            }

            if let sessionID = sessionID {
                request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
            }

            if let lastEventID = lastEventID {
                request.addValue(lastEventID, forHTTPHeaderField: HTTPHeaderName.lastEventID)
                logger.info("→ Resuming SSE stream with Last-Event-ID", metadata: ["lastEventID": "\(lastEventID)"])
            } else {
                logger.info("→ Connecting to SSE stream (no last event ID to resume from)")
            }

            if let authValue = authorizer?.authorizationHeader(for: endpoint) {
                request.setValue(authValue, forHTTPHeaderField: HTTPHeaderName.authorization)
            }

            request = requestModifier(request)

            logger.debug("Starting SSE connection")

            let (stream, response) = try await session.bytes(for: request)
            self.activeGETSessionTask = stream.task

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 405 {
                    self.streamingTask?.cancel()
                }
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }

            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            defer { self.activeGETSessionTask = nil }
            try await self.processSSE(stream)
        }

        @discardableResult
        private func processSSE(_ stream: URLSession.AsyncBytes) async throws -> Bool {
            logger.debug("📥 Starting SSE event processing")
            var eventCount = 0
            var hadDataEvent = false

            for try await event in stream.events {
                eventCount += 1

                if Task.isCancelled {
                    logger.debug("⏹️ SSE processing cancelled", metadata: ["eventsProcessed": "\(eventCount)"])
                    break
                }

                logger.trace(
                    "SSE event received",
                    metadata: [
                        "type": "\(event.event ?? "message")",
                        "id": "\(event.id ?? "none")",
                    ]
                )

                if let eventID = event.id, !eventID.isEmpty {
                    self.lastEventID = eventID
                    logger.debug("Stored event ID for resumability", metadata: ["eventID": "\(eventID)"])
                }

                if let retry = event.retry {
                    self.retryInterval = retry
                    logger.debug("SSE retry interval updated", metadata: ["retryMs": "\(retry)"])
                }

                if !event.data.isEmpty, let data = event.data.data(using: .utf8) {
                    hadDataEvent = true
                    messageContinuation.yield(data)
                }
            }

            logger.debug("✓ SSE event stream completed", metadata: ["eventsProcessed": "\(eventCount)", "hadData": "\(hadDataEvent)"])
            return hadDataEvent
        }
    #endif
}

extension HTTPClientTransport: HTTPProtocolNegotiationTransport {}
