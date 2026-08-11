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

/// Classifies the result of an HTTP per-request metadata compatibility probe.
package enum ProtocolLifecycleProbeError: Error {
    case initializationBasedResponse
    case inconclusive(MCPError)
}
