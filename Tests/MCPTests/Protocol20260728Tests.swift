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
