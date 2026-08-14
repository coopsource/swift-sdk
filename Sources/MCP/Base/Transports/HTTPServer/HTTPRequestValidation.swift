import Foundation

// MARK: - Validation Protocol

/// Validates an incoming HTTP request before the transport processes it.
///
/// Validators are composed into a pipeline and executed in order. The first validator
/// that returns a non-nil response short-circuits the pipeline and that error response
/// is returned to the client.
///
/// Conform to this protocol to add custom validation (e.g., authentication):
/// ```swift
/// struct BearerTokenValidator: HTTPRequestValidator {
///     func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
///         guard let auth = request.header("Authorization"),
///               auth.hasPrefix("Bearer ") else {
///             return .error(statusCode: 401, .invalidRequest("Missing bearer token"))
///         }
///         return nil
///     }
/// }
/// ```
public protocol HTTPRequestValidator: Sendable {
    /// Validates the request. Returns an error response if invalid, or `nil` if valid.
    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse?
}

// MARK: - Validation Context

/// Context provided to validators for making validation decisions.
public struct HTTPValidationContext: Sendable {
    /// The HTTP method of the request (GET, POST, DELETE).
    public let httpMethod: String

    /// The current session ID, if any (nil in stateless mode or before initialization).
    public let sessionID: String?

    /// Whether the request body contains an `initialize` JSON-RPC request.
    public let isInitializationRequest: Bool

    /// The set of protocol versions this server supports.
    public let supportedProtocolVersions: Set<String>

    public init(
        httpMethod: String,
        sessionID: String? = nil,
        isInitializationRequest: Bool = false,
        supportedProtocolVersions: Set<String> = Version.supported
    ) {
        self.httpMethod = httpMethod
        self.sessionID = sessionID
        self.isInitializationRequest = isInitializationRequest
        self.supportedProtocolVersions = supportedProtocolVersions
    }
}

private enum HTTPMediaValueParser {
    struct MediaRange {
        let type: String
        let subtype: String
        let parameters: [String: String]
        let quality: Int

        private var typeSpecificity: Int {
            if type == "*" { return 0 }
            if subtype == "*" { return 1 }
            return 2
        }

        func matches(
            type expectedType: String,
            subtype expectedSubtype: String,
            parameters expectedParameters: [String: String] = [:]
        ) -> Bool {
            (type == "*" || type == expectedType)
                && (subtype == "*" || subtype == expectedSubtype)
                && parameters.allSatisfy { expectedParameters[$0.key] == $0.value }
        }

        func isLessSpecific(than other: MediaRange) -> Bool {
            if typeSpecificity != other.typeSpecificity {
                return typeSpecificity < other.typeSpecificity
            }
            return parameters.count < other.parameters.count
        }

        func hasSameSpecificity(as other: MediaRange) -> Bool {
            typeSpecificity == other.typeSpecificity
                && parameters.count == other.parameters.count
        }
    }

    static func accepts(_ value: String, type: String, subtype: String) -> Bool {
        guard let elements = split(value, on: ","), !elements.isEmpty else { return false }
        var matches: [MediaRange] = []
        for element in elements {
            guard let range = parse(element, allowsWildcards: true, parsesQuality: true) else {
                return false
            }
            if range.matches(type: type, subtype: subtype) {
                matches.append(range)
            }
        }
        guard let mostSpecific = matches.max(by: { $0.isLessSpecific(than: $1) }) else {
            return false
        }
        let qualities = Set(
            matches.lazy.filter { $0.hasSameSpecificity(as: mostSpecific) }.map(\.quality)
        )
        guard qualities.count == 1, let quality = qualities.first else { return false }
        return quality > 0
    }

    static func contentType(_ value: String, matches type: String, subtype: String) -> Bool {
        guard let values = split(value, on: ","), values.count == 1,
            let mediaType = parse(values[0], allowsWildcards: false, parsesQuality: false)
        else {
            return false
        }
        return mediaType.type == type && mediaType.subtype == subtype
    }

    private static func parse(
        _ value: String,
        allowsWildcards: Bool,
        parsesQuality: Bool
    ) -> MediaRange? {
        guard let parts = split(value, on: ";"), let essence = parts.first else { return nil }
        let typeAndSubtype = trimOWS(essence).split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard typeAndSubtype.count == 2,
            isToken(String(typeAndSubtype[0])),
            isToken(String(typeAndSubtype[1]))
        else {
            return nil
        }

        let type = typeAndSubtype[0].lowercased()
        let subtype = typeAndSubtype[1].lowercased()
        if allowsWildcards {
            guard subtype == "*" || !subtype.contains("*") else { return nil }
            guard type != "*" || subtype == "*" else { return nil }
            guard type == "*" || !type.contains("*") else { return nil }
        } else {
            guard !type.contains("*"), !subtype.contains("*") else { return nil }
        }

        var quality = 1000
        var qualitySeen = false
        var mediaParameters: [String: String] = [:]
        for rawParameter in parts.dropFirst() {
            let parameter = trimOWS(rawParameter)
            guard !parameter.isEmpty else { return nil }
            guard let equals = parameter.firstIndex(of: "=") else { return nil }

            let untrimmedName = String(parameter[..<equals])
            let untrimmedValue = String(parameter[parameter.index(after: equals)...])
            let trimmedName = trimOWS(untrimmedName)
            let name = trimmedName.lowercased()
            let rawValue = trimOWS(untrimmedValue)
            guard untrimmedName == trimmedName, untrimmedValue == rawValue else { return nil }
            guard isToken(name), isParameterValue(rawValue) else { return nil }

            if parsesQuality, name == "q" {
                guard !qualitySeen, !rawValue.hasPrefix("\"") else { return nil }
                guard let parsedQuality = parseQuality(rawValue) else { return nil }
                quality = parsedQuality
                qualitySeen = true
            } else {
                guard mediaParameters.updateValue(rawValue, forKey: name) == nil else {
                    return nil
                }
            }
        }

        return MediaRange(
            type: type,
            subtype: subtype,
            parameters: mediaParameters,
            quality: quality
        )
    }

    private static func parseQuality(_ value: String) -> Int? {
        if value == "0" { return 0 }
        if value == "1" { return 1000 }

        guard value.count >= 2, value.count <= 5,
            value[value.index(after: value.startIndex)] == "."
        else {
            return nil
        }
        let whole = value[value.startIndex]
        let fraction = value.dropFirst(2)
        guard fraction.count <= 3, fraction.allSatisfy(\.isNumber) else { return nil }
        if whole == "1" {
            return fraction.allSatisfy { $0 == "0" } ? 1000 : nil
        }
        guard whole == "0" else { return nil }
        let padded = fraction + String(repeating: "0", count: 3 - fraction.count)
        return Int(padded)
    }

    private static func isParameterValue(_ value: String) -> Bool {
        if isToken(value) { return true }
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return false
        }
        var escaped = false
        for scalar in value.dropFirst().dropLast().unicodeScalars {
            let byte = scalar.value
            if escaped {
                guard byte == 0x09 || byte == 0x20 || (0x21...0x7E).contains(byte) else {
                    return false
                }
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else {
                guard byte == 0x09 || byte == 0x20 || byte == 0x21
                    || (0x23...0x5B).contains(byte) || (0x5D...0x7E).contains(byte)
                else {
                    return false
                }
            }
        }
        return !escaped
    }

    private static func isToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                return true
            case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E,
                0x5E, 0x5F, 0x60, 0x7C, 0x7E:
                return true
            default:
                return false
            }
        }
    }

    /// Splits a header value on a separator, honoring quoted strings.
    ///
    /// Empty elements are skipped rather than rejected: RFC 9110 §5.6.1 requires recipients to
    /// parse and ignore a reasonable number of empty list elements, and the §5.6.6 parameter
    /// grammar makes each parameter optional. A value that is entirely empty elements yields an
    /// empty list, which callers reject on their own terms. `nil` still signals a malformed
    /// value, such as an unterminated quoted string.
    private static func split(_ value: String, on separator: Character) -> [String]? {
        var result: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if quoted {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else if character == "\"" {
                quoted = true
                current.append(character)
            } else if character == separator {
                if !trimOWS(current).isEmpty {
                    result.append(current)
                }
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !quoted, !escaped else { return nil }
        if !trimOWS(current).isEmpty {
            result.append(current)
        }
        return result
    }

    private static func trimOWS(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }
}

// MARK: - Accept Header Validator

/// Validates the `Accept` header based on the HTTP method and transport response mode.
///
/// - Stateful (SSE) mode: POST requests must accept both `application/json` and `text/event-stream`
/// - Stateless (JSON) mode: POST requests only need to accept `application/json`
/// - GET requests always require `text/event-stream`
public struct AcceptHeaderValidator: HTTPRequestValidator {
    /// The response mode determines which content types are required.
    public enum Mode: Sendable {
        /// POST requires both `application/json` and `text/event-stream`.
        case sseRequired
        /// POST only requires `application/json`.
        case jsonOnly
    }

    public let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        let accept = request.header(HTTPHeaderName.accept) ?? ""
        let hasJSON = HTTPMediaValueParser.accepts(
            accept,
            type: "application",
            subtype: "json"
        )
        let hasSSE = HTTPMediaValueParser.accepts(
            accept,
            type: "text",
            subtype: "event-stream"
        )

        switch context.httpMethod {
        case "POST":
            switch mode {
            case .sseRequired:
                guard hasJSON, hasSSE else {
                    return .error(
                        statusCode: 406,
                        .invalidRequest(
                            "Not Acceptable: Client must accept both application/json and text/event-stream"
                        ),
                        sessionID: context.sessionID
                    )
                }
            case .jsonOnly:
                guard hasJSON else {
                    return .error(
                        statusCode: 406,
                        .invalidRequest(
                            "Not Acceptable: Client must accept application/json"
                        ),
                        sessionID: context.sessionID
                    )
                }
            }
        case "GET":
            guard hasSSE else {
                return .error(
                    statusCode: 406,
                    .invalidRequest(
                        "Not Acceptable: Client must accept text/event-stream"
                    ),
                    sessionID: context.sessionID
                )
            }
        default:
            break
        }

        return nil
    }
}

// MARK: - Content-Type Validator

/// Validates that POST requests have `Content-Type: application/json`.
public struct ContentTypeValidator: HTTPRequestValidator {
    public init() {}

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard context.httpMethod == "POST" else { return nil }

        let contentType = request.header(HTTPHeaderName.contentType) ?? ""
        guard HTTPMediaValueParser.contentType(
            contentType,
            matches: "application",
            subtype: "json"
        ) else {
            return .error(
                statusCode: 415,
                .invalidRequest(
                    "Unsupported Media Type: Content-Type must be application/json"
                ),
                sessionID: context.sessionID
            )
        }

        return nil
    }
}

// MARK: - Protocol Version Validator

/// Validates the `MCP-Protocol-Version` header against supported versions.
///
/// Per spec:
/// - If the header is absent, the server assumes the default negotiated version
/// - If the header is present but unsupported, the server returns 400 Bad Request
/// - Initialization requests are exempt (protocol version comes from the request body)
public struct ProtocolVersionValidator: HTTPRequestValidator {
    public init() {}

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // Skip for initialization requests (version is in the body, not the header)
        guard !context.isInitializationRequest else { return nil }

        // Skip for non-POST methods (GET/DELETE don't carry protocol version)
        // Actually, per spec, all subsequent requests should include it
        guard let version = request.header(HTTPHeaderName.protocolVersion) else {
            // Per spec: if not received, assume default version
            return nil
        }

        guard context.supportedProtocolVersions.contains(version) else {
            let supported = context.supportedProtocolVersions.sorted().joined(separator: ", ")
            return .error(
                statusCode: 400,
                .invalidRequest(
                    "Bad Request: Unsupported protocol version: \(version). Supported: \(supported)"
                ),
                sessionID: context.sessionID
            )
        }

        return nil
    }
}

// MARK: - Session Validator

/// Validates the `Mcp-Session-Id` header for stateful transports.
///
/// - Initialization requests are exempt (no session exists yet)
/// - Non-initialization requests must include the session ID header
/// - The session ID must match the active session
public struct SessionValidator: HTTPRequestValidator {
    public init() {}

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // Skip validation for initialization requests
        guard !context.isInitializationRequest else { return nil }

        // Non-initialization requests require an established session.
        guard let expectedSessionID = context.sessionID else {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Session not initialized"),
                sessionID: nil
            )
        }

        let requestSessionID = request.header(HTTPHeaderName.sessionID)

        guard let requestSessionID else {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"),
                sessionID: expectedSessionID
            )
        }

        guard requestSessionID == expectedSessionID else {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Invalid or expired session ID"),
                sessionID: expectedSessionID
            )
        }

        return nil
    }
}

// MARK: - Origin Validator

/// DNS rebinding protection: validates `Origin` and `Host` headers.
///
/// Per spec, servers MUST validate the Origin header to prevent DNS rebinding attacks.
/// This is particularly important for servers running on localhost.
///
/// Use `.localhost()` for local development servers.
/// Use `.disabled` to skip validation (e.g., cloud deployments).
/// Use `init(allowedHosts:allowedOrigins:)` for custom configurations.
public struct OriginValidator: HTTPRequestValidator {
    public let allowedHosts: [String]
    public let allowedOrigins: [String]
    private let enabled: Bool

    public init(allowedHosts: [String], allowedOrigins: [String]) {
        self.allowedHosts = allowedHosts
        self.allowedOrigins = allowedOrigins
        self.enabled = true
    }

    private init(disabled: Void) {
        self.allowedHosts = []
        self.allowedOrigins = []
        self.enabled = false
    }

    /// Protection for localhost-bound servers.
    /// Allows requests from `localhost`, `127.0.0.1`, and `[::1]` with the specified port.
    public static func localhost(port: Int? = nil) -> OriginValidator {
        let portPattern = port.map { String($0) } ?? "*"
        return OriginValidator(
            allowedHosts: [
                "127.0.0.1:\(portPattern)",
                "localhost:\(portPattern)",
                "[::1]:\(portPattern)",
            ],
            allowedOrigins: [
                "http://127.0.0.1:\(portPattern)",
                "http://localhost:\(portPattern)",
                "http://[::1]:\(portPattern)",
            ]
        )
    }

    /// Disables DNS rebinding protection.
    /// Use for cloud deployments where DNS rebinding is not a threat.
    public static var disabled: OriginValidator {
        OriginValidator(disabled: ())
    }

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard enabled else { return nil }

        // Validate Host header
        if let host = request.header(HTTPHeaderName.host) {
            let hostAllowed = allowedHosts.contains { pattern in
                matchesPattern(host, pattern: pattern)
            }
            if !hostAllowed {
                return .error(
                    statusCode: 421,
                    .invalidRequest("Misdirected Request: Host header not allowed"),
                    sessionID: context.sessionID
                )
            }
        }

        // Validate Origin header (only if present — non-browser clients won't send it)
        if let origin = request.header(HTTPHeaderName.origin) {
            let originAllowed = allowedOrigins.contains { pattern in
                matchesPattern(origin, pattern: pattern)
            }
            if !originAllowed {
                return .error(
                    statusCode: 403,
                    .invalidRequest("Forbidden: Origin not allowed"),
                    sessionID: context.sessionID
                )
            }
        }

        return nil
    }

    /// Matches a value against a pattern that may contain a port wildcard `:*`.
    ///
    /// Examples:
    /// - `"localhost:*"` matches `"localhost:8080"`, `"localhost:3000"`
    /// - `"http://localhost:*"` matches `"http://localhost:8080"`
    /// - `"localhost:8080"` matches only `"localhost:8080"` exactly
    private func matchesPattern(_ value: String, pattern: String) -> Bool {
        guard pattern.hasSuffix(":*") else {
            return value == pattern
        }

        let prefix = String(pattern.dropLast(2))
        guard value.hasPrefix(prefix + ":") else { return false }

        let portPart = value.dropFirst(prefix.count + 1)
        return !portPart.isEmpty && portPart.allSatisfy(\.isNumber)
    }
}

// MARK: - Protected Resource Metadata Validator

/// Serves the RFC 9728 Protected Resource Metadata document for discovery.
///
/// Per the MCP authorization specification, servers **MUST** serve Protected Resource
/// Metadata at `/.well-known/oauth-protected-resource` so that clients can discover
/// authorization server endpoints automatically.
///
/// Place this validator **before** ``BearerTokenValidator`` in the pipeline so that
/// unauthenticated metadata discovery requests succeed.
///
/// ```swift
/// let prmValidator = ProtectedResourceMetadataValidator(
///     metadata: OAuthProtectedResourceServerMetadata(
///         resource: "https://api.example.com",
///         authorizationServers: [URL(string: "https://auth.example.com")!]
///     )
/// )
/// let pipeline = StandardValidationPipeline(validators: [
///     prmValidator,
///     bearerTokenValidator,
///     // ...
/// ])
/// ```
public struct ProtectedResourceMetadataValidator: HTTPRequestValidator {
    private let encodedMetadata: Data

    public init(metadata: OAuthProtectedResourceServerMetadata) {
        self.encodedMetadata = (try? JSONEncoder().encode(metadata)) ?? Data()
    }

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard context.httpMethod == "GET",
            let path = request.path,
            path == OAuthWellKnownPath.protectedResource
                || path.hasPrefix("\(OAuthWellKnownPath.protectedResource)/")
        else {
            return nil
        }
        return .data(encodedMetadata, headers: [HTTPHeaderName.contentType: ContentType.json])
    }
}

// MARK: - OAuth Bearer Validator

/// Result produced by ``BearerTokenValidator`` when validating an access token.
public enum BearerTokenValidationResult: Sendable, Equatable {
    /// Access token is valid for this request, with its extracted claims.
    ///
    /// Supply a ``BearerTokenInfo`` with `audience` and `expiresAt` populated so that
    /// ``BearerTokenValidator`` can enforce expiry and audience checks automatically.
    /// Pass `BearerTokenInfo()` (all `nil`) to delegate all enforcement to the caller.
    case valid(BearerTokenInfo)

    /// Access token is missing required privileges, and new scopes are required.
    case insufficientScope(requiredScopes: Set<String>, errorDescription: String? = nil)

    /// Access token is invalid or expired.
    case invalidToken(errorDescription: String? = nil)

    /// Authorization request is malformed.
    case malformedRequest(errorDescription: String? = nil)
}

/// Validates OAuth 2.1 Bearer authorization for protected MCP HTTP endpoints.
///
/// This validator implements resource-server error semantics aligned with the MCP auth spec:
/// - `401` with `WWW-Authenticate: Bearer ...` for missing/invalid tokens
/// - `403` with `error="insufficient_scope"` for insufficient permissions
/// - `400` for malformed authorization requests
///
/// Include this validator early in your pipeline, before `SessionValidator`, so unauthenticated
/// initialization requests can return a challenge.
///
/// ## Audience Validation (MUST)
///
/// Per the MCP authorization specification, **the resource server MUST validate the audience
/// (`aud` claim) of the access token** to ensure it matches the resource server's own identifier.
/// Failure to validate the audience allows token substitution attacks where a token intended
/// for a different resource is replayed against your server.
///
/// Your ``TokenValidator`` closure **MUST** verify the audience. Example:
///
/// ```swift
/// let validator = BearerTokenValidator(
///     resourceMetadataURL: metadataURL,
///     tokenValidator: { token, request, context in
///         guard let claims = verifyAndDecode(token) else {
///             return .invalidToken(errorDescription: "Token verification failed")
///         }
///         // MUST: Verify token audience matches this resource server
///         guard claims.audience.contains("https://api.example.com") else {
///             return .invalidToken(errorDescription: "Token audience mismatch")
///         }
///         return .valid
///     }
/// )
/// ```
public struct BearerTokenValidator: HTTPRequestValidator {
    /// Validates a bearer token and returns token info for audience and expiry enforcement.
    public typealias TokenValidator = @Sendable (
        _ token: String,
        _ request: HTTPRequest,
        _ context: HTTPValidationContext
    ) -> BearerTokenValidationResult

    /// Closure that returns the scopes to advertise in `WWW-Authenticate` challenge headers.
    ///
    /// Return `nil` to omit the `scope` parameter from the challenge.
    public typealias ChallengeScopeProvider = @Sendable (
        _ request: HTTPRequest,
        _ context: HTTPValidationContext
    ) -> Set<String>?

    /// Closure that decides whether a request requires Bearer authentication.
    ///
    /// Return `false` to allow a request through unauthenticated (e.g., public health-check endpoints).
    /// Defaults to requiring authentication on all requests.
    public typealias RequirementPredicate = @Sendable (
        _ request: HTTPRequest,
        _ context: HTTPValidationContext
    ) -> Bool

    public let resourceMetadataURL: URL
    public let resourceIdentifier: URL
    private let tokenValidator: TokenValidator
    private let challengeScopeProvider: ChallengeScopeProvider?
    private let requiresAuthentication: RequirementPredicate
    private let metadataDiscovery: any OAuthMetadataDiscovering

    /// Creates a `BearerTokenValidator`.
    ///
    /// - Parameters:
    ///   - resourceMetadataURL: Included in `WWW-Authenticate` challenge headers as the
    ///     `resource_metadata` parameter, pointing to the RFC 9728 Protected Resource Metadata document.
    ///   - resourceIdentifier: The canonical URI of this resource server. Used to validate the
    ///     `aud` claim in tokens that supply audience information via ``BearerTokenInfo``.
    ///   - tokenValidator: Validates the Bearer token and returns ``BearerTokenInfo`` with
    ///     claims for SDK-side expiry and audience enforcement.
    ///   - challengeScopeProvider: Optional closure supplying scopes to include in challenge headers.
    ///   - requiresAuthentication: Predicate controlling which requests require a Bearer token.
    ///     Defaults to requiring authentication on all requests.
    ///   - metadataDiscovery: Used for audience URL matching. Defaults to ``DefaultOAuthMetadataDiscovery``.
    public init(
        resourceMetadataURL: URL,
        resourceIdentifier: URL,
        tokenValidator: @escaping TokenValidator,
        challengeScopeProvider: ChallengeScopeProvider? = nil,
        requiresAuthentication: @escaping RequirementPredicate = { _, _ in true },
        metadataDiscovery: any OAuthMetadataDiscovering = DefaultOAuthMetadataDiscovery()
    ) {
        self.resourceMetadataURL = resourceMetadataURL
        self.resourceIdentifier = resourceIdentifier
        self.tokenValidator = tokenValidator
        self.challengeScopeProvider = challengeScopeProvider
        self.requiresAuthentication = requiresAuthentication
        self.metadataDiscovery = metadataDiscovery
    }

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard requiresAuthentication(request, context) else { return nil }

        guard let authorizationHeader = request.header(HTTPHeaderName.authorization) else {
            return unauthorizedResponse(
                challengeScope: challengeScopeProvider?(request, context),
                error: nil,
                errorDescription: nil,
                sessionID: context.sessionID
            )
        }

        let parsedToken: String
        switch parseBearerToken(from: authorizationHeader) {
        case .success(let token):
            parsedToken = token
        case .failure(let error):
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: \(error.message)"),
                sessionID: context.sessionID
            )
        }

        switch tokenValidator(parsedToken, request, context) {
        case .valid(let info):
            // Expiry check
            if let exp = info.expiresAt, exp <= Date() {
                return unauthorizedResponse(
                    challengeScope: challengeScopeProvider?(request, context),
                    error: "invalid_token",
                    errorDescription: "Token has expired",
                    sessionID: context.sessionID
                )
            }
            // Audience check — skipped for opaque tokens (audience == nil)
            if let audience = info.audience {
                let matches = audience.contains { audString in
                    guard let audURL = URL(string: audString) else { return false }
                    return metadataDiscovery.protectedResourceMatches(
                        resource: audURL, endpoint: resourceIdentifier)
                }
                if !matches {
                    return unauthorizedResponse(
                        challengeScope: challengeScopeProvider?(request, context),
                        error: "invalid_token",
                        errorDescription: "Token audience mismatch",
                        sessionID: context.sessionID
                    )
                }
            }
            return nil

        case .invalidToken(let errorDescription):
            return unauthorizedResponse(
                challengeScope: challengeScopeProvider?(request, context),
                error: "invalid_token",
                errorDescription: errorDescription,
                sessionID: context.sessionID
            )

        case .insufficientScope(let requiredScopes, let errorDescription):
            return forbiddenInsufficientScopeResponse(
                requiredScopes: requiredScopes,
                errorDescription: errorDescription,
                sessionID: context.sessionID
            )

        case .malformedRequest(let errorDescription):
            let message = errorDescription ?? "Malformed authorization request"
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: \(message)"),
                sessionID: context.sessionID
            )
        }
    }

    private func unauthorizedResponse(
        challengeScope: Set<String>?,
        error: String?,
        errorDescription: String?,
        sessionID: String?
    ) -> HTTPResponse {
        let challenge = makeBearerChallenge(
            resourceMetadataURL: resourceMetadataURL,
            scope: challengeScope,
            error: error,
            errorDescription: errorDescription
        )
        return .error(
            statusCode: 401,
            .invalidRequest("Unauthorized"),
            sessionID: sessionID,
            extraHeaders: [HTTPHeaderName.wwwAuthenticate: challenge]
        )
    }

    private func forbiddenInsufficientScopeResponse(
        requiredScopes: Set<String>,
        errorDescription: String?,
        sessionID: String?
    ) -> HTTPResponse {
        let challenge = makeBearerChallenge(
            resourceMetadataURL: resourceMetadataURL,
            scope: requiredScopes,
            error: "insufficient_scope",
            errorDescription: errorDescription
        )
        return .error(
            statusCode: 403,
            .invalidRequest("Forbidden: Insufficient scope"),
            sessionID: sessionID,
            extraHeaders: [HTTPHeaderName.wwwAuthenticate: challenge]
        )
    }

    private func makeBearerChallenge(
        resourceMetadataURL: URL,
        scope: Set<String>?,
        error: String?,
        errorDescription: String?
    ) -> String {
        var parameters: [String] = []
        parameters.append("resource_metadata=\"\(escapeAuthParameter(resourceMetadataURL.absoluteString))\"")

        if let scope, !scope.isEmpty {
            let serializedScope = scope.sorted().joined(separator: " ")
            parameters.append("scope=\"\(escapeAuthParameter(serializedScope))\"")
        }

        if let error {
            parameters.append("error=\"\(escapeAuthParameter(error))\"")
        }

        if let errorDescription, !errorDescription.isEmpty {
            parameters.append("error_description=\"\(escapeAuthParameter(errorDescription))\"")
        }

        return "\(OAuthTokenType.bearer) " + parameters.joined(separator: ", ")
    }

    private func escapeAuthParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private struct BearerTokenParseError: Swift.Error {
        let message: String
    }

    private func parseBearerToken(
        from authorizationHeader: String
    ) -> Result<String, BearerTokenParseError> {
        let trimmed = authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.init(message: "Authorization header is empty"))
        }

        let parts = trimmed.split(
            maxSplits: 1,
            whereSeparator: { $0.isWhitespace }
        )

        guard parts.count == 2 else {
            return .failure(
                .init(message: "Authorization header must be in the form: Bearer <token>")
            )
        }

        guard String(parts[0]).caseInsensitiveCompare(OAuthTokenType.bearer) == .orderedSame else {
            return .failure(.init(message: "Authorization scheme must be Bearer"))
        }

        let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .failure(.init(message: "Bearer token is empty"))
        }

        if token.contains(where: \.isWhitespace) {
            return .failure(.init(message: "Bearer token must not contain whitespace"))
        }

        return .success(token)
    }
}

// MARK: - Validation Pipeline Protocol

/// Runs a validation pipeline against an HTTP request.
///
/// Implementations execute a sequence of validators and return the first error,
/// or `nil` if all validations pass.
public protocol HTTPRequestValidationPipeline: Sendable {
    /// Validates the request using the configured pipeline.
    /// Returns an error response if validation fails, or `nil` if the request is valid.
    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse?
}

// MARK: - Standard Validation Pipeline

/// Standard implementation of `HTTPRequestValidationPipeline` that runs validators in sequence.
///
/// The first validator that returns a non-nil error response short-circuits the pipeline.
public struct StandardValidationPipeline: HTTPRequestValidationPipeline {
    private let validators: [any HTTPRequestValidator]

    /// Creates a pipeline with the given validators.
    /// Validators are executed in the order provided.
    public init(validators: [any HTTPRequestValidator]) {
        self.validators = validators
    }

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        for validator in validators {
            if let errorResponse = validator.validate(request, context: context) {
                return errorResponse
            }
        }
        return nil
    }
}
