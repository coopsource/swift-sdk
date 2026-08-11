import Foundation
import Testing

@testable import MCP

private func makeHeaderTool(
    name: String = "header-tool",
    properties: [String: Value],
    additionalSchema: [String: Value] = [:]
) -> Tool {
    var schema: [String: Value] = [
        "type": "object",
        "properties": .object(properties),
    ]
    schema.merge(additionalSchema) { _, new in new }
    return Tool(
        name: name,
        description: nil,
        inputSchema: .object(schema)
    )
}

private func makeHeaderCall(
    id: Value = .int(1),
    toolName: String = "header-tool",
    arguments: [String: Value]
) throws -> Data {
    try JSONEncoder().encode(Value.object([
        "jsonrpc": "2.0",
        "id": id,
        "method": .string(CallTool.name),
        "params": .object([
            "name": .string(toolName),
            "arguments": .object(arguments),
            "_meta": .object([
                ProtocolMetadataKey.protocolVersion: .string(
                    Version.perRequestMetadataVersion),
                ProtocolMetadataKey.clientCapabilities: .object([:]),
            ]),
        ]),
    ]))
}

private func makeHeaderHTTPRequest(
    body: Data,
    generatedHeaders: [String: String]
) -> HTTPRequest {
    var headers = [
        HTTPHeaderName.accept: "application/json, text/event-stream",
        HTTPHeaderName.contentType: "application/json",
        HTTPHeaderName.protocolVersion: Version.perRequestMetadataVersion,
    ]
    headers.merge(generatedHeaders) { _, new in new }
    return HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp")
}

@Suite("MCP 2026-07-28 HTTP request headers")
struct HTTPHeaderMetadataTests {
    @Test("Standard and schema-derived headers use exact value encoding")
    func exactEncoding() throws {
        let toolName = "header 世界"
        let tool = makeHeaderTool(name: toolName, properties: [
            "region": .object(["type": "string", "x-mcp-header": "Region"]),
            "greeting": .object(["type": "string", "x-mcp-header": "Greeting"]),
            "padded": .object(["type": "string", "x-mcp-header": "Padded"]),
            "newline": .object(["type": "string", "x-mcp-header": "Newline"]),
            "sentinel": .object(["type": "string", "x-mcp-header": "Sentinel"]),
            "count": .object(["type": "integer", "x-mcp-header": "Count"]),
            "enabled": .object(["type": "boolean", "x-mcp-header": "Enabled"]),
        ])
        let plan = try ToolHeaderPlan(tool: tool)
        let body = try makeHeaderCall(toolName: toolName, arguments: [
            "region": "us-west1",
            "greeting": "Hello, 世界",
            "padded": " padded ",
            "newline": "line1\nline2",
            "sentinel": "=?base64?literal?=",
            "count": 42,
            "enabled": true,
        ])

        let headers = try MCPHTTPHeaders.requestHeaders(
            for: body,
            toolPlans: [toolName: plan]
        )

        #expect(headers[HTTPHeaderName.mcpMethod] == CallTool.name)
        #expect(headers[HTTPHeaderName.mcpName] == "=?base64?aGVhZGVyIOS4lueVjA==?=")
        #expect(headers["Mcp-Param-Region"] == "us-west1")
        #expect(headers["Mcp-Param-Greeting"] == "=?base64?SGVsbG8sIOS4lueVjA==?=")
        #expect(headers["Mcp-Param-Padded"] == "=?base64?IHBhZGRlZCA=?=")
        #expect(headers["Mcp-Param-Newline"] == "=?base64?bGluZTEKbGluZTI=?=")
        #expect(headers["Mcp-Param-Sentinel"]
            == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
        #expect(headers["Mcp-Param-Count"] == "42")
        #expect(headers["Mcp-Param-Enabled"] == "true")
    }

    @Test("Nested properties are reached only through object properties")
    func nestedProperties() throws {
        let tool = makeHeaderTool(properties: [
            "routing": .object([
                "type": "object",
                "properties": .object([
                    "tenant": .object([
                        "type": "string",
                        "x-mcp-header": "Tenant",
                    ])
                ]),
            ])
        ])
        let plan = try ToolHeaderPlan(tool: tool)
        let body = try makeHeaderCall(arguments: [
            "routing": .object(["tenant": "alpha"])
        ])
        let headers = try MCPHTTPHeaders.requestHeaders(
            for: body,
            toolPlans: [tool.name: plan]
        )

        #expect(plan.fields.count == 1)
        #expect(plan.fields[0].propertyPath == ["routing", "tenant"])
        #expect(headers["Mcp-Param-Tenant"] == "alpha")
    }

    @Test("Mcp-Name mirrors prompt names and resource URIs")
    func standardNameSources() throws {
        let cases: [(method: String, key: String, value: String)] = [
            (GetPrompt.name, "name", "daily-summary"),
            (ReadResource.name, "uri", "file:///project/config.json"),
        ]

        for item in cases {
            let body = try JSONEncoder().encode(Value.object([
                "jsonrpc": "2.0",
                "id": 1,
                "method": .string(item.method),
                "params": .object([item.key: .string(item.value)]),
            ]))
            let headers = try MCPHTTPHeaders.requestHeaders(for: body, toolPlans: [:])
            #expect(headers[HTTPHeaderName.mcpMethod] == item.method)
            #expect(headers[HTTPHeaderName.mcpName] == item.value)
        }
    }

    @Test("Invalid header annotations reject only their tool definition")
    func invalidAnnotations() async throws {
        let valid = makeHeaderTool(name: "valid", properties: [
            "region": .object(["type": "string", "x-mcp-header": "Region"])
        ])
        let unannotated = Tool(
            name: "unannotated",
            description: nil,
            inputSchema: .object(["properties": .object([:])])
        )
        let invalid = [
            makeHeaderTool(name: "empty", properties: [
                "value": .object(["type": "string", "x-mcp-header": ""])
            ]),
            makeHeaderTool(name: "bad-token", properties: [
                "value": .object(["type": "string", "x-mcp-header": "Bad Header"])
            ]),
            makeHeaderTool(name: "number", properties: [
                "value": .object(["type": "number", "x-mcp-header": "Value"])
            ]),
            makeHeaderTool(name: "duplicate", properties: [
                "one": .object(["type": "string", "x-mcp-header": "Tenant"]),
                "two": .object(["type": "string", "x-mcp-header": "tenant"]),
            ]),
            makeHeaderTool(
                name: "array",
                properties: [
                    "values": .object([
                        "type": "array",
                        "items": .object([
                            "type": "string",
                            "x-mcp-header": "Value",
                        ]),
                    ])
                ]
            ),
            makeHeaderTool(
                name: "composition",
                properties: [:],
                additionalSchema: [
                    "oneOf": .array([
                        .object([
                            "type": "object",
                            "properties": .object([
                                "value": .object([
                                    "type": "string",
                                    "x-mcp-header": "Value",
                                ])
                            ]),
                        ])
                    ])
                ]
            ),
        ]

        for tool in invalid {
            #expect(throws: MCPError.self) {
                _ = try ToolHeaderPlan(tool: tool)
            }
        }

        let transport = HTTPClientTransport(
            endpoint: URL(string: "https://localhost/mcp")!
        )
        let accepted = await transport.updateToolHeaderSchemas(
            [valid, unannotated] + invalid,
            replacing: true
        )
        #expect(accepted.map(\.name) == ["valid", "unannotated"])
        #expect(await transport.toolHeaderPlan(named: "valid") != nil)
        #expect(await transport.toolHeaderPlan(named: "number") == nil)
    }

    @Test("Absent and null parameters omit custom headers")
    func absentAndNullValues() throws {
        let tool = makeHeaderTool(properties: [
            "optional": .object(["type": "string", "x-mcp-header": "Optional"])
        ])
        let plan = try ToolHeaderPlan(tool: tool)

        for arguments: [String: Value] in [[:], ["optional": .null]] {
            let headers = try MCPHTTPHeaders.requestHeaders(
                for: makeHeaderCall(arguments: arguments),
                toolPlans: [tool.name: plan]
            )
            #expect(headers["Mcp-Param-Optional"] == nil)
        }
    }

    @Test("Integers outside the IEEE 754 safe range are rejected")
    func unsafeInteger() throws {
        let tool = makeHeaderTool(properties: [
            "count": .object(["type": "integer", "x-mcp-header": "Count"])
        ])
        let plan = try ToolHeaderPlan(tool: tool)
        let body = try makeHeaderCall(arguments: ["count": .int(9_007_199_254_740_992)])

        #expect(throws: MCPError.self) {
            _ = try MCPHTTPHeaders.requestHeaders(
                for: body,
                toolPlans: [tool.name: plan]
            )
        }
    }

    @Test("Server comparison decodes names and compares integers numerically")
    func serverComparison() throws {
        let tool = makeHeaderTool(properties: [
            "count": .object(["type": "integer", "x-mcp-header": "Count"])
        ])
        let plan = try ToolHeaderPlan(tool: tool)
        let body = try makeHeaderCall(arguments: ["count": 42])
        var headers = try MCPHTTPHeaders.requestHeaders(
            for: body,
            toolPlans: [tool.name: plan]
        )
        headers["Mcp-Param-Count"] = "42.0"
        let request = makeHeaderHTTPRequest(body: body, generatedHeaders: headers)

        #expect(MCPHTTPHeaders.validationFailure(
            for: request,
            toolPlans: [tool.name: plan]
        ) == nil)

        headers["Mcp-Param-Count"] = "43"
        #expect(MCPHTTPHeaders.validationFailure(
            for: makeHeaderHTTPRequest(body: body, generatedHeaders: headers),
            toolPlans: [tool.name: plan]
        )?.contains("Mcp-Param-Count") == true)
    }

    @Test("Header names compare without case but values remain case-sensitive")
    func headerCaseSensitivity() throws {
        let body = try makeHeaderCall(arguments: [:])
        let generated = try MCPHTTPHeaders.requestHeaders(for: body, toolPlans: [:])
        var headers = [
            "mcp-method": generated[HTTPHeaderName.mcpMethod]!,
            "MCP-NAME": generated[HTTPHeaderName.mcpName]!,
        ]
        #expect(MCPHTTPHeaders.validationFailure(
            for: makeHeaderHTTPRequest(body: body, generatedHeaders: headers),
            toolPlans: [:]
        ) == nil)

        headers["mcp-method"] = CallTool.name.uppercased()
        #expect(MCPHTTPHeaders.validationFailure(
            for: makeHeaderHTTPRequest(body: body, generatedHeaders: headers),
            toolPlans: [:]
        )?.contains("Mcp-Method") == true)
    }

    @Test("Server comparison ignores HTTP optional whitespace around values")
    func headerOptionalWhitespace() throws {
        let body = try makeHeaderCall(arguments: [:])
        let generated = try MCPHTTPHeaders.requestHeaders(for: body, toolPlans: [:])
        let headers = generated.mapValues { " \t\($0)\t " }

        #expect(MCPHTTPHeaders.validationFailure(
            for: makeHeaderHTTPRequest(body: body, generatedHeaders: headers),
            toolPlans: [:]
        ) == nil)
    }

    @Test("Required standard headers fail with HeaderMismatch and preserve the request id")
    func standardHeaderError() async throws {
        let transport = StreamableHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let body = try makeHeaderCall(id: .string("header-error"), arguments: [:])
        let response = await transport.handleRequest(makeHeaderHTTPRequest(
            body: body,
            generatedHeaders: [HTTPHeaderName.mcpName: "header-tool"]
        ))
        let responseBody = try #require(response.bodyData)
        let decoded = try JSONDecoder().decode(Value.self, from: responseBody)
        let object = try #require(decoded.objectValue)

        #expect(response.statusCode == 400)
        #expect(object["id"]?.stringValue == "header-error")
        #expect(object["error"]?.objectValue?["code"]?.intValue
            == ProtocolErrorCode.headerMismatch)
    }

    @Test("Official HeaderMismatch fixture decodes as the structured protocol error")
    func officialFixture() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent(
            "Fixtures/2026-07-28/header-mismatch.json")
        let response = try JSONDecoder().decode(AnyResponse.self, from: Data(contentsOf: url))
        guard case .failure(let error) = response.result else {
            Issue.record("Expected HeaderMismatch error fixture")
            return
        }
        #expect(response.id == 1)
        #expect(error.code == ProtocolErrorCode.headerMismatch)
    }
}
