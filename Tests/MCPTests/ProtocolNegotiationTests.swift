import Foundation
import Testing

@testable import MCP

private enum ContextProbe: MCP.Method {
    static let name = "test/context"

    struct Result: Hashable, Codable, Sendable {
        let lifecycle: ProtocolLifecycle
        let protocolVersion: String?
        let clientName: String?
    }
}

@Suite("MCP 2026-07-28 protocol negotiation", .timeLimit(.minutes(1)))
struct ProtocolNegotiationTests {
    @Test("Per-request metadata client discovers a per-request server")
    func perRequestDiscovery() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "PerRequestServer",
            version: "1.2.3",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(ContextProbe.self) { _ in
            let context = Server.currentHandlerContext
            return .init(
                lifecycle: context?.protocolLifecycle ?? .initializationBased,
                protocolVersion: context?.protocolVersion,
                clientName: context?.clientInfo?.name
            )
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "PerRequestClient",
            version: "4.5.6",
            capabilities: .init(roots: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        let connection = try await client.connectWithInfo(transport: transports.client)

        #expect(connection.protocolLifecycle == .perRequestMetadata)
        #expect(connection.protocolVersion == Version.perRequestMetadataVersion)
        #expect(connection.serverInfo?.name == "PerRequestServer")
        #expect(connection.capabilities.tools != nil)

        let result = try await client.sendAndAwait(ContextProbe.request())
        #expect(result.lifecycle == .perRequestMetadata)
        #expect(result.protocolVersion == Version.perRequestMetadataVersion)
        #expect(result.clientName == "PerRequestClient")

        await client.disconnect()
        await server.stop()
    }

    @Test("Automatic client falls back after an initialization-only discovery error")
    func automaticFallback() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "InitializationServer",
            version: "1.0",
            configuration: .init(strict: true, protocolMode: .initializationOnly)
        )
        try await server.start(transport: transports.server)

        let client = Client(
            name: "AutomaticClient",
            version: "1.0",
            configuration: .init(protocolMode: .automatic)
        )
        let connection = try await client.connectWithInfo(transport: transports.client)

        #expect(connection.protocolLifecycle == .initializationBased)
        #expect(connection.protocolVersion == Version.latestInitializationVersion)
        #expect(connection.serverInfo?.name == "InitializationServer")

        await client.disconnect()
        await server.stop()
    }

    @Test("Initialization client remains compatible with a combined-lifecycle server")
    func initializationAgainstCombinedServer() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "CombinedServer",
            version: "1.0",
            configuration: .init(
                strict: true,
                protocolMode: .initializationAndPerRequestMetadata
            )
        )
        try await server.start(transport: transports.server)

        let client = Client(name: "InitializationClient", version: "1.0")
        let connection = try await client.connectWithInfo(transport: transports.client)

        #expect(connection.protocolLifecycle == .initializationBased)
        #expect(connection.protocolVersion == Version.latestInitializationVersion)

        await client.disconnect()
        await server.stop()
    }

    @Test("Recognized per-request errors do not trigger initialization fallback")
    func recognizedErrorDoesNotFallback() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "AutomaticClient",
            version: "1.0",
            configuration: .init(protocolMode: .automatic)
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }

        while await transport.sentData.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        let request: AnyRequest? = await transport.decodeLastSentMessage()
        let error = MCPError.remote(
            code: ProtocolErrorCode.unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            data: try Value(UnsupportedProtocolVersionData(
                supported: ["2099-01-01"],
                requested: Version.perRequestMetadataVersion
            ))
        )
        try await transport.queue(
            response: AnyMethod.response(id: request!.id, error: error))

        do {
            _ = try await connectionTask.value
            Issue.record("Expected the recognized protocol error")
        } catch let error as MCPError {
            guard case .remote(let code, _, _) = error else {
                Issue.record("Expected a remote protocol error")
                await client.disconnect()
                return
            }
            #expect(code == ProtocolErrorCode.unsupportedProtocolVersion)
        }
        #expect(await transport.sentData.count == 1)
        await client.disconnect()
    }

    @Test("Per-request success responses include result type and server identity")
    func perRequestResponseFields() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "ResponseServer",
            version: "3.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await server.start(transport: transport)

        await transport.queue(data: try JSONEncoder().encode(validRequest(id: 3, method: Ping.name)))
        try await Task.sleep(for: .milliseconds(20))

        let response: Value? = await transport.decodeLastSentMessage()
        let result = response?.objectValue?["result"]?.objectValue
        #expect(result?["resultType"] == .string("complete"))
        #expect(
            result?["_meta"]?.objectValue?[ProtocolMetadataKey.serverInfo]?
                .objectValue?["name"] == .string("ResponseServer")
        )
        await server.stop()
    }

    @Test("Server rejects malformed per-request metadata")
    func malformedMetadata() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "Server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await server.start(transport: transport)

        let request: Value = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "ping",
            "params": [
                "_meta": [
                    ProtocolMetadataKey.protocolVersion: .string(
                        Version.perRequestMetadataVersion)
                ]
            ],
        ]
        await transport.queue(data: try JSONEncoder().encode(request))
        try await Task.sleep(for: .milliseconds(20))

        let response: AnyResponse? = await transport.decodeLastSentMessage()
        guard case .failure(.invalidRequest(let message)) = response?.result else {
            Issue.record("Expected an invalid-request response")
            await server.stop()
            return
        }
        #expect(message?.contains(ProtocolMetadataKey.clientCapabilities) == true)
        await server.stop()
    }

    @Test("Server returns supported versions for an unsupported request version")
    func unsupportedVersion() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "Server",
            version: "1.0",
            configuration: .init(protocolMode: .initializationAndPerRequestMetadata)
        )
        try await server.start(transport: transport)

        let request: Value = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "ping",
            "params": [
                "_meta": [
                    ProtocolMetadataKey.protocolVersion: .string("1900-01-01"),
                    ProtocolMetadataKey.clientCapabilities: .object([:]),
                ]
            ],
        ]
        await transport.queue(data: try JSONEncoder().encode(request))
        try await Task.sleep(for: .milliseconds(20))

        let response: AnyResponse? = await transport.decodeLastSentMessage()
        guard case .failure(.remote(let code, _, let data)) = response?.result else {
            Issue.record("Expected an unsupported-version response")
            await server.stop()
            return
        }
        #expect(code == ProtocolErrorCode.unsupportedProtocolVersion)
        let decoded = try JSONDecoder().decode(
            UnsupportedProtocolVersionData.self,
            from: JSONEncoder().encode(data)
        )
        #expect(decoded.requested == "1900-01-01")
        #expect(decoded.supported.first == Version.perRequestMetadataVersion)
        await server.stop()
    }

    @Test("Server rejects initialize carrying per-request metadata")
    func initializeWithPerRequestMetadata() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "Server",
            version: "1.0",
            configuration: .init(protocolMode: .initializationAndPerRequestMetadata)
        )
        try await server.start(transport: transport)

        let request: Value = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": .string(Initialize.name),
            "params": [
                "protocolVersion": .string(Version.latestInitializationVersion),
                "capabilities": .object([:]),
                "clientInfo": ["name": "Client", "version": "1.0"],
                "_meta": [
                    ProtocolMetadataKey.protocolVersion: .string(
                        Version.perRequestMetadataVersion),
                    ProtocolMetadataKey.clientCapabilities: .object([:]),
                ],
            ],
        ]
        await transport.queue(data: try JSONEncoder().encode(request))
        try await Task.sleep(for: .milliseconds(20))

        let response: AnyResponse? = await transport.decodeLastSentMessage()
        guard case .failure(.methodNotFound(let message)) = response?.result else {
            Issue.record("Expected initialize to be rejected on the per-request path")
            await server.stop()
            return
        }
        #expect(message?.contains("per-request-metadata lifecycle") == true)
        await server.stop()
    }

    @Test("Serialized configurations without a mode remain initialization-only")
    func configurationDecodingCompatibility() throws {
        let data = Data(#"{"strict":true}"#.utf8)
        let client = try JSONDecoder().decode(Client.Configuration.self, from: data)
        let server = try JSONDecoder().decode(Server.Configuration.self, from: data)

        #expect(client.protocolMode == .initializationOnly)
        #expect(server.protocolMode == .initializationOnly)
    }

    private func validRequest(id: Int, method: String) -> Value {
        [
            "jsonrpc": "2.0",
            "id": .int(id),
            "method": .string(method),
            "params": [
                "_meta": [
                    ProtocolMetadataKey.protocolVersion: .string(
                        Version.perRequestMetadataVersion),
                    ProtocolMetadataKey.clientCapabilities: .object([:]),
                ]
            ],
        ]
    }
}
