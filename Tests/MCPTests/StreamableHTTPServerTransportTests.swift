import Foundation
import Testing

@testable import MCP

private enum HTTPServerProbe: MCP.Method {
    static let name = "test/http-server-probe"

    struct Parameters: Hashable, Codable, Sendable {
        let value: String
        let delayMilliseconds: Int
    }

    struct Result: Hashable, Codable, Sendable {
        let value: String
        let lifecycle: ProtocolLifecycle
        let authorization: String?
    }
}

private struct HTTPServerProgressNotification: MCP.Notification {
    static let name = "notifications/test_progress"

    struct Parameters: Hashable, Codable, Sendable {
        let step: Int
    }
}

private actor HTTPServerCancellationProbe {
    private(set) var started = false
    private(set) var cancelled = false

    func markStarted() { started = true }
    func markCancelled() { cancelled = true }
}

private func makePerRequestBody(
    id: Value? = .string("request-1"),
    method: String = HTTPServerProbe.name,
    value: String = "value",
    delayMilliseconds: Int = 0,
    protocolVersion: String? = Version.perRequestMetadataVersion,
    includeClientCapabilities: Bool = true
) throws -> Data {
    var metadata: [String: Value] = [
        ProtocolMetadataKey.clientInfo: .object([
            "name": "HTTP test client",
            "version": "1.0",
        ]),
    ]
    if includeClientCapabilities {
        metadata[ProtocolMetadataKey.clientCapabilities] = .object([:])
    }
    if let protocolVersion {
        metadata[ProtocolMetadataKey.protocolVersion] = .string(protocolVersion)
    }

    var object: [String: Value] = [
        "jsonrpc": "2.0",
        "method": .string(method),
        "params": .object([
            "value": .string(value),
            "delayMilliseconds": .int(delayMilliseconds),
            "_meta": .object(metadata),
        ]),
    ]
    if let id { object["id"] = id }
    return try JSONEncoder().encode(Value.object(object))
}

private func makeProtocolRequestBody(
    id: String,
    method: String,
    parameters: [String: Value]
) throws -> Data {
    var parameters = parameters
    parameters["_meta"] = .object([
        ProtocolMetadataKey.protocolVersion: .string(Version.perRequestMetadataVersion),
        ProtocolMetadataKey.clientCapabilities: .object([:]),
        ProtocolMetadataKey.clientInfo: .object([
            "name": "HTTP test client",
            "version": "1.0",
        ]),
    ])
    return try JSONEncoder().encode(Value.object([
        "jsonrpc": "2.0",
        "id": .string(id),
        "method": .string(method),
        "params": .object(parameters),
    ]))
}

private func makePerRequestHTTPPost(
    body: Data,
    protocolVersion: String? = Version.perRequestMetadataVersion,
    authorization: String? = nil,
    extraHeaders: [String: String] = [:]
) -> HTTPRequest {
    var headers = [
        HTTPHeaderName.contentType: "application/json",
        HTTPHeaderName.accept: "application/json, text/event-stream",
    ]
    if let protocolVersion {
        headers[HTTPHeaderName.protocolVersion] = protocolVersion
    }
    if let authorization {
        headers[HTTPHeaderName.authorization] = authorization
    }
    if let generated = try? MCPHTTPHeaders.requestHeaders(for: body, toolPlans: [:]) {
        headers.merge(generated) { _, new in new }
    }
    headers.merge(extraHeaders) { _, new in new }
    return HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp")
}

private func makeSubscriptionBody(id: ID, filter: SubscriptionFilter) throws -> Data {
    try PerRequestMetadataWire.encodeRequest(
        SubscriptionsListen.request(id: id, .init(notifications: filter)),
        protocolVersion: Version.perRequestMetadataVersion,
        clientInfo: .init(name: "HTTP test client", version: "1.0"),
        clientCapabilities: .init(),
        using: JSONEncoder()
    )
}

private func decodeResponseObject(_ response: HTTPResponse) throws -> [String: Value] {
    let data = try #require(response.bodyData)
    return try #require(JSONDecoder().decode(Value.self, from: data).objectValue)
}

private func decodeSSEObject(_ data: Data) throws -> [String: Value] {
    let string = String(decoding: data, as: UTF8.self)
    let dataLine = try #require(string.split(whereSeparator: \Character.isNewline)
        .first { $0.hasPrefix("data:") })
    let json = dataLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
    return try #require(
        JSONDecoder().decode(Value.self, from: Data(json.utf8)).objectValue)
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await predicate()) {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("MCP 2026-07-28 Streamable HTTP server", .timeLimit(.minutes(1)))
struct StreamableHTTPServerTransportTests {
    @Test("GET and DELETE are rejected without creating session behavior", arguments: ["GET", "DELETE"])
    func postOnly(method: String) async {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let response = await transport.handleRequest(HTTPRequest(
            method: method,
            headers: [
                HTTPHeaderName.sessionID: "ignored",
                HTTPHeaderName.lastEventID: "ignored",
            ]
        ))

        #expect(response.statusCode == 405)
        #expect(response.headers[HTTPHeaderName.allow] == "POST")
        #expect(response.headers[HTTPHeaderName.sessionID] == nil)
    }

    @Test("Notification POST is accepted without a response body")
    func notificationAccepted() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()
        let body = try makePerRequestBody(id: nil, method: "notifications/example")

        let receiveTask = Task {
            var iterator = await transport.receive().makeAsyncIterator()
            return try await iterator.next()
        }
        let response = await transport.handleRequest(makePerRequestHTTPPost(body: body))

        #expect(response.statusCode == 202)
        #expect(response.bodyData == nil)
        #expect(try await receiveTask.value == body)
        await transport.disconnect()
    }

    @Test("Protocol header is required and must agree with request metadata")
    func protocolVersionValidation() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let body = try makePerRequestBody(id: .int(7))

        let missing = await transport.handleRequest(makePerRequestHTTPPost(
            body: body,
            protocolVersion: nil
        ))
        #expect(missing.statusCode == 400)
        #expect(try decodeResponseObject(missing)["id"]?.intValue == 7)
        #expect(try decodeResponseObject(missing)["error"]?.objectValue?["code"]?.intValue
            == ProtocolErrorCode.headerMismatch)

        let mismatch = await transport.handleRequest(makePerRequestHTTPPost(
            body: body,
            protocolVersion: "2025-11-25"
        ))
        #expect(mismatch.statusCode == 400)
        #expect(try decodeResponseObject(mismatch)["error"]?.objectValue?["code"]?.intValue
            == ProtocolErrorCode.headerMismatch)

        let withoutBodyVersion = try makePerRequestBody(protocolVersion: nil)
        let absentMetadata = await transport.handleRequest(makePerRequestHTTPPost(
            body: withoutBodyVersion
        ))
        #expect(absentMetadata.statusCode == 400)
        #expect(try decodeResponseObject(absentMetadata)["error"]?.objectValue?["code"]?.intValue
            == -32602)
    }

    @Test("Malformed required request metadata returns invalid params")
    func malformedRequiredMetadata() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let malformedMetadata: [Value] = [
            .string("not an object"),
            .object([
                ProtocolMetadataKey.protocolVersion: .int(2026),
                ProtocolMetadataKey.clientCapabilities: .object([:]),
            ]),
            .object([
                ProtocolMetadataKey.protocolVersion: .string(
                    Version.perRequestMetadataVersion),
                ProtocolMetadataKey.clientCapabilities: .string("not capabilities"),
            ]),
        ]

        for metadata in malformedMetadata {
            let body = try JSONEncoder().encode(Value.object([
                "jsonrpc": .string("2.0"),
                "id": .string("malformed-metadata"),
                "method": .string(Ping.name),
                "params": .object(["_meta": metadata]),
            ]))
            let response = await transport.handleRequest(makePerRequestHTTPPost(body: body))
            let object = try decodeResponseObject(response)

            #expect(response.statusCode == 400)
            #expect(object["id"]?.stringValue == "malformed-metadata")
            #expect(object["error"]?.objectValue?["code"]?.intValue == -32602)
        }
    }

    @Test("Unsupported version error advertises supported per-request versions")
    func unsupportedVersion() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let requested = "2099-01-01"
        let body = try makePerRequestBody(protocolVersion: requested)
        let response = await transport.handleRequest(makePerRequestHTTPPost(
            body: body,
            protocolVersion: requested
        ))

        let object = try decodeResponseObject(response)
        let error = try #require(object["error"]?.objectValue)
        #expect(response.statusCode == 400)
        #expect(error["code"]?.intValue == ProtocolErrorCode.unsupportedProtocolVersion)
        #expect(error["data"]?.objectValue?["requested"]?.stringValue == requested)
        #expect(error["data"]?.objectValue?["supported"]?.arrayValue
            == [.string(Version.perRequestMetadataVersion)])
    }

    @Test("Batch and JSON-RPC response bodies are rejected")
    func invalidBodyShapes() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let request = try makePerRequestBody()
        let batch = try JSONEncoder().encode(Value.array([
            try JSONDecoder().decode(Value.self, from: request)
        ]))
        let responseBody = try JSONEncoder().encode(Value.object([
            "jsonrpc": "2.0",
            "id": "response-1",
            "result": .object([:]),
        ]))

        let batchResponse = await transport.handleRequest(makePerRequestHTTPPost(body: batch))
        let clientResponse = await transport.handleRequest(makePerRequestHTTPPost(body: responseBody))

        #expect(batchResponse.statusCode == 400)
        #expect(clientResponse.statusCode == 400)
    }

    @Test("Default validation enforces Origin, Accept, and Content-Type")
    func defaultValidation() async throws {
        let transport = StreamableHTTPServerTransport()
        let body = try makePerRequestBody()
        let validHeaders = makePerRequestHTTPPost(body: body).headers

        var missingAcceptHeaders = validHeaders
        missingAcceptHeaders.removeValue(forKey: HTTPHeaderName.accept)
        let missingAccept = await transport.handleRequest(HTTPRequest(
            method: "POST", headers: missingAcceptHeaders, body: body
        ))

        var missingContentTypeHeaders = validHeaders
        missingContentTypeHeaders.removeValue(forKey: HTTPHeaderName.contentType)
        let missingContentType = await transport.handleRequest(HTTPRequest(
            method: "POST", headers: missingContentTypeHeaders, body: body
        ))

        var invalidOriginHeaders = validHeaders
        invalidOriginHeaders[HTTPHeaderName.origin] = "https://example.com"
        let invalidOrigin = await transport.handleRequest(HTTPRequest(
            method: "POST", headers: invalidOriginHeaders, body: body
        ))

        #expect(missingAccept.statusCode == 406)
        #expect(missingContentType.statusCode == 415)
        #expect(invalidOrigin.statusCode == 403)
    }

    @Test("A custom streamable origin keeps the rest of standard validation")
    func customOriginPreservesStandardValidation() async throws {
        let transport = StreamableHTTPServerTransport(
            originValidator: OriginValidator(
                allowedHosts: ["mcp.example.com"],
                allowedOrigins: ["https://app.example.com"]
            )
        )
        let body = try makePerRequestBody(id: nil, method: "notifications/example")
        let remoteHeaders = [
            HTTPHeaderName.host: "mcp.example.com",
            HTTPHeaderName.origin: "https://app.example.com",
        ]

        let invalidHost = await transport.handleRequest(makePerRequestHTTPPost(
            body: body,
            extraHeaders: remoteHeaders.merging([
                HTTPHeaderName.host: "attacker.example.com"
            ]) { _, new in new }
        ))
        let invalidOrigin = await transport.handleRequest(makePerRequestHTTPPost(
            body: body,
            extraHeaders: remoteHeaders.merging([
                HTTPHeaderName.origin: "https://attacker.example.com"
            ]) { _, new in new }
        ))
        let accepted = await transport.handleRequest(makePerRequestHTTPPost(
            body: body,
            extraHeaders: remoteHeaders
        ))
        let invalidAccept = await transport.handleRequest(makePerRequestHTTPPost(
            body: body,
            extraHeaders: remoteHeaders.merging([
                HTTPHeaderName.accept: ContentType.json
            ]) { _, new in new }
        ))
        let invalidContentType = await transport.handleRequest(makePerRequestHTTPPost(
            body: body,
            extraHeaders: remoteHeaders.merging([
                HTTPHeaderName.contentType: "text/plain"
            ]) { _, new in new }
        ))
        let olderBody = try makePerRequestBody(
            id: nil,
            method: "notifications/example",
            protocolVersion: Version.latestInitializationVersion
        )
        let invalidVersion = await transport.handleRequest(makePerRequestHTTPPost(
            body: olderBody,
            protocolVersion: Version.latestInitializationVersion,
            extraHeaders: remoteHeaders
        ))

        #expect(invalidHost.statusCode == 421)
        #expect(invalidOrigin.statusCode == 403)
        #expect(accepted.statusCode == 202)
        #expect(invalidAccept.statusCode == 406)
        #expect(invalidContentType.statusCode == 415)
        #expect(invalidVersion.statusCode == 400)
        #expect(try decodeResponseObject(invalidVersion)["error"]?
            .objectValue?["code"]?.intValue == ProtocolErrorCode.unsupportedProtocolVersion)
    }

    @Test("Server JSON-RPC requests cannot be sent on a request response")
    func serverRequestsRejected() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await transport.connect()
        let data = try JSONEncoder().encode(Ping.request(id: .string("server-request")))

        await #expect(throws: MCPError.self) {
            try await transport.send(data)
        }
        await transport.disconnect()
    }

    @Test("Direct response preserves request id, metadata, and HTTP context")
    func directResponse() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(HTTPServerProbe.self) { parameters in
            if parameters.delayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(parameters.delayMilliseconds))
            }
            let context = Server.currentHandlerContext
            return .init(
                value: parameters.value,
                lifecycle: context?.protocolLifecycle ?? .initializationBased,
                authorization: context?.httpContext?.header(HTTPHeaderName.authorization)
            )
        }
        try await server.start(transport: transport)

        let body = try makePerRequestBody(id: .int(42), value: "direct")
        let response = await transport.handleRequest(makePerRequestHTTPPost(
            body: body,
            authorization: "Bearer request-token",
            extraHeaders: [
                HTTPHeaderName.sessionID: "must-not-be-echoed",
                HTTPHeaderName.lastEventID: "must-be-ignored",
            ]
        ))
        let object = try decodeResponseObject(response)
        let result = try #require(object["result"]?.objectValue)

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeaderName.contentType] == "application/json")
        #expect(response.headers[HTTPHeaderName.sessionID] == nil)
        #expect(object["id"]?.intValue == 42)
        #expect(result["value"]?.stringValue == "direct")
        #expect(result["lifecycle"]?.stringValue == ProtocolLifecycle.perRequestMetadata.rawValue)
        #expect(result["authorization"]?.stringValue == "Bearer request-token")
        #expect(result["_meta"]?.objectValue?[ProtocolMetadataKey.serverInfo] != nil)
        #expect(await transport.httpRequestContext(for: .number(42)) == nil)

        await server.stop()
    }

    @Test("Unknown method uses HTTP 404 and retains the JSON-RPC id")
    func unknownMethod() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await server.start(transport: transport)

        let body = try makePerRequestBody(id: .string("unknown-1"), method: "missing/method")
        let response = await transport.handleRequest(makePerRequestHTTPPost(body: body))
        let object = try decodeResponseObject(response)

        #expect(response.statusCode == 404)
        #expect(object["id"]?.stringValue == "unknown-1")
        #expect(object["error"]?.objectValue?["code"]?.intValue == -32601)

        await server.stop()
    }

    @Test("Missing client capabilities are rejected through the HTTP response")
    func missingClientCapabilities() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(HTTPServerProbe.self) { parameters in
            .init(
                value: parameters.value,
                lifecycle: .perRequestMetadata,
                authorization: nil
            )
        }
        try await server.start(transport: transport)

        let body = try makePerRequestBody(
            id: .string("missing-capabilities"),
            includeClientCapabilities: false
        )
        let response = await transport.handleRequest(makePerRequestHTTPPost(body: body))
        let object = try decodeResponseObject(response)

        #expect(response.statusCode == 400)
        #expect(object["id"]?.stringValue == "missing-capabilities")
        #expect(object["error"]?.objectValue?["code"]?.intValue == -32602)

        await server.stop()
    }

    @Test("Configured tool definitions activate schema-derived header validation")
    func schemaDerivedHeaderValidation() async throws {
        let tool = Tool(
            name: "weather",
            description: nil,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "region": .object([
                        "type": "string",
                        "x-mcp-header": "Region",
                    ])
                ]),
            ])
        )
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(CallTool.self) { _ in
            .init(content: [])
        }
        try await server.start(transport: transport)
        try await transport.updateTools([tool])

        func body(id: String, method: String, parameters: [String: Value]) throws -> Data {
            var parameters = parameters
            parameters["_meta"] = .object([
                ProtocolMetadataKey.protocolVersion: .string(
                    Version.perRequestMetadataVersion),
                ProtocolMetadataKey.clientCapabilities: .object([:]),
                ProtocolMetadataKey.clientInfo: .object([
                    "name": "Header client",
                    "version": "1.0",
                ]),
            ])
            return try JSONEncoder().encode(Value.object([
                "jsonrpc": "2.0",
                "id": .string(id),
                "method": .string(method),
                "params": .object(parameters),
            ]))
        }

        let callBody = try body(
            id: "call-missing",
            method: CallTool.name,
            parameters: [
                "name": "weather",
                "arguments": .object(["region": "us-west1"]),
            ]
        )
        let missing = await transport.handleRequest(makePerRequestHTTPPost(body: callBody))
        #expect(missing.statusCode == 400)
        #expect(try decodeResponseObject(missing)["error"]?.objectValue?["code"]?.intValue
            == ProtocolErrorCode.headerMismatch)

        let plan = try ToolHeaderPlan(tool: tool)
        let customHeaders = try MCPHTTPHeaders.requestHeaders(
            for: callBody,
            toolPlans: [tool.name: plan]
        )
        let validBody = try body(
            id: "call-valid",
            method: CallTool.name,
            parameters: [
                "name": "weather",
                "arguments": .object(["region": "us-west1"]),
            ]
        )
        let valid = await transport.handleRequest(makePerRequestHTTPPost(
            body: validBody,
            extraHeaders: customHeaders
        ))
        #expect(valid.statusCode == 200)

        await server.stop()
    }

    @Test("Tool-list responses do not change server-wide header validation")
    func toolListDoesNotChangeValidation() async throws {
        let tool = Tool(
            name: "weather",
            description: nil,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "region": .object([
                        "type": "string",
                        "x-mcp-header": "Region",
                    ])
                ]),
            ])
        )
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: [tool]) }
        await server.withMethodHandler(CallTool.self) { _ in .init(content: []) }
        try await server.start(transport: transport)

        let list = await transport.handleRequest(makePerRequestHTTPPost(
            body: try makeProtocolRequestBody(
                id: "list-tools",
                method: ListTools.name,
                parameters: [:]
            )
        ))
        #expect(list.statusCode == 200)

        let call = await transport.handleRequest(makePerRequestHTTPPost(
            body: try makeProtocolRequestBody(
                id: "call-tool",
                method: CallTool.name,
                parameters: [
                    "name": "weather",
                    "arguments": .object(["region": "us-west1"]),
                ]
            )
        ))
        #expect(call.statusCode == 200)

        await server.stop()
    }

    @Test("Request-local tool schemas remain isolated across concurrent callers")
    func requestLocalToolSchemas() async throws {
        let regionTool = Tool(
            name: "weather",
            description: nil,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "region": .object([
                        "type": "string",
                        "x-mcp-header": "Region",
                    ])
                ]),
            ])
        )
        let tenantTool = Tool(
            name: "weather",
            description: nil,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "tenant": .object([
                        "type": "string",
                        "x-mcp-header": "Tenant",
                    ])
                ]),
            ])
        )
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: []),
            toolHeaderSchemaProvider: { _, request in
                request.header(HTTPHeaderName.authorization) == "Bearer region"
                    ? regionTool : tenantTool
            }
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(CallTool.self) { _ in .init(content: []) }
        try await server.start(transport: transport)

        func request(
            id: String,
            authorization: String,
            arguments: [String: Value],
            tool: Tool
        ) throws -> HTTPRequest {
            let body = try makeProtocolRequestBody(
                id: id,
                method: CallTool.name,
                parameters: [
                    "name": "weather",
                    "arguments": .object(arguments),
                ]
            )
            let headers = try MCPHTTPHeaders.requestHeaders(
                for: body,
                toolPlans: [tool.name: try ToolHeaderPlan(tool: tool)]
            )
            return makePerRequestHTTPPost(
                body: body,
                authorization: authorization,
                extraHeaders: headers
            )
        }

        let regionRequest = try request(
            id: "region",
            authorization: "Bearer region",
            arguments: ["region": "us-west1"],
            tool: regionTool
        )
        let tenantRequest = try request(
            id: "tenant",
            authorization: "Bearer tenant",
            arguments: ["tenant": "example"],
            tool: tenantTool
        )
        async let regionResponse = transport.handleRequest(regionRequest)
        async let tenantResponse = transport.handleRequest(tenantRequest)

        #expect(await regionResponse.statusCode == 200)
        #expect(await tenantResponse.statusCode == 200)

        let wrongSchema = await transport.handleRequest(try request(
            id: "wrong",
            authorization: "Bearer region",
            arguments: [
                "region": "us-west1",
                "tenant": "example",
            ],
            tool: tenantTool
        ))
        #expect(wrongSchema.statusCode == 400)

        await server.stop()
    }

    @Test("Related notification selects SSE and precedes the final response")
    func requestScopedSSE() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(HTTPServerProbe.self) { parameters in
            try await server.notify(HTTPServerProgressNotification.message(.init(step: 1)))
            return .init(
                value: parameters.value,
                lifecycle: .perRequestMetadata,
                authorization: nil
            )
        }
        try await server.start(transport: transport)

        let response = await transport.handleRequest(makePerRequestHTTPPost(
            body: try makePerRequestBody(id: .string("stream-1"), value: "streamed")
        ))
        guard case .stream(let stream, let headers) = response else {
            Issue.record("Expected an SSE response")
            await server.stop()
            return
        }
        var chunks: [Data] = []
        for try await chunk in stream { chunks.append(chunk) }

        #expect(headers[HTTPHeaderName.contentType] == "text/event-stream")
        #expect(headers[HTTPHeaderName.xAccelBuffering] == "no")
        #expect(chunks.count == 2)
        #expect(try decodeSSEObject(chunks[0])["method"]?.stringValue
            == HTTPServerProgressNotification.name)
        #expect(try decodeSSEObject(chunks[1])["id"]?.stringValue == "stream-1")
        #expect(String(decoding: chunks[0], as: UTF8.self).contains("id:") == false)

        await server.stop()
    }

    @Test("Subscription stream preserves the client id and closes gracefully")
    func subscriptionStream() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            capabilities: .init(tools: .init(listChanged: true)),
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        try await server.start(transport: transport)

        let requestID = ID.string("listen-http")
        let body = try makeSubscriptionBody(
            id: requestID,
            filter: .init(toolsListChanged: true)
        )
        let response = await transport.handleRequest(makePerRequestHTTPPost(body: body))
        guard case .stream(let stream, let headers) = response else {
            Issue.record("Expected a subscription SSE response")
            await server.stop()
            return
        }
        var iterator = stream.makeAsyncIterator()

        let acknowledgment = try decodeSSEObject(try #require(await iterator.next()))
        #expect(headers[HTTPHeaderName.contentType] == ContentType.sse)
        #expect(
            acknowledgment["method"]?.stringValue
                == SubscriptionsAcknowledgedNotification.name
        )
        #expect(
            acknowledgment["params"]?.objectValue?["_meta"]?
                .objectValue?[ProtocolMetadataKey.subscriptionID]?.stringValue
                == "listen-http"
        )

        try await server.notify(ToolListChangedNotification.message(.init()))
        let notification = try decodeSSEObject(try #require(await iterator.next()))
        #expect(notification["method"]?.stringValue == ToolListChangedNotification.name)
        #expect(
            notification["params"]?.objectValue?["_meta"]?
                .objectValue?[ProtocolMetadataKey.subscriptionID]?.stringValue
                == "listen-http"
        )

        let stopTask = Task { await server.stop() }
        let completion = try decodeSSEObject(try #require(await iterator.next()))
        #expect(completion["id"]?.stringValue == "listen-http")
        #expect(
            completion["result"]?.objectValue?["_meta"]?
                .objectValue?[ProtocolMetadataKey.subscriptionID]?.stringValue
                == "listen-http"
        )
        await stopTask.value
        #expect(try await iterator.next() == nil)
    }

    @Test("Concurrent clients may reuse an id and complete out of order")
    func concurrentOutOfOrderResponses() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(HTTPServerProbe.self) { parameters in
            try await Task.sleep(for: .milliseconds(parameters.delayMilliseconds))
            return .init(
                value: parameters.value,
                lifecycle: .perRequestMetadata,
                authorization: nil
            )
        }
        try await server.start(transport: transport)

        let slow = Task { await transport.handleRequest(makePerRequestHTTPPost(
            body: try! makePerRequestBody(
                id: .int(1), value: "slow", delayMilliseconds: 100)
        )) }
        let fast = Task { await transport.handleRequest(makePerRequestHTTPPost(
            body: try! makePerRequestBody(
                id: .int(1), value: "fast", delayMilliseconds: 5)
        )) }

        let fastResponse = await fast.value
        let fastObject = try decodeResponseObject(fastResponse)
        #expect(fastObject["id"]?.intValue == 1)
        #expect(fastObject["result"]?.objectValue?["value"]?.stringValue == "fast")
        #expect(!slow.isCancelled)
        let slowResponse = await slow.value
        let slowObject = try decodeResponseObject(slowResponse)
        #expect(slowObject["id"]?.intValue == 1)
        #expect(slowObject["result"]?.objectValue?["value"]?.stringValue == "slow")

        await server.stop()
    }

    @Test("Cancellation before response headers stops server work")
    func cancellationBeforeHeaders() async throws {
        let probe = HTTPServerCancellationProbe()
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(HTTPServerProbe.self) { parameters in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError {
                await probe.markCancelled()
                throw CancellationError()
            }
            return .init(
                value: parameters.value,
                lifecycle: .perRequestMetadata,
                authorization: nil
            )
        }
        try await server.start(transport: transport)

        let responseTask = Task { await transport.handleRequest(makePerRequestHTTPPost(
            body: try! makePerRequestBody(id: .string("cancel-before"))
        )) }
        try await waitUntil { await probe.started }
        responseTask.cancel()
        let cancelledResponse = await responseTask.value
        try await waitUntil { await probe.cancelled }

        #expect(cancelledResponse.bodyData == nil)
        #expect(await probe.cancelled)
        #expect(await transport.httpRequestContext(for: .string("cancel-before")) == nil)
        await server.stop()
    }

    @Test("Closing an SSE stream cancels work and prevents a final response")
    func cancellationDuringStreaming() async throws {
        let probe = HTTPServerCancellationProbe()
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "HTTP server",
            version: "1.0",
            configuration: .init(protocolMode: .perRequestMetadataOnly)
        )
        await server.withMethodHandler(HTTPServerProbe.self) { parameters in
            await probe.markStarted()
            try await server.notify(HTTPServerProgressNotification.message(.init(step: 1)))
            do {
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError {
                await probe.markCancelled()
                throw CancellationError()
            }
            return .init(
                value: parameters.value,
                lifecycle: .perRequestMetadata,
                authorization: nil
            )
        }
        try await server.start(transport: transport)

        let response = await transport.handleRequest(makePerRequestHTTPPost(
            body: try makePerRequestBody(id: .string("cancel-stream"))
        ))
        let stream = try #require({
            if case .stream(let stream, _) = response { return stream }
            return nil
        }())
        let consumer = Task { () throws -> [Data] in
            var chunks: [Data] = []
            for try await chunk in stream { chunks.append(chunk) }
            return chunks
        }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        let chunks = (try? await consumer.value) ?? []
        try await waitUntil { await probe.cancelled }

        #expect(chunks.count <= 1)
        #expect(await probe.cancelled)
        #expect(await transport.httpRequestContext(for: .string("cancel-stream")) == nil)
        await server.stop()
    }
}
