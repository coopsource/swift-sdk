/// Metadata keys reserved by MCP protocol version 2026-07-28.
public enum ProtocolMetadataKey {
    public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    public static let clientInfo = "io.modelcontextprotocol/clientInfo"
    public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    public static let serverInfo = "io.modelcontextprotocol/serverInfo"
    public static let logLevel = "io.modelcontextprotocol/logLevel"
    public static let subscriptionID = "io.modelcontextprotocol/subscriptionId"
}

enum ProtocolExtensionIdentifier {
    /// MCP 2026-07-28 versioning requires extension identifiers to use the
    /// `_meta` key format with a prefix.
    static func isValid(_ identifier: String) -> Bool {
        let segments = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, !segments[0].isEmpty else { return false }

        let labels = segments[0].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy(validLabel) else { return false }

        let name = segments[1]
        guard !name.isEmpty else { return true }
        guard let first = name.first, let last = name.last,
            isASCIIAlphanumeric(first),
            isASCIIAlphanumeric(last)
        else {
            return false
        }
        return name.allSatisfy {
            isASCIIAlphanumeric($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func validLabel(_ label: Substring) -> Bool {
        guard let first = label.first, let last = label.last,
            isASCIILetter(first),
            isASCIIAlphanumeric(last)
        else {
            return false
        }
        return label.allSatisfy { isASCIIAlphanumeric($0) || $0 == "-" }
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        isASCIILetter(character) || isASCIIDigit(character)
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
            let value = character.unicodeScalars.first?.value
        else {
            return false
        }
        return (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
            let value = character.unicodeScalars.first?.value
        else {
            return false
        }
        return (0x30...0x39).contains(value)
    }
}

enum ProtocolCapabilityValidation {
    static func invalidReason(
        experimental: [String: Value]?,
        extensions: [String: Value]?
    ) -> String? {
        if let name = experimental?.first(where: { $0.value.objectValue == nil })?.key {
            return "Experimental capability settings for \(name) must be a JSON object"
        }
        if let name = extensions?.first(where: { $0.value.objectValue == nil })?.key {
            return "Extension settings for \(name) must be a JSON object"
        }
        if let name = extensions?.keys.first(where: {
            !ProtocolExtensionIdentifier.isValid($0)
        }) {
            return "Invalid MCP extension identifier: \(name)"
        }
        return nil
    }
}

struct ProtocolCapabilityCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
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
