import Foundation
@testable import MCP
@testable import MCPConformanceServerSupport
@preconcurrency import NIOCore
@preconcurrency import NIOEmbedded
@preconcurrency import NIOHTTP1
import Testing

private enum AdapterTestError: Swift.Error {
    case timedOut
    case writeFailed
}

private struct AdapterNotification: MCP.Notification {
    static let name = "notifications/adapter-test"

    struct Parameters: Hashable, Codable, Sendable {
        var sequence: Int
    }
}

private actor AdapterCancellationProbe {
    private(set) var enteredCount = 0
    private(set) var cancellationCount = 0
    private var waiters: [UUID: CheckedContinuation<Void, Swift.Error>] = [:]

    func suspend() async throws {
        let id = UUID()
        enteredCount += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                if Task.isCancelled {
                    cancel(id: id)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        cancellationCount += 1
        continuation.resume(throwing: CancellationError())
    }
}

private final class FailingBodyHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        if case .body = unwrapOutboundIn(data) {
            promise?.fail(AdapterTestError.writeFailed)
        } else {
            context.write(data, promise: promise)
        }
    }
}

private final class RecordingOutboundHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    private let lock = NSLock()
    private var bodies = 0

    var bodyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        if case .body = unwrapOutboundIn(data) {
            lock.lock()
            bodies += 1
            lock.unlock()
        }
        context.write(data, promise: promise)
    }
}

private struct AdapterHarness {
    let server: Server
    let transport: StreamableHTTPServerTransport
    let handler: HTTPHandler
    let recorder: RecordingOutboundHandler
    let channel: NIOAsyncTestingChannel

    func stop() async {
        if channel.isActive {
            try? await channel.close()
        }
        await server.stop()
    }
}

@Suite("MCP conformance HTTP adapter", .serialized, .timeLimit(.minutes(1)))
struct HTTPHandlerTests {
    @Test("Conformance custom-header schema is installed on the transport")
    func conformanceCustomHeaderSchema() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await configureConformanceToolHeaders(on: transport)
        let body = try PerRequestMetadataWire.encodeRequest(
            CallTool.request(
                id: .string("missing-header"),
                .init(
                    name: conformanceHeaderValidationTool.name,
                    arguments: ["value": .string("Hello")]
                )
            ),
            protocolVersion: Version.perRequestMetadataVersion,
            clientInfo: .init(name: "Conformance test client", version: "1.0"),
            clientCapabilities: .init(),
            using: JSONEncoder()
        )
        var headers = [
            HTTPHeaderName.contentType: "application/json",
            HTTPHeaderName.accept: "application/json, text/event-stream",
            HTTPHeaderName.protocolVersion: Version.perRequestMetadataVersion,
        ]
        headers.merge(
            try MCPHTTPHeaders.requestHeaders(for: body, toolPlans: [:])
        ) { _, new in new }

        let response = await transport.handleRequest(
            HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp")
        )
        let responseBody = try #require(response.bodyData)
        let object = try #require(
            JSONDecoder().decode(Value.self, from: responseBody).objectValue
        )

        #expect(response.statusCode == 400)
        #expect(
            object["error"]?.objectValue?["code"]?.intValue
                == ProtocolErrorCode.headerMismatch
        )
    }

    @Test("Disconnect before route completion cancels server work")
    func disconnectBeforeResponse() async throws {
        let probe = AdapterCancellationProbe()
        let harness = try await makeHarness { _, _ in
            try await probe.suspend()
            return .init(tools: [], ttlMs: 0, cacheScope: .private)
        }

        try await sendRequest(id: "first", through: harness.channel)
        try await wait(on: harness.channel) { await probe.enteredCount == 1 }

        try await harness.channel.close()
        try await wait(on: harness.channel) { await probe.cancellationCount == 1 }
        #expect(await activeRequestCount(in: harness) == 0)

        await harness.stop()
    }

    @Test("Disconnect after an SSE event does not write a terminal response")
    func disconnectDuringStream() async throws {
        let probe = AdapterCancellationProbe()
        let harness = try await makeHarness { server, _ in
            try await server.notify(AdapterNotification.message(.init(sequence: 1)))
            try await probe.suspend()
            return .init(tools: [], ttlMs: 0, cacheScope: .private)
        }

        try await sendRequest(id: "stream", through: harness.channel)
        try await wait(on: harness.channel) {
            harness.recorder.bodyCount > 0
        }
        let beforeClose = try await readOutbound(from: harness.channel)
        #expect(beforeClose.contains { if case .head = $0 { true } else { false } })
        #expect(beforeClose.contains { if case .body = $0 { true } else { false } })

        try await harness.channel.close()
        try await wait(on: harness.channel) { await probe.cancellationCount == 1 }

        let afterClose = try await readOutbound(from: harness.channel)
        #expect(!afterClose.contains { if case .end = $0 { true } else { false } })
        await harness.stop()
    }

    @Test("A failed body write cancels the stream and prevents later writes")
    func writeFailureCancelsStream() async throws {
        let probe = AdapterCancellationProbe()
        let harness = try await makeHarness(failBodyWrites: true) { server, _ in
            try await server.notify(AdapterNotification.message(.init(sequence: 1)))
            try await probe.suspend()
            return .init(tools: [], ttlMs: 0, cacheScope: .private)
        }

        try await sendRequest(id: "write-failure", through: harness.channel)
        try await wait(on: harness.channel) { await probe.enteredCount == 1 }
        try await wait(on: harness.channel) { await probe.cancellationCount == 1 }

        let parts = try await readOutbound(from: harness.channel)
        #expect(parts.contains { if case .head = $0 { true } else { false } })
        #expect(!parts.contains { if case .end = $0 { true } else { false } })
        #expect(!harness.channel.isActive)
        await harness.stop()
    }

    @Test("Successful SSE writes preserve head, events, and end ordering")
    func successfulStreamOrdering() async throws {
        let harness = try await makeHarness { server, _ in
            try await server.notify(AdapterNotification.message(.init(sequence: 1)))
            return .init(tools: [], ttlMs: 0, cacheScope: .private)
        }

        try await sendRequest(id: "success", through: harness.channel)
        try await wait(on: harness.channel) { await activeRequestCount(in: harness) == 0 }
        let parts = try await readOutbound(from: harness.channel)

        #expect(parts.count == 4)
        guard parts.count == 4 else {
            await harness.stop()
            return
        }
        if case .head = parts[0] {} else { Issue.record("Expected response head first") }
        if case .body = parts[1] {} else { Issue.record("Expected notification body second") }
        if case .body = parts[2] {} else { Issue.record("Expected final response body third") }
        if case .end = parts[3] {} else { Issue.record("Expected response end last") }

        await harness.stop()
    }

    @Test("Closing a channel cancels every tracked request")
    func disconnectCancelsMultipleRequests() async throws {
        let probe = AdapterCancellationProbe()
        let harness = try await makeHarness { _, _ in
            try await probe.suspend()
            return .init(tools: [], ttlMs: 0, cacheScope: .private)
        }

        try await sendRequest(id: "one", cursor: "one", through: harness.channel)
        try await sendRequest(id: "two", cursor: "two", through: harness.channel)
        try await wait(on: harness.channel) { await probe.enteredCount == 2 }
        #expect(await activeRequestCount(in: harness) == 2)

        try await harness.channel.close()
        try await wait(on: harness.channel) { await probe.cancellationCount == 2 }
        #expect(await activeRequestCount(in: harness) == 0)

        await harness.stop()
    }

    private func makeHarness(
        failBodyWrites: Bool = false,
        handler: @escaping @Sendable (Server, ListTools.Parameters) async throws -> ListTools.Result
    ) async throws -> AdapterHarness {
        let transport = StreamableHTTPServerTransport()
        let server = Server(
            name: "Adapter test server",
            version: "1.0",
            capabilities: .init(tools: .init(listChanged: true)),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(ListTools.self) { parameters in
            try await handler(server, parameters)
        }
        try await server.start(transport: transport)

        let httpHandler = HTTPHandler(
            endpoint: "/mcp",
            responder: { request in await transport.handleRequest(request) }
        )
        let recorder = RecordingOutboundHandler()
        let channel: NIOAsyncTestingChannel
        if failBodyWrites {
            channel = await NIOAsyncTestingChannel(handlers: [
                recorder,
                FailingBodyHandler(),
                httpHandler,
            ])
        } else {
            channel = await NIOAsyncTestingChannel(handlers: [recorder, httpHandler])
        }
        return AdapterHarness(
            server: server,
            transport: transport,
            handler: httpHandler,
            recorder: recorder,
            channel: channel
        )
    }

    private func sendRequest(
        id: String,
        cursor: String? = nil,
        through channel: NIOAsyncTestingChannel
    ) async throws {
        let parameters = cursor.map(ListTools.Parameters.init(cursor:)) ?? .init()
        let request: Request<ListTools> = ListTools.request(id: .string(id), parameters)
        let body = try PerRequestMetadataWire.encodeRequest(
            request,
            protocolVersion: Version.perRequestMetadataVersion,
            clientInfo: .init(name: "Adapter test client", version: "1.0"),
            clientCapabilities: .init(),
            using: JSONEncoder()
        )
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: HTTPHeaderName.accept, value: "application/json, text/event-stream")
        head.headers.add(name: HTTPHeaderName.contentType, value: "application/json")
        head.headers.add(
            name: HTTPHeaderName.protocolVersion,
            value: Version.perRequestMetadataVersion
        )
        for (name, value) in try MCPHTTPHeaders.requestHeaders(for: body, toolPlans: [:]) {
            head.headers.add(name: name, value: value)
        }

        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        _ = try await channel.writeInbound(HTTPServerRequestPart.head(head))
        _ = try await channel.writeInbound(HTTPServerRequestPart.body(buffer))
        _ = try await channel.writeInbound(HTTPServerRequestPart.end(nil))
    }

    private func wait(
        on channel: NIOAsyncTestingChannel,
        until condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            await channel.testingEventLoop.run()
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AdapterTestError.timedOut
    }

    private func readOutbound(
        from channel: NIOAsyncTestingChannel
    ) async throws -> [HTTPServerResponsePart] {
        var parts: [HTTPServerResponsePart] = []
        while let part = try await channel.readOutbound(as: HTTPServerResponsePart.self) {
            parts.append(part)
        }
        return parts
    }

    private func activeRequestCount(in harness: AdapterHarness) async -> Int {
        (try? await harness.channel.testingEventLoop.executeInContext {
            harness.handler.activeRequestCount
        }) ?? -1
    }
}
