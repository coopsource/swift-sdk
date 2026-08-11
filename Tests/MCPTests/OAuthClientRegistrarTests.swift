@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1) && !os(Linux)

    @Suite("OAuthClientRegistrar", .serialized)
    struct OAuthClientRegistrarTests {

        let registrar = OAuthClientRegistrar(urlValidator: OAuthURLValidator())
        let registrationEndpoint = URL(string: "https://auth.example.com/register")!

        func makeASMetadata(registrationEndpoint: URL? = nil) -> OAuthAuthorizationServerMetadata {
            OAuthAuthorizationServerMetadata(
                issuer: URL(string: "https://auth.example.com"),
                authorizationEndpoint: URL(string: "https://auth.example.com/authorize"),
                tokenEndpoint: URL(string: "https://auth.example.com/token"),
                registrationEndpoint: registrationEndpoint,
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: nil,
                clientIDMetadataDocumentSupported: nil
            )
        }

        func makeConfig(
            authentication: OAuthConfiguration.TokenEndpointAuthentication = .none(clientID: "")
        ) -> OAuthConfiguration {
            OAuthConfiguration(authentication: authentication)
        }

        func successRegistrationBody(clientID: String = "registered-client") throws -> Data {
            let dict: [String: Any] = ["client_id": clientID]
            return try JSONSerialization.data(withJSONObject: dict)
        }

        // MARK: - Skip Conditions

        @Test("Returns nil when authentication is not .none")
        func testRegisterReturnsNilForNonNoneAuth() async throws {
            let config = makeConfig(
                authentication: .clientSecretBasic(clientID: "id", clientSecret: "secret"))
            let (session, _) = makeIsolatedSession()
            let result = try await registrar.register(
                configuration: config,
                asMetadata: makeASMetadata(),
                session: session
            )
            #expect(result == nil)
        }

        @Test("Returns nil when no registration endpoint and no CIMD")
        func testRegisterReturnsNilWithoutRegistrationEndpoint() async throws {
            let config = makeConfig(authentication: .none(clientID: "plain-client-id"))
            let (session, _) = makeIsolatedSession()
            let result = try await registrar.register(
                configuration: config,
                asMetadata: makeASMetadata(registrationEndpoint: nil),
                session: session
            )
            #expect(result == nil)
        }

        // MARK: - CIMD Errors

        @Test("Throws when clientID is HTTPS URL with path but server does not support CIMD")
        func testRegisterThrowsCIMDNotSupported() async throws {
            let config = makeConfig(
                authentication: .none(clientID: "https://client.example.com/metadata.json"))
            let asMetadata = OAuthAuthorizationServerMetadata(
                issuer: nil, authorizationEndpoint: nil, tokenEndpoint: nil,
                registrationEndpoint: nil, codeChallengeMethodsSupported: nil,
                tokenEndpointAuthMethodsSupported: nil, clientIDMetadataDocumentSupported: false
            )
            let (session, _) = makeIsolatedSession()

            await #expect(throws: OAuthAuthorizationError.self) {
                try await registrar.register(
                    configuration: config,
                    asMetadata: asMetadata,
                    session: session
                )
            }
        }

        // MARK: - Successful Registration

        @Test("Returns registration response and updated authentication on success")
        func testRegisterSucceeds() async throws {
            let body = try successRegistrationBody(clientID: "registered-client")
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.registrationEndpoint, statusCode: 201,
                    httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            let config = makeConfig(authentication: .none(clientID: ""))
            let result = try await registrar.register(
                configuration: config,
                asMetadata: makeASMetadata(registrationEndpoint: registrationEndpoint),
                session: session
            )

            let resultValue = try #require(result)
            let expected = OAuthConfiguration.TokenEndpointAuthentication.none(clientID: "registered-client")
            #expect(resultValue.updatedAuthentication == expected)
        }

        @Test("Registration includes the configured application type")
        func registrationIncludesApplicationType() async throws {
            let body = try successRegistrationBody()
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                let requestBody = try #require(readRequestBody(request))
                let payload = try #require(
                    JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
                )
                #expect(payload["application_type"] as? String == "native")
                let response = HTTPURLResponse(
                    url: self.registrationEndpoint,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, body)
            }

            let config = OAuthConfiguration(
                authentication: .none(clientID: ""),
                applicationType: .native
            )
            _ = try await registrar.register(
                configuration: config,
                asMetadata: makeASMetadata(registrationEndpoint: registrationEndpoint),
                session: session
            )
        }

        @Test("Application type defaults from the redirect URI")
        func applicationTypeDefaults() {
            let native = OAuthConfiguration(authentication: .none(clientID: "client"))
            let web = OAuthConfiguration(
                authentication: .none(clientID: "client"),
                authorizationRedirectURI: URL(string: "https://app.example.com/callback")!
            )

            #expect(native.applicationType == .native)
            #expect(web.applicationType == .web)
        }

        private func readRequestBody(_ request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }

            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: bufferSize)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }

        @Test("Throws on 4xx registration response")
        func testRegisterThrowsOn4xx() async throws {
            let errorBody = try JSONSerialization.data(
                withJSONObject: ["error": "invalid_client_metadata"])
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.registrationEndpoint, statusCode: 400,
                    httpVersion: nil, headerFields: nil)!
                return (response, errorBody)
            }

            let config = makeConfig(authentication: .none(clientID: ""))
            await #expect(throws: OAuthAuthorizationError.self) {
                try await registrar.register(
                    configuration: config,
                    asMetadata: makeASMetadata(registrationEndpoint: registrationEndpoint),
                    session: session
                )
            }
        }

        @Test("Throws tokenRequestFailed on non-2xx non-4xx response")
        func testRegisterThrowsOn5xx() async throws {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.registrationEndpoint, statusCode: 503,
                    httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            let config = makeConfig(authentication: .none(clientID: ""))
            let error = await #expect(throws: OAuthAuthorizationError.self) {
                try await registrar.register(
                    configuration: config,
                    asMetadata: makeASMetadata(registrationEndpoint: registrationEndpoint),
                    session: session
                )
            }
            guard case .tokenRequestFailed(let statusCode, let oauthError) = error else {
                Issue.record("Expected tokenRequestFailed, got \(String(describing: error))")
                return
            }
            #expect(statusCode == 503)
            #expect(oauthError == nil)
        }

        // MARK: - updatedAuthentication helper

        @Test("updatedAuthentication updates client ID and secret for basic auth")
        func testUpdatedAuthenticationBasic() {
            let registration = OAuthClientRegistrationResponse(
                clientID: "new-id", clientSecret: "new-secret",
                tokenEndpointAuthMethod: nil, clientSecretExpiresAt: nil
            )
            let result = OAuthClientRegistrar.updatedAuthentication(
                from: registration,
                current: .clientSecretBasic(clientID: "old-id", clientSecret: "old-secret")
            )
            let expected = OAuthConfiguration.TokenEndpointAuthentication.clientSecretBasic(clientID: "new-id", clientSecret: "new-secret")
            #expect(result == expected)
        }

        @Test("updatedAuthentication falls back to existing secret when not returned")
        func testUpdatedAuthenticationFallsBackToCurrentSecret() {
            let registration = OAuthClientRegistrationResponse(
                clientID: "new-id", clientSecret: nil,
                tokenEndpointAuthMethod: nil, clientSecretExpiresAt: nil
            )
            let result = OAuthClientRegistrar.updatedAuthentication(
                from: registration,
                current: .clientSecretBasic(clientID: "old-id", clientSecret: "kept-secret")
            )
            let expected = OAuthConfiguration.TokenEndpointAuthentication.clientSecretBasic(clientID: "new-id", clientSecret: "kept-secret")
            #expect(result == expected)
        }
    }

#endif
