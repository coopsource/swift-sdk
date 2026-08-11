import Testing

import MCP

@Suite("MCP public API compatibility")
struct PublicAPICompatibilityTests {
    @Test("Existing resource-link construction keeps trailing defaults")
    func resourceLinkConstruction() {
        let tool = Tool.Content.resourceLink(
            uri: "file:///tool.txt",
            name: "tool.txt",
            title: nil,
            description: nil,
            mimeType: "text/plain",
            annotations: nil
        )
        let prompt = Prompt.Message.Content.resourceLink(
            uri: "file:///prompt.txt",
            name: "prompt.txt",
            title: nil,
            description: nil,
            mimeType: "text/plain",
            annotations: nil
        )
        let sampling = Sampling.ToolResultContent.ContentBlock.resourceLink(
            uri: "file:///sampling.txt",
            name: "sampling.txt",
            title: nil,
            description: nil,
            mimeType: "text/plain",
            annotations: nil
        )

        #expect(resourceLinkName(tool) == "tool.txt")
        #expect(promptResourceLinkName(prompt) == "prompt.txt")
        #expect(samplingResourceLinkName(sampling) == "sampling.txt")
    }

    @Test("Remote errors remain distinguishable through the public API")
    func remoteError() {
        let error = MCPError.remote(code: -32_022, message: "Unsupported", data: nil)
        #expect(remoteErrorCode(error) == -32_022)
    }

    private func resourceLinkName(_ content: Tool.Content) -> String? {
        switch content {
        case .resourceLink(_, let name, _, _, _, _, _, _, _): name
        default: nil
        }
    }

    private func promptResourceLinkName(_ content: Prompt.Message.Content) -> String? {
        switch content {
        case .resourceLink(_, let name, _, _, _, _, _, _, _): name
        default: nil
        }
    }

    private func samplingResourceLinkName(
        _ content: Sampling.ToolResultContent.ContentBlock
    ) -> String? {
        switch content {
        case .resourceLink(_, let name, _, _, _, _, _, _, _): name
        default: nil
        }
    }

    private func remoteErrorCode(_ error: MCPError) -> Int? {
        switch error {
        case .remote(let code, _, _): code
        case .parseError,
            .invalidRequest,
            .methodNotFound,
            .invalidParams,
            .internalError,
            .serverError,
            .urlElicitationRequired,
            .connectionClosed,
            .transportError:
            nil
        @unknown default: nil
        }
    }
}
