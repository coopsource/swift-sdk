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

    @Test("Subscription buffer configuration is positive and backward compatible")
    func bufferConfiguration() throws {
        let decoder = JSONDecoder()
        let oldClient = try decoder.decode(
            Client.Configuration.self,
            from: Data(#"{"strict":false}"#.utf8)
        )
        let oldServer = try decoder.decode(
            Server.Configuration.self,
            from: Data(#"{"strict":false}"#.utf8)
        )
        #expect(oldClient.subscriptionBufferCapacity == 32)
        #expect(oldServer.subscriptionBufferCapacity == 32)

        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(
                Client.Configuration.self,
                from: Data(#"{"subscriptionBufferCapacity":0}"#.utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(
                Server.Configuration.self,
                from: Data(#"{"subscriptionBufferCapacity":-1}"#.utf8)
            )
        }
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

    @Test("Prompt and tool listeners receive only their list-change notifications")
    func promptAndToolListeners() async throws {
        let (client, server) = try await connectedPair(
            capabilities: .init(
                prompts: .init(listChanged: true),
                tools: .init(listChanged: true)
            )
        )
        async let promptListen = client.listen(
            notifications: SubscriptionFilter(promptsListChanged: true)
        )
        async let toolListen = client.listen(
            notifications: SubscriptionFilter(toolsListChanged: true)
        )
        let (promptSubscription, toolSubscription) = try await (promptListen, toolListen)
        var promptEvents = promptSubscription.events.makeAsyncIterator()
        var toolEvents = toolSubscription.events.makeAsyncIterator()

        #expect(
            try await promptEvents.next()
                == .acknowledged(.init(promptsListChanged: true))
        )
        #expect(
            try await toolEvents.next()
                == .acknowledged(.init(toolsListChanged: true))
        )

        try await server.notify(PromptListChangedNotification.message(.init()))
        try await server.notify(ToolListChangedNotification.message(.init()))

        guard case .notification(let promptNotification) = try await promptEvents.next(),
            case .notification(let toolNotification) = try await toolEvents.next()
        else {
            Issue.record("Expected one matching list-change notification per subscription")
            await client.disconnect()
            await server.stop()
            return
        }
        #expect(promptNotification.method == PromptListChangedNotification.name)
        #expect(promptNotification.subscriptionID == promptSubscription.id)
        #expect(toolNotification.method == ToolListChangedNotification.name)
        #expect(toolNotification.subscriptionID == toolSubscription.id)

        try await client.cancelSubscription(promptSubscription.id)
        try await client.cancelSubscription(toolSubscription.id)
        #expect(try await promptEvents.next() == nil)
        #expect(try await toolEvents.next() == nil)
        await client.disconnect()
        await server.stop()
    }

    @Test("A slow client fails explicitly and cancels its remote subscription once")
    func clientBufferOverflow() async throws {
        let transport = MockTransport()
        let client = makeClient(subscriptionBufferCapacity: 2)
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
        let request = try JSONDecoder().decode(
            Request<SubscriptionsListen>.self,
            from: await transport.sentData[1]
        )
        try await transport.queue(notification: SubscriptionsAcknowledgedNotification.message(
            .init(
                subscriptionID: request.id,
                notifications: .init(toolsListChanged: true)
            )
        ))
        let subscription = try await listenTask.value

        await transport.queue(data: try correlatedToolNotification(subscriptionID: request.id))
        await transport.queue(data: try correlatedToolNotification(subscriptionID: request.id))
        try await Task.sleep(for: .milliseconds(20))

        var events = subscription.events.makeAsyncIterator()
        #expect(try await events.next() == .acknowledged(.init(toolsListChanged: true)))
        guard case .notification = try await events.next() else {
            Issue.record("Expected the buffered tool notification")
            await client.disconnect()
            return
        }
        await #expect(throws: MCPError.self) {
            _ = try await events.next()
        }

        for _ in 0..<1_000 where await cancellationCount(in: transport) < 1 {
            await Task.yield()
        }
        #expect(await cancellationCount(in: transport) == 1)
        await transport.queue(data: try correlatedToolNotification(subscriptionID: request.id))
        try await Task.sleep(for: .milliseconds(10))
        #expect(await cancellationCount(in: transport) == 1)
        await client.disconnect()
    }

    @Test("Server subscription publishing applies bounded FIFO backpressure")
    func serverBackpressure() async throws {
        let gate = SubscriptionSendGate()
        let completion = SubscriptionCompletionFlag()
        let transport = MockTransport()
        await transport.setSendObserver { _ in await gate.wait() }
        let server = makeServer(
            capabilities: .init(resources: .init(subscribe: true)),
            subscriptionBufferCapacity: 1
        )
        try await server.start(transport: transport)
        let requestID = ID.string("bounded-server-test")
        await transport.queue(data: try subscriptionRequest(
            id: requestID,
            resources: ["file:///one", "file:///two", "file:///three"]
        ))
        await gate.waitForArrivals(1)

        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "file:///one")))
        let second = Task {
            try await server.notify(
                ResourceUpdatedNotification.message(.init(uri: "file:///two"))
            )
            await completion.finish()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await completion.isFinished == false)
        await #expect(throws: MCPError.self) {
            try await server.notify(
                ResourceUpdatedNotification.message(.init(uri: "file:///three"))
            )
        }

        await gate.open()
        try await second.value
        await gate.waitForArrivals(3)
        let messages = await transport.sentData.compactMap {
            try? JSONDecoder().decode(AnyMessage.self, from: $0)
        }
        #expect(messages.count >= 3)
        #expect(messages[0].method == SubscriptionsAcknowledgedNotification.name)
        #expect(messages[1].params.objectValue?["uri"]?.stringValue == "file:///one")
        #expect(messages[2].params.objectValue?["uri"]?.stringValue == "file:///two")

        try await transport.queue(notification: CancelledNotification.message(
            .init(requestId: requestID, reason: "Test complete")
        ))
        await server.stop()
    }

    @Test("Cancellation and shutdown release blocked subscription publishers")
    func serverBackpressureTermination() async throws {
        let gate = SubscriptionSendGate()
        let transport = MockTransport()
        await transport.setSendObserver { _ in await gate.wait() }
        let server = makeServer(
            capabilities: .init(resources: .init(subscribe: true)),
            subscriptionBufferCapacity: 1
        )
        try await server.start(transport: transport)
        await transport.queue(data: try subscriptionRequest(
            id: .string("blocked-server-test"),
            resources: ["file:///one", "file:///two", "file:///three"]
        ))
        await gate.waitForArrivals(1)

        try await server.notify(ResourceUpdatedNotification.message(.init(uri: "file:///one")))
        let cancelledPublisher = Task {
            try await server.notify(
                ResourceUpdatedNotification.message(.init(uri: "file:///two"))
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        cancelledPublisher.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledPublisher.value
        }

        let closingPublisher = Task {
            try await server.notify(
                ResourceUpdatedNotification.message(.init(uri: "file:///three"))
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let stop = Task { await server.stop() }
        await #expect(throws: MCPError.self) {
            try await closingPublisher.value
        }
        await gate.open()
        await stop.value
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

    private func makeClient(subscriptionBufferCapacity: Int = 32) -> Client {
        Client(
            name: "SubscriptionClient",
            version: "1.0",
            configuration: .init(
                protocolMode: .perRequestMetadataOnly,
                subscriptionBufferCapacity: subscriptionBufferCapacity
            )
        )
    }

    private func makeServer(
        capabilities: Server.Capabilities,
        subscriptionBufferCapacity: Int = 32
    ) -> Server {
        Server(
            name: "SubscriptionServer",
            version: "1.0",
            capabilities: capabilities,
            configuration: .init(
                protocolMode: .perRequestMetadataOnly,
                subscriptionBufferCapacity: subscriptionBufferCapacity
            )
        )
    }

    private func correlatedToolNotification(subscriptionID: ID) throws -> Data {
        let metadata = Metadata(additionalFields: [
            ProtocolMetadataKey.subscriptionID: try Value(subscriptionID)
        ])
        return try JSONEncoder().encode(Value.object([
            "jsonrpc": "2.0",
            "method": .string(ToolListChangedNotification.name),
            "params": .object(["_meta": try Value(metadata)]),
        ]))
    }

    private func cancellationCount(in transport: MockTransport) async -> Int {
        await transport.sentData.reduce(into: 0) { count, data in
            guard let message = try? JSONDecoder().decode(AnyMessage.self, from: data),
                message.method == CancelledNotification.name
            else { return }
            count += 1
        }
    }

    private func subscriptionRequest(id: ID, resources: [String]) throws -> Data {
        try PerRequestMetadataWire.encodeRequest(
            SubscriptionsListen.request(
                id: id,
                .init(notifications: .init(resourceSubscriptions: resources))
            ),
            protocolVersion: Version.perRequestMetadataVersion,
            clientInfo: .init(name: "Client", version: "1.0"),
            clientCapabilities: .init(),
            using: JSONEncoder()
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

private actor SubscriptionSendGate {
    private var isOpen = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrivals(_ count: Int) async {
        while arrivals < count { await Task.yield() }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor SubscriptionCompletionFlag {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}
