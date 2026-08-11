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

private enum CancellationProbeMethod: MCP.Method {
    static let name = "test/cancellation"
    typealias Result = Empty
}

private enum ClientRequestProbeMethod: MCP.Method {
    static let name = "test/client-request"
    typealias Result = Empty
}

private actor NegotiationEventProbe {
    private(set) var initializedNotifications = 0
    private(set) var requestStarted = false
    private(set) var requestCancelled = false
    private(set) var clientRequestHandled = false

    func recordInitialized() { initializedNotifications += 1 }
    func recordStart() { requestStarted = true }
    func recordCancellation() { requestCancelled = true }
    func recordClientRequest() { clientRequestHandled = true }
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

    @Test("Automatic client selects a per-request-metadata-only server")
    func automaticClientUsesPerRequestServer() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "PerRequestServer",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await server.start(transport: transports.server)
        let client = Client(
            name: "AutomaticClient",
            version: "1.0",
            configuration: .init(protocolMode: .automatic)
        )

        let connection = try await client.connectWithInfo(transport: transports.client)
        #expect(connection.protocolLifecycle == .perRequestMetadata)
        #expect(connection.protocolVersion == Version.perRequestMetadataVersion)

        await client.disconnect()
        await server.stop()
    }

    @Test("Lifecycle-only clients fail against servers from the other lifecycle")
    func incompatibleLifecycleOnlyModesFail() async throws {
        let perRequestTransports = await InMemoryTransport.createConnectedPair()
        let initializationServer = Server(
            name: "InitializationServer",
            version: "1.0",
            configuration: .init(protocolMode: .initializationOnly)
        )
        try await initializationServer.start(transport: perRequestTransports.server)
        let perRequestClient = Client(
            name: "PerRequestClient",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )

        await #expect(throws: MCPError.self) {
            _ = try await perRequestClient.connectWithInfo(transport: perRequestTransports.client)
        }
        await perRequestClient.disconnect()
        await initializationServer.stop()

        let initializationTransports = await InMemoryTransport.createConnectedPair()
        let perRequestServer = Server(
            name: "PerRequestServer",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await perRequestServer.start(transport: initializationTransports.server)
        let initializationClient = Client(
            name: "InitializationClient",
            version: "1.0",
            configuration: .init(protocolMode: .initializationOnly)
        )

        await #expect(throws: MCPError.self) {
            _ = try await initializationClient.connectWithInfo(
                transport: initializationTransports.client)
        }
        await initializationClient.disconnect()
        await perRequestServer.stop()
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

    @Test("Strict client accepts a request after its initialized notification is visible")
    func clientInitializationNotificationOrdering() async throws {
        let transport = MockTransport()
        let probe = NegotiationEventProbe()
        await transport.setSendObserver { data in
            let decoder = JSONDecoder()
            if let request = try? decoder.decode(AnyRequest.self, from: data),
                request.method == Initialize.name
            {
                try? await transport.queue(
                    response: Initialize.response(
                        id: request.id,
                        result: .init(
                            protocolVersion: Version.latestInitializationVersion,
                            capabilities: .init(),
                            serverInfo: .init(name: "Server", version: "1.0")
                        )
                    )
                )
            } else if let message = try? decoder.decode(AnyMessage.self, from: data),
                message.method == InitializedNotification.name
            {
                try? await transport.queue(request: ClientRequestProbeMethod.request())
            }
        }
        let client = Client(
            name: "StrictClient",
            version: "1.0",
            configuration: .strict
        )
        await client.withMethodHandler(ClientRequestProbeMethod.self) { _ in
            await probe.recordClientRequest()
            return Empty()
        }

        _ = try await client.connectWithInfo(transport: transport)
        try await waitUntil { await probe.clientRequestHandled }

        await client.disconnect()
    }

    @Test(
        "Recognized per-request errors do not trigger initialization fallback",
        arguments: [
            ProtocolErrorCode.headerMismatch,
            ProtocolErrorCode.missingRequiredClientCapability,
            ProtocolErrorCode.unsupportedProtocolVersion,
        ]
    )
    func recognizedErrorDoesNotFallback(expectedCode: Int) async throws {
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
            code: expectedCode,
            message: "Recognized per-request error",
            data: nil
        )
        try await transport.queue(
            response: AnyMethod.response(id: request!.id, error: error))

        do {
            _ = try await connectionTask.value
            Issue.record("Expected the recognized protocol error")
        } catch let error as MCPError {
            guard case .remote(let actualCode, _, _) = error else {
                Issue.record("Expected a remote protocol error")
                await client.disconnect()
                return
            }
            #expect(actualCode == expectedCode)
        }
        #expect(await transport.sentData.count == 1)
        await client.disconnect()
    }

    @Test("Client retries a mutually supported advertised version once")
    func advertisedVersionRetry() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "PerRequestClient",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }

        try await waitUntil { await transport.sentData.count == 1 }
        let firstData = try #require(await transport.sentData.first)
        let firstRequest = try JSONDecoder().decode(AnyRequest.self, from: firstData)
        try await transport.queue(response: AnyMethod.response(
            id: firstRequest.id,
            error: .remote(
                code: ProtocolErrorCode.unsupportedProtocolVersion,
                message: "Retry the advertised version",
                data: try Value(UnsupportedProtocolVersionData(
                    supported: [Version.perRequestMetadataVersion],
                    requested: Version.perRequestMetadataVersion
                ))
            )
        ))

        try await waitUntil { await transport.sentData.count == 2 }
        let sent = await transport.sentData
        let secondRequest = try JSONDecoder().decode(AnyRequest.self, from: sent[1])
        #expect(firstRequest.method == Discover.name)
        #expect(secondRequest.method == Discover.name)
        #expect(firstRequest.id != secondRequest.id)
        #expect(firstRequest.params == secondRequest.params)
        #expect(protocolVersion(in: firstRequest) == Version.perRequestMetadataVersion)
        #expect(protocolVersion(in: secondRequest) == Version.perRequestMetadataVersion)

        try await transport.queue(response: Discover.response(
            id: secondRequest.id,
            result: .init(
                supportedVersions: [Version.perRequestMetadataVersion],
                capabilities: .init(),
                ttlMs: 0,
                cacheScope: .public
            )
        ))

        let connection = try await connectionTask.value
        #expect(connection.protocolLifecycle == .perRequestMetadata)
        #expect(connection.protocolVersion == Version.perRequestMetadataVersion)
        #expect(await transport.sentData.count == 2)
        await client.disconnect()
    }

    @Test("Client surfaces a second advertised-version rejection without another retry")
    func advertisedVersionRetryStopsAfterSecondRejection() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "AutomaticClient",
            version: "1.0",
            configuration: .init(protocolMode: .automatic)
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }

        try await waitUntil { await transport.sentData.count == 1 }
        let firstData = try #require(await transport.sentData.first)
        let firstRequest = try JSONDecoder().decode(AnyRequest.self, from: firstData)
        try await transport.queue(response: AnyMethod.response(
            id: firstRequest.id,
            error: .remote(
                code: ProtocolErrorCode.unsupportedProtocolVersion,
                message: "First rejection",
                data: try Value(UnsupportedProtocolVersionData(
                    supported: [Version.perRequestMetadataVersion],
                    requested: Version.perRequestMetadataVersion
                ))
            )
        ))

        try await waitUntil { await transport.sentData.count == 2 }
        let sent = await transport.sentData
        let secondRequest = try JSONDecoder().decode(AnyRequest.self, from: sent[1])
        #expect(firstRequest.method == Discover.name)
        #expect(secondRequest.method == Discover.name)
        try await transport.queue(response: AnyMethod.response(
            id: secondRequest.id,
            error: .remote(
                code: ProtocolErrorCode.unsupportedProtocolVersion,
                message: "Second rejection",
                data: try Value(UnsupportedProtocolVersionData(
                    supported: [Version.perRequestMetadataVersion],
                    requested: Version.perRequestMetadataVersion
                ))
            )
        ))

        do {
            _ = try await connectionTask.value
            Issue.record("Expected the second unsupported-version error")
        } catch let error as MCPError {
            guard case .remote(let code, let message, _) = error else {
                Issue.record("Expected a remote protocol error")
                await client.disconnect()
                return
            }
            #expect(code == ProtocolErrorCode.unsupportedProtocolVersion)
            #expect(message == "Second rejection")
        }
        #expect(firstRequest.id != secondRequest.id)
        #expect(firstRequest.params == secondRequest.params)
        #expect(protocolVersion(in: firstRequest) == Version.perRequestMetadataVersion)
        #expect(protocolVersion(in: secondRequest) == Version.perRequestMetadataVersion)
        #expect(await transport.sentData.count == 2)
        await client.disconnect()
    }

    @Test("Discovery without a mutually supported per-request version does not fall back")
    func discoveryWithoutMutualVersionDoesNotFallback() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "AutomaticClient",
            version: "1.0",
            configuration: .init(protocolMode: .automatic)
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }

        try await waitUntil { await !transport.sentData.isEmpty }
        let request: AnyRequest = try #require(await transport.decodeLastSentMessage())
        try await transport.queue(response: Discover.response(
            id: request.id,
            result: .init(
                supportedVersions: [Version.latestInitializationVersion],
                capabilities: .init(),
                ttlMs: 0,
                cacheScope: .public
            )
        ))

        do {
            _ = try await connectionTask.value
            Issue.record("Expected unsupported protocol version")
        } catch let error as MCPError {
            #expect(error.code == ProtocolErrorCode.unsupportedProtocolVersion)
        }
        #expect(await transport.sentData.count == 1)
        await client.disconnect()
    }

    @Test("Cancelling automatic discovery does not start initialization")
    func cancelledAutomaticDiscoveryDoesNotFallback() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "AutomaticClient",
            version: "1.0",
            configuration: .init(
                protocolMode: .automatic,
                discoveryProbeTimeout: 0
            )
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }

        try await waitUntil { await !transport.sentData.isEmpty }
        connectionTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await connectionTask.value
        }
        try await waitUntil { await transport.sentData.count == 2 }

        let sent = await transport.sentData
        #expect(try JSONDecoder().decode(AnyRequest.self, from: sent[0]).method == Discover.name)
        #expect(
            try JSONDecoder().decode(AnyMessage.self, from: sent[1]).method
                == CancelledNotification.name
        )
        await client.disconnect()
    }

    @Test("A timed-out discovery probe is cancelled before initialization fallback")
    func timeoutCancellationPrecedesFallback() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "AutomaticClient",
            version: "1.0",
            configuration: .init(
                protocolMode: .automatic,
                discoveryProbeTimeout: 0.01
            )
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }

        try await waitUntil { await transport.sentData.count >= 3 }
        let sent = await transport.sentData
        let discover = try JSONDecoder().decode(AnyRequest.self, from: sent[0])
        let cancellation = try JSONDecoder().decode(AnyMessage.self, from: sent[1])
        let initialize = try JSONDecoder().decode(AnyRequest.self, from: sent[2])
        let discoverID = try Value(discover.id)

        #expect(discover.method == Discover.name)
        #expect(cancellation.method == CancelledNotification.name)
        #expect(
            cancellation.params.objectValue?["requestId"]
                == discoverID
        )
        #expect(initialize.method == Initialize.name)

        try await transport.queue(
            response: Initialize.response(
                id: initialize.id,
                result: .init(
                    protocolVersion: Version.latestInitializationVersion,
                    capabilities: .init(),
                    serverInfo: .init(name: "LegacyServer", version: "1.0")
                )
            )
        )
        let connection = try await connectionTask.value
        #expect(connection.protocolLifecycle == .initializationBased)
        await client.disconnect()
    }

    @Test("Per-request-only timeout cancels discovery without initialization")
    func perRequestTimeoutDoesNotFallback() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "PerRequestClient",
            version: "1.0",
            configuration: .init(
                protocolMode: .perRequestMetadataOnly,
                discoveryProbeTimeout: 0.01
            )
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }

        do {
            _ = try await connectionTask.value
            Issue.record("Expected discovery to time out")
        } catch {
            #expect(error is MCPError)
        }
        let sent = await transport.sentData
        #expect(sent.count == 2)
        #expect(try JSONDecoder().decode(AnyRequest.self, from: sent[0]).method == Discover.name)
        #expect(
            try JSONDecoder().decode(AnyMessage.self, from: sent[1]).method
                == CancelledNotification.name
        )
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

        await transport.queue(data: try JSONEncoder().encode(
            validRequest(id: 3, method: Discover.name)
        ))
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

    @Test("Per-request client treats an absent result type as complete")
    func missingResultType() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "PerRequestClient",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }
        try await waitUntil { await !transport.sentData.isEmpty }
        let decodedRequest: AnyRequest? = await transport.decodeLastSentMessage()
        let request = try #require(decodedRequest)
        let response: Value = [
            "jsonrpc": "2.0",
            "id": try Value(request.id),
            "result": [
                "supportedVersions": [.string(Version.perRequestMetadataVersion)],
                "capabilities": .object([:]),
                "ttlMs": 0,
                "cacheScope": "public",
            ],
        ]
        await transport.queue(data: try JSONEncoder().encode(response))

        let connection = try await connectionTask.value
        #expect(connection.protocolLifecycle == .perRequestMetadata)
        #expect(connection.protocolVersion == Version.perRequestMetadataVersion)
        await client.disconnect()
    }

    @Test("Per-request client rejects an unrecognized result type")
    func unrecognizedResultType() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "PerRequestClient",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }
        try await waitUntil { await !transport.sentData.isEmpty }
        let decodedRequest: AnyRequest? = await transport.decodeLastSentMessage()
        let request = try #require(decodedRequest)
        let response: Value = [
            "jsonrpc": "2.0",
            "id": try Value(request.id),
            "result": [
                "supportedVersions": [.string(Version.perRequestMetadataVersion)],
                "capabilities": .object([:]),
                "ttlMs": 0,
                "cacheScope": "public",
                "resultType": "totally_unknown",
            ],
        ]
        await transport.queue(data: try JSONEncoder().encode(response))

        do {
            _ = try await connectionTask.value
            Issue.record("Expected an unrecognized result type to be rejected")
        } catch let error as MCPError {
            guard case .invalidRequest(let message) = error else {
                Issue.record("Expected an invalid-request error, got \(error)")
                await client.disconnect()
                return
            }
            #expect(message?.contains("totally_unknown") == true)
        }
        await client.disconnect()
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
        guard case .failure(.invalidParams(let message)) = response?.result else {
            Issue.record("Expected an invalid-params response")
            await server.stop()
            return
        }
        #expect(message?.contains(ProtocolMetadataKey.clientCapabilities) == true)
        await server.stop()
    }

    @Test("Server rejects an unrecognized request-scoped log level")
    func malformedLogLevel() async throws {
        let transport = MockTransport()
        let server = Server(
            name: "Server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await server.start(transport: transport)

        guard case .object(var request) = validRequest(id: 4, method: ContextProbe.name)
        else {
            Issue.record("Expected an object-valued request")
            await server.stop()
            return
        }
        var parameters = request["params"]?.objectValue ?? [:]
        var metadata = parameters["_meta"]?.objectValue ?? [:]
        metadata[ProtocolMetadataKey.logLevel] = .string("verbose")
        parameters["_meta"] = .object(metadata)
        request["params"] = .object(parameters)
        await transport.queue(data: try JSONEncoder().encode(Value.object(request)))
        try await Task.sleep(for: .milliseconds(20))

        let response: AnyResponse? = await transport.decodeLastSentMessage()
        guard case .failure(.invalidParams(let message)) = response?.result else {
            Issue.record("Expected an invalid-params response")
            await server.stop()
            return
        }
        #expect(message?.contains(ProtocolMetadataKey.logLevel) == true)
        await server.stop()
    }

    @Test(
        "Removed initialization methods are unavailable in 2026-07-28",
        arguments: [
            Ping.name,
            SetLoggingLevel.name,
            ResourceSubscribe.name,
            ResourceUnsubscribe.name,
        ]
    )
    func removedMethod(method: String) async throws {
        let transport = MockTransport()
        let server = Server(
            name: "Server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await server.start(transport: transport)

        await transport.queue(data: try JSONEncoder().encode(
            validRequest(id: 5, method: method)
        ))
        try await Task.sleep(for: .milliseconds(20))

        let response: AnyResponse? = await transport.decodeLastSentMessage()
        guard case .failure(.methodNotFound(let message)) = response?.result else {
            Issue.record("Expected a method-not-found response for \(method)")
            await server.stop()
            return
        }
        #expect(message?.contains(method) == true)
        await server.stop()
    }

    @Test("Client compatibility helpers reject removed 2026-07-28 operations")
    func clientRemovedOperationHelpers() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "Server",
            version: "1.0",
            capabilities: .init(
                logging: .init(),
                resources: .init(subscribe: true)
            ),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await server.start(transport: pair.server)
        let client = Client(
            name: "Client",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        _ = try await client.connectWithInfo(transport: pair.client)

        await #expect(throws: MCPError.self) { try await client.ping() }
        await #expect(throws: MCPError.self) { try await client.setLoggingLevel(.info) }
        await #expect(throws: MCPError.self) {
            try await client.subscribeToResource(uri: "file:///resource")
        }
        await #expect(throws: MCPError.self) { try await client.notifyRootsChanged() }
        await #expect(throws: MCPError.self) {
            _ = try await client.send(Ping.request())
        }
        await #expect(throws: MCPError.self) {
            try await client.notify(InitializedNotification.message())
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("Per-request roots capability omits the removed list-change flag")
    func perRequestRootsCapability() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "Client",
            version: "1.0",
            capabilities: .init(roots: .init(listChanged: true)),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }
        while await transport.sentData.isEmpty {
            await Task.yield()
        }

        let request: AnyRequest = try #require(await transport.decodeLastSentMessage())
        let roots = request.params.objectValue?["_meta"]?
            .objectValue?[ProtocolMetadataKey.clientCapabilities]?
            .objectValue?["roots"]?.objectValue
        #expect(roots != nil)
        #expect(roots?["listChanged"] == nil)

        let result = Discover.Result(
            supportedVersions: [Version.perRequestMetadataVersion],
            capabilities: .init(),
            ttlMs: 0,
            cacheScope: .public,
            _meta: Metadata(additionalFields: [
                ProtocolMetadataKey.serverInfo: try Value(
                    Server.Info(name: "Server", version: "1.0")
                )
            ])
        )
        try await transport.queue(response: Discover.response(id: request.id, result: result))
        _ = try await connectionTask.value
        await client.disconnect()
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
        #expect(decoded.supported == Version.preferenceOrder)
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

    @Test("Strict combined lifecycle enforces initialized notification ordering")
    func combinedLifecycleInitializationOrdering() async throws {
        let transport = MockTransport()
        let probe = NegotiationEventProbe()
        let server = Server(
            name: "CombinedServer",
            version: "1.0",
            configuration: .init(
                strict: true,
                protocolMode: .initializationAndPerRequestMetadata
            )
        )
        await server.onNotification(InitializedNotification.self) { _ in
            await probe.recordInitialized()
        }
        try await server.start(transport: transport)

        try await transport.queue(notification: InitializedNotification.message())
        try await waitUntil { await !transport.sentData.isEmpty }
        #expect(await probe.initializedNotifications == 0)
        await transport.clearMessages()

        let initializeRequest = Initialize.request(
            .init(
                protocolVersion: Version.latestInitializationVersion,
                capabilities: .init(),
                clientInfo: .init(name: "Client", version: "1.0")
            )
        )
        try await transport.queue(request: initializeRequest)
        try await waitUntil {
            await transport.sentData.contains { data in
                (try? JSONDecoder().decode(AnyResponse.self, from: data).id)
                    == initializeRequest.id
            }
        }
        let initializeResponseData = try #require(
            await transport.sentData.first { data in
                (try? JSONDecoder().decode(AnyResponse.self, from: data).id)
                    == initializeRequest.id
            })
        let initializeResponse = try JSONDecoder().decode(
            AnyResponse.self, from: initializeResponseData)
        guard case .success = initializeResponse.result else {
            Issue.record("Expected initialize to succeed")
            await server.stop()
            return
        }
        try await transport.queue(notification: InitializedNotification.message())
        try await waitUntil { await probe.initializedNotifications == 1 }

        await server.stop()
    }

    @Test("Strict combined lifecycle accepts cancellation for an active per-request call")
    func combinedLifecycleRelatedCancellation() async throws {
        let transport = MockTransport()
        let probe = NegotiationEventProbe()
        let server = Server(
            name: "CombinedServer",
            version: "1.0",
            configuration: .init(
                strict: true,
                protocolMode: .initializationAndPerRequestMetadata
            )
        )
        await server.withMethodHandler(CancellationProbeMethod.self) { _ in
            await probe.recordStart()
            do {
                try await Task.sleep(for: .seconds(10))
                return Empty()
            } catch {
                await probe.recordCancellation()
                throw error
            }
        }
        try await server.start(transport: transport)

        await transport.queue(data: try JSONEncoder().encode(
            validRequest(id: 91, method: CancellationProbeMethod.name)))
        try await waitUntil { await probe.requestStarted }
        try await transport.queue(
            notification: CancelledNotification.message(
                .init(requestId: .number(91), reason: "test cancellation")
            )
        )
        try await waitUntil { await probe.requestCancelled }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await transport.sentData.isEmpty)

        await server.stop()
    }

    @Test("Per-request-only server rejects initialized notifications")
    func perRequestOnlyRejectsInitialized() async throws {
        let transport = MockTransport()
        let probe = NegotiationEventProbe()
        let server = Server(
            name: "PerRequestServer",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.onNotification(InitializedNotification.self) { _ in
            await probe.recordInitialized()
        }
        try await server.start(transport: transport)

        try await transport.queue(notification: InitializedNotification.message())
        try await Task.sleep(for: .milliseconds(10))

        #expect(await probe.initializedNotifications == 0)
        await server.stop()
    }

    @Test("Serialized configurations without a mode remain initialization-only")
    func configurationDecodingCompatibility() throws {
        let data = Data(#"{"strict":true}"#.utf8)
        let client = try JSONDecoder().decode(Client.Configuration.self, from: data)
        let server = try JSONDecoder().decode(Server.Configuration.self, from: data)

        #expect(client.protocolMode == .initializationOnly)
        #expect(client.discoveryProbeTimeout == 15)
        #expect(client.multiRoundTripMode == .disabled)
        #expect(client.responseCacheMode == .disabled)
        #expect(server.protocolMode == .initializationOnly)

        let noTimeout = Client.Configuration(discoveryProbeTimeout: 0)
        #expect(
            try JSONDecoder().decode(
                Client.Configuration.self,
                from: JSONEncoder().encode(noTimeout)
            ) == noTimeout
        )
    }

    private func protocolVersion(in request: AnyRequest) -> String? {
        request.params.objectValue?["_meta"]?.objectValue?[
            ProtocolMetadataKey.protocolVersion
        ]?.stringValue
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for test condition")
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
