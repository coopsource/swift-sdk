import Logging

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Model Context Protocol server
public actor Server {
    /// Selects which protocol lifecycle mechanisms a server accepts.
    public enum ProtocolMode: String, Hashable, Codable, Sendable {
        /// Accept initialization-based clients only.
        case initializationOnly

        /// Accept both initialization and per-request metadata clients.
        case initializationAndPerRequestMetadata

        /// Accept per-request metadata clients only.
        case perRequestMetadataOnly
    }

    /// The server configuration
    public struct Configuration: Hashable, Codable, Sendable {
        /// The default configuration.
        public static let `default` = Configuration(strict: false)

        /// The strict configuration.
        public static let strict = Configuration(strict: true)

        /// When strict mode is enabled, the server:
        /// - Requires clients to send an initialize request before any other requests
        /// - Rejects all requests from uninitialized clients with a protocol error
        ///
        /// While the MCP specification requires clients to initialize the connection
        /// before sending other requests, some implementations may not follow this.
        /// Disabling strict mode allows the server to be more lenient with non-compliant
        /// clients, though this may lead to undefined behavior.
        public var strict: Bool

        /// The protocol lifecycle mechanisms accepted by the server.
        public var protocolMode: ProtocolMode

        /// Maximum queued messages and waiting publishers for each subscription.
        public var subscriptionBufferCapacity: Int

        public init(
            strict: Bool = false,
            protocolMode: ProtocolMode = .initializationOnly,
            subscriptionBufferCapacity: Int = 32
        ) {
            self.strict = strict
            self.protocolMode = protocolMode
            self.subscriptionBufferCapacity = subscriptionBufferCapacity
        }

        private enum CodingKeys: String, CodingKey {
            case strict, protocolMode, subscriptionBufferCapacity
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            strict = try container.decodeIfPresent(Bool.self, forKey: .strict) ?? false
            protocolMode =
                try container.decodeIfPresent(ProtocolMode.self, forKey: .protocolMode)
                ?? .initializationOnly
            subscriptionBufferCapacity =
                try container.decodeIfPresent(Int.self, forKey: .subscriptionBufferCapacity)
                ?? 32
            guard subscriptionBufferCapacity > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .subscriptionBufferCapacity,
                    in: container,
                    debugDescription: "Subscription buffer capacity must be positive"
                )
            }
        }
    }

    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The server name
        public let name: String
        /// A human-readable server title for display
        public let title: String?
        /// The server version
        public let version: String
        /// Optional description of the server
        public let description: String?
        /// Optional website URL for the server
        public let websiteUrl: String?
        /// Optional set of sized icons for display in a user interface
        public let icons: [Icon]?

        public init(
            name: String,
            version: String,
            title: String? = nil,
            description: String? = nil,
            websiteUrl: String? = nil,
            icons: [Icon]? = nil
        ) {
            self.name = name
            self.title = title
            self.version = version
            self.description = description
            self.websiteUrl = websiteUrl
            self.icons = icons
        }
    }

    /// Server capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// Resources capabilities
        public struct Resources: Hashable, Codable, Sendable {
            /// Whether the resource can be subscribed to
            public var subscribe: Bool?
            /// Whether the list of resources has changed
            public var listChanged: Bool?

            public init(
                subscribe: Bool? = nil,
                listChanged: Bool? = nil
            ) {
                self.subscribe = subscribe
                self.listChanged = listChanged
            }
        }

        /// Tools capabilities
        public struct Tools: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when tools change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Prompts capabilities
        public struct Prompts: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when prompts change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Logging capabilities
        public struct Logging: Hashable, Codable, Sendable {
            public var settings: [String: Value]

            public init(settings: [String: Value] = [:]) { self.settings = settings }
            public init(from decoder: Decoder) throws {
                settings = try [String: Value](from: decoder)
            }
            public func encode(to encoder: Encoder) throws { try settings.encode(to: encoder) }
        }

        /// Completions capabilities
        public struct Completions: Hashable, Codable, Sendable {
            public var settings: [String: Value]

            public init(settings: [String: Value] = [:]) { self.settings = settings }
            public init(from decoder: Decoder) throws {
                settings = try [String: Value](from: decoder)
            }
            public func encode(to encoder: Encoder) throws { try settings.encode(to: encoder) }
        }

        /// Completions capabilities
        public var completions: Completions?
        /// Logging capabilities
        public var logging: Logging?
        /// Prompts capabilities
        public var prompts: Prompts?
        /// Resources capabilities
        public var resources: Resources?
        /// Tools capabilities
        public var tools: Tools?
        /// Experimental, non-standard capabilities supported by the server.
        public var experimental: [String: Value]?
        /// MCP extensions supported by the server and their settings.
        public var extensions: [String: Value]?
        /// Additional capabilities not defined by this SDK version.
        public var additionalCapabilities: [String: Value]

        public init(
            completions: Completions? = nil,
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            tools: Tools? = nil,
            experimental: [String: Value]? = nil,
            extensions: [String: Value]? = nil,
            additionalCapabilities: [String: Value] = [:]
        ) {
            self.completions = completions
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.tools = tools
            self.experimental = experimental
            self.extensions = extensions
            self.additionalCapabilities = additionalCapabilities
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case completions, logging, prompts, resources, tools, experimental, extensions
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            completions = try container.decodeIfPresent(Completions.self, forKey: .completions)
            logging = try container.decodeIfPresent(Logging.self, forKey: .logging)
            prompts = try container.decodeIfPresent(Prompts.self, forKey: .prompts)
            resources = try container.decodeIfPresent(Resources.self, forKey: .resources)
            tools = try container.decodeIfPresent(Tools.self, forKey: .tools)
            experimental = try container.decodeIfPresent([String: Value].self, forKey: .experimental)
            extensions = try container.decodeIfPresent([String: Value].self, forKey: .extensions)

            let dynamicContainer = try decoder.container(
                keyedBy: ProtocolCapabilityCodingKey.self)
            let known = Set(CodingKeys.allCases.map(\.stringValue))
            additionalCapabilities = try Dictionary(uniqueKeysWithValues:
                dynamicContainer.allKeys.compactMap { key in
                    guard !known.contains(key.stringValue) else { return nil }
                    return (key.stringValue, try dynamicContainer.decode(Value.self, forKey: key))
                }
            )

            if let reason = ProtocolCapabilityValidation.invalidReason(
                experimental: experimental,
                extensions: extensions
            ) {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: reason))
            }
        }

        public func encode(to encoder: Encoder) throws {
            if let reason = ProtocolCapabilityValidation.invalidReason(
                experimental: experimental,
                extensions: extensions
            ) {
                throw EncodingError.invalidValue(
                    extensions as Any,
                    .init(codingPath: encoder.codingPath, debugDescription: reason)
                )
            }
            if let collision = additionalCapabilities.keys.first(where: {
                CodingKeys(rawValue: $0) != nil
            }) {
                throw EncodingError.invalidValue(
                    additionalCapabilities,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Additional capability conflicts with \(collision)"
                    )
                )
            }

            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(completions, forKey: .completions)
            try container.encodeIfPresent(logging, forKey: .logging)
            try container.encodeIfPresent(prompts, forKey: .prompts)
            try container.encodeIfPresent(resources, forKey: .resources)
            try container.encodeIfPresent(tools, forKey: .tools)
            try container.encodeIfPresent(experimental, forKey: .experimental)
            try container.encodeIfPresent(extensions, forKey: .extensions)

            var dynamicContainer = encoder.container(keyedBy: ProtocolCapabilityCodingKey.self)
            for (name, value) in additionalCapabilities {
                try dynamicContainer.encode(
                    value,
                    forKey: ProtocolCapabilityCodingKey(stringValue: name)!)
            }
        }
    }

    /// Server information
    private let serverInfo: Server.Info
    /// The server connection
    private var connection: (any Transport)?
    /// Versions implemented by the active transport binding, when it constrains them.
    private var transportSupportedProtocolVersions: Set<String>?
    /// The server logger
    private var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The server name
    public nonisolated var name: String { serverInfo.name }
    /// A human-readable server title
    public nonisolated var title: String? { serverInfo.title }
    /// The server version
    public nonisolated var version: String { serverInfo.version }
    /// Instructions describing how to use the server and its features
    ///
    /// This can be used by clients to improve the LLM's understanding of
    /// available tools, resources, etc.
    /// It can be thought of like a "hint" to the model.
    /// For example, this information MAY be added to the system prompt.
    public nonisolated let instructions: String?
    /// The server capabilities
    public var capabilities: Capabilities
    /// The server configuration
    public var configuration: Configuration

    /// Request handlers
    private var methodHandlers: [String: RequestHandlerBox] = [:]
    /// Notification handlers
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// Pending request tasks (for cancellation support)
    private var pendingRequestTasks: [ID: Task<Response<AnyMethod>, Error>] = [:]
    /// Requests whose dispatch has begun but whose handler task is not yet registered.
    ///
    /// A request is dispatched on its own task so the receive loop keeps reading, which leaves a
    /// window in which the request is known but has nothing to cancel. Tracking it bounds
    /// ``cancelledBeforeDispatchRequestIDs`` to requests this server actually received.
    private var dispatchingRequestIDs: Set<ID> = []
    /// Cancellations that arrived during that window, from either cancellation mechanism:
    /// a `notifications/cancelled` message, or a request-scoped transport reporting a disconnect.
    private var cancelledBeforeDispatchRequestIDs: Set<ID> = []

    /// Pending requests sent to the client, awaiting responses
    private var pendingRequests: [ID: AnyPendingRequest] = [:]

    private enum InitializationPhase {
        case notStarted
        case handling
        case responseSending
        case responseSent
        case ready
    }

    private var initializationPhase = InitializationPhase.notStarted
    private var isInitialized: Bool {
        switch initializationPhase {
        case .responseSent, .ready: true
        case .notStarted, .handling, .responseSending: false
        }
    }
    private var pendingInitializedNotification: AnyMessage?
    /// The client information
    private var clientInfo: Client.Info?
    /// The client capabilities
    private var clientCapabilities: Client.Capabilities?
    /// The protocol version
    private var protocolVersion: String?
    /// One active long-lived notification stream, keyed by its transport routing ID.
    private struct PendingSubscriptionMessage {
        let id: Int
        let data: Data
        let continuation: CheckedContinuation<Void, Swift.Error>
    }

    private struct ActiveSubscription {
        let requestID: ID
        let notifications: SubscriptionFilter
        var queuedMessages: SubscriptionQueue<Data>
        var pendingMessages: SubscriptionQueue<PendingSubscriptionMessage>
        var isDraining: Bool
        var isClosing: Bool
        let closureContinuation: AsyncThrowingStream<Void, Swift.Error>.Continuation
    }

    private var subscriptions: [ID: ActiveSubscription] = [:]
    private var nextSubscriptionMessageID = 0
    private var subscriptionClosureWaiters: [CheckedContinuation<Void, Never>] = []
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

    public init(
        name: String,
        version: String,
        title: String? = nil,
        instructions: String? = nil,
        capabilities: Server.Capabilities = .init(),
        configuration: Configuration = .default
    ) {
        self.serverInfo = Server.Info(name: name, version: version, title: title)
        self.capabilities = capabilities
        self.configuration = configuration
        self.instructions = instructions
    }

    /// Start the server
    /// - Parameters:
    ///   - transport: The transport to use for the server
    ///   - initializeHook: An optional hook that runs when the client sends an initialize request
    public func start(
        transport: any Transport,
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)? = nil
    ) async throws {
        self.connection = transport
        if let versionProvider = transport as? any TransportProtocolVersionProviding {
            transportSupportedProtocolVersions = await versionProvider.supportedProtocolVersions()
        } else {
            transportSupportedProtocolVersions = nil
        }
        registerDefaultHandlers(initializeHook: initializeHook)
        registerCancellationHandler()
        if let transport = transport as? any RequestCancellationRegistering {
            await transport.setRequestCancellationHandler { [weak self] id in
                await self?.cancelRequestFromTransport(id)
            }
        }
        try await transport.connect()

        await logger?.debug(
            "Server started", metadata: ["name": "\(name)", "version": "\(version)"]
        )

        // Start message handling loop
        task = Task {
            do {
                let stream = await transport.receive()
                for try await data in stream {
                    if Task.isCancelled { break }  // Check cancellation inside loop

                    var requestID: ID?
                    do {
                        // Attempt to decode as batch first, then as individual response, request, or notification
                        let decoder = JSONDecoder()
                        if let batch = try? decoder.decode(Server.Batch.self, from: data) {
                            try await handleBatch(batch)
                        } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                            await handleResponse(response)
                        } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            // Handle request in a separate task to avoid blocking the receive loop.
                            // Record the dispatch first: this runs without interleaving, so a
                            // cancellation read by the next loop iteration cannot arrive before the
                            // request is known.
                            beginDispatch(request.id)
                            Task {
                                _ = try? await self.handleRequest(request, sendResponse: true)
                            }
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            try await handleMessage(message)
                        } else {
                            // Try to extract request ID from raw JSON if possible
                            if let json = try? JSONDecoder().decode(
                                [String: Value].self, from: data),
                                let idValue = json["id"]
                            {
                                if let strValue = idValue.stringValue {
                                    requestID = .string(strValue)
                                } else if let intValue = idValue.intValue {
                                    requestID = .number(intValue)
                                }
                            }
                            throw MCPError.parseError("Invalid message format")
                        }
                    } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                        // Resource temporarily unavailable, retry after a short delay
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    } catch {
                        await logger?.error(
                            "Error processing message", metadata: ["error": "\(error)"])
                        let response = AnyMethod.response(
                            id: requestID ?? .random,
                            error: error as? MCPError
                                ?? MCPError.internalError(error.localizedDescription)
                        )
                        try? await send(response)
                    }
                }
            } catch {
                await logger?.error(
                    "Fatal error in message handling loop", metadata: ["error": "\(error)"])
            }
            await logger?.debug("Server finished", metadata: [:])
        }
    }

    /// Stop the server
    public func stop() async {
        await closeSubscriptionsGracefully()

        task?.cancel()
        task = nil

        // Clear pending requests with errors
        let pendingRequestsToCancel = self.pendingRequests
        self.pendingRequests = [:]
        for (_, request) in pendingRequestsToCancel {
            request.resume(throwing: MCPError.internalError("Server disconnected"))
        }

        if let connection = connection {
            if let connection = connection as? any RequestCancellationRegistering {
                await connection.setRequestCancellationHandler(nil)
            }
            await connection.disconnect()
        }
        connection = nil
        transportSupportedProtocolVersions = nil
        dispatchingRequestIDs.removeAll()
        cancelledBeforeDispatchRequestIDs.removeAll()
    }

    public func waitUntilCompleted() async {
        await task?.value
    }

    // MARK: - Request Context

    /// Per-dispatch context the SDK attaches to the currently executing handler.
    ///
    /// Exposed via the ``Server/currentHandlerContext`` task-local so method
    /// handlers can observe the originating HTTP request (headers, auth, path,
    /// body) without changing the `withMethodHandler` signature.
    public struct HandlerContext: Sendable {
        /// The JSON-RPC request id of the in-flight request. SDK-internal use
        /// (e.g. transports closing an SSE stream mid-call per SEP-1699).
        package let id: ID

        /// The JSON-RPC request ID supplied by the client.
        ///
        /// This differs from the package-level routing ID only when a transport isolates
        /// requests from independent clients that chose the same JSON-RPC ID.
        public let requestID: ID

        /// The originating HTTP request, if the active transport conforms to
        /// ``HTTPContextProviding``. `nil` for transports that don't carry HTTP
        /// context (stdio, in-memory) or for handlers reached off the dispatch
        /// path.
        public let httpContext: HTTPRequest?

        /// The lifecycle mechanism used for this request.
        public let protocolLifecycle: ProtocolLifecycle

        /// The protocol version selected for this request or initialized connection.
        public let protocolVersion: String?

        /// Self-reported client information supplied for this request, when present.
        public let clientInfo: Client.Info?

        /// Client capabilities supplied for this request or initialized connection.
        public let clientCapabilities: Client.Capabilities?

        /// Minimum log level requested for this request, when present.
        public let logLevel: LogLevel?

        /// The method being handled.
        public let method: String?

        package init(
            id: ID,
            requestID: ID? = nil,
            httpContext: HTTPRequest?,
            protocolLifecycle: ProtocolLifecycle = .initializationBased,
            protocolVersion: String? = nil,
            clientInfo: Client.Info? = nil,
            clientCapabilities: Client.Capabilities? = nil,
            logLevel: LogLevel? = nil,
            method: String? = nil
        ) {
            self.id = id
            self.requestID = requestID ?? id
            self.httpContext = httpContext
            self.protocolLifecycle = protocolLifecycle
            self.protocolVersion = protocolVersion
            self.clientInfo = clientInfo
            self.clientCapabilities = clientCapabilities
            self.logLevel = logLevel
            self.method = method
        }
    }

    /// The handler context for the currently executing method handler.
    ///
    /// Set via `@TaskLocal` before dispatching each request, so it propagates
    /// automatically into the handler task. `nil` outside of a handler.
    ///
    /// When spawning `Task.detached { … }` from inside a handler, capture the
    /// value up front — detached tasks do not inherit task-locals:
    ///
    /// ```swift
    /// let ctx = Server.currentHandlerContext
    /// Task.detached { await doWork(with: ctx?.httpContext) }
    /// ```
    @TaskLocal public static var currentHandlerContext: HandlerContext? = nil

    // MARK: - Registration

    /// Register a method handler
    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        methodHandlers[M.name] = TypedRequestHandler { (request: Request<M>) -> Response<M> in
            let result = try await handler(request.params)
            return Response(id: request.id, result: result)
        }
        return self
    }

    /// Registers a handler that may request embedded client input before completing.
    @discardableResult
    public func withMultiRoundTripHandler<M: MultiRoundTripMethod>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> MultiRoundTripResult<M.Result>
    ) -> Self {
        methodHandlers[M.name] = MultiRoundTripRequestHandler {
            (request: Request<M>) -> MultiRoundTripResult<M.Result> in
            try await handler(request.params)
        }
        return self
    }

    /// Register a notification handler
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) -> Self {
        let handlers = notificationHandlers[N.name, default: []]
        notificationHandlers[N.name] = handlers + [TypedNotificationHandler(handler)]
        return self
    }

    // MARK: - Sending

    /// Send a response to a request
    public func send<M: Method>(_ response: Response<M>) async throws {
        try await send(response, protocolLifecycle: Server.currentHandlerContext?.protocolLifecycle)
    }

    private func send<M: Method>(
        _ response: Response<M>,
        protocolLifecycle: ProtocolLifecycle?
    ) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let responseData: Data
        if protocolLifecycle == .perRequestMetadata {
            responseData = try PerRequestMetadataWire.encodeResponse(
                response, serverInfo: serverInfo, using: encoder)
        } else {
            responseData = try encoder.encode(response)
        }
        try await connection.send(responseData)
    }

    /// Send a notification to connected clients
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let notificationData = try encoder.encode(notification)
        if configuration.protocolMode == .initializationOnly
            || Server.currentHandlerContext?.protocolLifecycle == .initializationBased
            || (Server.currentHandlerContext == nil && isInitialized)
        {
            try await connection.send(notificationData)
            return
        }

        if selectedSubscriptionNotificationMethod(notification.method) {
            try await enqueueSubscriptionNotification(notificationData)
            return
        }

        if notification.method == LogMessageNotification.name {
            guard let context = Server.currentHandlerContext,
                context.protocolLifecycle == .perRequestMetadata,
                context.method != SubscriptionsListen.name,
                let requestedLevel = context.logLevel,
                let parameters = try? JSONDecoder().decode(
                    Message<LogMessageNotification>.self,
                    from: notificationData
                ).params,
                parameters.level.isAtLeast(requestedLevel)
            else {
                return
            }
        }

        if let context = Server.currentHandlerContext,
            context.protocolLifecycle == .perRequestMetadata
        {
            if let connection = connection as? any RequestScopedSending {
                try await connection.send(notificationData, relatedTo: context.id)
            } else {
                try await connection.send(notificationData)
            }
            return
        }

        if configuration.protocolMode == .perRequestMetadataOnly {
            throw MCPError.invalidRequest(
                "Per-request-metadata notifications must relate to a request or subscription")
        }
        try await connection.send(notificationData)
    }

    /// Send a request to the client and return a Task for the response
    private func send<M: Method>(_ request: Request<M>) throws -> Task<M.Result, Error> {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }
        try validateStandaloneServerRequest()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let requestData = try encoder.encode(request)

        let requestTask = Task<M.Result, Error> {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    // Add pending response before sending
                    self.addPendingResponse(
                        id: request.id,
                        continuation: continuation,
                        type: M.Result.self
                    )

                    // Send the request
                    do {
                        try await connection.send(requestData)
                    } catch {
                        // If send fails, remove pending response and resume with error
                        if self.removePendingResponse(id: request.id) != nil {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }

        return requestTask
    }

    private func validateStandaloneServerRequest() throws {
        if Server.currentHandlerContext?.protocolLifecycle == .perRequestMetadata {
            throw MCPError.invalidRequest(
                "Standalone server requests are not supported by per-request metadata")
        }

        switch configuration.protocolMode {
        case .perRequestMetadataOnly:
            throw MCPError.invalidRequest(
                "Standalone server requests are not supported by per-request metadata")
        case .initializationAndPerRequestMetadata:
            guard protocolVersion != nil else {
                throw MCPError.invalidRequest(
                    "Standalone server requests require an initialization-based connection")
            }
        case .initializationOnly:
            break
        }
    }

    /// Send a request and await its response
    private func sendAndAwait<M: Method>(_ request: Request<M>) async throws -> M.Result {
        let task = try send(request)
        return try await task.value
    }

    private func addPendingResponse<T: Sendable & Decodable>(
        id: ID,
        continuation: CheckedContinuation<T, Swift.Error>,
        type: T.Type
    ) {
        pendingRequests[id] = AnyPendingRequest(
            PendingRequest(continuation: continuation)
        )
    }

    private func removePendingResponse(id: ID) -> AnyPendingRequest? {
        return pendingRequests.removeValue(forKey: id)
    }

    // MARK: - Sampling

    /// Request sampling from the connected client
    ///
    /// Sampling allows servers to request LLM completions through the client,
    /// enabling sophisticated agentic behaviors while maintaining human-in-the-loop control.
    ///
    /// The sampling flow follows these steps:
    /// 1. Server sends a `sampling/createMessage` request to the client
    /// 2. Client reviews the request and can modify it
    /// 3. Client samples from an LLM
    /// 4. Client reviews the completion
    /// 5. Client returns the result to the server
    ///
    /// - Parameters:
    ///   - messages: The conversation history to send to the LLM
    ///   - modelPreferences: Model selection preferences
    ///   - systemPrompt: Optional system prompt
    ///   - includeContext: What MCP context to include
    ///   - temperature: Controls randomness (0.0 to 1.0)
    ///   - maxTokens: Maximum tokens to generate
    ///   - stopSequences: Array of sequences that stop generation
    ///   - _meta: Optional request metadata
    /// - Returns: The sampling result containing the model used, stop reason, role, and content
    /// - Throws: MCPError if the request fails
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/sampling#how-sampling-works
    public func requestSampling(
        messages: [Sampling.Message],
        modelPreferences: Sampling.ModelPreferences? = nil,
        systemPrompt: String? = nil,
        includeContext: Sampling.ContextInclusion? = nil,
        temperature: Double? = nil,
        maxTokens: Int,
        stopSequences: [String]? = nil,
        _meta: Metadata? = nil
    ) async throws -> CreateSamplingMessage.Result {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.sampling, "Sampling")

        let request = CreateSamplingMessage.request(
            .init(
                messages: messages,
                modelPreferences: modelPreferences,
                systemPrompt: systemPrompt,
                includeContext: includeContext,
                temperature: temperature,
                maxTokens: maxTokens,
                stopSequences: stopSequences,
                _meta: _meta
            )
        )

        let result = try await sendAndAwait(request)
        return result
    }

    // MARK: - Elicitation

    /// Request user input from the client using form-based elicitation
    ///
    /// Elicitation allows servers to request user input during operations.
    /// This is useful for collecting user feedback, confirmations, or data
    /// that the server needs but doesn't have.
    ///
    /// The flow:
    /// 1. Server requests elicitation with a message and optional schema
    /// 2. Client displays the request to the user
    /// 3. User provides input or declines
    /// 4. Client returns the result to the server
    ///
    /// - Parameters:
    ///   - message: The message to display to the user
    ///   - mode: The elicitation mode (form or url)
    ///   - requestedSchema: Optional JSON schema describing the expected response
    ///   - _meta: Optional request metadata
    /// - Returns: The elicitation result containing the action and optional content
    /// - Throws: MCPError if the request fails
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/elicitation
    public func requestElicitation(
        message: String,
        requestedSchema: Elicitation.RequestSchema,
        mode: Elicitation.Mode? = nil,
        _meta: Metadata? = nil
    ) async throws -> CreateElicitation.Result {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.elicitation, "Elicitation")

        let request = CreateElicitation.request(
            .form(
                .init(
                    message: message,
                    mode: mode,
                    requestedSchema: requestedSchema,
                    _meta: _meta
                )
            )
        )

        let result = try await sendAndAwait(request)
        return result
    }

    /// Request user input from the client using URL-based elicitation
    ///
    /// URL-based elicitation directs the user to an external URL for authentication
    /// or data collection. This is useful for OAuth flows or other web-based input.
    ///
    /// - Parameters:
    ///   - message: The message to display to the user
    ///   - url: The URL to direct the user to
    ///   - elicitationId: Unique identifier for this elicitation
    ///   - _meta: Optional request metadata
    /// - Returns: The elicitation result containing the action and optional content
    /// - Throws: MCPError if the request fails
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/elicitation
    public func requestElicitation(
        message: String,
        url: String,
        elicitationId: String,
        _meta: Metadata? = nil
    ) async throws -> CreateElicitation.Result {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.elicitation, "Elicitation")

        let request = CreateElicitation.request(
            .url(
                .init(
                    message: message,
                    url: url,
                    elicitationId: elicitationId,
                    _meta: _meta
                )
            )
        )

        let result = try await sendAndAwait(request)
        return result
    }

    // MARK: - Logging

    /// Send a log message notification to connected clients.
    ///
    /// Servers that declare the `logging` capability can send structured log messages
    /// to clients. The client controls which severity levels it wants to receive via
    /// the `logging/setLevel` request.
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: Optional logger name to identify the source
    ///   - data: Arbitrary JSON-serializable data for the log message
    /// - Throws: MCPError if the server is not connected
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
    public func log(
        level: LogLevel,
        logger: String? = nil,
        data: Value
    ) async throws {
        let notification = LogMessageNotification.message(
            .init(level: level, logger: logger, data: data)
        )
        try await notify(notification)
    }

    /// Send a log message notification with codable data.
    ///
    /// Convenience method that encodes data to JSON before sending.
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: Optional logger name to identify the source
    ///   - data: Any codable data for the log message
    /// - Throws: MCPError if the server is not connected or encoding fails
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
    public func log<T: Codable>(
        level: LogLevel,
        logger: String? = nil,
        data: T
    ) async throws {
        let value = try Value(data)
        try await log(level: level, logger: logger, data: value)
    }

    // MARK: - Roots

    /// Request the list of roots from the connected client
    ///
    /// Roots define filesystem boundaries that servers can operate within.
    /// The client must have declared the `roots` capability and registered
    /// a roots handler for this to work.
    ///
    /// - Returns: Array of Root objects representing accessible directories/files
    /// - Throws: MCPError if the client doesn't support roots or request fails
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
    public func listRoots() async throws -> [Root] {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.roots, "Roots")

        let request = ListRoots.request()
        let result = try await sendAndAwait(request)
        return result.roots
    }

    /// A JSON-RPC batch containing multiple requests and/or notifications
    struct Batch: Sendable {
        /// An item in a JSON-RPC batch
        enum Item: Sendable {
            case request(Request<AnyMethod>)
            case notification(Message<AnyNotification>)

        }

        var items: [Item]

        init(items: [Item]) {
            self.items = items
        }
    }

    /// Process a batch of requests and/or notifications
    private func handleBatch(_ batch: Batch) async throws {
        await logger?.trace("Processing batch request", metadata: ["size": "\(batch.items.count)"])

        if batch.items.isEmpty {
            // Empty batch is invalid according to JSON-RPC spec
            let error = MCPError.invalidRequest("Batch array must not be empty")
            let response = AnyMethod.response(id: .random, error: error)
            try await send(response)
            return
        }

        // Process each item in the batch and collect responses
        var responses: [Response<AnyMethod>] = []
        var includesInitializationResponse = false

        for item in batch.items {
            do {
                switch item {
                case .request(let request):
                    // For batched requests, collect responses instead of sending immediately
                    if let response = try await handleRequest(request, sendResponse: false) {
                        responses.append(response)
                        if request.method == Initialize.name,
                            case .success = response.result
                        {
                            includesInitializationResponse = true
                        }
                    }

                case .notification(let notification):
                    // Handle notification (no response needed)
                    try await handleMessage(notification)
                }
            } catch {
                // Only add errors to response for requests (notifications don't have responses)
                if case .request(let request) = item {
                    let mcpError =
                        error as? MCPError ?? MCPError.internalError(error.localizedDescription)
                    responses.append(AnyMethod.response(id: request.id, error: mcpError))
                }
            }
        }

        // Send collected responses if any
        if !responses.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let responseData = try encoder.encode(responses)

            guard let connection = connection else {
                throw MCPError.internalError("Server connection not initialized")
            }

            if includesInitializationResponse {
                beginInitializationResponseSend()
            }
            do {
                try await connection.send(responseData)
            } catch {
                if includesInitializationResponse { resetInitialization() }
                throw error
            }
            if includesInitializationResponse {
                try await finishInitializationResponseSend()
            }
        }
    }

    // MARK: - Request and Message Handling

    /// Handle a request and either send the response immediately or return it
    ///
    /// - Parameters:
    ///   - request: The request to handle
    ///   - sendResponse: Whether to send the response immediately (true) or return it (false)
    /// - Returns: The response when sendResponse is false
    private func handleRequest(_ request: Request<AnyMethod>, sendResponse: Bool = true)
        async throws -> Response<AnyMethod>?
    {
        // Callers that do not go through the receive loop still need the request to be known
        // before the first suspension point, so a cancellation cannot arrive with nothing to find.
        dispatchingRequestIDs.insert(request.id)
        defer { dispatchingRequestIDs.remove(request.id) }

        // Check if this is a pre-processed error request (empty method)
        if request.method.isEmpty && !sendResponse {
            // This is a placeholder for an invalid request that couldn't be parsed in batch mode
            return AnyMethod.response(
                id: request.id,
                error: MCPError.invalidRequest("Invalid batch item format")
            )
        }

        await logger?.trace(
            "Processing request",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ])

        let handlerContext: HandlerContext
        do {
            handlerContext = try await makeHandlerContext(for: request)
        } catch {
            let mcpError = error as? MCPError ?? MCPError.internalError(error.localizedDescription)
            let response = AnyMethod.response(id: request.id, error: mcpError)
            if sendResponse {
                try await send(response, protocolLifecycle: nil)
                return nil
            }
            return response
        }

        if configuration.strict && handlerContext.protocolLifecycle == .initializationBased {
            // The client SHOULD NOT send requests other than pings
            // before the server has responded to the initialize request.
            switch request.method {
            case Initialize.name, Ping.name:
                break
            default:
                try checkInitialized()
            }
        }

        // Cancellation can race dispatch: a `notifications/cancelled` message can be handled, or a
        // request-scoped HTTP response closed, before this request registers its handler task. If
        // that happened, do not start the work.
        if cancelledBeforeDispatchRequestIDs.remove(request.id) != nil {
            return nil
        }

        // Find handler for method name
        guard let handler = methodHandlers[request.method] else {
            let error = MCPError.methodNotFound("Unknown method: \(request.method)")
            let response = AnyMethod.response(id: request.id, error: error)

            if sendResponse {
                do {
                    try await send(
                        response, protocolLifecycle: handlerContext.protocolLifecycle)
                    if request.method == SubscriptionsListen.name {
                        removeSubscription(request.id)
                    }
                } catch {
                    if request.method == SubscriptionsListen.name {
                        removeSubscription(request.id)
                    }
                    throw error
                }
                return nil
            }

            return response
        }

        // Create a task to handle the request with cancellation support.
        // Set currentHandlerContext as a task local so handlers see it.
        var handlerTask: Task<Response<AnyMethod>, Error>!
        Server.$currentHandlerContext.withValue(handlerContext) {
            handlerTask = Task<Response<AnyMethod>, Error> {
                do {
                    // Check if task was cancelled before starting
                    try Task.checkCancellation()

                    // Handle request and get response
                    let response = try await handler(request)
                    return response
                } catch is CancellationError {
                    // Request was cancelled, don't send a response per MCP spec
                    await logger?.debug(
                        "Request cancelled",
                        metadata: ["id": "\(request.id)", "method": "\(request.method)"]
                    )
                    throw CancellationError()
                } catch {
                    let mcpError =
                        error as? MCPError ?? MCPError.internalError(error.localizedDescription)
                    return AnyMethod.response(id: request.id, error: mcpError)
                }
            }
        }

        // Store the handler task for potential cancellation
        pendingRequestTasks[request.id] = handlerTask

        // Ensure cleanup happens regardless of success or failure
        defer {
            pendingRequestTasks.removeValue(forKey: request.id)
        }

        do {
            let response = try await handlerTask.value

            if sendResponse {
                if request.method == Initialize.name {
                    beginInitializationResponseSend()
                }
                do {
                    try await send(
                        response, protocolLifecycle: handlerContext.protocolLifecycle)
                    if request.method == Initialize.name {
                        try await finishInitializationResponseSend()
                    }
                    if request.method == SubscriptionsListen.name {
                        removeSubscription(request.id)
                    }
                } catch {
                    if request.method == Initialize.name {
                        resetInitialization()
                    }
                    if request.method == SubscriptionsListen.name {
                        removeSubscription(request.id)
                    }
                    throw error
                }
                return nil
            }

            return response
        } catch is CancellationError {
            // Request was cancelled, don't send a response per MCP spec
            if request.method == SubscriptionsListen.name {
                removeSubscription(request.id)
            }
            return nil
        } catch {
            // This should not happen as errors are caught in the task
            if request.method == Initialize.name {
                resetInitialization()
            }
            let mcpError = error as? MCPError ?? MCPError.internalError(error.localizedDescription)
            let response = AnyMethod.response(id: request.id, error: mcpError)

            if sendResponse {
                try await send(
                    response, protocolLifecycle: handlerContext.protocolLifecycle)
                return nil
            }

            return response
        }
    }

    private func makeHandlerContext(for request: AnyRequest) async throws -> HandlerContext {
        let httpContext = await (connection as? any HTTPContextProviding)?
            .httpRequestContext(for: request.id)
        let originalRequestID = await (connection as? any OriginalRequestIDProviding)?
            .originalRequestID(for: request.id) ?? request.id
        let carriesPerRequestMetadata =
            PerRequestMetadataWire.containsLifecycleMetadata(request)

        switch configuration.protocolMode {
        case .initializationOnly:
            if request.method == Discover.name {
                throw MCPError.methodNotFound("Unknown method: \(request.method)")
            }
            return HandlerContext(
                id: request.id,
                requestID: originalRequestID,
                httpContext: httpContext,
                protocolLifecycle: .initializationBased,
                protocolVersion: protocolVersion,
                clientInfo: clientInfo,
                clientCapabilities: clientCapabilities,
                method: request.method
            )

        case .initializationAndPerRequestMetadata:
            if !carriesPerRequestMetadata {
                return HandlerContext(
                    id: request.id,
                    requestID: originalRequestID,
                    httpContext: httpContext,
                    protocolLifecycle: .initializationBased,
                    protocolVersion: protocolVersion,
                    clientInfo: clientInfo,
                    clientCapabilities: clientCapabilities,
                    method: request.method
                )
            }

        case .perRequestMetadataOnly:
            if !carriesPerRequestMetadata {
                if request.method == Initialize.name {
                    throw MCPError.methodNotFound(
                        "initialize is not supported; supported protocol versions: "
                            + supportedProtocolVersions.joined(separator: ", "))
                }
                throw MCPError.invalidParams(
                    "Request is missing required per-request protocol metadata")
            }
        }

        let metadata = try PerRequestMetadataWire.decodeRequestMetadata(from: request)
        guard Version.perRequestMetadataSupported.contains(metadata.protocolVersion) else {
            throw MCPError.remote(
                code: ProtocolErrorCode.unsupportedProtocolVersion,
                message: "Unsupported protocol version",
                data: try? Value(UnsupportedProtocolVersionData(
                    supported: supportedProtocolVersions,
                    requested: metadata.protocolVersion
                ))
            )
        }

        // `initialize` opens the initialization-based lifecycle. A request that carries
        // per-request metadata has already selected the other lifecycle, so it must not
        // reach the initialization state machine.
        if request.method == Initialize.name {
            throw MCPError.methodNotFound(
                "initialize is not part of the per-request-metadata lifecycle")
        }
        switch request.method {
        case Ping.name, SetLoggingLevel.name, ResourceSubscribe.name, ResourceUnsubscribe.name:
            throw MCPError.methodNotFound(
                "\(request.method) is not part of protocol version \(metadata.protocolVersion)")
        default:
            break
        }

        return HandlerContext(
            id: request.id,
            requestID: originalRequestID,
            httpContext: httpContext,
            protocolLifecycle: .perRequestMetadata,
            protocolVersion: metadata.protocolVersion,
            clientInfo: metadata.clientInfo,
            clientCapabilities: metadata.clientCapabilities,
            logLevel: metadata.logLevel,
            method: request.method
        )
    }

    private var supportedProtocolVersions: [String] {
        let lifecycleVersions: Set<String> = switch configuration.protocolMode {
        case .initializationOnly:
            Version.supported(for: .initializationBased)
        case .initializationAndPerRequestMetadata:
            Version.supported
        case .perRequestMetadataOnly:
            Version.supported(for: .perRequestMetadata)
        }

        let effectiveVersions = if let transportSupportedProtocolVersions {
            lifecycleVersions.intersection(transportSupportedProtocolVersions)
        } else {
            lifecycleVersions
        }
        return Version.preferenceOrder.filter(effectiveVersions.contains)
    }

    private func handleMessage(_ message: Message<AnyNotification>) async throws {
        await logger?.trace(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        if message.method == InitializedNotification.name {
            guard configuration.protocolMode != .perRequestMetadataOnly else {
                throw MCPError.invalidRequest(
                    "notifications/initialized is not defined for per-request metadata")
            }
            if initializationPhase == .responseSending {
                pendingInitializedNotification = message
                return
            }
            if configuration.strict {
                guard initializationPhase == .responseSent else {
                    throw MCPError.invalidRequest(
                        "notifications/initialized must follow the initialize response")
                }
            }
            if initializationPhase == .responseSent {
                initializationPhase = .ready
            }
        } else if configuration.strict {
            let isRelatedPerRequestCancellation =
                configuration.protocolMode == .initializationAndPerRequestMetadata
                && correlatedCancellationRequestID(in: message).map {
                    pendingRequestTasks[$0] != nil
                } == true
            if !isRelatedPerRequestCancellation {
                try checkInitialized()
            }
        }

        // Find notification handlers for this method
        guard let handlers = notificationHandlers[message.method] else { return }

        // Convert notification parameters to concrete type and call handlers
        for handler in handlers {
            do {
                try await handler(message)
            } catch {
                await logger?.error(
                    "Error handling notification",
                    metadata: [
                        "method": "\(message.method)",
                        "error": "\(error)",
                    ])
            }
        }
    }

    private func handleResponse(_ response: Response<AnyMethod>) async {
        if let pendingRequest = self.removePendingResponse(id: response.id) {
            switch response.result {
            case .success(let value):
                pendingRequest.resume(returning: value)
            case .failure(let error):
                pendingRequest.resume(throwing: error)
            }
        } else {
            await logger?.warning(
                "Received response for unknown request",
                metadata: ["id": "\(response.id)"]
            )
        }
    }

    private func checkInitialized() throws {
        guard isInitialized else {
            throw MCPError.invalidRequest("Server is not initialized")
        }
    }

    private func correlatedCancellationRequestID(in message: AnyMessage) -> ID? {
        guard message.method == CancelledNotification.name,
            let value = message.params.objectValue?["requestId"]
        else {
            return nil
        }
        if let string = value.stringValue { return .string(string) }
        if let number = value.intValue { return .number(number) }
        return nil
    }

    /// Validate the client capabilities.
    /// Throws an error if the server is configured to be strict and the capability is not supported.
    private func validateClientCapability<T>(
        _ keyPath: KeyPath<Client.Capabilities, T?>,
        _ name: String
    )
        throws
    {
        if configuration.strict {
            guard let capabilities = clientCapabilities else {
                throw MCPError.methodNotFound("Client capabilities not initialized")
            }
            guard capabilities[keyPath: keyPath] != nil else {
                throw MCPError.methodNotFound("\(name) is not supported by the client")
            }
        }
    }

    private func registerDefaultHandlers(
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)?
    ) {
        // Initialize
        withMethodHandler(Initialize.self) { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Server was deallocated")
            }

            guard await self.beginInitialization() else {
                throw MCPError.invalidRequest("Server is already initialized")
            }

            do {
                // Call initialization hook if registered
                if let hook = initializeHook {
                    try await hook(params.clientInfo, params.capabilities)
                }

                // Perform version negotiation
                let clientRequestedVersion = params.protocolVersion
                let initializationVersions = Set(await self.supportedProtocolVersions)
                    .intersection(Version.supported(for: .initializationBased))
                guard let negotiatedProtocolVersion = Version.negotiate(
                    clientRequestedVersion: clientRequestedVersion,
                    supportedVersions: initializationVersions
                ) else {
                    throw MCPError.methodNotFound(
                        "initialize is not supported by the active transport binding")
                }

                // Set initial state with the negotiated protocol version
                await self.setInitialState(
                    clientInfo: params.clientInfo,
                    clientCapabilities: params.capabilities,
                    protocolVersion: negotiatedProtocolVersion
                )

                return Initialize.Result(
                    protocolVersion: negotiatedProtocolVersion,
                    capabilities: await self.capabilities,
                    serverInfo: self.serverInfo,
                    instructions: self.instructions
                )
            } catch {
                await self.resetInitialization()
                throw error
            }
        }

        // Discovery
        withMethodHandler(Discover.self) { [weak self] _ in
            guard let self = self else {
                throw MCPError.internalError("Server was deallocated")
            }
            guard await self.configuration.protocolMode != .initializationOnly else {
                throw MCPError.methodNotFound("Unknown method: \(Discover.name)")
            }

            return Discover.Result(
                supportedVersions: await self.supportedProtocolVersions,
                capabilities: await self.capabilities,
                instructions: self.instructions,
                ttlMs: 0,
                cacheScope: .public,
                _meta: Metadata(additionalFields: [
                    ProtocolMetadataKey.serverInfo: try Value(self.serverInfo)
                ])
            )
        }

        // Long-lived notification streams
        withMethodHandler(SubscriptionsListen.self) { [weak self] parameters in
            guard let self else {
                throw MCPError.internalError("Server was deallocated")
            }
            return try await self.handleSubscriptionListen(parameters)
        }

        // Ping
        withMethodHandler(Ping.self) { _ in return Empty() }
    }

    private func handleSubscriptionListen(
        _ parameters: SubscriptionsListen.Parameters
    ) async throws -> SubscriptionsListen.Result {
        guard let context = Server.currentHandlerContext,
            context.protocolLifecycle == .perRequestMetadata,
            let connection
        else {
            throw MCPError.methodNotFound(
                "subscriptions/listen requires the per-request-metadata lifecycle")
        }
        guard configuration.subscriptionBufferCapacity > 0 else {
            throw MCPError.invalidParams("Subscription buffer capacity must be positive")
        }

        let accepted = acceptedSubscriptionFilter(parameters.notifications)
        let acknowledgment = SubscriptionsAcknowledgedNotification.message(.init(
            subscriptionID: context.requestID,
            notifications: accepted
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let acknowledgmentData = try encoder.encode(acknowledgment)

        let (closure, closureContinuation) =
            AsyncThrowingStream<Void, Swift.Error>.makeStream()
        subscriptions[context.id] = ActiveSubscription(
            requestID: context.requestID,
            notifications: accepted,
            queuedMessages: SubscriptionQueue([acknowledgmentData]),
            pendingMessages: SubscriptionQueue(),
            isDraining: false,
            isClosing: false,
            closureContinuation: closureContinuation
        )
        beginDrainingSubscription(context.id, connection: connection)

        do {
            try await withTaskCancellationHandler {
                for try await _ in closure {}
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.cancelSubscription(context.id) }
            }
        } catch {
            cancelSubscription(context.id)
            throw error
        }

        return SubscriptionsListen.Result(subscriptionID: context.requestID)
    }

    private func acceptedSubscriptionFilter(_ requested: SubscriptionFilter)
        -> SubscriptionFilter
    {
        let resources = capabilities.resources
        let resourceSubscriptions: [String]?
        if resources?.subscribe == true,
            let requestedResources = requested.resourceSubscriptions,
            !requestedResources.isEmpty
        {
            resourceSubscriptions = requestedResources
        } else {
            resourceSubscriptions = nil
        }

        return SubscriptionFilter(
            toolsListChanged: capabilities.tools?.listChanged == true
                && requested.toolsListChanged == true ? true : nil,
            promptsListChanged: capabilities.prompts?.listChanged == true
                && requested.promptsListChanged == true ? true : nil,
            resourcesListChanged: resources?.listChanged == true
                && requested.resourcesListChanged == true ? true : nil,
            resourceSubscriptions: resourceSubscriptions
        )
    }

    private func selectedSubscriptionNotificationMethod(_ method: String) -> Bool {
        switch method {
        case ToolListChangedNotification.name,
            PromptListChangedNotification.name,
            ResourceListChangedNotification.name,
            ResourceUpdatedNotification.name:
            return true
        default:
            return false
        }
    }

    private func enqueueSubscriptionNotification(_ data: Data) async throws {
        guard let message = try? JSONDecoder().decode(AnyMessage.self, from: data) else {
            throw MCPError.invalidRequest("Subscription notification is malformed")
        }
        guard let connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        var selectedMessages: [(ID, Data)] = []
        for routingID in Array(subscriptions.keys) {
            guard let subscription = subscriptions[routingID],
                !subscription.isClosing,
                subscription.notifications.permits(
                    method: message.method,
                    parameters: message.params
                )
            else {
                continue
            }
            selectedMessages.append((
                routingID,
                try Self.addingSubscriptionID(subscription.requestID, to: data)
            ))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (routingID, message) in selectedMessages {
                group.addTask {
                    try await self.enqueueSubscriptionMessage(
                        message,
                        routingID: routingID,
                        connection: connection
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    private func enqueueSubscriptionMessage(
        _ data: Data,
        routingID: ID,
        connection: any Transport
    ) async throws {
        guard var subscription = subscriptions[routingID], !subscription.isClosing else {
            return
        }
        if subscription.pendingMessages.isEmpty,
            subscription.queuedMessages.count < configuration.subscriptionBufferCapacity
        {
            subscription.queuedMessages.append(data)
            subscriptions[routingID] = subscription
            beginDrainingSubscription(routingID, connection: connection)
            return
        }

        let messageID = nextSubscriptionMessageID
        nextSubscriptionMessageID += 1
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Swift.Error>) in
                guard var current = subscriptions[routingID], !current.isClosing else {
                    continuation.resume(throwing: MCPError.connectionClosed)
                    return
                }
                if current.pendingMessages.isEmpty,
                    current.queuedMessages.count < configuration.subscriptionBufferCapacity
                {
                    current.queuedMessages.append(data)
                    subscriptions[routingID] = current
                    continuation.resume()
                    beginDrainingSubscription(routingID, connection: connection)
                    return
                }
                guard current.pendingMessages.count < configuration.subscriptionBufferCapacity
                else {
                    continuation.resume(throwing: MCPError.internalError(
                        "Subscription publisher buffer is full"
                    ))
                    return
                }
                current.pendingMessages.append(PendingSubscriptionMessage(
                    id: messageID,
                    data: data,
                    continuation: continuation
                ))
                subscriptions[routingID] = current
            }
        }, onCancel: {
            Task {
                await self.cancelPendingSubscriptionMessage(
                    messageID,
                    routingID: routingID
                )
            }
        })
        try Task.checkCancellation()
    }

    private func beginDrainingSubscription(
        _ routingID: ID,
        connection: any Transport
    ) {
        guard var subscription = subscriptions[routingID], !subscription.isDraining else {
            return
        }
        subscription.isDraining = true
        subscriptions[routingID] = subscription
        Task { await self.drainSubscription(routingID, connection: connection) }
    }

    private func drainSubscription(
        _ routingID: ID,
        connection: any Transport
    ) async {
        while var subscription = subscriptions[routingID] {
            guard !subscription.queuedMessages.isEmpty else {
                subscription.isDraining = false
                subscriptions[routingID] = subscription
                if subscription.isClosing {
                    subscription.closureContinuation.finish()
                }
                return
            }

            guard let data = subscription.queuedMessages.popFirst() else { return }
            if !subscription.isClosing,
                let pending = subscription.pendingMessages.popFirst()
            {
                subscription.queuedMessages.append(pending.data)
                pending.continuation.resume()
            }
            subscriptions[routingID] = subscription
            do {
                if let connection = connection as? any RequestScopedSending {
                    try await connection.send(data, relatedTo: routingID)
                } else {
                    try await connection.send(data)
                }
            } catch {
                guard let subscription = removeSubscription(
                    routingID,
                    pendingError: error
                ) else {
                    return
                }
                subscription.closureContinuation.finish(throwing: error)
                return
            }
        }
    }

    private func closeSubscriptionsGracefully() async {
        guard let connection else { return }
        guard !subscriptions.isEmpty else { return }
        await withCheckedContinuation { continuation in
            subscriptionClosureWaiters.append(continuation)
            for routingID in Array(subscriptions.keys) {
                guard var subscription = subscriptions[routingID] else { continue }
                subscription.isClosing = true
                failPendingSubscriptionMessages(
                    &subscription,
                    error: MCPError.connectionClosed
                )
                subscriptions[routingID] = subscription
                beginDrainingSubscription(routingID, connection: connection)
            }
        }
    }

    private func cancelSubscription(_ routingID: ID) {
        guard let subscription = removeSubscription(
            routingID,
            pendingError: CancellationError()
        ) else { return }
        subscription.closureContinuation.finish()
    }

    @discardableResult
    private func removeSubscription(
        _ routingID: ID,
        pendingError: Swift.Error = MCPError.connectionClosed
    ) -> ActiveSubscription? {
        guard var subscription = subscriptions.removeValue(forKey: routingID) else {
            return nil
        }
        failPendingSubscriptionMessages(&subscription, error: pendingError)
        if subscriptions.isEmpty, !subscriptionClosureWaiters.isEmpty {
            let waiters = subscriptionClosureWaiters
            subscriptionClosureWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        return subscription
    }

    private func cancelPendingSubscriptionMessage(
        _ messageID: Int,
        routingID: ID
    ) {
        guard var subscription = subscriptions[routingID] else { return }
        let removed = subscription.pendingMessages.removeAll { $0.id == messageID }
        subscriptions[routingID] = subscription
        for pending in removed {
            pending.continuation.resume(throwing: CancellationError())
        }
    }

    private func failPendingSubscriptionMessages(
        _ subscription: inout ActiveSubscription,
        error: Swift.Error
    ) {
        while let pending = subscription.pendingMessages.popFirst() {
            pending.continuation.resume(throwing: error)
        }
    }

    private static func addingSubscriptionID(_ id: ID, to data: Data) throws -> Data {
        guard case .object(var message) = try JSONDecoder().decode(Value.self, from: data) else {
            throw MCPError.invalidRequest("Notification must encode as a JSON object")
        }
        var parameters = message["params"]?.objectValue ?? [:]
        var metadata = parameters["_meta"]?.objectValue ?? [:]
        metadata[ProtocolMetadataKey.subscriptionID] = try Value(id)
        parameters["_meta"] = .object(metadata)
        message["params"] = .object(parameters)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Value.object(message))
    }

    private func setInitialState(
        clientInfo: Client.Info,
        clientCapabilities: Client.Capabilities,
        protocolVersion: String
    ) async {
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.protocolVersion = protocolVersion
    }

    private func beginInitialization() -> Bool {
        guard initializationPhase == .notStarted else { return false }
        initializationPhase = .handling
        return true
    }

    private func beginInitializationResponseSend() {
        guard initializationPhase == .handling else { return }
        initializationPhase = .responseSending
    }

    private func finishInitializationResponseSend() async throws {
        guard initializationPhase == .responseSending else { return }
        initializationPhase = .responseSent
        if let notification = pendingInitializedNotification {
            pendingInitializedNotification = nil
            try await handleMessage(notification)
        }
    }

    private func resetInitialization() {
        guard initializationPhase == .handling || initializationPhase == .responseSending else {
            return
        }
        initializationPhase = .notStarted
        pendingInitializedNotification = nil
        clientInfo = nil
        clientCapabilities = nil
        protocolVersion = nil
    }

    /// Cancel and remove a pending request task
    private func removePendingRequest(id: ID) -> Task<Response<AnyMethod>, Error>? {
        pendingRequestTasks.removeValue(forKey: id)
    }

    private func cancelRequestFromTransport(_ id: ID) {
        if let task = pendingRequestTasks.removeValue(forKey: id) {
            task.cancel()
        } else {
            cancelledBeforeDispatchRequestIDs.insert(id)
        }
    }

    /// Records that a request has been received and is about to be dispatched.
    private func beginDispatch(_ id: ID) {
        dispatchingRequestIDs.insert(id)
    }

    /// Records a cancellation for a request that is dispatching but has not registered its task.
    ///
    /// - Returns: `true` when the cancellation was recorded, `false` when the request is unknown,
    ///   in which case the specification allows the notification to be ignored.
    private func recordCancellationBeforeDispatch(_ id: ID) -> Bool {
        guard dispatchingRequestIDs.contains(id) else { return false }
        cancelledBeforeDispatchRequestIDs.insert(id)
        return true
    }

    private func registerCancellationHandler() {
        onNotification(CancelledNotification.self) { [weak self] message in
            guard let self = self else { return }

            let requestId = message.params.requestId
            let reason = message.params.reason

            await self.logger?.debug(
                "Received cancellation notification",
                metadata: [
                    "requestId": requestId.map { "\($0)" } ?? "none",
                    "reason": reason.map { "\($0)" } ?? "none",
                ]
            )

            guard let requestId = requestId else {
                await self.logger?.warning(
                    "Received cancellation notification with no requestId (violates spec MUST)",
                    metadata: ["reason": reason.map { "\($0)" } ?? "none"]
                )
                return
            }

            // Cancel the pending request task if it exists and remove from tracking
            if let task = await self.removePendingRequest(id: requestId) {
                task.cancel()
                await self.logger?.debug(
                    "Cancelled request",
                    metadata: ["requestId": "\(requestId)"]
                )
            } else if await self.recordCancellationBeforeDispatch(requestId) {
                // The request is dispatching but has not registered its handler task yet. On stdio
                // this notification is the only cancellation mechanism the revision defines, so it
                // must not be dropped: the dispatch consumes the record before starting work.
                await self.logger?.debug(
                    "Cancelled request before its handler started",
                    metadata: ["requestId": "\(requestId)"]
                )
            } else {
                // Request may have already completed or is unknown
                // Per MCP spec, we should ignore this gracefully
                await self.logger?.trace(
                    "Cancellation notification for unknown or completed request",
                    metadata: ["requestId": "\(requestId)"]
                )
            }
        }
    }

    /// Cancel a request by sending a CancelledNotification to the client.
    ///
    /// This is used when the server needs to cancel an in-progress request it made to the client
    /// (e.g., a sampling request).
    ///
    /// According to the MCP specification, cancellation is advisory:
    /// - The client SHOULD stop processing and free resources
    /// - The client MAY ignore the cancellation if the request is unknown, already completed,
    ///   or cannot be cancelled
    /// - The server SHOULD ignore any response that arrives after cancellation
    ///
    /// - Parameters:
    ///   - requestID: The ID of the request to cancel
    ///   - reason: An optional human-readable reason for the cancellation
    /// - Throws: MCPError if the notification cannot be sent
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
    public func cancelRequest(_ requestID: ID, reason: String? = nil) async throws {
        // Send cancellation notification to client
        let notification = CancelledNotification.message(
            .init(requestId: requestID, reason: reason)
        )
        try await notify(notification)
    }
}

extension Server.Batch: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var items: [Item] = []
        for item in try container.decode([Value].self) {
            let data = try encoder.encode(item)
            try items.append(decoder.decode(Item.self, from: data))
        }

        self.items = items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(items)
    }
}

extension Server.Batch.Item: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Check if it's a request (has id) or notification (no id)
        if container.contains(.id) {
            self = .request(try Request<AnyMethod>(from: decoder))
        } else {
            self = .notification(try Message<AnyNotification>(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let request):
            try request.encode(to: encoder)
        case .notification(let notification):
            try notification.encode(to: encoder)
        }
    }
}
