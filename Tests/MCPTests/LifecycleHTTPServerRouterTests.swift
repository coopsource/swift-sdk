import Foundation
import Testing

@testable import MCP

private enum LifecycleRouterProbe: MCP.Method {
    static let name = "test/lifecycle-router"

    struct Parameters: Hashable, Codable, Sendable {
        let value: String
    }

    struct Result: Hashable, Codable, Sendable {
        let value: String
        let lifecycle: ProtocolLifecycle
    }
}

private actor InitializationRouteRecorder {
    private(set) var requests: [HTTPRequest] = []

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        requests.append(request)
        return .data(
            Data(#"{"lifecycle":"initializationBased"}"#.utf8),
            headers: [HTTPHeaderName.contentType: "application/json"]
        )
    }

    var count: Int { requests.count }
}

private func makeRouterBody(
    id: Value = .string("router-request"),
    method: String = LifecycleRouterProbe.name,
    protocolVersion: String? = Version.perRequestMetadataVersion,
    includeClientCapabilities: Bool = true
) throws -> Data {
    var metadata: [String: Value] = [
        ProtocolMetadataKey.clientInfo: .object([
            "name": "Router test client",
            "version": "1.0",
        ])
    ]
    if let protocolVersion {
        metadata[ProtocolMetadataKey.protocolVersion] = .string(protocolVersion)
    }
    if includeClientCapabilities {
        metadata[ProtocolMetadataKey.clientCapabilities] = .object([:])
    }

    return try JSONEncoder().encode(Value.object([
        "jsonrpc": "2.0",
        "id": id,
        "method": .string(method),
        "params": .object([
            "value": "per-request",
            "_meta": .object(metadata),
        ]),
    ]))
}

private func makeRouterRequest(
    body: Data,
    protocolVersion: String? = Version.perRequestMetadataVersion,
    sessionID: String? = nil,
    method: String = "POST"
) -> HTTPRequest {
    var headers = [
        HTTPHeaderName.accept: "application/json, text/event-stream",
        HTTPHeaderName.contentType: "application/json",
    ]
    if let protocolVersion {
        headers[HTTPHeaderName.protocolVersion] = protocolVersion
    }
    if let sessionID {
        headers[HTTPHeaderName.sessionID] = sessionID
    }
    if let generated = try? MCPHTTPHeaders.requestHeaders(for: body, toolPlans: [:]) {
        headers.merge(generated) { _, new in new }
    }
    return HTTPRequest(method: method, headers: headers, body: body, path: "/mcp")
}

private func makeInitializationBody(id: Int = 1) throws -> Data {
    try JSONEncoder().encode(Value.object([
        "jsonrpc": "2.0",
        "id": .int(id),
        "method": "initialize",
        "params": .object([
            "protocolVersion": .string(Version.latestInitializationVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": "Old client", "version": "1.0"]),
        ]),
    ]))
}

private func makeRouter(
    mode: Server.ProtocolMode = .initializationAndPerRequestMetadata,
    recorder: InitializationRouteRecorder
) async throws -> (LifecycleHTTPServerRouter, StreamableHTTPServerTransport, Server) {
    let transport = StreamableHTTPServerTransport(
        validationPipeline: StandardValidationPipeline(validators: [])
    )
    let server = Server(
        name: "Router test server",
        version: "1.0",
        configuration: .init(protocolMode: .perRequestMetadataOnly)
    )
    await server.withMethodHandler(LifecycleRouterProbe.self) { parameters in
        .init(value: parameters.value, lifecycle: .perRequestMetadata)
    }
    try await server.start(transport: transport)

    let router = LifecycleHTTPServerRouter(
        protocolMode: mode,
        perRequestMetadataTransport: transport,
        initializationBasedRequestHandler: { request in
            await recorder.handle(request)
        }
    )
    return (router, transport, server)
}

private func routerResponseObject(_ response: HTTPResponse) throws -> [String: Value] {
    let body = try #require(response.bodyData)
    return try #require(JSONDecoder().decode(Value.self, from: body).objectValue)
}

@Suite("MCP HTTP lifecycle routing", .timeLimit(.minutes(1)))
struct LifecycleHTTPServerRouterTests {
    @Test("Per-request metadata and initialize openings use separate server paths")
    func openingMechanismSelectsLifecycle() async throws {
        let recorder = InitializationRouteRecorder()
        let (router, _, server) = try await makeRouter(recorder: recorder)

        let perRequestResponse = await router.handleRequest(makeRouterRequest(
            body: try makeRouterBody()
        ))
        let perRequestObject = try routerResponseObject(perRequestResponse)
        #expect(perRequestResponse.statusCode == 200)
        #expect(perRequestObject["result"]?.objectValue?["lifecycle"]?.stringValue
            == ProtocolLifecycle.perRequestMetadata.rawValue)
        #expect(await recorder.count == 0)

        let initializationResponse = await router.handleRequest(makeRouterRequest(
            body: try makeInitializationBody(),
            protocolVersion: nil
        ))
        #expect(initializationResponse.statusCode == 200)
        #expect(await recorder.count == 1)

        await server.stop()
    }

    @Test("Per-request metadata takes precedence over an old session header")
    func metadataTakesPrecedenceOverSession() async throws {
        let recorder = InitializationRouteRecorder()
        let (router, _, server) = try await makeRouter(recorder: recorder)

        let response = await router.handleRequest(makeRouterRequest(
            body: try makeRouterBody(id: .int(12)),
            sessionID: "old-session"
        ))
        let object = try routerResponseObject(response)

        #expect(response.statusCode == 200)
        #expect(object["id"]?.intValue == 12)
        #expect(response.headers[HTTPHeaderName.sessionID] == nil)
        #expect(await recorder.count == 0)

        await server.stop()
    }

    @Test("Lifecycle metadata on initialize does not create an old session")
    func metadataOnInitializeUsesPerRequestPath() async throws {
        let recorder = InitializationRouteRecorder()
        let (router, _, server) = try await makeRouter(recorder: recorder)

        let response = await router.handleRequest(makeRouterRequest(
            body: try makeRouterBody(
                id: .string("metadata-initialize"),
                method: Initialize.name
            )
        ))
        let object = try routerResponseObject(response)

        #expect(response.statusCode == 404)
        #expect(object["id"]?.stringValue == "metadata-initialize")
        #expect(object["error"]?.objectValue?["code"]?.intValue == -32601)
        #expect(await recorder.count == 0)

        await server.stop()
    }

    @Test("Malformed per-request openings do not fall back to session routing")
    func malformedPerRequestOpeningDoesNotFallBack() async throws {
        let recorder = InitializationRouteRecorder()
        let (router, _, server) = try await makeRouter(recorder: recorder)

        let metadataWithoutHeader = await router.handleRequest(makeRouterRequest(
            body: try makeRouterBody(),
            protocolVersion: nil
        ))

        let bodyWithoutMetadata = try JSONEncoder().encode(Value.object([
            "jsonrpc": "2.0",
            "id": "missing-metadata",
            "method": .string(LifecycleRouterProbe.name),
            "params": .object(["value": "missing"]),
        ]))
        let headerWithoutMetadata = await router.handleRequest(makeRouterRequest(
            body: bodyWithoutMetadata
        ))

        #expect(metadataWithoutHeader.statusCode == 400)
        #expect(try routerResponseObject(metadataWithoutHeader)["error"]?
            .objectValue?["code"]?.intValue == ProtocolErrorCode.headerMismatch)
        #expect(headerWithoutMetadata.statusCode == 400)
        #expect(try routerResponseObject(headerWithoutMetadata)["error"]?
            .objectValue?["code"]?.intValue == -32602)
        #expect(await recorder.count == 0)

        await server.stop()
    }

    @Test("Unknown per-request version reaches structured protocol validation")
    func unknownVersionDoesNotFallBack() async throws {
        let recorder = InitializationRouteRecorder()
        let (router, _, server) = try await makeRouter(recorder: recorder)
        let unknownVersion = "2099-01-01"

        let response = await router.handleRequest(makeRouterRequest(
            body: try makeRouterBody(protocolVersion: unknownVersion),
            protocolVersion: unknownVersion
        ))
        let error = try #require(routerResponseObject(response)["error"]?.objectValue)

        #expect(response.statusCode == 400)
        #expect(error["code"]?.intValue == ProtocolErrorCode.unsupportedProtocolVersion)
        #expect(error["data"]?.objectValue?["requested"]?.stringValue == unknownVersion)
        #expect(await recorder.count == 0)

        await server.stop()
    }

    @Test("Known initialization headers and session methods remain initialization based")
    func initializationTrafficRemainsOnSessionPath() async throws {
        let recorder = InitializationRouteRecorder()
        let (router, _, server) = try await makeRouter(recorder: recorder)
        let body = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8)

        let post = await router.handleRequest(makeRouterRequest(
            body: body,
            protocolVersion: Version.latestInitializationVersion,
            sessionID: "session-1"
        ))
        let get = await router.handleRequest(HTTPRequest(
            method: "GET",
            headers: [HTTPHeaderName.sessionID: "session-1"]
        ))

        #expect(post.statusCode == 200)
        #expect(get.statusCode == 200)
        #expect(await recorder.count == 2)

        await server.stop()
    }

    @Test("An established session takes precedence over conflicting version headers")
    func sessionTakesPrecedenceOverVersionHeader() async throws {
        let recorder = InitializationRouteRecorder()
        let (router, _, server) = try await makeRouter(recorder: recorder)
        let body = Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#.utf8)

        let get = await router.handleRequest(HTTPRequest(
            method: "GET",
            headers: [
                HTTPHeaderName.protocolVersion: Version.perRequestMetadataVersion,
                HTTPHeaderName.sessionID: "session-1",
            ]
        ))
        let delete = await router.handleRequest(HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeaderName.protocolVersion: "2099-01-01",
                HTTPHeaderName.sessionID: "session-1",
            ]
        ))
        let post = await router.handleRequest(makeRouterRequest(
            body: body,
            protocolVersion: "2099-01-01",
            sessionID: "session-1"
        ))

        #expect(get.statusCode == 200)
        #expect(delete.statusCode == 200)
        #expect(post.statusCode == 200)
        #expect(await recorder.count == 3)

        await server.stop()
    }

    @Test("An empty session header does not claim an initialization session")
    func emptySessionDoesNotTakePrecedence() async throws {
        let recorder = InitializationRouteRecorder()
        let (router, _, server) = try await makeRouter(recorder: recorder)
        let body = Data(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}"#.utf8
        )

        let response = await router.handleRequest(makeRouterRequest(
            body: body,
            protocolVersion: "2099-01-01",
            sessionID: ""
        ))

        #expect(response.statusCode == 400)
        #expect(try routerResponseObject(response)["error"]?
            .objectValue?["code"]?.intValue == -32602)
        #expect(await recorder.count == 0)

        await server.stop()
    }

    @Test("Protocol mode can isolate either HTTP lifecycle")
    func protocolModesIsolateLifecycles() async throws {
        let initializationRecorder = InitializationRouteRecorder()
        let (initializationRouter, _, initializationServer) = try await makeRouter(
            mode: .initializationOnly,
            recorder: initializationRecorder
        )
        let perRequestRequest = makeRouterRequest(body: try makeRouterBody())
        let initializationResponse = await initializationRouter.handleRequest(perRequestRequest)

        #expect(initializationResponse.statusCode == 200)
        #expect(await initializationRecorder.count == 1)
        await initializationServer.stop()

        let perRequestRecorder = InitializationRouteRecorder()
        let (perRequestRouter, _, perRequestServer) = try await makeRouter(
            mode: .perRequestMetadataOnly,
            recorder: perRequestRecorder
        )
        let oldOpening = await perRequestRouter.handleRequest(makeRouterRequest(
            body: try makeInitializationBody(),
            protocolVersion: nil
        ))

        #expect(oldOpening.statusCode == 400)
        #expect(await perRequestRecorder.count == 0)
        await perRequestServer.stop()
    }
}
