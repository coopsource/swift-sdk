import Foundation
import Logging
import Testing

@testable import MCP

private actor ManualResponseCacheClock: ResponseCacheClock {
    private var instant: Duration = .zero

    func now() -> Duration {
        instant
    }

    func advance(milliseconds: Int) {
        instant += .milliseconds(milliseconds)
    }
}

/// A clock that suspends its first reader until the test releases it.
///
/// A cacheable request consults the clock before recording its first attempt, so holding the
/// clock parks the logical request at exactly that point.
private actor GatedResponseCacheClock: ResponseCacheClock {
    private var isSuspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func now() async -> Duration {
        if !isOpen {
            isSuspended = true
            await withCheckedContinuation { continuation = $0 }
        }
        return .zero
    }

    func waitUntilSuspended() async {
        while !isSuspended { await Task.yield() }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ResponseCacheTestState {
    private var counts: [String: Int] = [:]
    private var scope: CacheScope = .private

    func record(_ key: String) -> Int {
        counts[key, default: 0] += 1
        return counts[key] ?? 0
    }

    func count(_ key: String) -> Int {
        counts[key] ?? 0
    }

    func setScope(_ scope: CacheScope) {
        self.scope = scope
    }

    func currentScope() -> CacheScope {
        scope
    }
}

private actor AuthorizationContextTransport: Transport,
    ResponseCacheAuthorizationContextProviding
{
    nonisolated let logger = Logger(label: "mcp.test.response-cache-authorization")
    private let base: InMemoryTransport
    private var context: ResponseCacheAuthorizationContext

    init(base: InMemoryTransport, context: ResponseCacheAuthorizationContext) {
        self.base = base
        self.context = context
    }

    func connect() async throws {
        try await base.connect()
    }

    func disconnect() async {
        await base.disconnect()
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            let forwardingTask = Task {
                let stream = await base.receive()
                do {
                    for try await data in stream {
                        try Task.checkCancellation()
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in forwardingTask.cancel() }
        }
    }

    func responseCacheAuthorizationContext() -> ResponseCacheAuthorizationContext {
        context
    }

    func setContext(_ context: ResponseCacheAuthorizationContext) {
        self.context = context
    }
}

@Suite("MCP 2026-07-28 response caching", .timeLimit(.minutes(1)))
struct ResponseCacheTests {
    @Test("Official cacheable-result fixtures decode")
    func officialFixtures() throws {
        let decoder = JSONDecoder()
        let tools = try decoder.decode(
            ListTools.Result.self,
            from: try fixture(named: "tools-list-with-cursor-and-ttl")
        )
        #expect(tools.ttlMs == 300_000)
        #expect(tools.cacheScope == .public)
        #expect(tools.nextCursor == "next-page-cursor")

        let prompts = try decoder.decode(
            ListPrompts.Result.self,
            from: try fixture(named: "prompts-list-with-cursor-and-ttl")
        )
        #expect(prompts.ttlMs == 600_000)
        #expect(prompts.cacheScope == .public)

        let resources = try decoder.decode(
            ListResources.Result.self,
            from: try fixture(named: "resources-list-with-cursor-and-ttl")
        )
        #expect(resources.ttlMs == 600_000)
        #expect(resources.cacheScope == .private)

        let templates = try decoder.decode(
            ListResourceTemplates.Result.self,
            from: try fixture(named: "resource-templates-list-with-cursor-and-ttl")
        )
        #expect(templates.ttlMs == 3_600_000)
        #expect(templates.cacheScope == .public)

        let read = try decoder.decode(
            ReadResource.Result.self,
            from: try fixture(named: "read-resource-with-ttl")
        )
        #expect(read.ttlMs == 60_000)
        #expect(read.cacheScope == .private)
    }

    @Test("Freshness and per-call policies control reuse")
    func freshnessAndPolicies() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            let call = await state.record(ListTools.name)
            return .init(
                tools: [Self.tool(named: "tool-\(call)")],
                ttlMs: 100,
                cacheScope: .public
            )
        }
        try await server.start(transport: pair.server)

        let client = makeClient()
        _ = try await client.connectWithInfo(transport: pair.client)
        let clock = ManualResponseCacheClock()
        await client.setResponseCacheClock(clock)

        #expect(try await client.listTools().tools.map(\.name) == ["tool-1"])
        #expect(try await client.listTools().tools.map(\.name) == ["tool-1"])
        #expect(await state.count(ListTools.name) == 1)

        #expect(
            try await client.listTools(cachePolicy: .reload).tools.map(\.name)
                == ["tool-2"]
        )
        #expect(
            try await client.listTools(cachePolicy: .bypass).tools.map(\.name)
                == ["tool-3"]
        )
        #expect(try await client.listTools().tools.map(\.name) == ["tool-2"])

        await clock.advance(milliseconds: 100)
        #expect(try await client.listTools().tools.map(\.name) == ["tool-4"])
        #expect(await state.count(ListTools.name) == 4)

        await client.disconnect()
        await server.stop()
    }

    @Test("Pagination keys and subscription notifications invalidate every page")
    func paginationAndNotificationInvalidation() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(tools: .init(listChanged: true)))
        await server.withMethodHandler(ListTools.self) { parameters in
            _ = await state.record(ListTools.name)
            return .init(
                tools: [Self.tool(named: parameters.cursor ?? "first")],
                nextCursor: parameters.cursor == nil ? "next" : nil,
                ttlMs: 10_000,
                cacheScope: .public
            )
        }
        try await server.start(transport: pair.server)

        let client = makeClient()
        _ = try await client.connectWithInfo(transport: pair.client)
        let subscription = try await client.listen(
            notifications: .init(toolsListChanged: true)
        )
        var events = subscription.events.makeAsyncIterator()
        _ = try await events.next()

        _ = try await client.listTools()
        _ = try await client.listTools(cursor: "next")
        _ = try await client.listTools()
        _ = try await client.listTools(cursor: "next")
        #expect(await state.count(ListTools.name) == 2)

        try await server.notify(ToolListChangedNotification.message(.init()))
        _ = try await events.next()
        _ = try await client.listTools()
        _ = try await client.listTools(cursor: "next")
        #expect(await state.count(ListTools.name) == 4)

        try await client.cancelSubscription(subscription.id)
        await client.disconnect()
        await server.stop()
    }

    @Test("Private entries are isolated while public entries cross authorization contexts")
    func authorizationPartitions() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let clientTransport = AuthorizationContextTransport(
            base: pair.client,
            context: .known("token-a")
        )
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            let call = await state.record(ListTools.name)
            return .init(
                tools: [Self.tool(named: "tool-\(call)")],
                ttlMs: 10_000,
                cacheScope: await state.currentScope()
            )
        }
        try await server.start(transport: pair.server)

        let client = makeClient()
        _ = try await client.connectWithInfo(transport: clientTransport)
        _ = try await client.listTools()
        _ = try await client.listTools()
        #expect(await state.count(ListTools.name) == 1)

        await clientTransport.setContext(.known("token-b"))
        _ = try await client.listTools()
        #expect(await state.count(ListTools.name) == 2)

        await state.setScope(.public)
        _ = try await client.listTools(cachePolicy: .reload)
        await clientTransport.setContext(.known("token-c"))
        _ = try await client.listTools()
        #expect(await state.count(ListTools.name) == 3)

        await client.disconnect()
        await server.stop()
    }

    @Test("Resource notifications invalidate only the selected URI")
    func resourceNotificationInvalidation() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(
            resources: .init(subscribe: true)
        ))
        await server.withMethodHandler(ReadResource.self) { parameters in
            let call = await state.record(parameters.uri)
            return .init(
                contents: [.text("value-\(call)", uri: parameters.uri)],
                ttlMs: 10_000,
                cacheScope: .private
            )
        }
        try await server.start(transport: pair.server)

        let client = makeClient()
        _ = try await client.connectWithInfo(transport: pair.client)
        let firstURI = "file:///first"
        let secondURI = "file:///second"
        let subscription = try await client.listen(notifications: .init(
            resourceSubscriptions: [firstURI, secondURI]
        ))
        var events = subscription.events.makeAsyncIterator()
        _ = try await events.next()

        _ = try await client.readResource(uri: firstURI)
        _ = try await client.readResource(uri: secondURI)
        _ = try await client.readResource(uri: firstURI)
        _ = try await client.readResource(uri: secondURI)
        #expect(await state.count(firstURI) == 1)
        #expect(await state.count(secondURI) == 1)

        try await server.notify(ResourceUpdatedNotification.message(.init(uri: firstURI)))
        _ = try await events.next()
        _ = try await client.readResource(uri: firstURI)
        _ = try await client.readResource(uri: secondURI)
        #expect(await state.count(firstURI) == 2)
        #expect(await state.count(secondURI) == 1)

        try await client.cancelSubscription(subscription.id)
        await client.disconnect()
        await server.stop()
    }

    @Test("Private responses are not stored when authorization cannot be partitioned")
    func unavailableAuthorizationContext() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let clientTransport = AuthorizationContextTransport(
            base: pair.client,
            context: .unavailable
        )
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            _ = await state.record(ListTools.name)
            return .init(tools: [], ttlMs: 10_000, cacheScope: .private)
        }
        try await server.start(transport: pair.server)
        let client = makeClient()
        _ = try await client.connectWithInfo(transport: clientTransport)

        _ = try await client.listTools()
        _ = try await client.listTools()
        #expect(await state.count(ListTools.name) == 2)
        #expect(await client.responseCacheEntryCount == 0)

        await client.disconnect()
        await server.stop()
    }

    @Test("Bounded storage evicts the least recently used response")
    func boundedStorage() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(resources: .init()))
        await server.withMethodHandler(ReadResource.self) { parameters in
            _ = await state.record(ReadResource.name)
            return .init(
                contents: [.text(parameters.uri, uri: parameters.uri)],
                ttlMs: 10_000,
                cacheScope: .private
            )
        }
        try await server.start(transport: pair.server)

        let client = makeClient(responseCacheMode: .enabled(maxEntries: 2))
        _ = try await client.connectWithInfo(transport: pair.client)
        _ = try await client.readResource(uri: "file:///one")
        _ = try await client.readResource(uri: "file:///two")
        _ = try await client.readResource(uri: "file:///three")
        #expect(await client.responseCacheEntryCount == 2)
        _ = try await client.readResource(uri: "file:///one")
        #expect(await state.count(ReadResource.name) == 4)

        await client.disconnect()
        await server.stop()
    }

    @Test("Invalid cache configuration and server policies are rejected")
    func invalidPolicies() async throws {
        for maximumEntries in [0, 513] {
            let pair = await InMemoryTransport.createConnectedPair()
            let client = makeClient(
                responseCacheMode: .enabled(maxEntries: maximumEntries)
            )
            await #expect(throws: MCPError.self) {
                _ = try await client.connectWithInfo(transport: pair.client)
            }
        }

        let pair = await InMemoryTransport.createConnectedPair()
        let server = makeServer(capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [])
        }
        try await server.start(transport: pair.server)
        let client = makeClient()
        _ = try await client.connectWithInfo(transport: pair.client)
        await #expect(throws: MCPError.self) {
            _ = try await client.listTools(cachePolicy: .bypass)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [], ttlMs: -1, cacheScope: .public)
        }
        await #expect(throws: MCPError.self) {
            _ = try await client.listTools(cachePolicy: .bypass)
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("Malformed peer fields fail while a negative TTL is immediately stale")
    func malformedPeerFields() async throws {
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
                capabilities: .init(tools: .init()),
                ttlMs: 0,
                cacheScope: .public
            )
        ))
        _ = try await connectTask.value

        let missingFields = Task {
            try await client.listTools(cachePolicy: .bypass)
        }
        while await transport.sentData.count < 2 {
            await Task.yield()
        }
        let missingRequest: AnyRequest = try #require(await transport.decodeLastSentMessage())
        try await transport.queue(response: AnyMethod.response(
            id: missingRequest.id,
            result: .object([
                "resultType": "complete",
                "tools": .array([]),
            ])
        ))
        await #expect(throws: MCPError.self) {
            _ = try await missingFields.value
        }

        let negativeTTL = Task { try await client.listTools() }
        while await transport.sentData.count < 3 {
            await Task.yield()
        }
        let negativeRequest: AnyRequest = try #require(await transport.decodeLastSentMessage())
        try await transport.queue(response: AnyMethod.response(
            id: negativeRequest.id,
            result: .object([
                "resultType": "complete",
                "tools": .array([]),
                "ttlMs": -1,
                "cacheScope": "public",
            ])
        ))
        _ = try await negativeTTL.value
        #expect(await client.responseCacheEntryCount == 0)

        let immediatelyStale = Task { try await client.listTools() }
        while await transport.sentData.count < 4 {
            await Task.yield()
        }
        let staleRequest: AnyRequest = try #require(await transport.decodeLastSentMessage())
        try await transport.queue(response: AnyMethod.response(
            id: staleRequest.id,
            result: .object([
                "resultType": "complete",
                "tools": .array([]),
                "ttlMs": 0,
                "cacheScope": "public",
            ])
        ))
        _ = try await immediatelyStale.value

        await client.disconnect()
    }

    @Test("Disabled mode validates but never stores responses")
    func disabledMode() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            _ = await state.record(ListTools.name)
            return .init(tools: [], ttlMs: 10_000, cacheScope: .public)
        }
        try await server.start(transport: pair.server)
        let client = makeClient(responseCacheMode: .disabled)
        _ = try await client.connectWithInfo(transport: pair.client)

        _ = try await client.listTools()
        _ = try await client.listTools()
        #expect(await state.count(ListTools.name) == 2)
        #expect(await client.responseCacheEntryCount == 0)

        await client.disconnect()
        await server.stop()
    }

    @Test("List pages with inconsistent scopes are rejected and invalidated")
    func inconsistentPageScopes() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let clientTransport = AuthorizationContextTransport(
            base: pair.client,
            context: .known("token-a")
        )
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { parameters in
            _ = await state.record(ListTools.name)
            return .init(
                tools: [],
                nextCursor: parameters.cursor == nil ? "next" : nil,
                ttlMs: 10_000,
                cacheScope: parameters.cursor == nil ? .public : .private
            )
        }
        try await server.start(transport: pair.server)
        let client = makeClient()
        _ = try await client.connectWithInfo(transport: clientTransport)

        _ = try await client.listTools()
        await clientTransport.setContext(.known("token-b"))
        await #expect(throws: MCPError.self) {
            _ = try await client.listTools(cursor: "next")
        }
        _ = try await client.listTools()
        #expect(await state.count(ListTools.name) == 3)

        await client.disconnect()
        await server.stop()
    }

    @Test("Multi-round-trip results are not cached")
    func multiRoundTripIsNotCached() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(resources: .init()))
        await server.withMultiRoundTripHandler(ReadResource.self) { parameters in
            _ = await state.record(ReadResource.name)
            if parameters.requestState == nil {
                return .inputRequired(.init(requestState: "continue"))
            }
            return .complete(.init(
                contents: [.text("complete", uri: parameters.uri)],
                ttlMs: 10_000,
                cacheScope: .private
            ))
        }
        try await server.start(transport: pair.server)
        let client = makeClient()
        _ = try await client.connectWithInfo(transport: pair.client)

        _ = try await client.readResource(uri: "file:///round-trip")
        _ = try await client.readResource(uri: "file:///round-trip")
        #expect(await state.count(ReadResource.name) == 4)
        #expect(await client.responseCacheEntryCount == 0)

        await client.disconnect()
        await server.stop()
    }

    @Test("A list change that cannot be delivered still invalidates the cache")
    func undeliverableNotificationInvalidatesCache() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(tools: .init(listChanged: true)))
        await server.withMethodHandler(ListTools.self) { _ in
            _ = await state.record(ListTools.name)
            return .init(
                tools: [Self.tool(named: "first")],
                ttlMs: 60_000,
                cacheScope: .public
            )
        }
        try await server.start(transport: pair.server)

        // A single-message queue that is never drained: the acknowledgment fills it, so the
        // list-change notification that follows is dropped before any subscriber sees it.
        let client = Client(
            name: "CacheClient",
            version: "1.0",
            configuration: .init(
                protocolMode: .perRequestMetadataOnly,
                subscriptionBufferCapacity: 1
            )
        )
        _ = try await client.connectWithInfo(transport: pair.client)
        let subscription = try await client.listen(
            notifications: .init(toolsListChanged: true)
        )

        _ = try await client.listTools()
        _ = try await client.listTools()
        #expect(await state.count(ListTools.name) == 1)

        try await server.notify(ToolListChangedNotification.message(.init()))
        try await Task.sleep(for: .milliseconds(50))

        // The notification never reached the subscriber, but the cached list is still stale.
        _ = try await client.listTools()
        #expect(await state.count(ListTools.name) == 2)

        _ = subscription.id
        await client.disconnect()
        await server.stop()
    }

    @Test("Cancelling a cacheable request before its first attempt is honored")
    func cancellationBeforeCachedAttempt() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let state = ResponseCacheTestState()
        let server = makeServer(capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            _ = await state.record(ListTools.name)
            return .init(
                tools: [Self.tool(named: "first")],
                ttlMs: 60_000,
                cacheScope: .public
            )
        }
        try await server.start(transport: pair.server)
        let client = makeClient()
        _ = try await client.connectWithInfo(transport: pair.client)
        let clock = GatedResponseCacheClock()
        await client.setResponseCacheClock(clock)

        // A cacheable request consults the cache before recording its first attempt. Holding the
        // clock parks the logical request there, so the cancellation below is delivered before
        // the request has any attempt registered.
        let context = try await client.send(ListTools.request(.init()))
        await clock.waitUntilSuspended()
        try await client.cancelRequest(context.requestID, reason: "immediate cancellation")
        await clock.open()

        await #expect(throws: CancellationError.self) {
            _ = try await context.value
        }
        #expect(await state.count(ListTools.name) == 0)
        #expect(await client.responseCacheEntryCount == 0)

        await client.disconnect()
        await server.stop()
    }

    private func makeClient(
        responseCacheMode: Client.ResponseCacheMode = .enabled(maxEntries: 512)
    ) -> Client {
        Client(
            name: "CacheClient",
            version: "1.0",
            configuration: .init(
                protocolMode: .perRequestMetadataOnly,
                responseCacheMode: responseCacheMode
            )
        )
    }

    private func makeServer(capabilities: Server.Capabilities) -> Server {
        Server(
            name: "CacheServer",
            version: "1.0",
            capabilities: capabilities,
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
    }

    private static func tool(named name: String) -> Tool {
        Tool(
            name: name,
            description: nil,
            inputSchema: .object(["type": "object"])
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
