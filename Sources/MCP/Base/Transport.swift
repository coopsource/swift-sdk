import Logging

import struct Foundation.Data

/// Protocol defining the transport layer for MCP communication
public protocol Transport: Actor {
    var logger: Logger { get }

    /// Establishes connection with the transport
    func connect() async throws

    /// Disconnects from the transport
    func disconnect() async

    /// Sends data
    func send(_ data: Data) async throws

    /// Receives data in an async sequence
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}

/// Optional transport hook for lifecycle-specific request routing.
///
/// The raw `Transport` interface remains unchanged. Transports whose wire behavior differs
/// between lifecycle mechanisms can adopt this package-only protocol.
package protocol ProtocolLifecycleUpdating: Transport {
    func updateProtocolLifecycle(_ lifecycle: ProtocolLifecycle, protocolVersion: String) async
}

/// Optional transport hook for bindings that support only a subset of protocol versions.
///
/// The server intersects this set with its configured lifecycle modes for discovery and
/// initialization negotiation. Transports that do not adopt this protocol retain the SDK-wide
/// version set.
package protocol TransportProtocolVersionProviding: Transport {
    func supportedProtocolVersions() -> Set<String>
}

/// Identifies transports whose lifecycle fallback is determined by HTTP responses.
package protocol HTTPProtocolNegotiationTransport: Transport {}

/// Optional transport hook for bindings that cancel by closing a request-scoped response.
package protocol RequestStreamCancelling: Transport {
    func cancelRequestStream(id: ID) async
}

/// Optional transport hook for messages that belong to one request-scoped response.
package protocol RequestScopedSending: Transport {
    func send(_ data: Data, relatedTo requestID: ID?) async throws
}

/// Optional transport hook for bindings where closing a response cancels server work.
package protocol RequestCancellationRegistering: Transport {
    func setRequestCancellationHandler(
        _ handler: (@Sendable (ID) async -> Void)?
    ) async
}

/// Optional transport hook for private request IDs used during internal routing.
package protocol OriginalRequestIDProviding: Transport {
    func originalRequestID(for requestID: ID) async -> ID?
}

/// The authorization boundary used for private protocol response caching.
package enum ResponseCacheAuthorizationContext: Hashable, Sendable {
    case known(String)
    case unavailable
}

/// Optional transport hook for isolating private cached responses.
package protocol ResponseCacheAuthorizationContextProviding: Transport {
    func responseCacheAuthorizationContext() async -> ResponseCacheAuthorizationContext
}

/// Optional transport hook for the authorization context used by one completed request attempt.
package protocol ResponseCacheRequestAuthorizationContextProviding: Transport {
    func takeResponseCacheAuthorizationContext(
        for requestID: ID
    ) async -> ResponseCacheAuthorizationContext
}

/// Supplies a stable key for caching a server's protocol lifecycle.
package protocol ProtocolLifecycleCacheKeyProviding: Transport {
    func protocolLifecycleCacheKey() async -> String?
}

/// Optional HTTP-client hook for schemas that define tool parameter headers.
package protocol ToolHeaderSchemaManaging: Transport {
    func updateToolHeaderSchemas(_ tools: [Tool], replacing: Bool) async -> [Tool]
    func toolHeaderPlan(named toolName: String) async -> ToolHeaderPlan?
    func clearToolHeaderSchemas() async
}

/// Classifies the result of an HTTP per-request metadata compatibility probe.
package enum ProtocolLifecycleProbeError: Error {
    case initializationBasedResponse
    case correlatedHTTPResponse(statusCode: Int, error: MCPError)
    case inconclusive(MCPError)
}
