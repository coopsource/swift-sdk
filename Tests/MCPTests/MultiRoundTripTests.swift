import Foundation
import Testing

@testable import MCP

private actor MultiRoundTripState {
    private(set) var attemptIDs: [ID] = []
    private(set) var completionOrder: [String] = []
    private(set) var rounds = 0

    func recordAttempt(_ id: ID) {
        attemptIDs.append(id)
        rounds += 1
    }

    func recordCompletion(_ name: String) {
        completionOrder.append(name)
    }
}

private enum StandaloneRequestProbe: MCP.Method {
    static let name = "test/standalone-server-requests"

    struct Result: Hashable, Codable, Sendable {
        let rejectedRequests: Int
    }
}

@Suite("MCP 2026-07-28 multi-round-trip requests", .timeLimit(.minutes(1)))
struct MultiRoundTripTests {
    @Test("Multi-round-trip configuration round-trips")
    func configurationCoding() throws {
        let configuration = Client.Configuration(
            protocolMode: .perRequestMetadataOnly,
            multiRoundTripMode: .automatic(maxRounds: 4)
        )
        let decoded = try JSONDecoder().decode(
            Client.Configuration.self,
            from: JSONEncoder().encode(configuration)
        )
        #expect(decoded == configuration)
    }

    @Test("Input-required results reject missing fields and malformed embedded requests")
    func inputRequiredValidation() {
        #expect(throws: MCPError.self) {
            try InputRequiredResult().validate(clientCapabilities: .init())
        }
        #expect(throws: MCPError.self) {
            try InputRequiredResult(
                inputRequests: ["bad": .object(["method": .string(ListRoots.name), "id": 1])]
            ).validate(clientCapabilities: .init(roots: .init()))
        }
    }

    @Test("Automatic mode fulfills embedded requests concurrently and retries with a fresh ID")
    func automaticEmbeddedRequests() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let state = MultiRoundTripState()
        let opaqueState = "eyJyb3VuZCI6MX0"
        let server = Server(
            name: "MultiRoundTripServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMultiRoundTripHandler(CallTool.self) { parameters in
            let requestID = try #require(Server.currentHandlerContext?.id)
            await state.recordAttempt(requestID)

            if parameters.inputResponses == nil {
                return .inputRequired(.init(
                    inputRequests: [
                        "user": try Self.embeddedRequest(
                            method: CreateElicitation.name,
                            parameters: CreateElicitation.Parameters.form(.init(
                                message: "Confirm the operation"
                            ))
                        ),
                        "roots": try Self.embeddedRequest(
                            method: ListRoots.name,
                            parameters: Empty()
                        ),
                    ],
                    requestState: opaqueState
                ))
            }

            #expect(parameters.requestState == opaqueState)
            let responses = try #require(parameters.inputResponses)
            let elicitation = try Self.decode(
                CreateElicitation.Result.self, from: try #require(responses["user"]))
            let roots = try Self.decode(
                ListRoots.Result.self, from: try #require(responses["roots"]))
            #expect(elicitation.action == .accept)
            #expect(roots.roots == [.init(uri: "file:///workspace")])
            return .complete(.init(content: [
                .text(text: "complete", annotations: nil, _meta: nil)
            ]))
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "MultiRoundTripClient",
            version: "1.0",
            capabilities: .init(elicitation: .init(), roots: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await client.withElicitationHandler { _ in
            try await Task.sleep(for: .milliseconds(30))
            await state.recordCompletion("user")
            return .init(action: .accept, content: ["confirmed": true])
        }
        await client.withRootsHandler {
            try await Task.sleep(for: .milliseconds(5))
            await state.recordCompletion("roots")
            return [.init(uri: "file:///workspace")]
        }
        _ = try await client.connectWithInfo(transport: transports.client)

        let result = try await client.sendAndAwait(
            CallTool.request(.init(name: "requires-input")))
        #expect(result.content == [
            .text(text: "complete", annotations: nil, _meta: nil)
        ])
        #expect(await state.completionOrder == ["roots", "user"])
        let attemptIDs = await state.attemptIDs
        #expect(attemptIDs.count == 2)
        #expect(attemptIDs[0] != attemptIDs[1])

        await client.disconnect()
        await server.stop()
    }

    @Test("Request-state-only responses retry without inventing input responses")
    func requestStateOnly() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "LoadSheddingServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMultiRoundTripHandler(CallTool.self) { parameters in
            if parameters.requestState == nil {
                return .inputRequired(.init(requestState: "opaque-state"))
            }
            #expect(parameters.requestState == "opaque-state")
            #expect(parameters.inputResponses == nil)
            return .complete(.init())
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "Client",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        _ = try await client.connectWithInfo(transport: transports.client)
        _ = try await client.sendAndAwait(CallTool.request(.init(name: "resume")))

        await client.disconnect()
        await server.stop()
    }

    @Test("Automatic mode enforces the configured round limit")
    func automaticRoundLimit() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let state = MultiRoundTripState()
        let server = Server(
            name: "LoopingServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMultiRoundTripHandler(CallTool.self) { _ in
            await state.recordAttempt(try #require(Server.currentHandlerContext?.id))
            return .inputRequired(.init(requestState: "retry"))
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "Client",
            version: "1.0",
            configuration: .init(
                protocolMode: .perRequestMetadataOnly,
                multiRoundTripMode: .automatic(maxRounds: 1)
            )
        )
        _ = try await client.connectWithInfo(transport: transports.client)

        await #expect(throws: MCPError.self) {
            _ = try await client.sendAndAwait(CallTool.request(.init(name: "loop")))
        }
        #expect(await state.rounds == 2)

        await client.disconnect()
        await server.stop()
    }

    @Test("Manual mode validates the aggregate response map")
    func manualResponseValidation() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "ManualServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMultiRoundTripHandler(CallTool.self) { _ in
            .inputRequired(.init(
                inputRequests: [
                    "roots": try Self.embeddedRequest(
                        method: ListRoots.name,
                        parameters: Empty()
                    )
                ]
            ))
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "Client",
            version: "1.0",
            capabilities: .init(roots: .init()),
            configuration: .init(
                protocolMode: .perRequestMetadataOnly,
                multiRoundTripMode: .manual
            )
        )
        await client.withMultiRoundTripHandler { context in
            #expect(context.method == CallTool.name)
            #expect(context.round == 1)
            return [:]
        }
        _ = try await client.connectWithInfo(transport: transports.client)

        await #expect(throws: MCPError.self) {
            _ = try await client.sendAndAwait(CallTool.request(.init(name: "manual")))
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("Manual mode validates embedded response values")
    func manualResponseValueValidation() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "ManualServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMultiRoundTripHandler(CallTool.self) { _ in
            .inputRequired(.init(inputRequests: [
                "roots": try Self.embeddedRequest(
                    method: ListRoots.name,
                    parameters: Empty()
                )
            ]))
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "Client",
            version: "1.0",
            capabilities: .init(roots: .init()),
            configuration: .init(
                protocolMode: .perRequestMetadataOnly,
                multiRoundTripMode: .manual
            )
        )
        await client.withMultiRoundTripHandler { _ in
            ["roots": .string("not a roots result")]
        }
        _ = try await client.connectWithInfo(transport: transports.client)

        await #expect(throws: MCPError.self) {
            _ = try await client.sendAndAwait(CallTool.request(.init(name: "manual")))
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("Per-request lifecycle rejects standalone server requests")
    func standaloneServerRequests() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "Server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(StandaloneRequestProbe.self) { _ in
            var rejectedRequests = 0
            do {
                _ = try await server.listRoots()
            } catch {
                rejectedRequests += 1
            }
            do {
                _ = try await server.requestSampling(messages: [], maxTokens: 1)
            } catch {
                rejectedRequests += 1
            }
            do {
                _ = try await server.requestElicitation(
                    message: "Confirm",
                    requestedSchema: .init()
                )
            } catch {
                rejectedRequests += 1
            }
            return .init(rejectedRequests: rejectedRequests)
        }
        try await server.start(transport: transports.server)

        await #expect(throws: MCPError.self) {
            _ = try await server.listRoots()
        }

        let client = Client(
            name: "Client",
            version: "1.0",
            capabilities: .init(
                sampling: .init(),
                elicitation: .init(),
                roots: .init()
            ),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        _ = try await client.connectWithInfo(transport: transports.client)
        let result = try await client.sendAndAwait(StandaloneRequestProbe.request())
        #expect(result.rejectedRequests == 3)

        await client.disconnect()
        await server.stop()
    }

    @Test("Per-request client rejects a standalone request from its peer")
    func clientRejectsStandaloneRequest() async throws {
        let transport = MockTransport()
        let state = MultiRoundTripState()
        let client = Client(
            name: "Client",
            version: "1.0",
            capabilities: .init(roots: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await client.withRootsHandler {
            await state.recordCompletion("roots handler")
            return []
        }
        try await connectPerRequestClient(client, transport: transport)
        await transport.clearMessages()

        try await transport.queue(request: ListRoots.request())
        try await waitUntil { await !transport.sentData.isEmpty }

        let response: AnyResponse? = await transport.decodeLastSentMessage()
        guard case .failure(.invalidRequest) = response?.result else {
            Issue.record("Expected a standalone-request protocol error")
            await client.disconnect()
            return
        }
        #expect(await state.completionOrder.isEmpty)
        await client.disconnect()
    }

    @Test("Unknown result types are rejected for single and batch requests")
    func unknownResultTypes() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "Client",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await connectPerRequestClient(client, transport: transport)
        await transport.clearMessages()

        let request = ListTools.request(.init())
        let context = try await client.send(request)
        try await waitUntil { await !transport.sentData.isEmpty }
        await transport.queue(data: try JSONEncoder().encode(Value.object([
            "jsonrpc": "2.0",
            "id": try Value(request.id),
            "result": .object(["resultType": "future_result"]),
        ])))
        await #expect(throws: MCPError.self) {
            _ = try await context.value
        }

        await transport.clearMessages()
        let batchRequest = ListTools.request(.init())
        nonisolated(unsafe) var batchTask: Task<ListTools.Result, Error>?
        try await client.withBatch { batch in
            batchTask = try await batch.addRequest(batchRequest)
        }
        try await waitUntil { await !transport.sentData.isEmpty }
        await transport.queue(data: try JSONEncoder().encode(Value.array([.object([
            "jsonrpc": "2.0",
            "id": try Value(batchRequest.id),
            "result": .object(["resultType": "future_result"]),
        ])])))
        await #expect(throws: MCPError.self) {
            _ = try await #require(batchTask).value
        }

        await client.disconnect()
    }

    @Test("Server rejects embedded requests not declared by client capabilities")
    func missingClientCapability() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "CapabilityServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMultiRoundTripHandler(CallTool.self) { _ in
            .inputRequired(.init(inputRequests: [
                "roots": try Self.embeddedRequest(method: ListRoots.name, parameters: Empty())
            ]))
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "Client",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        _ = try await client.connectWithInfo(transport: transports.client)

        do {
            _ = try await client.sendAndAwait(CallTool.request(.init(name: "capability")))
            Issue.record("Expected a missing client capability error")
        } catch let error as MCPError {
            guard case .remote(let code, _, _) = error else {
                Issue.record("Expected a remote protocol error")
                await client.disconnect()
                await server.stop()
                return
            }
            #expect(code == ProtocolErrorCode.missingRequiredClientCapability)
        }

        await client.disconnect()
        await server.stop()
    }

    @Test("Cancellation during embedded input prevents a retry")
    func cancellationDuringEmbeddedInput() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let state = MultiRoundTripState()
        let server = Server(
            name: "CancellationServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMultiRoundTripHandler(CallTool.self) { _ in
            await state.recordAttempt(try #require(Server.currentHandlerContext?.id))
            return .inputRequired(.init(inputRequests: [
                "user": try Self.embeddedRequest(
                    method: CreateElicitation.name,
                    parameters: CreateElicitation.Parameters.form(.init(message: "Wait"))
                )
            ]))
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "Client",
            version: "1.0",
            capabilities: .init(elicitation: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await client.withElicitationHandler { _ in
            await state.recordCompletion("started")
            try await Task.sleep(for: .milliseconds(30))
            await state.recordCompletion("finished")
            return .init(action: .cancel)
        }
        _ = try await client.connectWithInfo(transport: transports.client)

        let context = try await client.send(CallTool.request(.init(name: "cancel")))
        for _ in 0..<100 {
            if await state.completionOrder.contains("started") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await state.completionOrder.contains("started"))
        try await client.cancelRequest(context.requestID, reason: "test cancellation")
        await #expect(throws: CancellationError.self) {
            _ = try await context.value
        }
        #expect(await state.rounds == 1)
        #expect(await state.completionOrder == ["started"])

        await client.disconnect()
        await server.stop()
    }

    @Test("Cancelling immediately after send stops the request before its first attempt")
    func cancellationBeforeFirstAttempt() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let state = MultiRoundTripState()
        let server = Server(
            name: "CancellationServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMultiRoundTripHandler(CallTool.self) { _ in
            await state.recordAttempt(try #require(Server.currentHandlerContext?.id))
            return .inputRequired(.init(inputRequests: [
                "user": try Self.embeddedRequest(
                    method: CreateElicitation.name,
                    parameters: CreateElicitation.Parameters.form(.init(message: "Wait"))
                )
            ]))
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "Client",
            version: "1.0",
            capabilities: .init(elicitation: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await client.withElicitationHandler { _ in
            await state.recordCompletion("prompted")
            return .init(action: .cancel)
        }
        _ = try await client.connectWithInfo(transport: transports.client)

        // Cancel without waiting for the attempt to register: the cancellation action is
        // recorded by `send` itself, so the logical request must observe it either way.
        let context = try await client.send(CallTool.request(.init(name: "cancel")))
        try await client.cancelRequest(context.requestID, reason: "immediate cancellation")

        await #expect(throws: CancellationError.self) {
            _ = try await context.value
        }
        // A cancelled request must never prompt the user for embedded input.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await state.completionOrder.isEmpty)

        await client.disconnect()
        await server.stop()
    }

    @Test("Concurrent logical requests keep response maps and state separate")
    func concurrentLogicalRequests() async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let state = MultiRoundTripState()
        let server = Server(
            name: "ConcurrentServer",
            version: "1.0",
            capabilities: .init(tools: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMultiRoundTripHandler(CallTool.self) { parameters in
            if parameters.inputResponses == nil {
                return .inputRequired(.init(
                    inputRequests: [
                        "user": try Self.embeddedRequest(
                            method: CreateElicitation.name,
                            parameters: CreateElicitation.Parameters.form(.init(
                                message: parameters.name
                            ))
                        )
                    ],
                    requestState: parameters.name
                ))
            }

            #expect(parameters.requestState == parameters.name)
            let response = try #require(parameters.inputResponses?["user"])
            let elicitation = try Self.decode(CreateElicitation.Result.self, from: response)
            #expect(elicitation.content?["request"]?.stringValue == parameters.name)
            return .complete(.init(content: [
                .text(text: parameters.name, annotations: nil, _meta: nil)
            ]))
        }
        try await server.start(transport: transports.server)

        let client = Client(
            name: "Client",
            version: "1.0",
            capabilities: .init(elicitation: .init()),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await client.withElicitationHandler { parameters in
            guard case .form(let form) = parameters else {
                return .init(action: .cancel)
            }
            if form.message == "slow" {
                try await Task.sleep(for: .milliseconds(30))
            } else {
                try await Task.sleep(for: .milliseconds(5))
            }
            await state.recordCompletion(form.message)
            return .init(action: .accept, content: ["request": .string(form.message)])
        }
        _ = try await client.connectWithInfo(transport: transports.client)

        async let slow = client.sendAndAwait(CallTool.request(.init(name: "slow")))
        async let fast = client.sendAndAwait(CallTool.request(.init(name: "fast")))
        let fastResult = try await fast
        let slowResult = try await slow
        #expect(fastResult.content == [
            .text(text: "fast", annotations: nil, _meta: nil)
        ])
        #expect(slowResult.content == [
            .text(text: "slow", annotations: nil, _meta: nil)
        ])
        #expect(await state.completionOrder == ["fast", "slow"])

        await client.disconnect()
        await server.stop()
    }

    private static func embeddedRequest<Parameters: Codable>(
        method: String,
        parameters: Parameters
    ) throws -> Value {
        .object([
            "method": .string(method),
            "params": try Value(parameters),
        ])
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: Value) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func connectPerRequestClient(
        _ client: Client,
        transport: MockTransport
    ) async throws {
        let connectionTask = Task {
            try await client.connectWithInfo(transport: transport)
        }
        try await waitUntil { await !transport.sentData.isEmpty }
        let request: AnyRequest? = await transport.decodeLastSentMessage()
        let discover = try #require(request)
        try await transport.queue(response: Discover.response(
            id: discover.id,
            result: .init(
                supportedVersions: [Version.perRequestMetadataVersion],
                capabilities: .init(),
                ttlMs: 0,
                cacheScope: .public
            )
        ))
        _ = try await connectionTask.value
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
}
