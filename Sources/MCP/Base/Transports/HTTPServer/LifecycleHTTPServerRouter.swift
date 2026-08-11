import Foundation

/// Routes one HTTP endpoint between initialization-based sessions and the
/// per-request-metadata lifecycle.
///
/// The router does not own either server's lifecycle. Start the server attached
/// to ``StreamableHTTPServerTransport`` before accepting requests, and use the
/// initialization handler to retain the application's existing session factory.
public actor LifecycleHTTPServerRouter {
    /// Handles requests using the application's initialization-based session path.
    public typealias InitializationBasedRequestHandler =
        @Sendable (HTTPRequest) async -> HTTPResponse

    public nonisolated let protocolMode: Server.ProtocolMode

    private let perRequestMetadataTransport: StreamableHTTPServerTransport
    private let initializationBasedRequestHandler: InitializationBasedRequestHandler

    /// Creates a router over the two HTTP lifecycle implementations.
    ///
    /// - Parameters:
    ///   - protocolMode: The lifecycle mechanisms exposed by this endpoint.
    ///   - perRequestMetadataTransport: The transport attached to the single
    ///     per-request-metadata server.
    ///   - initializationBasedRequestHandler: The existing initialization and session
    ///     handler. It remains responsible for creating, locating, and closing
    ///     initialization-based sessions.
    public init(
        protocolMode: Server.ProtocolMode = .initializationAndPerRequestMetadata,
        perRequestMetadataTransport: StreamableHTTPServerTransport,
        initializationBasedRequestHandler: @escaping InitializationBasedRequestHandler
    ) {
        self.protocolMode = protocolMode
        self.perRequestMetadataTransport = perRequestMetadataTransport
        self.initializationBasedRequestHandler = initializationBasedRequestHandler
    }

    /// Routes a framework-neutral request according to its selected lifecycle.
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        switch protocolMode {
        case .initializationOnly:
            return await initializationBasedRequestHandler(request)
        case .perRequestMetadataOnly:
            return await perRequestMetadataTransport.handleRequest(request)
        case .initializationAndPerRequestMetadata:
            if Self.usesPerRequestMetadata(request) {
                return await perRequestMetadataTransport.handleRequest(request)
            }
            return await initializationBasedRequestHandler(request)
        }
    }

    private static func usesPerRequestMetadata(_ request: HTTPRequest) -> Bool {
        if carriesLifecycleMetadata(request.body) {
            return true
        }

        if let body = request.body,
            JSONRPCMessageKind(data: body)?.isInitializeRequest == true
        {
            return false
        }

        guard let version = request.header(HTTPHeaderName.protocolVersion),
            !version.isEmpty
        else {
            return false
        }

        if Version.supported.contains(version) {
            return Version.perRequestMetadataSupported.contains(version)
        }

        // An unrecognized header cannot identify an initialization-based revision.
        // Route it to protocol validation so the client receives a structured error.
        return true
    }

    private static func carriesLifecycleMetadata(_ body: Data?) -> Bool {
        guard let body,
            let value = try? JSONDecoder().decode(Value.self, from: body),
            let metadata = value.objectValue?["params"]?.objectValue?["_meta"]?.objectValue
        else {
            return false
        }

        return metadata[ProtocolMetadataKey.protocolVersion] != nil
            || metadata[ProtocolMetadataKey.clientInfo] != nil
            || metadata[ProtocolMetadataKey.clientCapabilities] != nil
    }
}
