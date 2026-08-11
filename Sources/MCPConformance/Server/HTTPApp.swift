import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

package actor HTTPApp {
    /// Configuration for the HTTP application.
    package struct Configuration: Sendable {
        /// The host address to bind to.
        var host: String

        /// The port to bind to.
        var port: Int

        /// The MCP endpoint path.
        var endpoint: String

        /// Session timeout in seconds.
        var sessionTimeout: TimeInterval

        /// SSE retry interval in milliseconds for priming events.
        var retryInterval: Int?

        package init(
            host: String = "127.0.0.1",
            port: Int = 3000,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            retryInterval: Int? = nil
        ) {
            self.host = host
            self.port = port
            self.endpoint = endpoint
            self.sessionTimeout = sessionTimeout
            self.retryInterval = retryInterval
        }
    }

    /// Factory function to create MCP Server instances for each session.
    package typealias ServerFactory =
        @Sendable (String, StatefulHTTPServerTransport) async throws -> Server

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    private let validationPipeline: (any HTTPRequestValidationPipeline)?
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]
    private var lifecycleRouter: LifecycleHTTPServerRouter?

    nonisolated let logger: Logger

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    // MARK: - Init

    /// Creates a new HTTP application.
    ///
    /// - Parameters:
    ///   - configuration: Application configuration.
    ///   - validationPipeline: Custom validation pipeline passed to each transport.
    ///     If `nil`, transports use their sensible defaults.
    ///   - serverFactory: Factory function to create Server instances for each session.
    ///   - logger: Optional logger instance.
    package init(
        configuration: Configuration = Configuration(),
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        serverFactory: @escaping ServerFactory,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.validationPipeline = validationPipeline
        self.logger = logger ?? Logger(
            label: "mcp.http.app",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
    }

    /// Convenience initializer with individual parameters.
    package init(
        host: String = "127.0.0.1",
        port: Int = 3000,
        endpoint: String = "/mcp",
        serverFactory: @escaping ServerFactory,
        logger: Logger? = nil
    ) {
        self.init(
            configuration: Configuration(host: host, port: port, endpoint: endpoint),
            serverFactory: serverFactory,
            logger: logger
        )
    }

    // MARK: - Lifecycle

    /// Starts the HTTP application.
    ///
    /// This starts the NIO HTTP server and begins accepting connections.
    /// The call blocks until the server is shut down via ``stop()``.
    package func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(
                        endpoint: self.configuration.endpoint,
                        responder: { request in await self.handleHTTPRequest(request) }
                    ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        logger.info(
            "Starting MCP HTTP application",
            metadata: [
                "host": "\(configuration.host)",
                "port": "\(configuration.port)",
                "endpoint": "\(configuration.endpoint)",
            ]
        )

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.channel = channel

        Task { await sessionCleanupLoop() }

        try await channel.closeFuture.get()
    }

    /// Stops the HTTP application gracefully, closing all sessions.
    package func stop() async {
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
        logger.info("MCP HTTP application stopped")
    }

    // MARK: - Request Routing

    var endpoint: String { configuration.endpoint }

    package func installLifecycleRouter(_ router: LifecycleHTTPServerRouter) {
        lifecycleRouter = router
    }

    /// Routes an incoming HTTP request to the appropriate session transport.
    ///
    /// - Requests with a valid `Mcp-Session-Id` are forwarded to the matching transport.
    /// - POST requests with an `initialize` body create a new session.
    /// - All other requests without a session return an error.
    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if let lifecycleRouter {
            return await lifecycleRouter.handleRequest(request)
        }
        return await handleInitializationBasedHTTPRequest(request)
    }

    package func handleInitializationBasedHTTPRequest(
        _ request: HTTPRequest
    ) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Route to existing session
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            // Clean up on successful DELETE
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }

            return response
        }

        // No session — check for initialize request
        if request.method.uppercased() == "POST",
            let body = request.body,
            let kind = JSONRPCMessageKind(data: body),
            kind.isInitializeRequest
        {
            return await createSessionAndHandle(request)
        }

        // No session and not initialize
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    // MARK: - Session Management

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: configuration.retryInterval,
            logger: logger
        )

        do {
            let server = try await serverFactory(sessionID, transport)
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)

            // If transport returned an error, clean up
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
        logger.info("Closed session", metadata: ["sessionID": "\(sessionID)"])
    }

    private func closeAllSessions() async {
        for sessionID in sessions.keys {
            await closeSession(sessionID)
        }
    }

    private func sessionCleanupLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(60))

            let now = Date()
            let expired = sessions.filter { _, context in
                now.timeIntervalSince(context.lastAccessedAt) > configuration.sessionTimeout
            }

            for (sessionID, _) in expired {
                logger.info("Session expired", metadata: ["sessionID": "\(sessionID)"])
                await closeSession(sessionID)
            }
        }
    }
}

// MARK: - NIO HTTP Handler

/// Thin NIO adapter that converts between NIO HTTP types and the framework-agnostic
/// `HTTPRequest`/`HTTPResponse` types, delegating all logic to the `HTTPApp`.
final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let endpoint: String
    private let responder: @Sendable (HTTPRequest) async -> HTTPResponse

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private struct EventLoopContext: @unchecked Sendable {
        let value: ChannelHandlerContext
    }

    private var requestState: RequestState?
    private var activeRequestTasks: [UUID: Task<Void, Never>] = [:]

    init(
        endpoint: String,
        responder: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) {
        self.endpoint = endpoint
        self.responder = responder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil
            startRequest(state: state, context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        requestState = nil
        cancelActiveRequests()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Swift.Error) {
        requestState = nil
        cancelActiveRequests()
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        requestState = nil
        cancelActiveRequests()
    }

    // MARK: - Request Processing

    var activeRequestCount: Int { activeRequestTasks.count }

    private func startRequest(state: RequestState, context: ChannelHandlerContext) {
        let requestID = UUID()
        let eventLoopContext = EventLoopContext(value: context)
        let task = Task {
            defer {
                eventLoopContext.value.eventLoop.execute {
                    self.activeRequestTasks.removeValue(forKey: requestID)
                }
            }
            do {
                try await self.handleRequest(state: state, context: eventLoopContext.value)
            } catch {
                try? await self.closeChannel(context: eventLoopContext.value)
            }
        }
        activeRequestTasks[requestID] = task
    }

    private func cancelActiveRequests() {
        let tasks = Array(activeRequestTasks.values)
        activeRequestTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func handleRequest(
        state: RequestState,
        context: ChannelHandlerContext
    ) async throws {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

        guard path == endpoint else {
            try await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: head.version,
                context: context
            )
            return
        }

        let httpRequest = makeHTTPRequest(from: state)
        let response = await responder(httpRequest)
        try Task.checkCancellation()
        try await writeResponse(response, version: head.version, context: context)
    }

    // MARK: - NIO ↔ HTTPRequest/HTTPResponse Conversion

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        // Combine multiple header values per RFC 7230
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
            let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))

        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async throws {
        let statusCode = response.statusCode
        let headers = response.headers
        var head = HTTPResponseHead(
            version: version,
            status: HTTPResponseStatus(statusCode: statusCode)
        )
        for (name, value) in headers {
            head.headers.add(name: name, value: value)
        }

        switch response {
        case .stream(let stream, _):
            try await writeAndFlush(.head(head), context: context)
            var iterator = stream.makeAsyncIterator()
            while let chunk = try await iterator.next() {
                try Task.checkCancellation()
                do {
                    try await writeBody(chunk, context: context)
                } catch {
                    let writeError = error
                    withUnsafeCurrentTask { $0?.cancel() }
                    // Let the response stream observe cancellation before closing the channel.
                    _ = try? await iterator.next()
                    throw writeError
                }
            }
            try Task.checkCancellation()
            try await writeAndFlush(.end(nil), context: context)

        default:
            let bodyData = response.bodyData
            try await writeAndFlush(.head(head), context: context)
            if let bodyData {
                try await writeBody(bodyData, context: context)
            }
            try Task.checkCancellation()
            try await writeAndFlush(.end(nil), context: context)
        }
    }

    private func writeBody(
        _ data: Data,
        context: ChannelHandlerContext
    ) async throws {
        try Task.checkCancellation()
        nonisolated(unsafe) let ctx = context
        try await ctx.eventLoop.submit {
            var buffer = ctx.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            return ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))))
        }.flatMap { $0 }.get()
        try Task.checkCancellation()
    }

    private func closeChannel(context: ChannelHandlerContext) async throws {
        nonisolated(unsafe) let ctx = context
        try await ctx.eventLoop.submit {
            ctx.close()
        }.flatMap { $0 }.get()
    }

    private func writeAndFlush(
        _ part: HTTPServerResponsePart,
        context: ChannelHandlerContext
    ) async throws {
        try Task.checkCancellation()
        nonisolated(unsafe) let ctx = context
        try await ctx.eventLoop.submit {
            ctx.writeAndFlush(self.wrapOutboundOut(part))
        }.flatMap { $0 }.get()
        try Task.checkCancellation()
    }
}
