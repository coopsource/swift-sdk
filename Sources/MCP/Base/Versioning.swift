import Foundation

/// The Model Context Protocol uses string-based version identifiers
/// following the format YYYY-MM-DD, to indicate
/// the last date backwards incompatible changes were made.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2026-07-28/
public enum Version {
    /// The first protocol version that carries lifecycle metadata on every request.
    public static let perRequestMetadataVersion = "2026-07-28"

    /// All protocol versions supported by this implementation.
    public static let supported: Set<String> = [
        perRequestMetadataVersion,
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    /// The newest initialization-based protocol version supported by this implementation.
    public static let latestInitializationVersion = "2025-11-25"

    /// The latest protocol version selected by the default lifecycle behavior.
    ///
    /// This remains initialization-based until automatic negotiation is enabled by default.
    public static let latest = latestInitializationVersion

    /// Protocol versions in preference order for explicit negotiation.
    static let preferenceOrder = [
        perRequestMetadataVersion,
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    static let perRequestMetadataSupported: Set<String> = [perRequestMetadataVersion]

    /// Negotiates the protocol version based on the client's request and server's capabilities.
    /// - Parameter clientRequestedVersion: The protocol version requested by the client.
    /// - Returns: The negotiated protocol version. If the client's requested version is supported,
    ///            that version is returned. Otherwise, the server's latest supported version is returned.
    static func negotiate(clientRequestedVersion: String) -> String {
        if supported.contains(clientRequestedVersion)
            && clientRequestedVersion != perRequestMetadataVersion
        {
            return clientRequestedVersion
        }
        return latestInitializationVersion
    }
}

/// The lifecycle mechanism used for a protocol connection.
public enum ProtocolLifecycle: String, Hashable, Codable, Sendable {
    /// The connection exchanges capabilities through `initialize`.
    case initializationBased

    /// Every request declares its protocol version and client capabilities in `_meta`.
    case perRequestMetadata
}
