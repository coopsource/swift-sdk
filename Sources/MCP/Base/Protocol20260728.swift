import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

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

struct PerRequestProtocolMetadata: Sendable {
    let protocolVersion: String
    let clientInfo: Client.Info?
    let clientCapabilities: Client.Capabilities
    let logLevel: LogLevel?
}

enum PerRequestMetadataWire {
    static func encodeRequest<M: Method>(
        _ request: Request<M>,
        protocolVersion: String,
        clientInfo: Client.Info,
        clientCapabilities: Client.Capabilities,
        logLevel: LogLevel? = nil,
        using encoder: JSONEncoder
    ) throws -> Data {
        let data = try encoder.encode(request)
        return try addingRequestMetadata(
            to: data,
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            clientCapabilities: clientCapabilities,
            logLevel: logLevel,
            using: encoder
        )
    }

    static func addingRequestMetadata(
        to data: Data,
        protocolVersion: String,
        clientInfo: Client.Info,
        clientCapabilities: Client.Capabilities,
        logLevel: LogLevel? = nil,
        using encoder: JSONEncoder
    ) throws -> Data {
        var value = try JSONDecoder().decode(Value.self, from: data)
        value = try addingRequestMetadata(
            to: value,
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            clientCapabilities: clientCapabilities,
            logLevel: logLevel
        )
        return try encoder.encode(value)
    }

    private static func addingRequestMetadata(
        to value: Value,
        protocolVersion: String,
        clientInfo: Client.Info,
        clientCapabilities: Client.Capabilities,
        logLevel: LogLevel?
    ) throws -> Value {
        if case .array(let items) = value {
            return .array(try items.map {
                try addingRequestMetadata(
                    to: $0,
                    protocolVersion: protocolVersion,
                    clientInfo: clientInfo,
                    clientCapabilities: clientCapabilities,
                    logLevel: logLevel
                )
            })
        }

        guard case .object(var request) = value else {
            throw MCPError.invalidRequest("Request must be a JSON object")
        }

        var parameters = request["params"]?.objectValue ?? [:]
        var metadata = parameters["_meta"]?.objectValue ?? [:]
        metadata[ProtocolMetadataKey.protocolVersion] = .string(protocolVersion)
        metadata[ProtocolMetadataKey.clientInfo] = try Value(clientInfo)
        metadata[ProtocolMetadataKey.clientCapabilities] = try Value(clientCapabilities)
        if let logLevel {
            metadata[ProtocolMetadataKey.logLevel] = .string(logLevel.rawValue)
        }
        parameters["_meta"] = .object(metadata)
        request["params"] = .object(parameters)
        return .object(request)
    }

    static func decodeRequestMetadata(from request: AnyRequest) throws
        -> PerRequestProtocolMetadata
    {
        guard let parameters = request.params.objectValue,
            let metadata = parameters["_meta"]?.objectValue
        else {
            throw MCPError.invalidParams(
                "Per-request metadata requires an object-valued params._meta field")
        }
        guard let protocolVersion = metadata[ProtocolMetadataKey.protocolVersion]?.stringValue
        else {
            throw MCPError.invalidParams(
                "Per-request metadata is missing io.modelcontextprotocol/protocolVersion")
        }
        guard let capabilitiesValue = metadata[ProtocolMetadataKey.clientCapabilities] else {
            throw MCPError.invalidParams(
                "Per-request metadata is missing io.modelcontextprotocol/clientCapabilities")
        }

        let decoder = JSONDecoder()
        let capabilities: Client.Capabilities
        let clientInfo: Client.Info?
        do {
            capabilities = try decoder.decode(
                Client.Capabilities.self, from: JSONEncoder().encode(capabilitiesValue))
            if let clientInfoValue = metadata[ProtocolMetadataKey.clientInfo] {
                clientInfo = try decoder.decode(
                    Client.Info.self, from: JSONEncoder().encode(clientInfoValue))
            } else {
                clientInfo = nil
            }
        } catch {
            throw MCPError.invalidParams("Per-request client metadata is malformed")
        }

        let logLevel: LogLevel?
        if let value = metadata[ProtocolMetadataKey.logLevel] {
            guard let rawValue = value.stringValue,
                let decodedLevel = LogLevel(rawValue: rawValue)
            else {
                throw MCPError.invalidParams(
                    "io.modelcontextprotocol/logLevel is not a recognized log level")
            }
            logLevel = decodedLevel
        } else {
            logLevel = nil
        }

        return PerRequestProtocolMetadata(
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            clientCapabilities: capabilities,
            logLevel: logLevel
        )
    }

    static func containsLifecycleMetadata(_ request: AnyRequest) -> Bool {
        guard let parameters = request.params.objectValue,
            let metadata = parameters["_meta"]?.objectValue
        else {
            return false
        }
        return metadata[ProtocolMetadataKey.protocolVersion] != nil
            || metadata[ProtocolMetadataKey.clientCapabilities] != nil
            || metadata[ProtocolMetadataKey.clientInfo] != nil
    }

    static func encodeResponse<M: Method>(
        _ response: Response<M>,
        serverInfo: Server.Info,
        using encoder: JSONEncoder
    ) throws -> Data {
        let data = try encoder.encode(response)
        guard case .object(var envelope) = try JSONDecoder().decode(Value.self, from: data),
            case .object(var result) = envelope["result"]
        else {
            return data
        }

        if result["resultType"] == nil {
            result["resultType"] = .string("complete")
        }
        var metadata = result["_meta"]?.objectValue ?? [:]
        metadata[ProtocolMetadataKey.serverInfo] = try Value(serverInfo)
        result["_meta"] = .object(metadata)
        envelope["result"] = .object(result)
        return try encoder.encode(Value.object(envelope))
    }
}

/// The disposition of a successful MCP result.
public enum ResultType: Hashable, Codable, Sendable {
    /// The operation completed normally.
    case complete
    /// The client must fulfill embedded requests and retry the original operation.
    case inputRequired
    /// A result type introduced by a later protocol extension.
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
    /// The result may be reused across authorization contexts.
    case `public`
    /// The result may be reused only within the same authorization context.
    case `private`
}

/// Cache information returned by methods whose results may be reused.
public struct CachePolicy: Hashable, Codable, Sendable {
    /// How long the complete result may be reused, in milliseconds.
    public var ttlMs: Int
    /// The authorization boundary within which the result may be reused.
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
    /// Protocol versions supported by the endpoint.
    public var supported: [String]
    /// The unsupported protocol version from the request.
    public var requested: String

    public init(supported: [String], requested: String) {
        self.supported = supported
        self.requested = requested
    }
}

/// Data returned when a request omitted a capability required by the server.
public struct MissingRequiredClientCapabilityData: Hashable, Codable, Sendable {
    /// The capability declaration required to process the request.
    public var requiredCapabilities: Client.Capabilities

    public init(requiredCapabilities: Client.Capabilities) {
        self.requiredCapabilities = requiredCapabilities
    }
}

/// Requests the versions and capabilities supported by a server.
public enum Discover: Method {
    public static let name = "server/discover"

    public struct Parameters: Hashable, Codable, Sendable {
        /// Optional request metadata, including lifecycle fields added by the client.
        public var _meta: Metadata

        public init(_meta: Metadata = .init()) {
            self._meta = _meta
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        /// Protocol versions supported by the server, in server preference order.
        public var supportedVersions: [String]
        /// Capabilities available from the server.
        public var capabilities: Server.Capabilities
        /// Optional instructions describing how to use the server.
        public var instructions: String?
        /// How long this discovery result may be reused, in milliseconds.
        public var ttlMs: Int
        /// The authorization boundary within which this result may be reused.
        public var cacheScope: CacheScope
        /// The disposition of this result.
        public var resultType: ResultType
        /// Optional result metadata, including server identity.
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

extension Discover.Result {
    /// Self-reported server information carried in the result metadata.
    public var serverInfo: Server.Info? {
        guard let value = _meta?[ProtocolMetadataKey.serverInfo] else { return nil }
        return try? JSONDecoder().decode(Server.Info.self, from: JSONEncoder().encode(value))
    }
}

/// A successful result that requires client input before the original request can complete.
public struct InputRequiredResult: Hashable, Codable, Sendable {
    /// The required `input_required` result disposition.
    public var resultType: ResultType
    /// Embedded client requests, keyed for correlation with the next attempt.
    public var inputRequests: [String: Value]?
    /// Opaque state that the client returns unchanged on the next attempt.
    public var requestState: String?
    /// Optional result metadata.
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

/// A server handler result for a method that may require additional client input.
public enum MultiRoundTripResult<Success: Hashable & Codable & Sendable>: Hashable, Sendable {
    /// The request completed with its normal method result.
    case complete(Success)

    /// The client must fulfill embedded input requests and retry the original method.
    case inputRequired(InputRequiredResult)
}

extension InputRequiredResult {
    func validate(clientCapabilities: Client.Capabilities?) throws {
        guard resultType == .inputRequired else {
            throw MCPError.invalidParams(
                "InputRequiredResult must use the input_required result type")
        }
        guard inputRequests != nil || requestState != nil else {
            throw MCPError.invalidParams(
                "InputRequiredResult requires inputRequests or requestState")
        }

        for request in inputRequests?.values.map({ $0 }) ?? [] {
            guard let object = request.objectValue,
                object["id"] == nil,
                object["jsonrpc"] == nil,
                let method = object["method"]?.stringValue
            else {
                throw MCPError.invalidParams("Embedded input request is malformed")
            }
            if let parameters = object["params"], parameters.objectValue == nil {
                throw MCPError.invalidParams(
                    "Embedded input request has non-object parameters")
            }

            switch method {
            case CreateElicitation.name:
                guard clientCapabilities?.elicitation != nil else {
                    throw missingCapability(.init(elicitation: .init()))
                }
            case CreateSamplingMessage.name:
                guard clientCapabilities?.sampling != nil else {
                    throw missingCapability(.init(sampling: .init()))
                }
            case ListRoots.name:
                guard clientCapabilities?.roots != nil else {
                    throw missingCapability(.init(roots: .init()))
                }
            default:
                throw MCPError.invalidParams(
                    "Unsupported embedded input request method: \(method)")
            }
        }
    }

    private func missingCapability(_ capabilities: Client.Capabilities) -> MCPError {
        .remote(
            code: ProtocolErrorCode.missingRequiredClientCapability,
            message: "Server requires a client capability for embedded input",
            data: try? Value(MissingRequiredClientCapabilityData(
                requiredCapabilities: capabilities))
        )
    }
}
