import Logging

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private struct EmbeddedInputWorkItem: Sendable {
    let key: String
    let handler: RequestHandlerBox
    let request: AnyRequest
}

private struct FulfilledEmbeddedInput: Sendable {
    let key: String
    let value: Value
}

private struct ActiveClientSubscription {
    let requested: SubscriptionFilter
    var acknowledged: SubscriptionFilter?
    let eventsContinuation: AsyncThrowingStream<Client.SubscriptionEvent, Swift.Error>.Continuation
    var acknowledgmentContinuation: CheckedContinuation<SubscriptionFilter, Swift.Error>?
    var attemptTask: Task<Void, Never>?
    var attemptGeneration: Int?
    var isAwaitingAcknowledgment: Bool
    var hasBeenAcknowledged: Bool
}

/// Model Context Protocol client
public actor Client {
    /// Selects the protocol lifecycle used when connecting to a server.
    public enum ProtocolMode: String, Hashable, Codable, Sendable {
        /// Use `initialize` and `notifications/initialized` only.
        case initializationOnly

        /// Probe for per-request metadata support and fall back to initialization when required.
        case automatic

        /// Require per-request metadata and do not fall back to initialization.
        case perRequestMetadataOnly
    }

    /// Controls how the client handles `input_required` results.
    public enum MultiRoundTripMode: Hashable, Codable, Sendable {
        /// Fulfill embedded requests with registered method handlers and retry automatically.
        case automatic(maxRounds: Int)

        /// Delegate each aggregate input request map to one registered handler.
        case manual

        /// Reject `input_required` results.
        case disabled

        private enum CodingKeys: String, CodingKey {
            case mode, maxRounds
        }

        private enum Mode: String, Codable {
            case automatic, manual, disabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Mode.self, forKey: .mode) {
            case .automatic:
                self = .automatic(
                    maxRounds: try container.decodeIfPresent(Int.self, forKey: .maxRounds) ?? 8)
            case .manual:
                self = .manual
            case .disabled:
                self = .disabled
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .automatic(let maxRounds):
                try container.encode(Mode.automatic, forKey: .mode)
                try container.encode(maxRounds, forKey: .maxRounds)
            case .manual:
                try container.encode(Mode.manual, forKey: .mode)
            case .disabled:
                try container.encode(Mode.disabled, forKey: .mode)
            }
        }
    }

    /// An aggregate request passed to a manual multi-round-trip handler.
    public struct MultiRoundTripContext: Hashable, Codable, Sendable {
        public let method: String
        public let round: Int
        public let inputRequired: InputRequiredResult

        public init(method: String, round: Int, inputRequired: InputRequiredResult) {
            self.method = method
            self.round = round
            self.inputRequired = inputRequired
        }
    }

    /// Handles all embedded input requests in one multi-round-trip response.
    public typealias MultiRoundTripHandler = @Sendable (MultiRoundTripContext) async throws
        -> [String: Value]

    /// The client configuration
    public struct Configuration: Hashable, Codable, Sendable {
        /// The default configuration.
        public static let `default` = Configuration(strict: false)

        /// The strict configuration.
        public static let strict = Configuration(strict: true)

        /// When strict mode is enabled, the client:
        /// - Requires server capabilities to be initialized before making requests
        /// - Rejects all requests that require capabilities before initialization
        ///
        /// While the MCP specification requires servers to respond to initialize requests
        /// with their capabilities, some implementations may not follow this.
        /// Disabling strict mode allows the client to be more lenient with non-compliant
        /// servers, though this may lead to undefined behavior.
        public var strict: Bool

        /// The protocol lifecycle selection policy.
        public var protocolMode: ProtocolMode

        /// Maximum time to wait for a stdio-style discovery probe, in seconds.
        /// Set to `0` to wait without an SDK-imposed limit.
        public var discoveryProbeTimeout: Double

        /// Multi-round-trip behavior for per-request metadata responses.
        public var multiRoundTripMode: MultiRoundTripMode

        /// Maximum number of subscription events buffered for a slow consumer.
        public var subscriptionBufferCapacity: Int

        public init(
            strict: Bool = false,
            protocolMode: ProtocolMode = .initializationOnly,
            discoveryProbeTimeout: Double = 2,
            multiRoundTripMode: MultiRoundTripMode = .automatic(maxRounds: 8),
            subscriptionBufferCapacity: Int = 32
        ) {
            self.strict = strict
            self.protocolMode = protocolMode
            self.discoveryProbeTimeout = discoveryProbeTimeout
            self.multiRoundTripMode = multiRoundTripMode
            self.subscriptionBufferCapacity = subscriptionBufferCapacity
        }

        private enum CodingKeys: String, CodingKey {
            case strict, protocolMode, discoveryProbeTimeout, multiRoundTripMode
            case subscriptionBufferCapacity
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            strict = try container.decodeIfPresent(Bool.self, forKey: .strict) ?? false
            protocolMode =
                try container.decodeIfPresent(ProtocolMode.self, forKey: .protocolMode)
                ?? .initializationOnly
            discoveryProbeTimeout =
                try container.decodeIfPresent(Double.self, forKey: .discoveryProbeTimeout)
                ?? 2
            multiRoundTripMode =
                try container.decodeIfPresent(
                    MultiRoundTripMode.self, forKey: .multiRoundTripMode)
                ?? .disabled
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
        /// The client name
        public var name: String
        /// A human-readable title for display purposes
        public var title: String?
        /// The client version
        public var version: String
        /// Optional description of the client
        public var description: String?
        /// Optional website URL for the client
        public var websiteUrl: String?
        /// Optional set of sized icons for display in a user interface
        public var icons: [Icon]?

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

    /// Information selected while establishing an MCP connection.
    public struct ConnectionInfo: Hashable, Codable, Sendable {
        /// The protocol version used for requests on this connection.
        public let protocolVersion: String

        /// The lifecycle mechanism used by the connection.
        public let protocolLifecycle: ProtocolLifecycle

        /// Capabilities reported by the server.
        public let capabilities: Server.Capabilities

        /// Self-reported server information, when supplied by the server.
        public let serverInfo: Server.Info?

        /// Optional instructions reported by the server.
        public let instructions: String?

        public init(
            protocolVersion: String,
            protocolLifecycle: ProtocolLifecycle,
            capabilities: Server.Capabilities,
            serverInfo: Server.Info? = nil,
            instructions: String? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.protocolLifecycle = protocolLifecycle
            self.capabilities = capabilities
            self.serverInfo = serverInfo
            self.instructions = instructions
        }

        fileprivate var initializeResult: Initialize.Result {
            Initialize.Result(
                protocolVersion: protocolVersion,
                capabilities: capabilities,
                serverInfo: serverInfo ?? .init(name: "unknown", version: "0.0.0"),
                instructions: instructions
            )
        }
    }

    /// The client capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// The roots capabilities
        public struct Roots: Hashable, Codable, Sendable {
            /// Whether the list of roots has changed
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// The sampling capabilities
        public struct Sampling: Hashable, Sendable {
            /// Tools sub-capability for sampling
            public struct Tools: Hashable, Codable, Sendable {
                public var settings: [String: Value]

                public init(settings: [String: Value] = [:]) { self.settings = settings }
                public init(from decoder: Decoder) throws {
                    settings = try [String: Value](from: decoder)
                }
                public func encode(to encoder: Encoder) throws { try settings.encode(to: encoder) }
            }

            /// Context sub-capability for sampling
            public struct Context: Hashable, Codable, Sendable {
                public var settings: [String: Value]

                public init(settings: [String: Value] = [:]) { self.settings = settings }
                public init(from decoder: Decoder) throws {
                    settings = try [String: Value](from: decoder)
                }
                public func encode(to encoder: Encoder) throws { try settings.encode(to: encoder) }
            }

            /// Whether tools are supported in sampling
            public var tools: Tools?
            /// Whether context is supported in sampling
            public var context: Context?

            public init(tools: Tools? = nil, context: Context? = nil) {
                self.tools = tools
                self.context = context
            }
        }

        /// The elicitation capabilities
        public struct Elicitation: Hashable, Sendable {
            /// Form-based elicitation sub-capability
            public struct Form: Hashable, Codable, Sendable {
                public var settings: [String: Value]

                public init(settings: [String: Value] = [:]) { self.settings = settings }
                public init(from decoder: Decoder) throws {
                    settings = try [String: Value](from: decoder)
                }
                public func encode(to encoder: Encoder) throws { try settings.encode(to: encoder) }
            }

            /// URL-based elicitation sub-capability
            public struct URL: Hashable, Codable, Sendable {
                public var settings: [String: Value]

                public init(settings: [String: Value] = [:]) { self.settings = settings }
                public init(from decoder: Decoder) throws {
                    settings = try [String: Value](from: decoder)
                }
                public func encode(to encoder: Encoder) throws { try settings.encode(to: encoder) }
            }

            /// Whether form-based elicitation is supported
            public var form: Form?
            /// Whether URL-based elicitation is supported
            public var url: URL?

            public init(form: Form? = Form(), url: URL? = nil) {
                self.form = form
                self.url = url
            }
        }

        /// Whether the client supports sampling
        public var sampling: Sampling?
        /// Whether the client supports elicitation
        public var elicitation: Elicitation?
        /// Experimental features supported by the client.
        public var experimental: [String: Value]?
        /// MCP extensions supported by the client and their settings.
        public var extensions: [String: Value]?
        /// Whether the client supports roots
        public var roots: Capabilities.Roots?
        /// Additional capabilities not defined by this SDK version.
        public var additionalCapabilities: [String: Value]

        public init(
            sampling: Sampling? = nil,
            elicitation: Elicitation? = nil,
            experimental: [String: Value]? = nil,
            roots: Capabilities.Roots? = nil,
            extensions: [String: Value]? = nil,
            additionalCapabilities: [String: Value] = [:]
        ) {
            self.sampling = sampling
            self.elicitation = elicitation
            self.experimental = experimental
            self.roots = roots
            self.extensions = extensions
            self.additionalCapabilities = additionalCapabilities
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case sampling, elicitation, experimental, extensions, roots
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sampling = try container.decodeIfPresent(Sampling.self, forKey: .sampling)
            elicitation = try container.decodeIfPresent(Elicitation.self, forKey: .elicitation)
            experimental = try container.decodeIfPresent([String: Value].self, forKey: .experimental)
            extensions = try container.decodeIfPresent([String: Value].self, forKey: .extensions)
            roots = try container.decodeIfPresent(Roots.self, forKey: .roots)

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
            try container.encodeIfPresent(sampling, forKey: .sampling)
            try container.encodeIfPresent(elicitation, forKey: .elicitation)
            try container.encodeIfPresent(experimental, forKey: .experimental)
            try container.encodeIfPresent(extensions, forKey: .extensions)
            try container.encodeIfPresent(roots, forKey: .roots)

            var dynamicContainer = encoder.container(keyedBy: ProtocolCapabilityCodingKey.self)
            for (name, value) in additionalCapabilities {
                try dynamicContainer.encode(
                    value,
                    forKey: ProtocolCapabilityCodingKey(stringValue: name)!)
            }
        }
    }

    /// The connection to the server
    private var connection: (any Transport)?
    /// The logger for the client
    private var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The client information
    private let clientInfo: Client.Info
    /// The client name
    public nonisolated var name: String { clientInfo.name }
    /// A human-readable client title
    public nonisolated var title: String? { clientInfo.title }
    /// The client version
    public nonisolated var version: String { clientInfo.version }

    /// The client capabilities
    public var capabilities: Client.Capabilities
    /// The client configuration
    public var configuration: Configuration

    /// The server capabilities
    private var serverCapabilities: Server.Capabilities?
    /// The server version
    private var serverVersion: String?
    /// The server instructions
    private var instructions: String?
    /// The lifecycle selected for the active connection.
    private var selectedProtocolLifecycle: ProtocolLifecycle?
    /// The protocol version selected for the active connection.
    private var selectedProtocolVersion: String?
    /// Protocol lifecycle previously selected for an HTTP origin.
    private var protocolLifecycleCache: [String: ProtocolLifecycle] = [:]
    /// Whether the initialization-based ready notification has been sent.
    private var initializationNotificationSent = false
    /// Aggregate handler used when multi-round-trip mode is manual.
    private var multiRoundTripHandler: MultiRoundTripHandler?
    /// Current wire request ID for each logical request.
    private var logicalRequestAttempts: [ID: ID] = [:]
    /// Logical requests cancelled while embedded input was being fulfilled.
    private var cancelledLogicalRequests: Set<ID> = []
    /// Cancellation actions for active logical request tasks.
    private var logicalRequestCancellations: [ID: @Sendable () -> Void] = [:]
    /// Subscription registrations survive a transport reconnect until explicitly cancelled.
    private var subscriptions: [ID: ActiveClientSubscription] = [:]
    /// Distinguishes completions from an earlier transport connection.
    private var connectionGeneration = 0

    /// A dictionary of type-erased notification handlers, keyed by method name
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// Method handlers for server-to-client requests
    private var methodHandlers: [String: RequestHandlerBox] = [:]
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

    /// A dictionary of type-erased pending requests, keyed by request ID
    private var pendingRequests: [ID: AnyPendingRequest] = [:]
    // Add reusable JSON encoder/decoder
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        name: String,
        version: String,
        title: String? = nil,
        description: String? = nil,
        websiteUrl: String? = nil,
        icons: [Icon]? = nil,
        capabilities: Capabilities = Capabilities(),
        configuration: Configuration = .default
    ) {
        self.clientInfo = Client.Info(
            name: name, version: version, title: title,
            description: description, websiteUrl: websiteUrl, icons: icons)
        self.capabilities = capabilities
        self.configuration = configuration
    }

    /// Connect to the server using the given transport
    @discardableResult
    public func connect(transport: any Transport) async throws -> Initialize.Result {
        try await connectWithInfo(transport: transport).initializeResult
    }

    /// Connects to a server and reports the selected protocol lifecycle.
    @discardableResult
    public func connectWithInfo(transport: any Transport) async throws -> ConnectionInfo {
        let lifecycleCacheKey: String?
        let cachedProtocolLifecycle: ProtocolLifecycle?
        if configuration.protocolMode == .automatic,
            let cacheKeyProvider = transport as? any ProtocolLifecycleCacheKeyProviding
        {
            lifecycleCacheKey = await cacheKeyProvider.protocolLifecycleCacheKey()
            cachedProtocolLifecycle = lifecycleCacheKey.flatMap { protocolLifecycleCache[$0] }
        } else {
            lifecycleCacheKey = nil
            cachedProtocolLifecycle = nil
        }
        connectionGeneration += 1
        self.connection = transport
        selectedProtocolLifecycle = nil
        selectedProtocolVersion = nil
        initializationNotificationSent = false
        if let transport = transport as? any ToolHeaderSchemaManaging {
            await transport.clearToolHeaderSchemas()
        }
        if let transport = transport as? any ProtocolLifecycleUpdating {
            switch configuration.protocolMode {
            case .initializationOnly:
                await transport.updateProtocolLifecycle(
                    .initializationBased,
                    protocolVersion: Version.latestInitializationVersion
                )
            case .automatic:
                let lifecycle = cachedProtocolLifecycle ?? .perRequestMetadata
                await transport.updateProtocolLifecycle(
                    lifecycle,
                    protocolVersion: lifecycle == .initializationBased
                        ? Version.latestInitializationVersion
                        : Version.perRequestMetadataVersion
                )
            case .perRequestMetadataOnly:
                await transport.updateProtocolLifecycle(
                    .perRequestMetadata,
                    protocolVersion: Version.perRequestMetadataVersion
                )
            }
        }
        try await self.connection?.connect()

        await logger?.debug(
            "Client connected", metadata: ["name": "\(name)", "version": "\(version)"])

        // Start message handling loop
        task = Task {
            guard let connection = self.connection else { return }
            repeat {
                // Check for cancellation before starting the iteration
                if Task.isCancelled { break }

                do {
                    let stream = await connection.receive()
                    for try await data in stream {
                        if Task.isCancelled { break }  // Check inside loop too

                        // Attempt to decode data
                        // Try decoding as a batch response first
                        if let batchResponse = try? decoder.decode([AnyResponse].self, from: data) {
                            await handleBatchResponse(batchResponse)
                        } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                            await handleResponse(response)
                        } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            await handleIncomingRequest(request)
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            await handleMessage(message)
                        } else {
                            var metadata: Logger.Metadata = [:]
                            if let string = String(data: data, encoding: .utf8) {
                                metadata["message"] = .string(string)
                            }
                            await logger?.warning(
                                "Unexpected message received by client (not single/batch response or notification)",
                                metadata: metadata
                            )
                        }
                    }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    await logger?.error(
                        "Error in message handling loop", metadata: ["error": "\(error)"])
                    break
                }
            } while true
            await self.logger?.debug("Client message handling loop task is terminating.")
        }

        // Register cancellation notification handler
        await self.onNotification(CancelledNotification.self) { [weak self] message in
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

            // Remove the pending request and resume with cancellation error
            if let requestId = requestId,
                let pendingRequest = await self.removePendingRequest(id: requestId)
            {
                pendingRequest.resume(throwing: CancellationError())
            }
        }

        let connectionInfo: ConnectionInfo
        switch configuration.protocolMode {
        case .initializationOnly:
            connectionInfo = try await initializeConnection()
        case .automatic:
            if cachedProtocolLifecycle == .initializationBased {
                do {
                    connectionInfo = try await initializeConnection()
                } catch {
                    if let lifecycleCacheKey {
                        protocolLifecycleCache.removeValue(forKey: lifecycleCacheKey)
                    }
                    throw error
                }
            } else {
                do {
                    connectionInfo = try await discoverConnection()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    switch classifyDiscoveryFailure(error) {
                    case .initializationBased:
                        connectionInfo = try await initializeConnection()
                    case .inconclusive(let error):
                        throw error
                    }
                }
            }
        case .perRequestMetadataOnly:
            do {
                connectionInfo = try await discoverConnection()
            } catch {
                throw underlyingDiscoveryError(error)
            }
        }

        if let lifecycleCacheKey {
            protocolLifecycleCache[lifecycleCacheKey] = connectionInfo.protocolLifecycle
        }

        if connectionInfo.protocolLifecycle == .perRequestMetadata {
            await reestablishSubscriptions()
        } else if !subscriptions.isEmpty {
            failSubscriptions(
                MCPError.invalidRequest(
                    "subscriptions/listen requires the per-request-metadata lifecycle")
            )
        }
        return connectionInfo
    }

    /// Disconnect the client and cancel all pending requests
    public func disconnect() async {
        await logger?.debug("Initiating client disconnect...")

        // Part 1: Inside actor - Grab state and clear internal references
        let taskToCancel = self.task
        let connectionToDisconnect = self.connection
        let pendingRequestsToCancel = self.pendingRequests
        let logicalRequestsToCancel = self.logicalRequestCancellations.values
        connectionGeneration += 1

        for id in Array(subscriptions.keys) {
            guard var subscription = subscriptions[id] else { continue }
            subscription.attemptTask?.cancel()
            subscription.attemptTask = nil
            subscription.attemptGeneration = nil
            subscription.isAwaitingAcknowledgment = true
            subscriptions[id] = subscription
            if subscription.hasBeenAcknowledged {
                _ = await yieldSubscriptionEvent(.disconnected, to: id)
            }
        }

        self.task = nil
        self.connection = nil
        self.pendingRequests = [:]  // Use empty dictionary literal
        self.selectedProtocolLifecycle = nil
        self.selectedProtocolVersion = nil
        self.logicalRequestAttempts = [:]
        self.cancelledLogicalRequests = []
        self.logicalRequestCancellations = [:]

        if let connectionToDisconnect = connectionToDisconnect as? any ToolHeaderSchemaManaging {
            await connectionToDisconnect.clearToolHeaderSchemas()
        }

        // Part 2: Outside actor - Resume continuations, disconnect transport, await task

        // Resume continuations first
        for (_, request) in pendingRequestsToCancel {
            request.resume(throwing: MCPError.internalError("Client disconnected"))
        }
        for cancel in logicalRequestsToCancel {
            cancel()
        }
        await logger?.debug("Pending requests cancelled.")

        // Cancel the task
        taskToCancel?.cancel()
        await logger?.debug("Message loop task cancellation requested.")

        // Disconnect the transport *before* awaiting the task
        // This should ensure the transport stream is finished, unblocking the loop.
        if let conn = connectionToDisconnect {
            await conn.disconnect()
            await logger?.debug("Transport disconnected.")
        } else {
            await logger?.debug("No active transport connection to disconnect.")
        }

        // Await the task completion *after* transport disconnect
        _ = await taskToCancel?.value
        await logger?.debug("Client message loop task finished.")

        await logger?.debug("Client disconnect complete.")
    }

    // MARK: - Registration

    /// Register a handler for a notification
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) async -> Self {
        let handlers = notificationHandlers[N.name, default: []]
        notificationHandlers[N.name] = handlers + [TypedNotificationHandler(handler)]
        return self
    }

    /// Register a handler for server-to-client requests
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

    /// Registers the aggregate handler used by manual multi-round-trip mode.
    @discardableResult
    public func withMultiRoundTripHandler(
        _ handler: @escaping MultiRoundTripHandler
    ) -> Self {
        multiRoundTripHandler = handler
        return self
    }

    /// Send a notification to the server
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }
        if selectedProtocolLifecycle == .perRequestMetadata {
            switch notification.method {
            case InitializedNotification.name, RootsListChangedNotification.name:
                throw MCPError.methodNotFound(
                    "\(notification.method) is not part of protocol version \(Version.perRequestMetadataVersion)")
            default:
                break
            }
        }

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Opens a long-lived stream for selected server notifications.
    ///
    /// The returned stream remains registered across an explicit disconnect and is re-sent with
    /// the same JSON-RPC ID after the client connects to another per-request-metadata transport.
    /// Call ``cancelSubscription(_:reason:)`` to permanently remove the registration.
    public func listen(
        notifications: SubscriptionFilter
    ) async throws -> Subscription {
        guard selectedProtocolLifecycle == .perRequestMetadata else {
            throw MCPError.invalidRequest(
                "subscriptions/listen requires the per-request-metadata lifecycle")
        }
        guard configuration.subscriptionBufferCapacity > 0 else {
            throw MCPError.invalidParams("Subscription buffer capacity must be positive")
        }

        var id = ID.random
        while subscriptions[id] != nil || logicalRequestCancellations[id] != nil {
            id = .random
        }
        let subscriptionID = id

        let (events, eventsContinuation) =
            AsyncThrowingStream<SubscriptionEvent, Swift.Error>.makeStream(
                bufferingPolicy: .bufferingOldest(configuration.subscriptionBufferCapacity)
            )
        eventsContinuation.onTermination = { @Sendable [weak self] _ in
            Task {
                try? await self?.cancelSubscription(
                    subscriptionID,
                    reason: "Listener terminated"
                )
            }
        }
        let acknowledged = try await withTaskCancellationHandler {
            try await self.beginSubscription(
                subscriptionID,
                notifications: notifications,
                eventsContinuation: eventsContinuation
            )
        } onCancel: {
            Task {
                try? await self.cancelSubscription(
                    subscriptionID,
                    reason: "Listener cancelled"
                )
            }
        }

        return Subscription(
            id: subscriptionID,
            requestedNotifications: notifications,
            acknowledgedNotifications: acknowledged,
            events: events
        )
    }

    private func beginSubscription(
        _ id: ID,
        notifications: SubscriptionFilter,
        eventsContinuation: AsyncThrowingStream<SubscriptionEvent, Swift.Error>.Continuation
    ) async throws -> SubscriptionFilter {
        try await withCheckedThrowingContinuation { continuation in
            subscriptions[id] = ActiveClientSubscription(
                requested: notifications,
                acknowledged: nil,
                eventsContinuation: eventsContinuation,
                acknowledgmentContinuation: continuation,
                attemptTask: nil,
                attemptGeneration: nil,
                isAwaitingAcknowledgment: true,
                hasBeenAcknowledged: false
            )
            do {
                try startSubscriptionAttempt(id)
            } catch {
                failSubscription(id, error: error)
            }
        }
    }

    /// Permanently cancels a subscription and finishes its event stream.
    public func cancelSubscription(_ id: ID, reason: String? = nil) async throws {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        subscription.acknowledgmentContinuation?.resume(throwing: CancellationError())
        subscription.eventsContinuation.finish()
        subscription.attemptTask?.cancel()

        guard connection != nil,
            subscription.attemptGeneration == connectionGeneration
        else {
            return
        }
        try await cancelRequest(id, reason: reason)
    }

    /// Send a response back to the server for a server-to-client request
    private func send<M: Method>(_ response: Response<M>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }
        let responseData = try encoder.encode(response)
        try await connection.send(responseData)
    }

    // MARK: - Requests

    /// Send a request and return a RequestContext that wraps both the request ID and the Task.
    ///
    /// This allows you to track and cancel the request by sending a CancelledNotification
    /// to the server using the requestID.
    ///
    /// Example:
    /// ```swift
    /// let context = try await client.send(request)
    /// // Later, to cancel:
    /// try await client.cancelRequest(context.requestID, reason: "User cancelled")
    /// // Await the result:
    /// let result = try await context.value
    /// ```
    ///
    /// - Parameter request: The request to send
    /// - Returns: A RequestContext containing the request ID and Task
    /// - Throws: MCPError if the client is not connected
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
    public func send<M: Method>(_ request: Request<M>) throws -> RequestContext<M.Result> {
        try send(request, logLevel: nil)
    }

    /// Sends a request with an optional request-scoped log level.
    ///
    /// The log level is carried in 2026-07-28 request metadata. Earlier lifecycle versions use
    /// `logging/setLevel` and reject this overload when a level is supplied.
    public func send<M: Method>(
        _ request: Request<M>,
        logLevel: LogLevel?
    ) throws -> RequestContext<M.Result> {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }
        if logLevel != nil, selectedProtocolLifecycle != .perRequestMetadata {
            throw MCPError.invalidRequest(
                "Request-scoped logging requires the per-request-metadata lifecycle")
        }
        if selectedProtocolLifecycle == .perRequestMetadata {
            switch request.method {
            case Initialize.name, Ping.name, SetLoggingLevel.name,
                ResourceSubscribe.name, ResourceUnsubscribe.name:
                throw MCPError.methodNotFound(
                    "\(request.method) is not part of protocol version \(Version.perRequestMetadataVersion)")
            default:
                break
            }
        }

        if selectedProtocolLifecycle == .perRequestMetadata {
            let requestTask = Task<M.Result, Error> {
                try await self.performLogicalRequest(
                    request,
                    connection: connection,
                    logLevel: logLevel
                )
            }
            logicalRequestCancellations[request.id] = { @Sendable [requestTask] in
                requestTask.cancel()
            }
            return RequestContext(requestID: request.id, requestTask: requestTask)
        }

        let requestData = try encodeRequest(request, logLevel: nil)

        let requestTask = Task<M.Result, Error> {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    // Add the pending request before attempting to send
                    self.addPendingRequest(
                        id: request.id,
                        continuation: continuation,
                        type: M.Result.self
                    )

                    // Send the request data
                    do {
                        try await connection.send(requestData)
                    } catch {
                        // If send fails, try to remove the pending request.
                        if self.removePendingRequest(id: request.id) != nil {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }

        return RequestContext(requestID: request.id, requestTask: requestTask)
    }

    /// Cancel an active request.
    ///
    /// Per-request-metadata HTTP closes the request-scoped response. Other transports send a
    /// `notifications/cancelled` message. According to the MCP specification, notification-based
    /// cancellation is advisory:
    /// - The server SHOULD stop processing and free resources
    /// - The server MAY ignore the cancellation if the request is unknown, already completed,
    ///   or cannot be cancelled
    /// - The client SHOULD ignore any response that arrives after cancellation
    ///
    /// This method removes the pending request and resumes it with CancellationError,
    /// ensuring that any response arriving after cancellation is ignored.
    ///
    /// - Parameters:
    ///   - requestID: The ID of the request to cancel
    ///   - reason: An optional human-readable reason for the cancellation
    /// - Throws: MCPError if the notification cannot be sent
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
    public func cancelRequest(_ requestID: ID, reason: String? = nil) async throws {
        let activeRequestID = logicalRequestAttempts[requestID] ?? requestID
        // `send` registers the cancellation action synchronously, before the request task runs
        // its first attempt. Gating on that registration — rather than on the attempt map, which
        // `performLogicalRequest` only populates once the task starts — cancels a logical request
        // that has not reached the wire yet.
        if let cancelLogicalRequest = logicalRequestCancellations[requestID] {
            cancelledLogicalRequests.insert(requestID)
            cancelLogicalRequest()
        }

        // Remove the pending request and resume with cancellation error
        // This ensures any response that arrives after cancellation is ignored
        if let pendingRequest = removePendingRequest(id: activeRequestID) {
            pendingRequest.resume(throwing: CancellationError())
        }

        if let transport = connection as? any RequestStreamCancelling {
            await transport.cancelRequestStream(id: activeRequestID)
            return
        }

        // Send cancellation notification to server
        let notification = CancelledNotification.message(
            .init(requestId: activeRequestID, reason: reason)
        )
        try await notify(notification)
    }

    /// Send a request and receive its response immediately.
    ///
    /// Internal convenience method for cases where cancellation tracking is not needed.
    ///
    /// - Parameter request: The request to send
    /// - Returns: The result of the request
    /// - Throws: MCPError if the client is not connected
    func sendAndAwait<M: Method>(_ request: Request<M>) async throws -> M.Result {
        let context = try send(request)
        return try await context.value
    }

    private func addPendingRequest<T: Sendable & Decodable>(
        id: ID,
        continuation: CheckedContinuation<T, Swift.Error>,
        type: T.Type  // Keep type for AnyPendingRequest internal logic
    ) {
        pendingRequests[id] = AnyPendingRequest(
            PendingRequest(continuation: continuation)
        )
    }

    private func removePendingRequest(id: ID) -> AnyPendingRequest? {
        return pendingRequests.removeValue(forKey: id)
    }

    private func performLogicalRequest<M: Method>(
        _ request: Request<M>,
        connection: any Transport,
        logLevel: LogLevel?
    ) async throws -> M.Result {
        let logicalRequestID = request.id
        var attemptID = request.id
        var attemptData = try encodeRequest(request, logLevel: logLevel)
        var usedRequestIDs: Set<ID> = [attemptID]
        var round = 0
        var correctedToolHeaders = false

        defer {
            logicalRequestAttempts.removeValue(forKey: logicalRequestID)
            cancelledLogicalRequests.remove(logicalRequestID)
            logicalRequestCancellations.removeValue(forKey: logicalRequestID)
        }

        while true {
            try Task.checkCancellation()
            if cancelledLogicalRequests.contains(logicalRequestID) {
                throw CancellationError()
            }

            logicalRequestAttempts[logicalRequestID] = attemptID
            let value: Value
            do {
                value = try await sendRawRequest(
                    data: attemptData, id: attemptID, connection: connection)
            } catch let error as MCPError {
                if !correctedToolHeaders,
                    await refreshToolHeadersIfNeeded(
                        after: error,
                        requestData: attemptData,
                        connection: connection
                    )
                {
                    correctedToolHeaders = true
                    repeat {
                        attemptID = .random
                    } while usedRequestIDs.contains(attemptID)
                    usedRequestIDs.insert(attemptID)
                    attemptData = try replacingRequestID(in: attemptData, with: attemptID)
                    continue
                }
                throw error
            }
            guard let result = value.objectValue else {
                throw MCPError.invalidRequest("Response result must be a JSON object")
            }
            let resultType: ResultType
            if let resultTypeValue = result["resultType"] {
                guard let rawResultType = resultTypeValue.stringValue else {
                    throw MCPError.invalidRequest("Response resultType must be a string")
                }
                resultType = try decoder.decode(
                    ResultType.self, from: encoder.encode(Value.string(rawResultType)))
            } else {
                resultType = .complete
            }

            switch resultType {
            case .complete:
                return try decoder.decode(M.Result.self, from: encoder.encode(value))
            case .other(let value):
                throw MCPError.invalidRequest("Unsupported resultType: \(value)")
            case .inputRequired:
                break
            }

            guard M.self is any MultiRoundTripMethod.Type else {
                throw MCPError.invalidRequest(
                    "Method \(M.name) does not support input_required results")
            }

            let inputRequired = try decoder.decode(
                InputRequiredResult.self, from: encoder.encode(value))
            try inputRequired.validate(clientCapabilities: capabilities)
            round += 1

            let inputResponses: [String: Value]
            switch configuration.multiRoundTripMode {
            case .automatic(let configuredMaximum):
                guard configuredMaximum > 0 else {
                    throw MCPError.invalidParams(
                        "Multi-round-trip maxRounds must be greater than zero")
                }
                guard round <= configuredMaximum else {
                    throw MCPError.internalError(
                        "Multi-round-trip request exceeded \(configuredMaximum) rounds")
                }
                inputResponses = try await fulfillEmbeddedInputRequests(
                    inputRequired.inputRequests ?? [:])
            case .manual:
                guard let multiRoundTripHandler else {
                    throw MCPError.internalError(
                        "Manual multi-round-trip mode requires a registered aggregate handler")
                }
                inputResponses = try await multiRoundTripHandler(.init(
                    method: M.name,
                    round: round,
                    inputRequired: inputRequired
                ))
            case .disabled:
                throw MCPError.internalError("Multi-round-trip handling is disabled")
            }

            if let requiredKeys = inputRequired.inputRequests?.keys {
                let missingKeys = requiredKeys.filter { inputResponses[$0] == nil }
                guard missingKeys.isEmpty else {
                    throw MCPError.invalidParams(
                        "Missing embedded input responses: "
                            + missingKeys.sorted().joined(separator: ", "))
                }
            }
            try validateInputResponses(
                inputResponses,
                for: inputRequired.inputRequests ?? [:]
            )

            try Task.checkCancellation()
            if cancelledLogicalRequests.contains(logicalRequestID) {
                throw CancellationError()
            }

            repeat {
                attemptID = .random
            } while usedRequestIDs.contains(attemptID)
            usedRequestIDs.insert(attemptID)
            attemptData = try encodeRetry(
                request,
                id: attemptID,
                inputResponses: inputRequired.inputRequests == nil ? nil : inputResponses,
                requestState: inputRequired.requestState,
                logLevel: logLevel
            )
        }
    }

    private func sendRawRequest(
        data: Data,
        id: ID,
        connection: any Transport
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            addPendingRequest(id: id, continuation: continuation, type: Value.self)
            Task {
                do {
                    try await connection.send(data)
                } catch {
                    if self.removePendingRequest(id: id) != nil {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func refreshToolHeadersIfNeeded(
        after error: MCPError,
        requestData: Data,
        connection: any Transport
    ) async -> Bool {
        guard error.code == ProtocolErrorCode.headerMismatch,
            error.errorDescription?.lowercased().contains("mcp-param-") == true,
            let schemas = connection as? any ToolHeaderSchemaManaging,
            let toolName = MCPHTTPHeaders.toolName(in: requestData)
        else {
            return false
        }

        let previousPlan = await schemas.toolHeaderPlan(named: toolName)
        do {
            var cursor: String?
            var seenCursors: Set<String> = []
            repeat {
                let page = try await listTools(cursor: cursor)
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw MCPError.invalidRequest(
                        "tools/list returned a repeated pagination cursor")
                }
            } while cursor != nil
        } catch {
            await logger?.warning(
                "Could not refresh tool headers after HeaderMismatch",
                metadata: [
                    "tool": "\(toolName)",
                    "error": "\(error.localizedDescription)",
                ]
            )
            return false
        }

        guard let refreshedPlan = await schemas.toolHeaderPlan(named: toolName),
            !refreshedPlan.fields.isEmpty,
            refreshedPlan != previousPlan
        else {
            return false
        }
        return true
    }

    private func replacingRequestID(in data: Data, with id: ID) throws -> Data {
        guard case .object(var object) = try decoder.decode(Value.self, from: data) else {
            throw MCPError.invalidRequest("Request must encode as a JSON object")
        }
        object["id"] = try Value(id)
        return try encoder.encode(Value.object(object))
    }

    private func fulfillEmbeddedInputRequests(
        _ inputRequests: [String: Value]
    ) async throws -> [String: Value] {
        var workItems: [EmbeddedInputWorkItem] = []
        for (key, value) in inputRequests {
            guard let object = value.objectValue,
                object["id"] == nil,
                object["jsonrpc"] == nil,
                let method = object["method"]?.stringValue,
                let handler = methodHandlers[method]
            else {
                throw MCPError.invalidParams(
                    "Embedded input request \(key) is malformed or has no registered handler")
            }
            let parameters = object["params"] ?? .object([:])
            guard parameters.objectValue != nil else {
                throw MCPError.invalidParams(
                    "Embedded input request \(key) has non-object parameters")
            }
            workItems.append(EmbeddedInputWorkItem(
                key: key,
                handler: handler,
                request: Request(id: .random, method: method, params: parameters)
            ))
        }

        return try await withThrowingTaskGroup(of: FulfilledEmbeddedInput.self) { group in
            for workItem in workItems {
                group.addTask {
                    let response = try await workItem.handler(workItem.request)
                    switch response.result {
                    case .success(let value):
                        return FulfilledEmbeddedInput(key: workItem.key, value: value)
                    case .failure(let error):
                        throw error
                    }
                }
            }

            var responses: [String: Value] = [:]
            for try await fulfilled in group {
                responses[fulfilled.key] = fulfilled.value
            }
            return responses
        }
    }

    private func validateInputResponses(
        _ responses: [String: Value],
        for requests: [String: Value]
    ) throws {
        for (key, request) in requests {
            guard let method = request.objectValue?["method"]?.stringValue,
                let response = responses[key]
            else {
                continue
            }
            do {
                let data = try encoder.encode(response)
                switch method {
                case CreateElicitation.name:
                    _ = try decoder.decode(CreateElicitation.Result.self, from: data)
                case CreateSamplingMessage.name:
                    _ = try decoder.decode(CreateSamplingMessage.Result.self, from: data)
                case ListRoots.name:
                    _ = try decoder.decode(ListRoots.Result.self, from: data)
                default:
                    continue
                }
            } catch {
                throw MCPError.invalidParams(
                    "Invalid embedded input response for \(key)")
            }
        }
    }

    private func encodeRetry<M: Method>(
        _ request: Request<M>,
        id: ID,
        inputResponses: [String: Value]?,
        requestState: String?,
        logLevel: LogLevel?
    ) throws -> Data {
        guard case .object(var envelope) = try decoder.decode(
            Value.self, from: encoder.encode(request))
        else {
            throw MCPError.invalidRequest("Request must encode as a JSON object")
        }
        envelope["id"] = try Value(id)
        var parameters = envelope["params"]?.objectValue ?? [:]
        parameters.removeValue(forKey: "inputResponses")
        parameters.removeValue(forKey: "requestState")
        if let inputResponses {
            parameters["inputResponses"] = .object(inputResponses)
        }
        if let requestState {
            parameters["requestState"] = .string(requestState)
        }
        envelope["params"] = .object(parameters)

        let data = try encoder.encode(Value.object(envelope))
        guard let selectedProtocolVersion else {
            throw MCPError.internalError("Per-request protocol version is not selected")
        }
        return try PerRequestMetadataWire.addingRequestMetadata(
            to: data,
            protocolVersion: selectedProtocolVersion,
            clientInfo: clientInfo,
            clientCapabilities: perRequestMetadataCapabilities,
            logLevel: logLevel,
            using: encoder
        )
    }

    // MARK: - Batching

    /// A batch of requests.
    ///
    /// Objects of this type are passed as an argument to the closure
    /// of the ``Client/withBatch(body:)`` method.
    public actor Batch {
        unowned let client: Client
        var requests: [AnyRequest] = []

        init(client: Client) {
            self.client = client
        }

        /// Adds a request to the batch and prepares its expected response task.
        /// The actual sending happens when the `withBatch` scope completes.
        /// - Returns: A `Task` that will eventually produce the result or throw an error.
        public func addRequest<M: Method>(_ request: Request<M>) async throws -> Task<
            M.Result, Swift.Error
        > {
            requests.append(try AnyRequest(request))

            // Return a Task that registers the pending request and awaits its result.
            // The continuation is resumed when the response arrives.
            return Task<M.Result, Swift.Error> {
                try await withCheckedThrowingContinuation { continuation in
                    // We are already inside a Task, but need another Task
                    // to bridge to the client actor's context.
                    Task {
                        await client.addPendingRequest(
                            id: request.id,
                            continuation: continuation,
                            type: M.Result.self
                        )
                    }
                }
            }
        }
    }

    /// Executes multiple requests in a single batch.
    ///
    /// This method allows you to group multiple MCP requests together,
    /// which are then sent to the server as a single JSON array.
    /// The server processes these requests and sends back a corresponding
    /// JSON array of responses.
    ///
    /// Within the `body` closure, use the provided `Batch` actor to add
    /// requests using `batch.addRequest(_:)`. Each call to `addRequest`
    /// returns a `Task` handle representing the asynchronous operation
    /// for that specific request's result.
    ///
    /// It's recommended to collect these `Task` handles into an array
    /// within the `body` closure`. After the `withBatch` method returns
    /// (meaning the batch request has been sent), you can then process
    /// the results by awaiting each `Task` in the collected array.
    ///
    /// Example 1: Batching multiple tool calls and collecting typed tasks:
    /// ```swift
    /// // Array to hold the task handles for each tool call
    /// var toolTasks: [Task<CallTool.Result, Error>] = []
    /// try await client.withBatch { batch in
    ///     for i in 0..<10 {
    ///         toolTasks.append(
    ///             try await batch.addRequest(
    ///                 CallTool.request(.init(name: "square", arguments: ["n": i]))
    ///             )
    ///         )
    ///     }
    /// }
    ///
    /// // Process results after the batch is sent
    /// print("Processing \(toolTasks.count) tool results...")
    /// for (index, task) in toolTasks.enumerated() {
    ///     do {
    ///         let result = try await task.value
    ///         print("\(index): \(result.content)")
    ///     } catch {
    ///         print("\(index) failed: \(error)")
    ///     }
    /// }
    /// ```
    ///
    /// Example 2: Batching different request types and awaiting individual tasks:
    /// ```swift
    /// // Declare optional task variables beforehand
    /// var pingTask: Task<Ping.Result, Error>?
    /// var promptTask: Task<GetPrompt.Result, Error>?
    ///
    /// try await client.withBatch { batch in
    ///     // Assign the tasks within the batch closure
    ///     pingTask = try await batch.addRequest(Ping.request())
    ///     promptTask = try await batch.addRequest(GetPrompt.request(.init(name: "greeting")))
    /// }
    ///
    /// // Await the results after the batch is sent
    /// do {
    ///     if let pingTask = pingTask {
    ///         try await pingTask.value // Await ping result (throws if ping failed)
    ///         print("Ping successful")
    ///     }
    ///     if let promptTask = promptTask {
    ///         let promptResult = try await promptTask.value // Await prompt result
    ///         print("Prompt description: \(promptResult.description ?? "None")")
    ///     }
    /// } catch {
    ///     print("Error processing batch results: \(error)")
    /// }
    /// ```
    ///
    /// - Parameter body: An asynchronous closure that takes a `Batch` object as input.
    ///                   Use this object to add requests to the batch.
    /// - Throws: `MCPError.internalError` if the client is not connected.
    ///           Can also rethrow errors from the `body` closure or from sending the batch request.
    public func withBatch(body: @escaping @Sendable (Batch) async throws -> Void) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }
        guard selectedProtocolLifecycle != .perRequestMetadata
            || !(connection is any HTTPProtocolNegotiationTransport)
        else {
            throw MCPError.invalidRequest(
                "JSON-RPC batches are not supported by per-request metadata HTTP")
        }

        // Create Batch actor, passing self (Client)
        let batch = Batch(client: self)

        // Populate the batch actor by calling the user's closure.
        try await body(batch)

        // Get the collected requests from the batch actor
        let requests = await batch.requests

        // Check if there are any requests to send
        guard !requests.isEmpty else {
            await logger?.debug("Batch requested but no requests were added.")
            return  // Nothing to send
        }

        await logger?.debug(
            "Sending batch request", metadata: ["count": "\(requests.count)"])

        // Encode the array of AnyMethod requests into a single JSON payload
        let encoded = try encoder.encode(requests)
        let data: Data
        if selectedProtocolLifecycle == .perRequestMetadata,
            let selectedProtocolVersion
        {
            data = try PerRequestMetadataWire.addingRequestMetadata(
                to: encoded,
                protocolVersion: selectedProtocolVersion,
                clientInfo: clientInfo,
                clientCapabilities: perRequestMetadataCapabilities,
                using: encoder
            )
        } else {
            data = encoded
        }
        try await connection.send(data)

        // Responses will be handled asynchronously by the message loop and handleBatchResponse/handleResponse.
    }

    // MARK: - Lifecycle

    /// Initialize the connection with the server.
    ///
    /// - Important: This method is deprecated. Initialization now happens automatically
    ///   when calling `connect(transport:)`. You should use that method instead.
    ///
    /// - Returns: The server's initialization response containing capabilities and server info
    @available(
        *, deprecated,
        message:
            "Initialization now happens automatically during connect. Use connect(transport:) instead."
    )
    public func initialize() async throws -> Initialize.Result {
        return try await _initialize()
    }

    private func initializeConnection() async throws -> ConnectionInfo {
        selectedProtocolLifecycle = .initializationBased
        selectedProtocolVersion = Version.latestInitializationVersion
        initializationNotificationSent = false
        await updateTransportLifecycle(
            .initializationBased, protocolVersion: Version.latestInitializationVersion)
        let result = try await _initialize()
        await updateTransportLifecycle(
            .initializationBased, protocolVersion: result.protocolVersion)
        return ConnectionInfo(
            protocolVersion: result.protocolVersion,
            protocolLifecycle: .initializationBased,
            capabilities: result.capabilities,
            serverInfo: result.serverInfo,
            instructions: result.instructions
        )
    }

    private struct DiscoveryProbeTimeout: Swift.Error {}

    private func discoverConnection(
        requestedVersion: String = Version.perRequestMetadataVersion,
        mayRetryVersion: Bool = true
    ) async throws -> ConnectionInfo {
        selectedProtocolLifecycle = .perRequestMetadata
        selectedProtocolVersion = requestedVersion
        await updateTransportLifecycle(
            .perRequestMetadata, protocolVersion: requestedVersion)

        let request = Discover.request(.init())
        let context = try send(request)
        let result: Discover.Result
        do {
            result = try await awaitDiscovery(context)
        } catch {
            if mayRetryVersion,
                let retryVersion = mutuallySupportedVersion(
                    from: underlyingDiscoveryError(error)
                )
            {
                return try await discoverConnection(
                    requestedVersion: retryVersion,
                    mayRetryVersion: false
                )
            }
            selectedProtocolLifecycle = nil
            selectedProtocolVersion = nil
            throw error
        }

        guard
            let selectedVersion = Version.preferenceOrder.first(where: {
                Version.perRequestMetadataSupported.contains($0)
                    && result.supportedVersions.contains($0)
            })
        else {
            selectedProtocolLifecycle = nil
            selectedProtocolVersion = nil
            throw MCPError.remote(
                code: ProtocolErrorCode.unsupportedProtocolVersion,
                message: "Server does not advertise a mutually supported per-request metadata version",
                data: try? Value(UnsupportedProtocolVersionData(
                    supported: result.supportedVersions,
                    requested: requestedVersion
                ))
            )
        }

        selectedProtocolVersion = selectedVersion
        serverCapabilities = result.capabilities
        serverVersion = result.serverInfo?.version
        instructions = result.instructions
        await updateTransportLifecycle(.perRequestMetadata, protocolVersion: selectedVersion)

        return ConnectionInfo(
            protocolVersion: selectedVersion,
            protocolLifecycle: .perRequestMetadata,
            capabilities: result.capabilities,
            serverInfo: result.serverInfo,
            instructions: result.instructions
        )
    }

    private func awaitDiscovery(_ context: RequestContext<Discover.Result>) async throws
        -> Discover.Result
    {
        if connection is any HTTPProtocolNegotiationTransport {
            return try await withTaskCancellationHandler {
                try await context.value
            } onCancel: {
                Task {
                    try? await self.cancelRequest(
                        context.requestID,
                        reason: "Server discovery cancelled"
                    )
                }
            }
        }

        guard configuration.discoveryProbeTimeout.isFinite,
            configuration.discoveryProbeTimeout > 0
        else {
            return try await withTaskCancellationHandler {
                try await context.value
            } onCancel: {
                Task {
                    try? await self.cancelRequest(
                        context.requestID,
                        reason: "Server discovery cancelled"
                    )
                }
            }
        }
        let timeout = configuration.discoveryProbeTimeout

        return try await withThrowingTaskGroup(of: Discover.Result.self) { group in
            group.addTask { try await context.value }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw DiscoveryProbeTimeout()
            }

            do {
                guard let first = try await group.next() else {
                    throw MCPError.internalError("Server discovery did not complete")
                }
                group.cancelAll()
                return first
            } catch is DiscoveryProbeTimeout {
                try? await cancelRequest(
                    context.requestID,
                    reason: "Server discovery timed out"
                )
                group.cancelAll()
                throw MCPError.internalError("Server discovery timed out")
            } catch is CancellationError {
                try? await cancelRequest(context.requestID, reason: "Server discovery cancelled")
                group.cancelAll()
                throw CancellationError()
            }
        }
    }

    private func updateTransportLifecycle(
        _ lifecycle: ProtocolLifecycle,
        protocolVersion: String
    ) async {
        if let transport = connection as? any ProtocolLifecycleUpdating {
            await transport.updateProtocolLifecycle(lifecycle, protocolVersion: protocolVersion)
        }
    }

    private func isRecognizedPerRequestMetadataError(_ error: Swift.Error) -> Bool {
        guard let mcpError = error as? MCPError,
            case .remote(let code, _, _) = mcpError
        else {
            return false
        }
        return code == ProtocolErrorCode.headerMismatch
            || code == ProtocolErrorCode.missingRequiredClientCapability
            || code == ProtocolErrorCode.unsupportedProtocolVersion
    }

    private enum DiscoveryFailureDisposition {
        case initializationBased
        case inconclusive(Swift.Error)
    }

    private func classifyDiscoveryFailure(
        _ error: Swift.Error
    ) -> DiscoveryFailureDisposition {
        if let probeError = error as? ProtocolLifecycleProbeError {
            switch probeError {
            case .initializationBasedResponse:
                return .initializationBased
            case .correlatedHTTPResponse(let statusCode, let remoteError):
                guard statusCode == 200 || [400, 404, 405].contains(statusCode),
                    !isRecognizedPerRequestMetadataError(remoteError)
                else {
                    return .inconclusive(remoteError)
                }
                return .initializationBased
            case .inconclusive(let error):
                return .inconclusive(error)
            }
        }

        if connection is any HTTPProtocolNegotiationTransport {
            return .inconclusive(error)
        }
        guard !isRecognizedPerRequestMetadataError(error) else {
            return .inconclusive(error)
        }
        return .initializationBased
    }

    private func underlyingDiscoveryError(_ error: Swift.Error) -> Swift.Error {
        guard let probeError = error as? ProtocolLifecycleProbeError else { return error }
        switch probeError {
        case .initializationBasedResponse:
            return error
        case .correlatedHTTPResponse(_, let error), .inconclusive(let error):
            return error
        }
    }

    private func mutuallySupportedVersion(from error: Swift.Error) -> String? {
        guard let mcpError = error as? MCPError,
            case .remote(let code, _, let value) = mcpError,
            code == ProtocolErrorCode.unsupportedProtocolVersion,
            let value,
            let data = try? JSONEncoder().encode(value),
            let details = try? JSONDecoder().decode(
                UnsupportedProtocolVersionData.self, from: data)
        else {
            return nil
        }
        return Version.preferenceOrder.first {
            Version.perRequestMetadataSupported.contains($0)
                && details.supported.contains($0)
        }
    }

    private func encodeRequest<M: Method>(
        _ request: Request<M>,
        logLevel: LogLevel? = nil
    ) throws -> Data {
        guard selectedProtocolLifecycle == .perRequestMetadata,
            let selectedProtocolVersion
        else {
            return try encoder.encode(request)
        }
        return try PerRequestMetadataWire.encodeRequest(
            request,
            protocolVersion: selectedProtocolVersion,
            clientInfo: clientInfo,
            clientCapabilities: perRequestMetadataCapabilities,
            logLevel: logLevel,
            using: encoder
        )
    }

    private var perRequestMetadataCapabilities: Capabilities {
        var result = capabilities
        if result.roots != nil {
            result.roots = .init()
        }
        return result
    }

    /// Internal initialization implementation
    private func _initialize() async throws -> Initialize.Result {
        let request = Initialize.request(
            .init(
                protocolVersion: Version.latest,
                capabilities: capabilities,
                clientInfo: clientInfo
            ))

        let result = try await sendAndAwait(request)

        self.serverCapabilities = result.capabilities
        self.serverVersion = result.protocolVersion
        self.instructions = result.instructions

        // For HTTP transport, ensure subsequent MCP-Protocol-Version headers
        // reflect the negotiated lifecycle version.
        if let httpTransport = connection as? HTTPClientTransport {
            await httpTransport.updateNegotiatedProtocolVersion(result.protocolVersion)
        }

        initializationNotificationSent = true
        do {
            try await notify(InitializedNotification.message())
        } catch {
            initializationNotificationSent = false
            throw error
        }

        return result
    }

    public func ping() async throws {
        guard selectedProtocolLifecycle != .perRequestMetadata else {
            throw MCPError.methodNotFound(
                "ping is not part of protocol version \(Version.perRequestMetadataVersion)")
        }
        let request = Ping.request()
        _ = try await sendAndAwait(request)
    }

    // MARK: - Prompts

    public func getPrompt(name: String, arguments: [String: String]? = nil) async throws
        -> (description: String?, messages: [Prompt.Message])
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request = GetPrompt.request(.init(name: name, arguments: arguments))
        let result = try await sendAndAwait(request)
        return (description: result.description, messages: result.messages)
    }

    public func listPrompts(cursor: String? = nil) async throws
        -> (prompts: [Prompt], nextCursor: String?)
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request: Request<ListPrompts>
        if let cursor = cursor {
            request = ListPrompts.request(.init(cursor: cursor))
        } else {
            request = ListPrompts.request(.init())
        }
        let result = try await sendAndAwait(request)
        return (prompts: result.prompts, nextCursor: result.nextCursor)
    }

    // MARK: - Resources

    public func readResource(uri: String) async throws -> [Resource.Content] {
        try validateServerCapability(\.resources, "Resources")
        let request = ReadResource.request(.init(uri: uri))
        let result = try await sendAndAwait(request)
        return result.contents
    }

    public func listResources(cursor: String? = nil) async throws -> (
        resources: [Resource], nextCursor: String?
    ) {
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResources>
        if let cursor = cursor {
            request = ListResources.request(.init(cursor: cursor))
        } else {
            request = ListResources.request(.init())
        }
        let result = try await sendAndAwait(request)
        return (resources: result.resources, nextCursor: result.nextCursor)
    }

    public func subscribeToResource(uri: String) async throws {
        guard selectedProtocolLifecycle != .perRequestMetadata else {
            throw MCPError.methodNotFound(
                "Use subscriptions/listen for protocol version \(Version.perRequestMetadataVersion)")
        }
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceSubscribe.request(.init(uri: uri))
        _ = try await sendAndAwait(request)
    }

    public func listResourceTemplates(cursor: String? = nil) async throws -> (
        templates: [Resource.Template], nextCursor: String?
    ) {
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResourceTemplates>
        if let cursor = cursor {
            request = ListResourceTemplates.request(.init(cursor: cursor))
        } else {
            request = ListResourceTemplates.request(.init())
        }
        let result = try await sendAndAwait(request)
        return (templates: result.templates, nextCursor: result.nextCursor)
    }

    // MARK: - Tools

    public func listTools(cursor: String? = nil) async throws -> (
        tools: [Tool], nextCursor: String?
    ) {
        try validateServerCapability(\.tools, "Tools")
        let request: Request<ListTools>
        if let cursor = cursor {
            request = ListTools.request(.init(cursor: cursor))
        } else {
            request = ListTools.request(.init())
        }
        let result = try await sendAndAwait(request)
        if selectedProtocolLifecycle == .perRequestMetadata,
            let schemas = connection as? any ToolHeaderSchemaManaging
        {
            let tools = await schemas.updateToolHeaderSchemas(
                result.tools,
                replacing: cursor == nil
            )
            return (tools: tools, nextCursor: result.nextCursor)
        }
        return (tools: result.tools, nextCursor: result.nextCursor)
    }

    /// Call a tool on the server.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Arguments to use for the tool call.
    ///   - meta: Optional request metadata including progress token. If `progressToken` is specified,
    ///           the caller is requesting out-of-band progress notifications for this request.
    ///           Use `onNotification(ProgressNotification.self)` to receive progress updates.
    /// - Returns: A tuple containing the tool's content response and an optional error flag.
    /// - Note: For advanced use cases requiring cancellation support, use `send()` directly to get a `RequestContext`.
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#calling-tools
    public func callTool(
        name: String,
        arguments: [String: Value]? = nil,
        meta: Metadata? = nil
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments, meta: meta))
        let result = try await sendAndAwait(request)
        return (content: result.content, isError: result.isError)
    }

    /// Call a tool on the server.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Arguments to use for the tool call.
    ///   - meta: Optional request metadata including progress token. If `progressToken` is specified,
    ///           the caller is requesting out-of-band progress notifications for this request.
    ///           Use `onNotification(ProgressNotification.self)` to receive progress updates.
    /// - Returns: A tuple containing the tool's content response and an optional error flag.
    /// - Note: For advanced use cases requiring cancellation support, use `send()` directly to get a `RequestContext`.
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#calling-tools
    public func callTool(
        name: String,
        arguments: [String: Value]? = nil,
        meta: Metadata? = nil
    ) throws -> RequestContext<CallTool.Result> {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments, meta: meta))
        return try send(request)
    }

    // MARK: - Sampling

    /// Register a handler for sampling requests from servers
    ///
    /// Sampling allows servers to request LLM completions through the client,
    /// enabling sophisticated agentic behaviors while maintaining human-in-the-loop control.
    ///
    /// The sampling flow follows these steps:
    /// 1. Server sends a `sampling/createMessage` request to the client
    /// 2. Client reviews the request and can modify it (via this handler)
    /// 3. Client samples from an LLM (via this handler)
    /// 4. Client reviews the completion (via this handler)
    /// 5. Client returns the result to the server
    ///
    /// - Parameter handler: A closure that processes sampling requests and returns completions
    /// - Returns: Self for method chaining
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/sampling#how-sampling-works
    @discardableResult
    public func withSamplingHandler(
        _ handler:
            @escaping @Sendable (CreateSamplingMessage.Parameters) async throws ->
            CreateSamplingMessage.Result
    ) -> Self {
        return withMethodHandler(CreateSamplingMessage.self, handler: handler)
    }

    // MARK: - Elicitation

    /// Register a handler for elicitation requests from servers
    ///
    /// The elicitation flow lets servers collect structured input from users during
    /// ongoing interactions. Clients remain in control by mediating the prompt,
    /// collecting the response, and returning the chosen action to the server.
    ///
    /// - Parameter handler: A closure that processes elicitation requests and returns user actions
    /// - Returns: Self for method chaining
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
    @discardableResult
    public func withElicitationHandler(
        _ handler:
            @escaping @Sendable (CreateElicitation.Parameters) async throws ->
            CreateElicitation.Result
    ) -> Self {
        return withMethodHandler(CreateElicitation.self, handler: handler)
    }

    // MARK: - Roots

    /// Register a handler for roots/list requests from servers
    ///
    /// Roots define filesystem boundaries that servers can operate within.
    /// Unlike other MCP features, roots use bidirectional communication where
    /// servers send requests TO clients to discover available roots.
    ///
    /// - Parameter handler: A closure that returns the list of available roots
    /// - Returns: Self for method chaining
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
    @discardableResult
    public func withRootsHandler(
        _ handler: @escaping @Sendable () async throws -> [Root]
    ) -> Self {
        return withMethodHandler(ListRoots.self) { _ in
            let roots = try await handler()
            return ListRoots.Result(roots: roots)
        }
    }

    /// Notify the server that the list of roots has changed
    ///
    /// Clients should send this notification when roots are added, removed,
    /// or modified to inform connected servers of the change.
    ///
    /// - Throws: MCPError if the client is not connected
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
    public func notifyRootsChanged() async throws {
        guard selectedProtocolLifecycle != .perRequestMetadata else {
            throw MCPError.methodNotFound(
                "notifications/roots/list_changed is not part of protocol version \(Version.perRequestMetadataVersion)")
        }
        let notification = RootsListChangedNotification.message()
        try await notify(notification)
    }

    // MARK: - Logging

    /// Set the minimum logging level for server log messages.
    ///
    /// Servers that declare the `logging` capability will send log messages via
    /// `notifications/message` notifications. Use this method to control which
    /// severity levels the server should send.
    ///
    /// - Parameter level: The minimum log level to receive
    /// - Throws: MCPError if the client is not connected or if the server doesn't support logging
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
    public func setLoggingLevel(_ level: LogLevel) async throws {
        guard selectedProtocolLifecycle != .perRequestMetadata else {
            throw MCPError.methodNotFound(
                "Use request-scoped log levels for protocol version \(Version.perRequestMetadataVersion)")
        }
        try validateServerCapability(\.logging, "Logging")
        let request = SetLoggingLevel.request(.init(level: level))
        _ = try await sendAndAwait(request)
    }

    // MARK: - Completions

    /// Request completion suggestions for a prompt argument.
    ///
    /// Servers that declare the `completions` capability can provide autocompletion
    /// suggestions for prompt arguments as users type.
    ///
    /// - Parameters:
    ///   - promptName: The name of the prompt
    ///   - argumentName: The name of the argument being completed
    ///   - argumentValue: The current (partial) value of the argument
    ///   - context: Optional context with already-resolved arguments
    /// - Returns: A completion result containing suggested values
    /// - Throws: MCPError if the client is not connected or if the server doesn't support completions
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/completion/
    public func complete(
        promptName: String,
        argumentName: String,
        argumentValue: String,
        context: [String: String]? = nil
    ) async throws -> Complete.Result.Completion {
        try validateServerCapability(\.completions, "Completions")
        let request = Complete.request(
            .init(
                ref: .prompt(.init(name: promptName)),
                argument: .init(name: argumentName, value: argumentValue),
                context: context.map { .init(arguments: $0) }
            )
        )
        let result = try await sendAndAwait(request)
        return result.completion
    }

    /// Request completion suggestions for a resource template argument.
    ///
    /// Servers that declare the `completions` capability can provide autocompletion
    /// suggestions for resource template arguments as users type.
    ///
    /// - Parameters:
    ///   - resourceURI: The URI of the resource template
    ///   - argumentName: The name of the argument being completed
    ///   - argumentValue: The current (partial) value of the argument
    ///   - context: Optional context with already-resolved arguments
    /// - Returns: A completion result containing suggested values
    /// - Throws: MCPError if the client is not connected or if the server doesn't support completions
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/completion/
    public func complete(
        resourceURI: String,
        argumentName: String,
        argumentValue: String,
        context: [String: String]? = nil
    ) async throws -> Complete.Result.Completion {
        try validateServerCapability(\.completions, "Completions")
        let request = Complete.request(
            .init(
                ref: .resource(.init(uri: resourceURI)),
                argument: .init(name: argumentName, value: argumentValue),
                context: context.map { .init(arguments: $0) }
            )
        )
        let result = try await sendAndAwait(request)
        return result.completion
    }

    // MARK: -

    private func handleResponse(_ response: Response<AnyMethod>) async {
        await logger?.trace(
            "Processing response",
            metadata: ["id": "\(response.id)"])

        // Attempt to remove the pending request using the response ID.
        // Resume with the response only if it hadn't yet been removed.
        if let removedRequest = self.removePendingRequest(id: response.id) {
            // If we successfully removed it, resume its continuation.
            switch response.result {
            case .success(let value):
                if let error = resultTypeValidationError(for: value) {
                    removedRequest.resume(throwing: error)
                } else {
                    removedRequest.resume(returning: value)
                }
            case .failure(let error):
                removedRequest.resume(throwing: error)
            }
        } else {
            // Request was already removed (e.g., by send error handler or disconnect).
            // Log this, but it's not an error in race condition scenarios.
            await logger?.warning(
                "Attempted to handle response for already removed request",
                metadata: ["id": "\(response.id)"]
            )
        }
    }

    private func handleMessage(_ message: Message<AnyNotification>) async {
        await logger?.trace(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        // A received change notification invalidates connection-scoped state even when it
        // cannot be delivered to a subscriber: a dropped, unfiltered, or unknown-subscription
        // notification still reports that the server's list changed.
        if message.method == ToolListChangedNotification.name,
            let schemas = connection as? any ToolHeaderSchemaManaging
        {
            await schemas.clearToolHeaderSchemas()
        }

        guard await processSubscriptionMessage(message) else { return }

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

    private func reestablishSubscriptions() async {
        for id in Array(subscriptions.keys) {
            do {
                try startSubscriptionAttempt(id)
            } catch {
                if subscriptions[id]?.hasBeenAcknowledged == true {
                    _ = await yieldSubscriptionEvent(.disconnected, to: id)
                } else {
                    failSubscription(id, error: error)
                }
            }
        }
    }

    private func startSubscriptionAttempt(_ id: ID) throws {
        guard connection != nil,
            selectedProtocolLifecycle == .perRequestMetadata,
            var subscription = subscriptions[id]
        else {
            throw MCPError.internalError("Client connection not initialized")
        }
        guard subscription.attemptTask == nil else { return }

        let generation = connectionGeneration
        subscription.attemptGeneration = generation
        subscription.isAwaitingAcknowledgment = true
        subscriptions[id] = subscription

        let request = SubscriptionsListen.request(
            id: id,
            .init(notifications: subscription.requested)
        )
        let context = try send(request)
        let attemptTask = Task { [weak self] in
            do {
                let result = try await context.value
                await self?.subscriptionCompleted(id, generation: generation, result: result)
            } catch {
                await self?.subscriptionFailed(id, generation: generation, error: error)
            }
        }
        if var current = subscriptions[id], current.attemptGeneration == generation {
            current.attemptTask = attemptTask
            subscriptions[id] = current
        } else {
            attemptTask.cancel()
        }
    }

    private func processSubscriptionMessage(_ message: AnyMessage) async -> Bool {
        let subscriptionID = Self.subscriptionID(in: message.params)
        if message.method == SubscriptionsAcknowledgedNotification.name {
            guard let subscriptionID else {
                let error = MCPError.invalidRequest(
                    "Subscription acknowledgment is missing its subscription ID")
                for id in Array(subscriptions.keys)
                where subscriptions[id]?.isAwaitingAcknowledgment == true {
                    await failSubscriptionAndCancel(id, error: error)
                }
                return false
            }
            guard var subscription = subscriptions[subscriptionID] else {
                await logger?.warning(
                    "Received acknowledgment for an unknown subscription",
                    metadata: ["subscriptionID": "\(subscriptionID)"]
                )
                return false
            }
            guard subscription.isAwaitingAcknowledgment,
                let typedMessage = try? decoder.decode(
                    Message<SubscriptionsAcknowledgedNotification>.self,
                    from: encoder.encode(message)
                ),
                typedMessage.params.notifications.isSubset(of: subscription.requested)
            else {
                await failSubscriptionAndCancel(
                    subscriptionID,
                    error: MCPError.invalidRequest(
                        "Subscription acknowledgment is duplicated, malformed, or exceeds the requested filter")
                )
                return false
            }

            let accepted = typedMessage.params.notifications
            let continuation = subscription.acknowledgmentContinuation
            subscription.acknowledged = accepted
            subscription.isAwaitingAcknowledgment = false
            subscription.hasBeenAcknowledged = true
            subscriptions[subscriptionID] = subscription
            guard await yieldSubscriptionEvent(.acknowledged(accepted), to: subscriptionID) else {
                return false
            }
            subscriptions[subscriptionID]?.acknowledgmentContinuation = nil
            continuation?.resume(returning: accepted)
            return true
        }

        guard let subscriptionID else { return true }
        guard let subscription = subscriptions[subscriptionID] else {
            await logger?.warning(
                "Received notification for an unknown subscription",
                metadata: [
                    "subscriptionID": "\(subscriptionID)",
                    "method": "\(message.method)",
                ]
            )
            return false
        }
        guard !subscription.isAwaitingAcknowledgment,
            let acknowledged = subscription.acknowledged,
            acknowledged.permits(method: message.method, parameters: message.params)
        else {
            await failSubscriptionAndCancel(
                subscriptionID,
                error: MCPError.invalidRequest(
                    "Subscription notification arrived before acknowledgment or outside its filter")
            )
            return false
        }
        return await yieldSubscriptionEvent(
            .notification(.init(
                subscriptionID: subscriptionID,
                method: message.method,
                parameters: message.params
            )),
            to: subscriptionID
        )
    }

    private func subscriptionCompleted(
        _ id: ID,
        generation: Int,
        result: SubscriptionsListen.Result
    ) {
        guard let subscription = subscriptions[id],
            subscription.attemptGeneration == generation
        else {
            return
        }
        guard !subscription.isAwaitingAcknowledgment,
            result.resultType == .complete,
            result._meta.subscriptionID == id
        else {
            failSubscription(
                id,
                error: MCPError.invalidRequest(
                    "Subscription closed with missing or mismatched correlation metadata")
            )
            return
        }
        subscriptions.removeValue(forKey: id)
        subscription.eventsContinuation.finish()
    }

    private func subscriptionFailed(_ id: ID, generation: Int, error: Swift.Error) async {
        guard var subscription = subscriptions[id],
            subscription.attemptGeneration == generation
        else {
            return
        }
        subscription.attemptTask = nil
        subscription.attemptGeneration = nil
        subscription.isAwaitingAcknowledgment = true
        subscriptions[id] = subscription

        guard generation == connectionGeneration, connection != nil else { return }
        if subscription.hasBeenAcknowledged, Self.isSubscriptionDisconnection(error) {
            await yieldSubscriptionEvent(.disconnected, to: id)
        } else {
            failSubscription(id, error: error)
        }
    }

    private static func isSubscriptionDisconnection(_ error: Swift.Error) -> Bool {
        guard let error = error as? MCPError else { return false }
        switch error {
        case .connectionClosed, .transportError:
            return true
        default:
            return false
        }
    }

    private func failSubscriptionAndCancel(_ id: ID, error: Swift.Error) async {
        guard let subscription = subscriptions[id] else { return }
        let shouldCancel = subscription.attemptGeneration == connectionGeneration
        failSubscription(id, error: error)
        if shouldCancel {
            try? await cancelRequest(id, reason: "Invalid subscription stream")
        }
    }

    @discardableResult
    private func yieldSubscriptionEvent(
        _ event: SubscriptionEvent,
        to id: ID
    ) async -> Bool {
        guard let continuation = subscriptions[id]?.eventsContinuation else { return false }
        switch continuation.yield(event) {
        case .enqueued:
            return true
        case .dropped:
            await failSubscriptionAndCancel(
                id,
                error: MCPError.internalError("Subscription event buffer is full")
            )
            return false
        case .terminated:
            try? await cancelSubscription(id, reason: "Listener terminated")
            return false
        @unknown default:
            await failSubscriptionAndCancel(
                id,
                error: MCPError.internalError("Subscription event could not be delivered")
            )
            return false
        }
    }

    private func failSubscription(_ id: ID, error: Swift.Error) {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        subscription.acknowledgmentContinuation?.resume(throwing: error)
        subscription.eventsContinuation.finish(throwing: error)
        subscription.attemptTask?.cancel()
    }

    private func failSubscriptions(_ error: Swift.Error) {
        for id in Array(subscriptions.keys) {
            failSubscription(id, error: error)
        }
    }

    private static func subscriptionID(in parameters: Value) -> ID? {
        guard let value = parameters.objectValue?["_meta"]?
            .objectValue?[ProtocolMetadataKey.subscriptionID]
        else {
            return nil
        }
        if let string = value.stringValue { return .string(string) }
        if let number = value.intValue { return .number(number) }
        return nil
    }

    private func handleIncomingRequest(_ request: Request<AnyMethod>) async {
        await logger?.trace(
            "Processing incoming request from server",
            metadata: ["method": "\(request.method)", "id": "\(request.id)"])

        if selectedProtocolLifecycle == .perRequestMetadata {
            let response = AnyMethod.response(
                id: request.id,
                error: MCPError.invalidRequest(
                    "Standalone server requests are not supported by this protocol lifecycle")
            )
            try? await send(response)
            return
        }

        if configuration.strict,
            selectedProtocolLifecycle == .initializationBased,
            !initializationNotificationSent,
            request.method != Ping.name
        {
            let response = AnyMethod.response(
                id: request.id,
                error: MCPError.invalidRequest(
                    "Server request arrived before notifications/initialized")
            )
            try? await send(response)
            return
        }

        guard let handler = methodHandlers[request.method] else {
            await logger?.warning(
                "No handler registered for method",
                metadata: ["method": "\(request.method)"])
            let error = MCPError.methodNotFound("Unknown method: \(request.method)")
            let response = AnyMethod.response(id: request.id, error: error)
            do {
                try await send(response)
            } catch {
                await logger?.error(
                    "Failed to send error response",
                    metadata: ["error": "\(error)"])
            }
            return
        }

        do {
            let response = try await handler(request)
            try await send(response)
        } catch {
            let mcpError = error as? MCPError ?? MCPError.internalError(error.localizedDescription)
            let response = AnyMethod.response(id: request.id, error: mcpError)
            do {
                try await send(response)
            } catch {
                await logger?.error(
                    "Failed to send error response",
                    metadata: ["error": "\(error)"])
            }
        }
    }

    // MARK: -

    /// Validate the server capabilities.
    /// Throws an error if the client is configured to be strict and the capability is not supported.
    private func validateServerCapability<T>(
        _ keyPath: KeyPath<Server.Capabilities, T?>,
        _ name: String
    )
        throws
    {
        if configuration.strict {
            guard let capabilities = serverCapabilities else {
                throw MCPError.methodNotFound("Server capabilities not initialized")
            }
            guard capabilities[keyPath: keyPath] != nil else {
                throw MCPError.methodNotFound("\(name) is not supported by the server")
            }
        }
    }

    private func resultTypeValidationError(for value: Value) -> MCPError? {
        guard selectedProtocolLifecycle == .perRequestMetadata else { return nil }
        guard let result = value.objectValue else {
            return MCPError.internalError(
                "Per-request metadata response result must be a JSON object")
        }
        guard let resultTypeValue = result["resultType"] else { return nil }
        guard let resultType = resultTypeValue.stringValue else {
            return MCPError.internalError(
                "Per-request metadata response has a non-string resultType")
        }
        switch resultType {
        case "complete":
            return nil
        case "input_required" where configuration.multiRoundTripMode == .disabled:
            return MCPError.internalError("Multi-round-trip handling is disabled")
        case "input_required":
            return nil
        default:
            return MCPError.invalidRequest("Unsupported resultType: \(resultType)")
        }
    }

    // Add handler for batch responses
    private func handleBatchResponse(_ responses: [AnyResponse]) async {
        await logger?.trace("Processing batch response", metadata: ["count": "\(responses.count)"])
        for response in responses {
            // Attempt to remove the pending request.
            // If successful, pendingRequest contains the request.
            if let pendingRequest = self.removePendingRequest(id: response.id) {
                // If we successfully removed it, handle the response using the pending request.
                switch response.result {
                case .success(let value):
                    if let error = resultTypeValidationError(for: value) {
                        pendingRequest.resume(throwing: error)
                    } else {
                        pendingRequest.resume(returning: value)
                    }
                case .failure(let error):
                    pendingRequest.resume(throwing: error)
                }
            } else {
                // If removal failed, it means the request ID was not found (or already handled).
                // Log a warning.
                await logger?.warning(
                    "Received response in batch for unknown or already handled request ID",
                    metadata: ["id": "\(response.id)"]
                )
            }
        }
    }
}

// MARK: - Codable

extension Client.Capabilities.Sampling: Codable {
    private enum CodingKeys: String, CodingKey {
        case tools, context
    }

    public init(from decoder: Decoder) throws {
        // Handle both empty object {} and object with sub-capabilities
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.tools = try container.decodeIfPresent(Tools.self, forKey: .tools)
            self.context = try container.decodeIfPresent(Context.self, forKey: .context)
        } else {
            // Empty object - no capabilities
            self.tools = nil
            self.context = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(context, forKey: .context)
    }
}

extension Client.Capabilities.Elicitation: Codable {
    private enum CodingKeys: String, CodingKey {
        case form, url
    }

    public init(from decoder: Decoder) throws {
        // Handle both empty object {} and object with sub-capabilities
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.form = try container.decodeIfPresent(Form.self, forKey: .form)
            self.url = try container.decodeIfPresent(URL.self, forKey: .url)
            // If both are nil, default to form for backward compatibility
            if self.form == nil && self.url == nil {
                self.form = Form()
            }
        } else {
            // Empty object - default to form-only for backward compatibility
            self.form = Form()
            self.url = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(form, forKey: .form)
        try container.encodeIfPresent(url, forKey: .url)
    }
}
