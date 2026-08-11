/// Metadata keys reserved by MCP protocol version 2026-07-28.
public enum ProtocolMetadataKey {
    public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    public static let clientInfo = "io.modelcontextprotocol/clientInfo"
    public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    public static let serverInfo = "io.modelcontextprotocol/serverInfo"
    public static let logLevel = "io.modelcontextprotocol/logLevel"
    public static let subscriptionID = "io.modelcontextprotocol/subscriptionId"
}

/// The disposition of a successful MCP result.
public enum ResultType: Hashable, Codable, Sendable {
    case complete
    case inputRequired
    case other(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "complete": self = .complete
        case "input_required": self = .inputRequired
        default: self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        let value: String
        switch self {
        case .complete: value = "complete"
        case .inputRequired: value = "input_required"
        case .other(let other): value = other
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// The authorization boundary within which a cached response may be reused.
public enum CacheScope: String, Hashable, Codable, Sendable {
    case `public`
    case `private`
}

/// Cache information returned by methods whose results may be reused.
public struct CachePolicy: Hashable, Codable, Sendable {
    public var ttlMs: Int
    public var cacheScope: CacheScope

    public init(ttlMs: Int, cacheScope: CacheScope) {
        self.ttlMs = ttlMs
        self.cacheScope = cacheScope
    }
}

/// Error codes allocated by MCP protocol version 2026-07-28.
public enum ProtocolErrorCode {
    public static let headerMismatch = -32020
    public static let missingRequiredClientCapability = -32021
    public static let unsupportedProtocolVersion = -32022
}

/// Data returned with an unsupported protocol version error.
public struct UnsupportedProtocolVersionData: Hashable, Codable, Sendable {
    public var supported: [String]
    public var requested: String

    public init(supported: [String], requested: String) {
        self.supported = supported
        self.requested = requested
    }
}

/// Data returned when a request omitted a capability required by the server.
public struct MissingRequiredClientCapabilityData: Hashable, Codable, Sendable {
    public var requiredCapabilities: Client.Capabilities

    public init(requiredCapabilities: Client.Capabilities) {
        self.requiredCapabilities = requiredCapabilities
    }
}

/// Requests the versions and capabilities supported by a server.
public enum Discover: Method {
    public static let name = "server/discover"

    public struct Parameters: Hashable, Codable, Sendable {
        public var _meta: Metadata

        public init(_meta: Metadata) {
            self._meta = _meta
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public var supportedVersions: [String]
        public var capabilities: Server.Capabilities
        public var instructions: String?
        public var ttlMs: Int
        public var cacheScope: CacheScope
        public var resultType: ResultType
        public var _meta: Metadata?

        public init(
            supportedVersions: [String],
            capabilities: Server.Capabilities,
            instructions: String? = nil,
            ttlMs: Int,
            cacheScope: CacheScope,
            resultType: ResultType = .complete,
            _meta: Metadata? = nil
        ) {
            self.supportedVersions = supportedVersions
            self.capabilities = capabilities
            self.instructions = instructions
            self.ttlMs = ttlMs
            self.cacheScope = cacheScope
            self.resultType = resultType
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey {
            case supportedVersions, capabilities, instructions, ttlMs, cacheScope, resultType, _meta
        }

        /// Decodes a discovery result, treating an absent `resultType` as `complete`.
        ///
        /// A server that omits `resultType` predates the field's introduction, and the
        /// specification requires clients to treat such a result as complete.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            supportedVersions = try container.decode([String].self, forKey: .supportedVersions)
            capabilities = try container.decode(Server.Capabilities.self, forKey: .capabilities)
            instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            ttlMs = try container.decode(Int.self, forKey: .ttlMs)
            cacheScope = try container.decode(CacheScope.self, forKey: .cacheScope)
            resultType =
                try container.decodeIfPresent(ResultType.self, forKey: .resultType)
                ?? .complete
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
        }
    }
}

/// A successful result that requires client input before the original request can complete.
public struct InputRequiredResult: Hashable, Codable, Sendable {
    public var resultType: ResultType
    public var inputRequests: [String: Value]?
    public var requestState: String?
    public var _meta: Metadata?

    public init(
        inputRequests: [String: Value]? = nil,
        requestState: String? = nil,
        _meta: Metadata? = nil
    ) {
        self.resultType = .inputRequired
        self.inputRequests = inputRequests
        self.requestState = requestState
        self._meta = _meta
    }
}
