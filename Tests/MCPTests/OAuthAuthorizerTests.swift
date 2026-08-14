@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Mock Implementations

final class MockURLValidator: OAuthURLValidating, @unchecked Sendable {
    var validateHTTPSOrLoopbackCallCount = 0
    var validateAuthorizationServerCallCount = 0
    var validateRedirectURICallCount = 0
    var shouldThrow: Error?

    func validateHTTPSOrLoopback(_ url: URL, context: String) throws {
        validateHTTPSOrLoopbackCallCount += 1
        if let error = shouldThrow { throw error }
    }

    func validateAuthorizationServer(_ url: URL, context: String) throws {
        validateAuthorizationServerCallCount += 1
        if let error = shouldThrow { throw error }
    }

    func validateRedirectURI(_ url: URL) throws {
        validateRedirectURICallCount += 1
        if let error = shouldThrow { throw error }
    }

    func isPrivateIPHost(_ host: String) -> Bool { false }
}

final class MockDiscoveryClient: OAuthDiscoveryFetching, @unchecked Sendable {
    var fetchProtectedResourceMetadataCallCount = 0
    var fetchAuthorizationServerMetadataCallCount = 0
    var authorizationServerCandidateCalls: [[URL]] = []
    let metadataDiscovery: any OAuthMetadataDiscovering = DefaultOAuthMetadataDiscovery()

    var protectedResourceMetadataResult: OAuthProtectedResourceMetadata
    var authorizationServerMetadataResult: (server: URL, metadata: OAuthAuthorizationServerMetadata)
    var authorizationServerMetadataByCandidate:
        [URL: (server: URL, metadata: OAuthAuthorizationServerMetadata)] = [:]

    init(
        authorizationServer: URL = URL(string: "https://auth.example.com")!,
        tokenEndpoint: URL = URL(string: "https://auth.example.com/token")!
    ) {
        self.protectedResourceMetadataResult = OAuthProtectedResourceMetadata(
            resource: nil,
            authorizationServers: [authorizationServer],
            scopesSupported: nil
        )
        self.authorizationServerMetadataResult = (
            server: authorizationServer,
            metadata: OAuthAuthorizationServerMetadata(
                issuer: authorizationServer,
                authorizationEndpoint: URL(string: "https://auth.example.com/authorize"),
                tokenEndpoint: tokenEndpoint,
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil
            )
        )
    }

    func fetchProtectedResourceMetadata(candidates: [URL], fallbackIssuer: URL?, session: URLSession) async throws -> OAuthProtectedResourceMetadata {
        fetchProtectedResourceMetadataCallCount += 1
        return protectedResourceMetadataResult
    }

    func fetchAuthorizationServerMetadata(candidates: [URL], session: URLSession) async throws -> (server: URL, metadata: OAuthAuthorizationServerMetadata) {
        fetchAuthorizationServerMetadataCallCount += 1
        authorizationServerCandidateCalls.append(candidates)
        if candidates.count == 1,
            let result = authorizationServerMetadataByCandidate[candidates[0]]
        {
            return result
        }
        return authorizationServerMetadataResult
    }
}

final class MockTokenClient: OAuthTokenRequesting, @unchecked Sendable {
    var requestCallCount = 0
    var capturedParameters: [String: String]?
    var capturedParameterHistory: [[String: String]] = []
    var capturedEndpoints: [URL] = []
    var invokePrivateKeyAssertion = false
    var privateKeyAssertions: [String] = []
    var tokenResponse = OAuthTokenResponse(
        accessToken: "mock-access-token",
        tokenType: "Bearer",
        expiresIn: 3600,
        scope: nil,
        refreshToken: nil
    )

    func request(
        parameters: inout [String: String],
        endpoint: URL,
        authentication: OAuthConfiguration.TokenEndpointAuthentication,
        session: URLSession
    ) async throws -> OAuthTokenResponse {
        requestCallCount += 1
        capturedParameters = parameters
        capturedParameterHistory.append(parameters)
        capturedEndpoints.append(endpoint)
        if invokePrivateKeyAssertion,
            case .privateKeyJWT(let clientID, let assertionFactory) = authentication
        {
            privateKeyAssertions.append(try await assertionFactory(endpoint, clientID))
        }
        return tokenResponse
    }
}

final class MockClientRegistrar: OAuthClientRegistering, @unchecked Sendable {
    var registerCallCount = 0
    var registrationResult: (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )?
    var errors: [any Error] = []

    func register(
        configuration: OAuthConfiguration,
        asMetadata: OAuthAuthorizationServerMetadata,
        session: URLSession
    ) async throws -> (
        response: OAuthClientRegistrationResponse,
        updatedAuthentication: OAuthConfiguration.TokenEndpointAuthentication
    )? {
        registerCallCount += 1
        if !errors.isEmpty { throw errors.removeFirst() }
        return registrationResult
    }
}

final class MockAuthCodeFlow: OAuthAuthorizationCodeFlowing, @unchecked Sendable {
    var buildURLCallCount = 0
    var performCallCount = 0
    var authorizationCode = "mock-auth-code"
    var capturedExpectedIssuer: String?
    var capturedIssuerParameterRequired = false

    func buildURL(
        authorizationEndpoint: URL,
        resource: URL,
        redirectURI: URL,
        clientID: String,
        codeChallenge: String,
        scopes: Set<String>?,
        state: String,
        scopeSerializer: any OAuthScopeSelecting
    ) throws -> URL {
        buildURLCallCount += 1
        return URL(string: "https://auth.example.com/authorize?code=stub")!
    }

    func perform(
        authorizationURL: URL,
        redirectURI: URL,
        state: String,
        expectedIssuer: String?,
        issuerParameterRequired: Bool,
        delegate: (any OAuthAuthorizationDelegate)?,
        session: URLSession
    ) async throws -> String {
        performCallCount += 1
        capturedExpectedIssuer = expectedIssuer
        capturedIssuerParameterRequired = issuerParameterRequired
        return authorizationCode
    }
}

// MARK: - OAuthAuthorizer Invocation Tests

@Suite("OAuthAuthorizer dependency invocations")
struct OAuthAuthorizerTests {

    let endpoint = URL(string: "https://mcp.example.com/mcp")!
    let headers401 = [
        "WWW-Authenticate":
            "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\""
    ]

    func makeAuthorizer(
        grantType: OAuthConfiguration.GrantType = .clientCredentials,
        urlValidator: MockURLValidator = MockURLValidator(),
        discoveryClient: MockDiscoveryClient = MockDiscoveryClient(),
        tokenClient: MockTokenClient = MockTokenClient(),
        registrar: MockClientRegistrar = MockClientRegistrar(),
        authCodeFlow: MockAuthCodeFlow = MockAuthCodeFlow()
    ) -> OAuthAuthorizer {
        let config = OAuthConfiguration(
            grantType: grantType,
            authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret")
        )
        return OAuthAuthorizer(
            configuration: config,
            urlValidator: urlValidator,
            discoveryClient: discoveryClient,
            tokenEndpointClient: tokenClient,
            clientRegistrar: registrar,
            authCodeFlow: authCodeFlow
        )
    }

    // MARK: - validateEndpointSecurity

    @Test("validateEndpointSecurity calls urlValidator")
    func testValidateEndpointSecurityCallsURLValidator() throws {
        let validator = MockURLValidator()
        let authorizer = makeAuthorizer(urlValidator: validator)

        try authorizer.validateEndpointSecurity(for: endpoint)

        #expect(validator.validateHTTPSOrLoopbackCallCount == 1)
    }

    @Test("validateEndpointSecurity propagates validation error")
    func testValidateEndpointSecurityPropagatesError() {
        let validator = MockURLValidator()
        validator.shouldThrow = OAuthAuthorizationError.insecureOAuthEndpoint(
            context: "test", url: "http://example.com")
        let authorizer = makeAuthorizer(urlValidator: validator)

        #expect(throws: OAuthAuthorizationError.self) {
            try authorizer.validateEndpointSecurity(for: endpoint)
        }
    }

    // MARK: - handleChallenge (401 — client_credentials)

    @Test("handleChallenge 401 calls discovery and token clients")
    func testHandleChallenge401CallsDiscoveryAndTokenClient() async throws {
        let discovery = MockDiscoveryClient()
        let tokenClient = MockTokenClient()

        let authorizer = makeAuthorizer(
            discoveryClient: discovery,
            tokenClient: tokenClient
        )

        let handled = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == true)
        #expect(discovery.fetchProtectedResourceMetadataCallCount >= 1)
        #expect(discovery.fetchAuthorizationServerMetadataCallCount >= 1)
        #expect(tokenClient.requestCallCount == 1)
    }

    @Test("handleChallenge 401 uses client_credentials grant type parameter")
    func testHandleChallenge401ClientCredentialsGrantType() async throws {
        let tokenClient = MockTokenClient()
        let authorizer = makeAuthorizer(tokenClient: tokenClient)

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(tokenClient.capturedParameters?["grant_type"] == "client_credentials")
    }

    @Test("handleChallenge 401 attaches resource parameter")
    func testHandleChallenge401AttachesResourceParameter() async throws {
        let tokenClient = MockTokenClient()
        let authorizer = makeAuthorizer(tokenClient: tokenClient)

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(tokenClient.capturedParameters?["resource"] != nil)
    }

    // MARK: - handleChallenge (authorization_code)

    #if canImport(CryptoKit)
    @Test("handleChallenge 401 calls authCodeFlow for authorization_code grant")
    func testHandleChallenge401AuthorizationCodeCallsFlow() async throws {
        let authCodeFlow = MockAuthCodeFlow()
        let tokenClient = MockTokenClient()

        let config = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: "my-client"),
            authorizationRedirectURI: URL(string: "https://app.example.com/callback")!
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: tokenClient,
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: authCodeFlow
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(authCodeFlow.buildURLCallCount == 1)
        #expect(authCodeFlow.performCallCount == 1)
        #expect(authCodeFlow.capturedExpectedIssuer == "https://auth.example.com")
        #expect(authCodeFlow.capturedIssuerParameterRequired == false)
        #expect(tokenClient.capturedParameters?["grant_type"] == "authorization_code")
        #expect(tokenClient.capturedParameters?["code"] == "mock-auth-code")
    }
    #endif

    // MARK: - handleChallenge (403)

    @Test("handleChallenge 403 returns false for non-insufficient_scope error")
    func testHandleChallenge403NonInsufficientScope() async throws {
        let authorizer = makeAuthorizer()

        let handled = try await authorizer.handleChallenge(
            statusCode: 403,
            headers: ["WWW-Authenticate": "Bearer error=\"access_denied\""],
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == false)
    }

    @Test("handleChallenge 403 insufficient_scope acquires token with upgraded scopes")
    func testHandleChallenge403InsufficientScope() async throws {
        let tokenClient = MockTokenClient()
        let discovery = MockDiscoveryClient()

        let authorizer = makeAuthorizer(
            discoveryClient: discovery,
            tokenClient: tokenClient
        )

        let handled = try await authorizer.handleChallenge(
            statusCode: 403,
            headers: [
                "WWW-Authenticate":
                    "Bearer error=\"insufficient_scope\", scope=\"admin\""
            ],
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == true)
        #expect(tokenClient.requestCallCount == 1)
    }

    // MARK: - Client registration

    @Test("handleChallenge calls client registrar when authentication is .none")
    func testHandleChallengeCallsRegistrar() async throws {
        let registrar = MockClientRegistrar()
        let config = OAuthConfiguration(
            authentication: .none(clientID: "plain-client"))
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(registrar.registerCallCount == 1)
    }

    @Test("handleChallenge skips client registrar when credentials are already configured")
    func testHandleChallengeSkipsRegistrarWithCredentials() async throws {
        let registrar = MockClientRegistrar()
        let authorizer = makeAuthorizer(registrar: registrar)

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(registrar.registerCallCount == 0)
    }

    @Test("handleChallenge persists the DCR-assigned clientID on the saved token")
    func testHandleChallengePersistsDCRClientIDOnToken() async throws {
        let assignedClientID = "dcr-assigned-client-id"
        let tokenStorage = InMemoryTokenStorage()
        let registrar = MockClientRegistrar()
        registrar.registrationResult = (
            response: OAuthClientRegistrationResponse(
                clientID: assignedClientID,
                clientSecret: nil,
                tokenEndpointAuthMethod: nil,
                clientSecretExpiresAt: nil
            ),
            updatedAuthentication: .none(clientID: assignedClientID)
        )

        let config = OAuthConfiguration(
            authentication: .none(clientID: "")
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            tokenStorage: tokenStorage,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        let handled = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(handled == true)
        #expect(registrar.registerCallCount == 1)
        #expect(tokenStorage.load()?.clientID == assignedClientID)
        #expect(tokenStorage.load()?.authorizationServerIssuer == "https://auth.example.com")
    }

    @Test("Preconfigured credentials reject a different issuer")
    func preconfiguredCredentialIssuerMismatch() async {
        let config = OAuthConfiguration(
            authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret"),
            clientCredentialIssuer: "https://expected.example.com"
        )
        let authorizer = OAuthAuthorizer(
            configuration: config,
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: MockAuthCodeFlow()
        )

        let error = await #expect(throws: OAuthAuthorizationError.self) {
            try await authorizer.handleChallenge(
                statusCode: 401,
                headers: headers401,
                endpoint: endpoint,
                operationKey: nil,
                session: .shared
            )
        }
        guard case .clientCredentialIssuerMismatch(let expected, let actual) = error else {
            Issue.record("Expected a client credential issuer mismatch")
            return
        }
        #expect(expected == "https://expected.example.com")
        #expect(actual == "https://auth.example.com")
    }

    @Test("Persisted tokens require the configured credential issuer")
    func persistedTokenIssuerBinding() {
        let issuerA = URL(string: "https://a.example.com")!
        let storage = InMemoryTokenStorage()
        storage.save(OAuthAccessToken(
            value: "token-a",
            tokenType: "Bearer",
            expiresAt: nil,
            scopes: [],
            authorizationServer: issuerA,
            refreshToken: nil
        ))
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(
                authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret"),
                clientCredentialIssuer: "https://b.example.com"
            ),
            tokenStorage: storage
        )

        #expect(authorizer.authorizationHeader(for: endpoint) == nil)
        #expect(storage.load() == nil)
    }

    @Test("Persisted tokens wait for issuer discovery")
    func persistedTokenWaitsForDiscovery() {
        let storage = InMemoryTokenStorage()
        storage.save(OAuthAccessToken(
            value: "token-a",
            tokenType: "Bearer",
            expiresAt: nil,
            scopes: [],
            authorizationServer: URL(string: "https://a.example.com"),
            refreshToken: nil
        ))
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(
                authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret")
            ),
            tokenStorage: storage
        )

        #expect(authorizer.authorizationHeader(for: endpoint) == nil)
        #expect(storage.load()?.value == "token-a")
    }

    @Test("Preconfigured credentials select their advertised issuer")
    func preconfiguredCredentialsSelectBoundIssuer() async throws {
        let issuerA = URL(string: "https://a.example.com")!
        let issuerB = URL(string: "https://b.example.com")!
        let discovery = MockDiscoveryClient(authorizationServer: issuerB)
        discovery.protectedResourceMetadataResult = .init(
            resource: nil,
            authorizationServers: [issuerA, issuerB],
            scopesSupported: nil
        )
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(
                authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret"),
                clientCredentialIssuer: issuerB.absoluteString
            ),
            urlValidator: MockURLValidator(),
            discoveryClient: discovery,
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: MockAuthCodeFlow()
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(discovery.authorizationServerCandidateCalls == [[issuerB]])
    }

    @Test("Preconfigured credentials do not probe an unrelated issuer")
    func preconfiguredCredentialsRequireAdvertisedIssuer() async {
        let discovery = MockDiscoveryClient()
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(
                authentication: .clientSecretBasic(clientID: "client", clientSecret: "secret"),
                clientCredentialIssuer: "https://missing.example.com"
            ),
            urlValidator: MockURLValidator(),
            discoveryClient: discovery,
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: MockAuthCodeFlow()
        )

        await #expect(throws: OAuthAuthorizationError.self) {
            try await authorizer.handleChallenge(
                statusCode: 401,
                headers: headers401,
                endpoint: endpoint,
                operationKey: nil,
                session: .shared
            )
        }
        #expect(discovery.fetchAuthorizationServerMetadataCallCount == 0)
    }

    @Test("Dynamic registration repeats when the issuer changes")
    func dynamicRegistrationFollowsIssuer() async throws {
        let discovery = MockDiscoveryClient()
        let registrar = MockClientRegistrar()
        registrar.registrationResult = (
            response: OAuthClientRegistrationResponse(
                clientID: "https://client.example.com/metadata.json",
                clientSecret: nil,
                tokenEndpointAuthMethod: nil,
                clientSecretExpiresAt: nil
            ),
            updatedAuthentication: .none(clientID: "https://client.example.com/metadata.json")
        )
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(authentication: .none(clientID: "")),
            urlValidator: MockURLValidator(),
            discoveryClient: discovery,
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        let secondIssuer = URL(string: "https://other-auth.example.com")!
        discovery.protectedResourceMetadataResult = OAuthProtectedResourceMetadata(
            resource: nil,
            authorizationServers: [secondIssuer],
            scopesSupported: nil
        )
        discovery.authorizationServerMetadataResult = (
            server: secondIssuer,
            metadata: OAuthAuthorizationServerMetadata(
                issuer: secondIssuer,
                authorizationEndpoint: secondIssuer.appendingPathComponent("authorize"),
                tokenEndpoint: secondIssuer.appendingPathComponent("token"),
                registrationEndpoint: secondIssuer.appendingPathComponent("register"),
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil
            )
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(discovery.fetchProtectedResourceMetadataCallCount == 2)
        #expect(registrar.registerCallCount == 2)
    }

    @Test("A changed issuer never receives another server's refresh token")
    func refreshTokenDoesNotCrossIssuerBoundary() async throws {
        let firstIssuer = URL(string: "https://auth.example.com")!
        let secondIssuer = URL(string: "https://other-auth.example.com")!
        let discovery = MockDiscoveryClient(authorizationServer: firstIssuer)
        discovery.authorizationServerMetadataResult.metadata = .init(
            issuer: firstIssuer,
            authorizationEndpoint: firstIssuer.appendingPathComponent("authorize"),
            tokenEndpoint: firstIssuer.appendingPathComponent("token"),
            registrationEndpoint: nil,
            codeChallengeMethodsSupported: ["S256"],
            tokenEndpointAuthMethodsSupported: ["private_key_jwt"],
            clientIDMetadataDocumentSupported: true
        )
        let tokenClient = MockTokenClient()
        tokenClient.tokenResponse = .init(
            accessToken: "token-a",
            tokenType: "Bearer",
            expiresIn: 3600,
            scope: nil,
            refreshToken: "refresh-a"
        )
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(
                authentication: .privateKeyJWT(
                    clientID: "https://client.example.com/metadata.json",
                    assertionFactory: { _, _ in "assertion" }
                )
            ),
            urlValidator: MockURLValidator(),
            discoveryClient: discovery,
            tokenEndpointClient: tokenClient,
            clientRegistrar: MockClientRegistrar(),
            authCodeFlow: MockAuthCodeFlow()
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        discovery.protectedResourceMetadataResult = .init(
            resource: nil,
            authorizationServers: [secondIssuer],
            scopesSupported: nil
        )
        discovery.authorizationServerMetadataResult = (
            server: secondIssuer,
            metadata: .init(
                issuer: secondIssuer,
                authorizationEndpoint: secondIssuer.appendingPathComponent("authorize"),
                tokenEndpoint: secondIssuer.appendingPathComponent("token"),
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: ["private_key_jwt"],
                clientIDMetadataDocumentSupported: true
            )
        )
        tokenClient.tokenResponse = .init(
            accessToken: "token-b",
            tokenType: "Bearer",
            expiresIn: 3600,
            scope: nil,
            refreshToken: "refresh-b"
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(tokenClient.capturedEndpoints == [
            firstIssuer.appendingPathComponent("token"),
            secondIssuer.appendingPathComponent("token"),
        ])
        #expect(tokenClient.capturedParameterHistory[1]["grant_type"] == "client_credentials")
        #expect(tokenClient.capturedParameterHistory[1]["refresh_token"] == nil)
    }

    @Test("Failed dynamic registration can be retried")
    func dynamicRegistrationFailureCanRetry() async throws {
        let registrar = MockClientRegistrar()
        registrar.errors = [
            OAuthAuthorizationError.tokenRequestFailed(statusCode: 500, oauthError: nil)
        ]
        registrar.registrationResult = (
            response: OAuthClientRegistrationResponse(
                clientID: "assigned-client",
                clientSecret: nil,
                tokenEndpointAuthMethod: nil,
                clientSecretExpiresAt: nil
            ),
            updatedAuthentication: .none(clientID: "assigned-client")
        )
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(authentication: .none(clientID: "")),
            urlValidator: MockURLValidator(),
            discoveryClient: MockDiscoveryClient(),
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        await #expect(throws: OAuthAuthorizationError.self) {
            try await authorizer.handleChallenge(
                statusCode: 401,
                headers: headers401,
                endpoint: endpoint,
                operationKey: nil,
                session: .shared
            )
        }
        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(registrar.registerCallCount == 2)
    }

    @Test("Dynamic registration selects an advertised server that supports it")
    func dynamicRegistrationSelectsCapableServer() async throws {
        let firstIssuer = URL(string: "https://first-auth.example.com")!
        let secondIssuer = URL(string: "https://second-auth.example.com")!
        let discovery = MockDiscoveryClient(authorizationServer: firstIssuer)
        discovery.protectedResourceMetadataResult = .init(
            resource: nil,
            authorizationServers: [firstIssuer, secondIssuer],
            scopesSupported: nil
        )
        discovery.authorizationServerMetadataByCandidate[firstIssuer] = (
            server: firstIssuer,
            metadata: .init(
                issuer: firstIssuer,
                authorizationEndpoint: firstIssuer.appendingPathComponent("authorize"),
                tokenEndpoint: firstIssuer.appendingPathComponent("token"),
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil
            )
        )
        discovery.authorizationServerMetadataByCandidate[secondIssuer] = (
            server: secondIssuer,
            metadata: .init(
                issuer: secondIssuer,
                authorizationEndpoint: secondIssuer.appendingPathComponent("authorize"),
                tokenEndpoint: secondIssuer.appendingPathComponent("token"),
                registrationEndpoint: secondIssuer.appendingPathComponent("register"),
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil
            )
        )
        let registrar = MockClientRegistrar()
        registrar.registrationResult = (
            response: .init(
                clientID: "assigned-client",
                clientSecret: nil,
                tokenEndpointAuthMethod: nil,
                clientSecretExpiresAt: nil
            ),
            updatedAuthentication: .none(clientID: "assigned-client")
        )
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(authentication: .none(clientID: "")),
            urlValidator: MockURLValidator(),
            discoveryClient: discovery,
            tokenEndpointClient: MockTokenClient(),
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(discovery.authorizationServerCandidateCalls == [[firstIssuer], [secondIssuer]])
        #expect(registrar.registerCallCount == 1)
    }

    @Test("Private-key client metadata documents remain portable across issuers")
    func privateKeyMetadataDocumentIsPortable() async throws {
        let firstIssuer = URL(string: "https://auth.example.com")!
        let discovery = MockDiscoveryClient(authorizationServer: firstIssuer)
        discovery.authorizationServerMetadataResult.metadata = .init(
            issuer: firstIssuer,
            authorizationEndpoint: firstIssuer.appendingPathComponent("authorize"),
            tokenEndpoint: firstIssuer.appendingPathComponent("token"),
            registrationEndpoint: nil,
            codeChallengeMethodsSupported: ["S256"],
            tokenEndpointAuthMethodsSupported: ["private_key_jwt"],
            clientIDMetadataDocumentSupported: true
        )
        let registrar = MockClientRegistrar()
        let tokenClient = MockTokenClient()
        tokenClient.invokePrivateKeyAssertion = true
        let authorizer = OAuthAuthorizer(
            configuration: OAuthConfiguration(
                authentication: .privateKeyJWT(
                    clientID: "https://client.example.com/metadata.json",
                    assertionFactory: { _, _ in "assertion" }
                )
            ),
            urlValidator: MockURLValidator(),
            discoveryClient: discovery,
            tokenEndpointClient: tokenClient,
            clientRegistrar: registrar,
            authCodeFlow: MockAuthCodeFlow()
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        let secondIssuer = URL(string: "https://other-auth.example.com")!
        discovery.protectedResourceMetadataResult = .init(
            resource: nil,
            authorizationServers: [secondIssuer],
            scopesSupported: nil
        )
        discovery.authorizationServerMetadataResult = (
            server: secondIssuer,
            metadata: .init(
                issuer: secondIssuer,
                authorizationEndpoint: secondIssuer.appendingPathComponent("authorize"),
                tokenEndpoint: secondIssuer.appendingPathComponent("token"),
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: ["private_key_jwt"],
                clientIDMetadataDocumentSupported: true
            )
        )

        _ = try await authorizer.handleChallenge(
            statusCode: 401,
            headers: headers401,
            endpoint: endpoint,
            operationKey: nil,
            session: .shared
        )

        #expect(registrar.registerCallCount == 0)
        #expect(tokenClient.privateKeyAssertions == ["assertion", "assertion"])
        #expect(discovery.fetchProtectedResourceMetadataCallCount == 2)
    }
}
