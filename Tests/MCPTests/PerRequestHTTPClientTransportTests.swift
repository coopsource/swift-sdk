@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)

    private enum StreamingHTTPEvent: Sendable {
        case data(Data, delayMilliseconds: Int)
        case finish(delayMilliseconds: Int)
    }

    private struct StreamingHTTPScript: Sendable {
        let response: HTTPURLResponse
        let events: [StreamingHTTPEvent]
    }

    private actor StreamingHTTPStorage {
        typealias Handler = @Sendable (URLRequest) async throws -> StreamingHTTPScript

        private var handler: Handler?
        private(set) var requestCount = 0
        private(set) var emittedChunkCount = 0
        private(set) var stoppedRequestCount = 0
        private var stoppedLoads: Set<UUID> = []

        func reset() {
            handler = nil
            requestCount = 0
            emittedChunkCount = 0
            stoppedRequestCount = 0
        }

        func setHandler(_ handler: @escaping Handler) {
            self.handler = handler
        }

        func script(for request: URLRequest) async throws -> StreamingHTTPScript {
            guard let handler else {
                throw MCPError.internalError("No streaming HTTP test handler is configured")
            }
            requestCount += 1
            return try await handler(request)
        }

        func recordEmittedChunk() {
            emittedChunkCount += 1
        }

        func recordStoppedRequest(_ id: UUID) {
            stoppedRequestCount += 1
            stoppedLoads.insert(id)
        }

        func isStopped(_ id: UUID) -> Bool {
            stoppedLoads.contains(id)
        }
    }

    private final class PerRequestHTTPURLProtocol: URLProtocol, @unchecked Sendable {
        static let storage = StreamingHTTPStorage()
        private let loadID = UUID()

        static func setHandler(
            _ handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) async {
            await storage.reset()
            await storage.setHandler { request in
                let (response, data) = try await handler(request)
                var events: [StreamingHTTPEvent] = []
                if !data.isEmpty {
                    events.append(.data(data, delayMilliseconds: 0))
                }
                events.append(.finish(delayMilliseconds: 0))
                return StreamingHTTPScript(response: response, events: events)
            }
        }

        static func verifyCallCount(
            _ expected: Int,
            for endpoint: URL,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            let actual = await storage.requestCount
            #expect(
                actual == expected,
                "Expected \(expected) HTTP calls to \(endpoint), got \(actual)",
                sourceLocation: sourceLocation
            )
        }

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let loadID = self.loadID
            Task {
                do {
                    let script = try await Self.storage.script(for: request)
                    guard !(await Self.storage.isStopped(loadID)) else { return }
                    client?.urlProtocol(
                        self,
                        didReceive: script.response,
                        cacheStoragePolicy: .notAllowed
                    )

                    for event in script.events {
                        switch event {
                        case .data(let data, let delayMilliseconds):
                            try await Task.sleep(for: .milliseconds(delayMilliseconds))
                            guard !(await Self.storage.isStopped(loadID)) else { return }
                            client?.urlProtocol(self, didLoad: data)
                            await Self.storage.recordEmittedChunk()
                        case .finish(let delayMilliseconds):
                            try await Task.sleep(for: .milliseconds(delayMilliseconds))
                            guard !(await Self.storage.isStopped(loadID)) else { return }
                            client?.urlProtocolDidFinishLoading(self)
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }

        override func stopLoading() {
            let loadID = self.loadID
            Task { await Self.storage.recordStoppedRequest(loadID) }
        }
    }

    private actor AuthorizationCallTracker {
        private var activeCalls = 0
        private(set) var maximumConcurrentCalls = 0
        private(set) var totalCalls = 0

        func enter() {
            activeCalls += 1
            totalCalls += 1
            maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        }

        func leave() {
            activeCalls -= 1
        }
    }

    private final class RefreshingAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        let tracker = AuthorizationCallTracker()
        let maxAuthorizationAttempts = 3

        private let tokenLock = NSLock()
        private var token = "stale-token"

        func validateEndpointSecurity(for endpoint: URL) throws {}

        func authorizationHeader(for endpoint: URL) -> String? {
            tokenLock.lock()
            let token = self.token
            tokenLock.unlock()
            return "Bearer \(token)"
        }

        func handleChallenge(
            statusCode: Int,
            headers: [String: String],
            endpoint: URL,
            operationKey: String?,
            session: URLSession
        ) async throws -> Bool {
            await tracker.enter()
            do {
                try await Task.sleep(for: .milliseconds(20))
                setToken("refreshed-token")
                await tracker.leave()
                return true
            } catch {
                await tracker.leave()
                throw error
            }
        }

        private func setToken(_ token: String) {
            tokenLock.lock()
            self.token = token
            tokenLock.unlock()
        }
    }

    private final class DelayedAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        let tracker = AuthorizationCallTracker()
        let maxAuthorizationAttempts = 2

        func validateEndpointSecurity(for endpoint: URL) throws {}

        func authorizationHeader(for endpoint: URL) -> String? { "Bearer test-token" }

        func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {
            await tracker.enter()
            try await Task.sleep(for: .milliseconds(20))
            await tracker.leave()
        }

        func handleChallenge(
            statusCode: Int,
            headers: [String: String],
            endpoint: URL,
            operationKey: String?,
            session: URLSession
        ) async throws -> Bool {
            false
        }
    }

    private final class SingleRetryAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        let maxAuthorizationAttempts = 1

        private let lock = NSLock()
        private var token = "stale-token"
        private var challengeCount = 0

        func validateEndpointSecurity(for endpoint: URL) throws {}

        func authorizationHeader(for endpoint: URL) -> String? {
            lock.lock()
            let token = self.token
            lock.unlock()
            return "Bearer \(token)"
        }

        func handleChallenge(
            statusCode: Int,
            headers: [String: String],
            endpoint: URL,
            operationKey: String?,
            session: URLSession
        ) async throws -> Bool {
            recordChallenge()
            return true
        }

        private func recordChallenge() {
            lock.lock()
            challengeCount += 1
            token = "fresh-token"
            lock.unlock()
        }

        func handledChallengeCount() -> Int {
            lock.lock()
            let count = challengeCount
            lock.unlock()
            return count
        }
    }

    @Suite("MCP 2026-07-28 HTTP client transport", .serialized, .timeLimit(.minutes(1)))
    struct PerRequestHTTPClientTransportTests {
        private let endpoint = URL(string: "https://localhost:8080/mcp")!

        @Test("Direct transports default to the latest initialization version")
        func initializationVersionDefault() async {
            let transport = makeTransport()
            #expect(await transport.protocolVersion == Version.latestInitializationVersion)
        }

        @Test("Per-request JSON response uses one POST without session state")
        func jsonResponse() async throws {
            let requestData = try makePerRequestData(id: 1)
            let responseData = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
            let transport = makeTransport()
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()

            await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                #expect(request.url == endpoint)
                #expect(request.httpMethod == "POST")
                #expect(requestBody(request) == requestData)
                #expect(
                    request.value(forHTTPHeaderField: HTTPHeaderName.protocolVersion)
                        == Version.perRequestMetadataVersion
                )
                #expect(request.value(forHTTPHeaderField: HTTPHeaderName.sessionID) == nil)

                let response = HTTPURLResponse(
                    url: endpoint,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": ContentType.json,
                        "Mcp-Session-Id": "must-be-ignored",
                    ]
                )!
                return (response, responseData)
            }

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            try await transport.send(requestData)
            #expect(try await iterator.next() == responseData)
            #expect(await transport.sessionID == nil)
            await transport.disconnect()
        }

        @Test("Notifications include the selected protocol version and require HTTP 202")
        func notificationResponse() async throws {
            let notificationData = Data(
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#.utf8
            )
            let transport = makeTransport()
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()

            await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                #expect(
                    request.value(forHTTPHeaderField: HTTPHeaderName.protocolVersion)
                        == Version.perRequestMetadataVersion
                )
                let response = HTTPURLResponse(
                    url: endpoint,
                    statusCode: 202,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!
                return (response, Data())
            }

            try await transport.send(notificationData)
            await transport.disconnect()
        }

        @Test("Request-scoped SSE preserves messages split across network chunks")
        func requestScopedSSE() async throws {
            await PerRequestHTTPURLProtocol.storage.reset()
            let requestData = try makePerRequestData(id: 7)
            let notification = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1,"progressToken":"work"}}"#
            let response = #"{"jsonrpc":"2.0","id":7,"result":{}}"#
            await PerRequestHTTPURLProtocol.storage.setHandler { [endpoint] request in
                #expect(requestBody(request) == requestData)
                return StreamingHTTPScript(
                    response: HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.sse]
                    )!,
                    events: [
                        .data(Data(": keepalive\r\ndata: \(notification)\r\n\r\nda".utf8), delayMilliseconds: 0),
                        .data(Data("ta: \(response)\r\n\r\n".utf8), delayMilliseconds: 5),
                        .finish(delayMilliseconds: 20),
                    ]
                )
            }

            let transport = makeStreamingTransport()
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()
            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let sendTask = Task { try await transport.send(requestData) }

            #expect(try await iterator.next() == Data(notification.utf8))
            #expect(try await iterator.next() == Data(response.utf8))
            try await sendTask.value
            await transport.disconnect()
        }

        @Test("Request-scoped SSE ignores one leading byte-order mark split across chunks")
        func requestScopedSSEByteOrderMark() async throws {
            await PerRequestHTTPURLProtocol.storage.reset()
            let requestData = try makePerRequestData(id: 8)
            let response = #"{"jsonrpc":"2.0","id":8,"result":{}}"#
            await PerRequestHTTPURLProtocol.storage.setHandler { [endpoint] _ in
                StreamingHTTPScript(
                    response: HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.sse]
                    )!,
                    events: [
                        .data(Data([0xEF]), delayMilliseconds: 0),
                        .data(Data([0xBB]), delayMilliseconds: 0),
                        .data(Data([0xBF]) + Data("data: \(response)\n\n".utf8), delayMilliseconds: 0),
                        .finish(delayMilliseconds: 0),
                    ]
                )
            }

            let transport = makeStreamingTransport()
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()
            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()

            try await transport.send(requestData)
            #expect(try await iterator.next() == Data(response.utf8))
            await transport.disconnect()
        }

        @Test("Cancelling a request closes its request-scoped SSE response")
        func requestScopedCancellation() async throws {
            await PerRequestHTTPURLProtocol.storage.reset()
            let requestData = try makePerRequestData(id: 9)
            let first = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1,"progressToken":"work"}}"#
            let second = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":2,"progressToken":"work"}}"#
            await PerRequestHTTPURLProtocol.storage.setHandler { [endpoint] _ in
                StreamingHTTPScript(
                    response: HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.sse]
                    )!,
                    events: [
                        .data(Data("data: \(first)\n\n".utf8), delayMilliseconds: 0),
                        .data(Data("data: \(second)\n\n".utf8), delayMilliseconds: 200),
                        .finish(delayMilliseconds: 0),
                    ]
                )
            }

            let transport = makeStreamingTransport()
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()
            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let sendTask = Task { try await transport.send(requestData) }

            #expect(try await iterator.next() == Data(first.utf8))
            await transport.cancelRequestStream(id: 9)
            await #expect(throws: (any Swift.Error).self) {
                try await sendTask.value
            }
            try await Task.sleep(for: .milliseconds(250))
            #expect(await PerRequestHTTPURLProtocol.storage.emittedChunkCount == 1)
            #expect(await PerRequestHTTPURLProtocol.storage.stoppedRequestCount >= 1)
            await transport.disconnect()
        }

        @Test("Cancelling before response headers closes the HTTP request")
        func cancellationBeforeResponse() async throws {
            await PerRequestHTTPURLProtocol.storage.reset()
            let requestData = try makePerRequestData(id: 10)
            await PerRequestHTTPURLProtocol.storage.setHandler { [endpoint] _ in
                try await Task.sleep(for: .milliseconds(200))
                return StreamingHTTPScript(
                    response: HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.json]
                    )!,
                    events: [.finish(delayMilliseconds: 0)]
                )
            }

            let transport = makeStreamingTransport()
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()
            let sendTask = Task { try await transport.send(requestData) }
            while await PerRequestHTTPURLProtocol.storage.requestCount == 0 {
                try await Task.sleep(for: .milliseconds(1))
            }

            await transport.cancelRequestStream(id: 10)
            await #expect(throws: (any Swift.Error).self) {
                try await sendTask.value
            }
            #expect(await PerRequestHTTPURLProtocol.storage.emittedChunkCount == 0)
            #expect(await PerRequestHTTPURLProtocol.storage.stoppedRequestCount >= 1)
            await transport.disconnect()
        }

        @Test("Cancellation before HTTP task registration prevents network I/O")
        func cancellationBeforeTaskRegistration() async throws {
            await PerRequestHTTPURLProtocol.storage.reset()
            let transport = makeTransport()
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()
            await transport.cancelRequestStream(id: 11)

            await #expect(throws: CancellationError.self) {
                try await transport.send(makePerRequestData(id: 11))
            }
            await PerRequestHTTPURLProtocol.verifyCallCount(0, for: endpoint)
            await transport.disconnect()
        }

        @Test("Concurrent requests may complete out of order")
        func outOfOrderResponses() async throws {
            let transport = makeTransport()
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()

            await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                let body = try #require(requestBody(request))
                let rpcRequest = try JSONDecoder().decode(AnyRequest.self, from: body)
                if rpcRequest.id == 1 {
                    try await Task.sleep(for: .milliseconds(40))
                }
                let response = try JSONEncoder().encode(
                    AnyMethod.response(id: rpcRequest.id, result: .object([:]))
                )
                return (
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.json]
                    )!,
                    response
                )
            }

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let firstTask = Task { try await transport.send(makePerRequestData(id: 1)) }
            let secondTask = Task { try await transport.send(makePerRequestData(id: 2)) }

            let firstResponse = try #require(try await iterator.next())
            let secondResponse = try #require(try await iterator.next())
            #expect(try JSONDecoder().decode(AnyResponse.self, from: firstResponse).id == 2)
            #expect(try JSONDecoder().decode(AnyResponse.self, from: secondResponse).id == 1)
            try await firstTask.value
            try await secondTask.value
            await transport.disconnect()
        }

        @Test("Authorization preparation is serialized across concurrent requests")
        func serializedAuthorization() async throws {
            let authorizer = DelayedAuthorizer()
            let transport = makeTransport(authorizer: authorizer)
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()

            await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                #expect(
                    request.value(forHTTPHeaderField: HTTPHeaderName.authorization)
                        == "Bearer test-token"
                )
                let body = try #require(requestBody(request))
                let rpcRequest = try JSONDecoder().decode(AnyRequest.self, from: body)
                let response = try JSONEncoder().encode(
                    AnyMethod.response(id: rpcRequest.id, result: .object([:]))
                )
                return (
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.json]
                    )!,
                    response
                )
            }

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let firstTask = Task { try await transport.send(makePerRequestData(id: 1)) }
            let secondTask = Task { try await transport.send(makePerRequestData(id: 2)) }
            _ = try await iterator.next()
            _ = try await iterator.next()
            try await firstTask.value
            try await secondTask.value

            #expect(await authorizer.tracker.maximumConcurrentCalls == 1)
            await transport.disconnect()
        }

        @Test("Concurrent authentication challenges share one refresh")
        func coalescedAuthenticationRefresh() async throws {
            let authorizer = RefreshingAuthorizer()
            let transport = makeTransport(authorizer: authorizer)
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()

            await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                let body = try #require(requestBody(request))
                let rpcRequest = try JSONDecoder().decode(AnyRequest.self, from: body)
                if request.value(forHTTPHeaderField: HTTPHeaderName.authorization)
                    == "Bearer stale-token"
                {
                    return (
                        HTTPURLResponse(
                            url: endpoint,
                            statusCode: 401,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["WWW-Authenticate": "Bearer"]
                        )!,
                        Data()
                    )
                }
                let response = try JSONEncoder().encode(
                    AnyMethod.response(id: rpcRequest.id, result: .object([:]))
                )
                return (
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.json]
                    )!,
                    response
                )
            }

            let stream = await transport.receive()
            var iterator = stream.makeAsyncIterator()
            let firstTask = Task { try await transport.send(makePerRequestData(id: 1)) }
            let secondTask = Task { try await transport.send(makePerRequestData(id: 2)) }
            _ = try await iterator.next()
            _ = try await iterator.next()
            try await firstTask.value
            try await secondTask.value

            #expect(await authorizer.tracker.maximumConcurrentCalls == 1)
            #expect(await authorizer.tracker.totalCalls == 1)
            await transport.disconnect()
        }

        @Test("One allowed authorization retry performs one retry in each lifecycle")
        func authorizationRetryLimit() async throws {
            for usesPerRequestMetadata in [false, true] {
                let authorizer = SingleRetryAuthorizer()
                let transport = makeTransport(authorizer: authorizer)
                if usesPerRequestMetadata {
                    await transport.updateProtocolLifecycle(
                        .perRequestMetadata,
                        protocolVersion: Version.perRequestMetadataVersion
                    )
                }
                try await transport.connect()

                let requestData = usesPerRequestMetadata
                    ? try makePerRequestData(id: 12)
                    : try JSONEncoder().encode(Ping.request(id: 12))
                await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                    if request.value(forHTTPHeaderField: HTTPHeaderName.authorization)
                        == "Bearer stale-token"
                    {
                        return (
                            HTTPURLResponse(
                                url: endpoint,
                                statusCode: 401,
                                httpVersion: "HTTP/1.1",
                                headerFields: ["WWW-Authenticate": "Bearer"]
                            )!,
                            Data()
                        )
                    }
                    return (
                        HTTPURLResponse(
                            url: endpoint,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": ContentType.json]
                        )!,
                        Data(#"{"jsonrpc":"2.0","id":12,"result":{}}"#.utf8)
                    )
                }

                let stream = await transport.receive()
                var iterator = stream.makeAsyncIterator()
                try await transport.send(requestData)
                #expect(try await iterator.next() != nil)
                await PerRequestHTTPURLProtocol.verifyCallCount(2, for: endpoint)
                #expect(authorizer.handledChallengeCount() == 1)
                await transport.disconnect()
            }

            let authorizer = SingleRetryAuthorizer()
            let transport = makeTransport(authorizer: authorizer)
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()
            await PerRequestHTTPURLProtocol.setHandler { [endpoint] _ in
                (
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 401,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["WWW-Authenticate": "Bearer"]
                    )!,
                    Data()
                )
            }

            await #expect(throws: MCPError.self) {
                try await transport.send(makePerRequestData(id: 13))
            }
            await PerRequestHTTPURLProtocol.verifyCallCount(2, for: endpoint)
            #expect(authorizer.handledChallengeCount() == 1)
            await transport.disconnect()
        }

        @Test("Automatic mode selects per-request metadata without opening a GET")
        func automaticSelection() async throws {
            await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                #expect(request.httpMethod == "POST")
                let body = try #require(requestBody(request))
                let rpcRequest = try JSONDecoder().decode(AnyRequest.self, from: body)
                #expect(rpcRequest.method == Discover.name)
                let result = Discover.Result(
                    supportedVersions: [Version.perRequestMetadataVersion],
                    capabilities: .init(tools: .init()),
                    ttlMs: 60_000,
                    cacheScope: .public,
                    _meta: Metadata(additionalFields: [
                        ProtocolMetadataKey.serverInfo: try Value(
                            Server.Info(name: "HTTPServer", version: "1.0")
                        )
                    ])
                )
                return (
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.json]
                    )!,
                    try JSONEncoder().encode(Discover.response(id: rpcRequest.id, result: result))
                )
            }

            let client = Client(
                name: "HTTPClient",
                version: "1.0",
                configuration: .init(protocolMode: .automatic)
            )
            let info = try await client.connectWithInfo(transport: makeTransport(streaming: true))
            #expect(info.protocolLifecycle == .perRequestMetadata)
            #expect(info.protocolVersion == Version.perRequestMetadataVersion)
            await PerRequestHTTPURLProtocol.verifyCallCount(1, for: endpoint)
            await client.disconnect()
        }

        @Test("Cancelling HTTP discovery does not start initialization fallback")
        func cancelledAutomaticDiscovery() async throws {
            await PerRequestHTTPURLProtocol.storage.reset()
            await PerRequestHTTPURLProtocol.storage.setHandler { [endpoint] _ in
                try await Task.sleep(for: .milliseconds(200))
                return StreamingHTTPScript(
                    response: HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.json]
                    )!,
                    events: [.finish(delayMilliseconds: 0)]
                )
            }

            let client = Client(
                name: "HTTPClient",
                version: "1.0",
                configuration: .init(protocolMode: .automatic)
            )
            let connectionTask = Task {
                try await client.connectWithInfo(transport: makeTransport())
            }
            while await PerRequestHTTPURLProtocol.storage.requestCount == 0 {
                try await Task.sleep(for: .milliseconds(1))
            }
            connectionTask.cancel()

            await #expect(throws: CancellationError.self) {
                _ = try await connectionTask.value
            }
            await PerRequestHTTPURLProtocol.verifyCallCount(1, for: endpoint)
            try await Task.sleep(for: .milliseconds(20))
            #expect(await PerRequestHTTPURLProtocol.storage.stoppedRequestCount >= 1)
            await client.disconnect()
        }

        @Test(
            "Automatic mode falls back for unrecognized compatibility responses",
            arguments: [400, 404, 405]
        )
        func automaticFallback(statusCode: Int) async throws {
            await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                let body = try #require(requestBody(request))
                let envelope = try #require(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let method = try #require(envelope["method"] as? String)

                if method == Discover.name {
                    return (
                        HTTPURLResponse(
                            url: endpoint,
                            statusCode: statusCode,
                            httpVersion: "HTTP/1.1",
                            headerFields: [:]
                        )!,
                        Data()
                    )
                }

                if method == Initialize.name {
                    let rpcRequest = try JSONDecoder().decode(AnyRequest.self, from: body)
                    let result = Initialize.Result(
                        protocolVersion: Version.latestInitializationVersion,
                        capabilities: .init(),
                        serverInfo: .init(name: "InitializationServer", version: "1.0")
                    )
                    return (
                        HTTPURLResponse(
                            url: endpoint,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": ContentType.json]
                        )!,
                        try JSONEncoder().encode(
                            Initialize.response(id: rpcRequest.id, result: result)
                        )
                    )
                }

                #expect(method == InitializedNotification.name)
                return (
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 202,
                        httpVersion: "HTTP/1.1",
                        headerFields: [:]
                    )!,
                    Data()
                )
            }

            let client = Client(
                name: "HTTPClient",
                version: "1.0",
                configuration: .init(protocolMode: .automatic)
            )
            let info = try await client.connectWithInfo(transport: makeTransport())
            #expect(info.protocolLifecycle == .initializationBased)
            #expect(info.protocolVersion == Version.latestInitializationVersion)
            await PerRequestHTTPURLProtocol.verifyCallCount(3, for: endpoint)
            await client.disconnect()
        }

        @Test("Authentication and transient failures do not select initialization")
        func inconclusiveProbeFailures() async throws {
            for statusCode in [401, 403, 408, 429, 500] {
                await PerRequestHTTPURLProtocol.storage.reset()
                await PerRequestHTTPURLProtocol.setHandler { [endpoint] _ in
                    (
                        HTTPURLResponse(
                            url: endpoint,
                            statusCode: statusCode,
                            httpVersion: "HTTP/1.1",
                            headerFields: [:]
                        )!,
                        Data()
                    )
                }

                let client = Client(
                    name: "HTTPClient",
                    version: "1.0",
                    configuration: .init(protocolMode: .automatic)
                )
                await #expect(throws: MCPError.self) {
                    _ = try await client.connectWithInfo(transport: makeTransport())
                }
                await PerRequestHTTPURLProtocol.verifyCallCount(1, for: endpoint)
                await client.disconnect()
            }
        }

        @Test(
            "Recognized protocol errors do not select initialization",
            arguments: [
                ProtocolErrorCode.headerMismatch,
                ProtocolErrorCode.missingRequiredClientCapability,
                ProtocolErrorCode.unsupportedProtocolVersion,
            ]
        )
        func recognizedProtocolError(expectedCode: Int) async throws {
            await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                let body = try #require(requestBody(request))
                let rpcRequest = try JSONDecoder().decode(AnyRequest.self, from: body)
                let error = MCPError.remote(
                    code: expectedCode,
                    message: "Recognized per-request error",
                    data: nil
                )
                return (
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 400,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.json]
                    )!,
                    try JSONEncoder().encode(AnyMethod.response(id: rpcRequest.id, error: error))
                )
            }

            let client = Client(
                name: "HTTPClient",
                version: "1.0",
                configuration: .init(protocolMode: .automatic)
            )
            do {
                _ = try await client.connectWithInfo(transport: makeTransport())
                Issue.record("Expected a recognized per-request error")
            } catch let error as MCPError {
                #expect(error.code == expectedCode)
            }
            await PerRequestHTTPURLProtocol.verifyCallCount(1, for: endpoint)
            await client.disconnect()
        }

        @Test("HTTP 404 method-not-found identifies a per-request metadata server")
        func methodNotFoundDoesNotFallback() async throws {
            await PerRequestHTTPURLProtocol.setHandler { [endpoint] request in
                let body = try #require(requestBody(request))
                let rpcRequest = try JSONDecoder().decode(AnyRequest.self, from: body)
                return (
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 404,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": ContentType.json]
                    )!,
                    try JSONEncoder().encode(
                        AnyMethod.response(
                            id: rpcRequest.id,
                            error: .methodNotFound("server/discover")
                        )
                    )
                )
            }

            let client = Client(
                name: "HTTPClient",
                version: "1.0",
                configuration: .init(protocolMode: .automatic)
            )
            await #expect(throws: MCPError.self) {
                _ = try await client.connectWithInfo(transport: makeTransport())
            }
            await PerRequestHTTPURLProtocol.verifyCallCount(1, for: endpoint)
            await client.disconnect()
        }

        @Test("JSON responses require a matching ID and JSON content type")
        func invalidJSONResponses() async throws {
            let scenarios: [(contentType: String, response: Data)] = [
                (
                    ContentType.json,
                    Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8)
                ),
                (
                    "text/plain",
                    Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
                ),
            ]

            for scenario in scenarios {
                await PerRequestHTTPURLProtocol.setHandler { [endpoint] _ in
                    (
                        HTTPURLResponse(
                            url: endpoint,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": scenario.contentType]
                        )!,
                        scenario.response
                    )
                }
                let transport = makeTransport()
                await transport.updateProtocolLifecycle(
                    .perRequestMetadata,
                    protocolVersion: Version.perRequestMetadataVersion
                )
                try await transport.connect()
                await #expect(throws: MCPError.self) {
                    try await transport.send(makePerRequestData(id: 1))
                }
                await transport.disconnect()
            }
        }

        @Test("Request-scoped SSE rejects server requests and missing final responses")
        func invalidRequestScopedSSE() async throws {
            let serverRequest =
                #"{"jsonrpc":"2.0","id":99,"method":"sampling/createMessage","params":{}}"#
            let notification =
                #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1,"progressToken":"work"}}"#

            for message in [serverRequest, notification] {
                await PerRequestHTTPURLProtocol.storage.reset()
                await PerRequestHTTPURLProtocol.storage.setHandler { [endpoint] _ in
                    StreamingHTTPScript(
                        response: HTTPURLResponse(
                            url: endpoint,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": ContentType.sse]
                        )!,
                        events: [
                            .data(Data("data: \(message)\r\r".utf8), delayMilliseconds: 0),
                            .finish(delayMilliseconds: 0),
                        ]
                    )
                }
                let transport = makeStreamingTransport()
                await transport.updateProtocolLifecycle(
                    .perRequestMetadata,
                    protocolVersion: Version.perRequestMetadataVersion
                )
                try await transport.connect()
                await #expect(throws: MCPError.self) {
                    try await transport.send(makePerRequestData(id: 1))
                }
                await transport.disconnect()
            }
        }

        @Test("Malformed requests and batches are rejected before network I/O")
        func invalidOutboundMessages() async throws {
            await PerRequestHTTPURLProtocol.setHandler { [endpoint] _ in
                (
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 500,
                        httpVersion: "HTTP/1.1",
                        headerFields: [:]
                    )!,
                    Data()
                )
            }
            let transport = makeTransport()
            await transport.updateProtocolLifecycle(
                .perRequestMetadata,
                protocolVersion: Version.perRequestMetadataVersion
            )
            try await transport.connect()

            let missingMetadata = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}"#.utf8)
            await #expect(throws: MCPError.self) {
                try await transport.send(missingMetadata)
            }
            let batch = Data("[\(String(decoding: try makePerRequestData(id: 2), as: UTF8.self))]".utf8)
            await #expect(throws: MCPError.self) {
                try await transport.send(batch)
            }
            await PerRequestHTTPURLProtocol.verifyCallCount(0, for: endpoint)
            await transport.disconnect()
        }

        private func makeTransport(
            streaming: Bool = false,
            authorizer: (any HTTPClientAuthorizer)? = nil
        ) -> HTTPClientTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PerRequestHTTPURLProtocol.self]
            return HTTPClientTransport(
                endpoint: endpoint,
                configuration: configuration,
                streaming: streaming,
                authorizer: authorizer
            )
        }

        private func makeStreamingTransport() -> HTTPClientTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PerRequestHTTPURLProtocol.self]
            return HTTPClientTransport(
                endpoint: endpoint,
                configuration: configuration,
                streaming: false
            )
        }

        private func makePerRequestData(id: Int, method: String = Ping.name) throws -> Data {
            try JSONEncoder().encode(Value.object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "method": .string(method),
                "params": .object([
                    "_meta": .object([
                        ProtocolMetadataKey.protocolVersion: .string(
                            Version.perRequestMetadataVersion),
                        ProtocolMetadataKey.clientCapabilities: .object([:]),
                    ])
                ]),
            ]))
        }
    }

    private func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

#endif
