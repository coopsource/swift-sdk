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

    /// The newest protocol version supported by this implementation.
    public static let latest = perRequestMetadataVersion

    /// Returns the protocol versions supported by one lifecycle mechanism.
    ///
    /// Use this partition when an endpoint supports only initialization-based sessions or only
    /// per-request metadata. The union of both lifecycle sets is ``supported``. This partitions
    /// lifecycle semantics only; a transport binding may support a narrower version set.
    public static func supported(for lifecycle: ProtocolLifecycle) -> Set<String> {
        switch lifecycle {
        case .initializationBased:
            return supported.subtracting(perRequestMetadataSupported)
        case .perRequestMetadata:
            return perRequestMetadataSupported
        }
    }

    /// Returns the versions implemented by the Streamable HTTP binding for one lifecycle.
    ///
    /// The initialization-based Streamable HTTP binding was introduced in `2025-03-26`.
    /// Protocol version `2024-11-05` instead uses the deprecated HTTP+SSE binding, so it is a
    /// member of ``supported(for:)`` but **not** of this set.
    ///
    /// Prefer ``supported(for:)`` to describe lifecycle semantics. Use this narrower partition
    /// when the question is what a *Streamable HTTP endpoint* actually implements — for example
    /// when an application supplies its own ``HTTPRequestValidator`` and needs to enforce the
    /// same version set this package's own transports enforce. Deriving that set by hand
    /// instead reproduces a rule that drifts silently as revisions are added.
    public static func streamableHTTPSupported(
        for lifecycle: ProtocolLifecycle
    ) -> Set<String> {
        switch lifecycle {
        case .initializationBased:
            return supported(for: lifecycle).intersection([
                "2025-03-26",
                "2025-06-18",
                "2025-11-25",
            ])
        case .perRequestMetadata:
            return supported(for: lifecycle)
        }
    }

    /// Protocol versions in preference order for explicit negotiation.
    static let preferenceOrder = [
        perRequestMetadataVersion,
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    static let perRequestMetadataSupported: Set<String> = [perRequestMetadataVersion]

    /// Negotiates an initialization-based protocol version from the client's request.
    ///
    /// Per-request-metadata versions are selected independently on each request and are not valid
    /// results for the `initialize` method.
    /// - Parameter clientRequestedVersion: The protocol version requested by the client.
    /// - Returns: The requested initialization-based version when supported; otherwise the latest
    ///            supported initialization-based version.
    static func negotiate(clientRequestedVersion: String) -> String {
        negotiate(
            clientRequestedVersion: clientRequestedVersion,
            supportedVersions: supported(for: .initializationBased)
        ) ?? latestInitializationVersion
    }

    /// Negotiates from an authoritative initialization-version allowlist.
    ///
    /// - Returns: The requested version when allowed, otherwise the most preferred allowed
    ///   initialization version, or `nil` when the allowlist contains no initialization version.
    static func negotiate(
        clientRequestedVersion: String,
        supportedVersions: Set<String>
    ) -> String? {
        let initializationVersions = supportedVersions.intersection(
            supported(for: .initializationBased)
        )
        if initializationVersions.contains(clientRequestedVersion) {
            return clientRequestedVersion
        }
        return preferenceOrder.first(where: initializationVersions.contains)
    }
}

/// The lifecycle mechanism used for a protocol connection.
public enum ProtocolLifecycle: String, Hashable, Codable, Sendable {
    /// The connection exchanges capabilities through `initialize`.
    case initializationBased

    /// Every request declares its protocol version and client capabilities in `_meta`.
    case perRequestMetadata
}
