import Foundation
import Testing

@testable import MCP

@Suite("MCP 2026-07-28 wire models")
struct Protocol20260728Tests {
    @Test("Version is known without changing supported lifecycle behavior")
    func versionSupport() {
        #expect(Version.perRequestMetadataVersion == "2026-07-28")
        #expect(!Version.supported.contains("2026-07-28"))
        #expect(Version.latest == "2025-11-25")
        #expect(Version.latestInitializationVersion == "2025-11-25")
        #expect(Version.preferenceOrder.first == "2026-07-28")
    }

    @Test("Official discovery fixture decodes")
    func discoveryFixture() throws {
        let result = try JSONDecoder().decode(
            Discover.Result.self,
            from: try fixture(named: "discover-result")
        )

        #expect(result.resultType == .complete)
        #expect(result.supportedVersions == ["2026-07-28"])
        #expect(result.capabilities.tools != nil)
        #expect(result.capabilities.resources != nil)
        #expect(result.ttlMs == 3_600_000)
        #expect(result.cacheScope == .public)
        #expect(
            result._meta?[ProtocolMetadataKey.serverInfo]?.objectValue?["name"]
                == .string("ExampleServer")
        )
    }

    @Test("Structured protocol error data is preserved")
    func structuredErrorData() throws {
        let response = try JSONDecoder().decode(
            Response<Ping>.self,
            from: try fixture(named: "unsupported-version")
        )

        guard case .failure(
            .remote(
                code: ProtocolErrorCode.unsupportedProtocolVersion,
                message: "Unsupported protocol version",
                data: let data
            )
        ) = response.result else {
            Issue.record("Expected a structured unsupported-version error")
            return
        }

        #expect(data?.objectValue?["requested"] == .string("1900-01-01"))
        #expect(
            data?.objectValue?["supported"]
                == .array([.string("2026-07-28"), .string("2025-11-25")])
        )
    }

    @Test("Capability extension settings retain JSON objects")
    func extensionSettings() throws {
        let capabilities = Client.Capabilities(
            experimental: [
                "com.example/feature": .object(["enabled": .bool(true)])
            ],
            extensions: [
                "io.modelcontextprotocol/ui": .object([
                    "mimeTypes": .array([.string("text/html;profile=mcp-app")])
                ])
            ]
        )

        let encoded = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(Client.Capabilities.self, from: encoded)
        #expect(decoded == capabilities)
    }

    @Test("Capability objects preserve settings and unknown capabilities")
    func capabilitySettings() throws {
        let capabilities = Client.Capabilities(
            sampling: .init(
                tools: .init(settings: ["formats": .array([.string("json")])])
            ),
            elicitation: .init(
                form: .init(settings: ["draft": .string("2020-12")])
            ),
            additionalCapabilities: [
                "com.example/custom": .object(["enabled": .bool(true)])
            ]
        )

        let data = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(Client.Capabilities.self, from: data)

        #expect(decoded == capabilities)
    }

    @Test("Capability maps require JSON-object values")
    func capabilityObjectValues() throws {
        let json = Data(
            #"{"experimental":{"com.example/feature":"enabled"},"extensions":{"com.example/extension":true}}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Client.Capabilities.self, from: json)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Server.Capabilities.self, from: json)
        }

        let invalid = Client.Capabilities(
            experimental: ["com.example/feature": .string("enabled")]
        )
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(invalid)
        }
    }

    @Test("Extension identifiers require a valid prefix")
    func extensionIdentifiers() throws {
        let invalid = Client.Capabilities(extensions: ["unprefixed": .object([:])])

        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(invalid)
        }

        let malformed = Data(#"{"extensions":{"com..example/feature":{}}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Client.Capabilities.self, from: malformed)
        }
    }

    @Test("Sampling tool results accept every JSON structured-content shape")
    func samplingToolResultStructuredContent() throws {
        let values: [Value] = [
            .object(["answer": .int(42)]),
            .array([.string("first"), .bool(true)]),
            .string("text"),
            .int(42),
            .double(4.2),
            .bool(false),
            .null,
        ]

        for value in values {
            let content = Sampling.Message.Content.ContentBlock.toolResult(
                .init(
                    toolUseId: "call-1",
                    content: [.text("result")],
                    structuredContent: value
                )
            )
            let encoded = try JSONEncoder().encode(content)
            let decoded = try JSONDecoder().decode(
                Sampling.Message.Content.ContentBlock.self,
                from: encoded
            )

            #expect(decoded == content)
        }
    }

    @Test("Tool results preserve explicit null structured content")
    func callToolResultNullStructuredContent() throws {
        let result = try JSONDecoder().decode(
            CallTool.Result.self,
            from: Data(#"{"content":[],"structuredContent":null}"#.utf8)
        )

        #expect(result.structuredContent == .null)
        let encoded = try JSONEncoder().encode(result)
        let object = try JSONDecoder().decode([String: Value].self, from: encoded)
        #expect(object["structuredContent"] == .null)
    }

    @Test("Official resource-link fixture remains compatible")
    func resourceLinkFixture() throws {
        let content = try JSONDecoder().decode(
            Tool.Content.self,
            from: try fixture(named: "resource-link")
        )

        guard case .resourceLink(
            let uri,
            let name,
            _,
            let description,
            let mimeType,
            _,
            let size,
            let icons,
            let metadata
        ) = content else {
            Issue.record("Expected resource-link content")
            return
        }

        #expect(uri == "file:///project/src/main.rs")
        #expect(name == "main.rs")
        #expect(description == "Primary application entry point")
        #expect(mimeType == "text/x-rust")
        #expect(size == nil)
        #expect(icons == nil)
        #expect(metadata == nil)
    }

    private func fixture(named name: String) throws -> Data {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try Data(
            contentsOf: testDirectory
                .appendingPathComponent("Fixtures/2026-07-28/\(name).json")
        )
    }
}
