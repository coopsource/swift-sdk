import Foundation
import Testing

@testable import MCP

@Suite("MCP 2026-07-28 subscriptions", .timeLimit(.minutes(1)))
struct SubscriptionTests {
    @Test("Server sends subscription acknowledgment before completion")
    func serverAcknowledgment() async throws {
        let transport = MockTransport()
        let server = makeServer(capabilities: .init(tools: .init(listChanged: true)))
        try await server.start(transport: transport)
        let requestID = ID.string("listen-server-test")
        let data = try PerRequestMetadataWire.encodeRequest(
            SubscriptionsListen.request(
                id: requestID,
                .init(notifications: .init(toolsListChanged: true))
            ),
            protocolVersion: Version.perRequestMetadataVersion,
            clientInfo: .init(name: "Client", version: "1.0"),
            clientCapabilities: .init(),
            using: JSONEncoder()
        )
        await transport.queue(data: data)
        try await Task.sleep(for: .milliseconds(50))

        let messages = await transport.sentData
        #expect(messages.count == 1)
        let acknowledgment = try JSONDecoder().decode(
            Message<SubscriptionsAcknowledgedNotification>.self,
            from: messages[0]
        )
        #expect(acknowledgment.params._meta.subscriptionID == requestID)

        try await transport.queue(notification: CancelledNotification.message(
            .init(requestId: requestID, reason: "Test complete")
        ))
        try await Task.sleep(for: .milliseconds(10))
        await server.stop()
    }

    @Test("Client accepts a correlated subscription acknowledgment")
    func clientAcknowledgment() async throws {
        let transport = MockTransport()
        let client = makeClient()
        let connectTask = Task {
            try await client.connectWithInfo(transport: transport)
        }
        while await transport.sentData.isEmpty {
            await Task.yield()
        }
        let discover: AnyRequest = try #require(await transport.decodeLastSentMessage())
        let discoverResult = Discover.Result(
            supportedVersions: [Version.perRequestMetadataVersion],
            capabilities: .init(tools: .init(listChanged: true)),
            ttlMs: 0,
            cacheScope: .public,
            _meta: Metadata(additionalFields: [
                ProtocolMetadataKey.serverInfo: try Value(
                    Server.Info(name: "Server", version: "1.0")
                )
            ])
        )
        try await transport.queue(
            response: Discover.response(id: discover.id, result: discoverResult)
        )
        _ = try await connectTask.value

        let listenTask = Task {
            try await client.listen(notifications: .init(toolsListChanged: true))
        }
        while await transport.sentData.count < 2 {
            await Task.yield()
        }
        let listenRequest = try JSONDecoder().decode(
            Request<SubscriptionsListen>.self,
            from: await transport.sentData[1]
        )
        try await transport.queue(notification: SubscriptionsAcknowledgedNotification.message(
            .init(
                subscriptionID: listenRequest.id,
                notifications: .init(toolsListChanged: true)
            )
        ))

        let subscription = try await listenTask.value
        #expect(subscription.id == listenRequest.id)
        var events = subscription.events.makeAsyncIterator()
        #expect(try await events.next() == .acknowledged(.init(toolsListChanged: true)))
        try await client.cancelSubscription(subscription.id)
        await client.disconnect()
    }

    @Test("Client rejects an acknowledgment outside the requested filter")
    func clientRejectsExpandedAcknowledgment() async throws {
        let transport = MockTransport()
        let client = makeClient()
        let connectTask = Task {
            try await client.connectWithInfo(transport: transport)
        }
        while await transport.sentData.isEmpty {
            await Task.yield()
        }
        let discover: AnyRequest = try #require(await transport.decodeLastSentMessage())
        let discoverResult = Discover.Result(
            supportedVersions: [Version.perRequestMetadataVersion],
            capabilities: .init(
                prompts: .init(listChanged: true),
                tools: .init(listChanged: true)
            ),
            ttlMs: 0,
            cacheScope: .public,
            _meta: Metadata(additionalFields: [
                ProtocolMetadataKey.serverInfo: try Value(
                    Server.Info(name: "Server", version: "1.0")
                )
            ])
        )
        try await transport.queue(
            response: Discover.response(id: discover.id, result: discoverResult)
        )
        _ = try await connectTask.value

        let listenTask = Task {
            try await client.listen(notifications: .init(toolsListChanged: true))
        }
        while await transport.sentData.count < 2 {
            await Task.yield()
        }
        let listenRequest = try JSONDecoder().decode(
            Request<SubscriptionsListen>.self,
            from: await transport.sentData[1]
        )
        try await transport.queue(notification: SubscriptionsAcknowledgedNotification.message(
            .init(
                subscriptionID: listenRequest.id,
                notifications: .init(
                    toolsListChanged: true,
                    promptsListChanged: true
                )
            )
        ))

        await #expect(throws: MCPError.self) {
            _ = try await listenTask.value
        }
        await client.disconnect()
    }

    @Test("Protocol errors terminate an acknowledged subscription")
    func protocolErrorTerminatesSubscription() async throws {
        let transport = MockTransport()
        let client = makeClient()
        let connectTask = Task {
            try await client.connectWithInfo(transport: transport)
        }
        while await transport.sentData.isEmpty {
            await Task.yield()
        }
        let discover: AnyRequest = try #require(await transport.decodeLastSentMessage())
        try await transport.queue(response: Discover.response(
            id: discover.id,
            result: .init(
                supportedVersions: [Version.perRequestMetadataVersion],
                capabilities: .init(tools: .init(listChanged: true)),
                ttlMs: 0,
                cacheScope: .public,
                _meta: Metadata(additionalFields: [
                    ProtocolMetadataKey.serverInfo: try Value(
                        Server.Info(name: "Server", version: "1.0")
                    )
                ])
            )
        ))
        _ = try await connectTask.value

        let listenTask = Task {
            try await client.listen(notifications: .init(toolsListChanged: true))
        }
        while await transport.sentData.count < 2 {
            await Task.yield()
        }
        let listenRequest = try JSONDecoder().decode(
            Request<SubscriptionsListen>.self,
            from: await transport.sentData[1]
        )
        try await transport.queue(notification: SubscriptionsAcknowledgedNotification.message(
            .init(
                subscriptionID: listenRequest.id,
                notifications: .init(toolsListChanged: true)
            )
        ))
        let subscription = try await listenTask.value
        var events = subscription.events.makeAsyncIterator()
        _ = try await events.next()

        try await transport.queue(response: AnyMethod.response(
            id: listenRequest.id,
            error: .invalidRequest("Invalid subscription stream")
        ))
        await #expect(throws: MCPError.self) {
            _ = try await events.next()
        }

        await client.disconnect()
    }

    @Test("Official subscription fixtures match the wire models")
    func officialFixtures() throws {
        let filter = SubscriptionFilter(
            toolsListChanged: true,
            resourceSubscriptions: ["file:///project/config.json"]
        )
        let encodedRequest = try PerRequestMetadataWire.encodeRequest(
            SubscriptionsListen.request(
                id: .string("listen-1"),
                .init(notifications: filter)
            ),
            protocolVersion: Version.perRequestMetadataVersion,
            clientInfo: .init(name: "ExampleClient", version: "1.0.0"),
            clientCapabilities: .init(),
            using: JSONEncoder()
        )

        let decoder = JSONDecoder()
        #expect(
            try decoder.decode(Value.self, from: encodedRequest)
                == decoder.decode(
                    Value.self,
                    from: try fixture(named: "subscriptions-listen-request")
                )
        )

        let acknowledgment = try decoder.decode(
            Message<SubscriptionsAcknowledgedNotification>.self,
            from: try fixture(named: "subscriptions-acknowledged")
        )
        #expect(acknowledgment.params._meta.subscriptionID == .string("listen-1"))
        #expect(acknowledgment.params.notifications == filter)

        let result = try decoder.decode(
            SubscriptionsListen.Result.self,
            from: try fixture(named: "subscriptions-listen-result")
        )
        #expect(result.resultType == .complete)
        #expect(result._meta.subscriptionID == .string("listen-1"))
    }

    @Test("Acknowledgment precedes selected notifications")
    func acknowledgmentAndFiltering() async throws {
        let (client, server) = try await connectedPair(
            capabilities: .init(
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: true)
            )
        )
        let subscription = try await client.listen(notifications: .init(
            toolsListChanged: true,
            resourceSubscriptions: ["file:///selected"]
        ))
        var events = subscription.events.makeAsyncIterator()

        #expect(
            try await events.next()
                == .acknowledged(.init(
                    toolsListChanged: true,
                    resourceSubscriptions: ["file:///selected"]
                ))
        )

        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "file:///other")))
        try await server.notify(ToolListChangedNotification.message(.init()))

        guard case .notification(let notification) = try await events.next() else {
            Issue.record("Expected the selected tool-list notification")
            await client.disconnect()
            await server.stop()
            return
        }
        #expect(notification.subscriptionID == subscription.id)
        #expect(notification.method == ToolListChangedNotification.name)

        try await client.cancelSubscription(subscription.id, reason: "Test complete")
        #expect(try await events.next() == nil)
        await client.disconnect()
        await server.stop()
    }

    @Test("Concurrent listeners receive only their acknowledged filters")
    func concurrentListeners() async throws {
        let (client, server) = try await connectedPair(
            capabilities: .init(
                resources: .init(subscribe: true),
                tools: .init(listChanged: true)
            )
        )
        async let toolListen = client.listen(
            notifications: SubscriptionFilter(toolsListChanged: true)
        )
        async let resourceListen = client.listen(
            notifications: SubscriptionFilter(resourceSubscriptions: ["file:///selected"])
        )
        let (toolSubscription, resourceSubscription) = try await (toolListen, resourceListen)
        var toolEvents = toolSubscription.events.makeAsyncIterator()
        var resourceEvents = resourceSubscription.events.makeAsyncIterator()
        _ = try await toolEvents.next()
        _ = try await resourceEvents.next()

        try await server.notify(ToolListChangedNotification.message(.init()))
        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "file:///selected")))

        guard case .notification(let toolNotification) = try await toolEvents.next(),
            case .notification(let resourceNotification) = try await resourceEvents.next()
        else {
            Issue.record("Expected one matching notification on each subscription")
            await client.disconnect()
            await server.stop()
            return
        }
        #expect(toolNotification.method == ToolListChangedNotification.name)
        #expect(toolNotification.subscriptionID == toolSubscription.id)
        #expect(resourceNotification.method == ResourceUpdatedNotification.name)
        #expect(resourceNotification.subscriptionID == resourceSubscription.id)

        try await client.cancelSubscription(toolSubscription.id)
        try await client.cancelSubscription(resourceSubscription.id)
        await client.disconnect()
        await server.stop()
    }

    @Test("Explicit reconnect re-sends the same subscription")
    func reconnect() async throws {
        let firstPair = await InMemoryTransport.createConnectedPair()
        let firstServer = makeServer(capabilities: .init(tools: .init(listChanged: true)))
        try await firstServer.start(transport: firstPair.server)
        let client = makeClient()
        _ = try await client.connectWithInfo(transport: firstPair.client)

        let subscription = try await client.listen(
            notifications: .init(toolsListChanged: true)
        )
        var events = subscription.events.makeAsyncIterator()
        #expect(try await events.next() == .acknowledged(.init(toolsListChanged: true)))

        await client.disconnect()
        #expect(try await events.next() == .disconnected)
        await firstServer.stop()

        let secondPair = await InMemoryTransport.createConnectedPair()
        let secondServer = makeServer(capabilities: .init(tools: .init(listChanged: true)))
        try await secondServer.start(transport: secondPair.server)
        _ = try await client.connectWithInfo(transport: secondPair.client)

        #expect(try await events.next() == .acknowledged(.init(toolsListChanged: true)))
        try await secondServer.notify(ToolListChangedNotification.message(.init()))
        guard case .notification(let notification) = try await events.next() else {
            Issue.record("Expected a notification after reconnect")
            await client.disconnect()
            await secondServer.stop()
            return
        }
        #expect(notification.subscriptionID == subscription.id)

        try await client.cancelSubscription(subscription.id)
        await client.disconnect()
        await secondServer.stop()
    }

    @Test("Server shutdown closes a subscription gracefully")
    func gracefulServerClosure() async throws {
        let (client, server) = try await connectedPair(
            capabilities: .init(tools: .init(listChanged: true))
        )
        let subscription = try await client.listen(
            notifications: .init(toolsListChanged: true)
        )
        var events = subscription.events.makeAsyncIterator()
        _ = try await events.next()

        await server.stop()
        #expect(try await events.next() == nil)
        await client.disconnect()
    }

    @Test("Initialization lifecycle rejects subscriptions")
    func initializationLifecycleRejection() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "Server", version: "1.0")
        try await server.start(transport: pair.server)
        let client = Client(name: "Client", version: "1.0")
        _ = try await client.connect(transport: pair.client)

        await #expect(throws: MCPError.self) {
            _ = try await client.listen(notifications: .init(toolsListChanged: true))
        }

        await client.disconnect()
        await server.stop()
    }

    private func connectedPair(
        capabilities: Server.Capabilities
    ) async throws -> (Client, Server) {
        let pair = await InMemoryTransport.createConnectedPair()
        let server = makeServer(capabilities: capabilities)
        try await server.start(transport: pair.server)
        let client = makeClient()
        _ = try await client.connectWithInfo(transport: pair.client)
        return (client, server)
    }

    private func makeClient() -> Client {
        Client(
            name: "SubscriptionClient",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
    }

    private func makeServer(capabilities: Server.Capabilities) -> Server {
        Server(
            name: "SubscriptionServer",
            version: "1.0",
            capabilities: capabilities,
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
    }

    private func fixture(named name: String) throws -> Data {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try Data(
            contentsOf: testDirectory
                .appendingPathComponent("Fixtures/2026-07-28/\(name).json")
        )
    }
}
