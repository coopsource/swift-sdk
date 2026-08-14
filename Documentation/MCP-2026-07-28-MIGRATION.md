# Migrating to MCP 2026-07-28

This guide shows how to migrate a Swift MCP client and server to protocol version
`2026-07-28`. It uses the weather-service examples from the SDK README. The same approach
applies to existing tools, prompts, and resources.

The new revision changes the protocol lifecycle: version, identity, and capabilities travel
with every request instead of being established once by `initialize`. It also adds discovery,
multi-round-trip input, response caching, explicit notification subscriptions, structured
errors, and schema-derived HTTP headers. The SDK keeps the initialization-based versions
through `2025-11-25` available during migration.

> [!NOTE]
> The SDK adds no production dependency, platform requirement, or minimum Swift requirement.
> Its package manifest remains compatible with Swift 6.0.

## Choose a rollout mode

Newly constructed clients and servers preserve initialization-era wire behavior:

| Component | Default | Behavior |
|---|---|---|
| `Client` | `.initializationOnly` | Uses `initialize` and `notifications/initialized`. |
| `Server` | `.initializationOnly` | Accepts initialization-based clients. |

Use explicit modes to stage or A/B test the migration:

```swift
let initializationClient = Client(
    name: "WeatherClient",
    version: "1.0.0",
    configuration: .init(protocolMode: .initializationOnly)
)

let perRequestClient = Client(
    name: "WeatherClient",
    version: "1.0.0",
    configuration: .init(protocolMode: .perRequestMetadataOnly)
)

let automaticClient = Client(
    name: "WeatherClient",
    version: "1.0.0",
    configuration: .init(protocolMode: .automatic)
)

let compatibilityServer = Server(
    name: "WeatherServer",
    version: "1.0.0",
    configuration: .init(protocolMode: .initializationAndPerRequestMetadata)
)
```

`Client.ProtocolMode.automatic` is normally the safest client rollout. A server can start in
`.initializationOnly`, move to `.initializationAndPerRequestMetadata`, and later use
`.perRequestMetadataOnly` after its clients have migrated.

> [!IMPORTANT]
> Newly constructed configurations and configurations decoded without a `protocolMode` both use
> `.initializationOnly`. Upgrading the SDK therefore does not change an application's lifecycle
> until its configuration explicitly opts in.
>
> Decoding is deliberately more conservative than construction for the two 2026-only features:
> a `Client.Configuration` decoded without `multiRoundTripMode` or `responseCacheMode` disables
> them, while the memberwise initializer defaults to `.automatic(maxRounds: 8)` and
> `.enabled(maxEntries: 512)`. A configuration that was serialized before these keys existed
> therefore keeps its old behavior. Set the keys explicitly to opt a stored configuration in.

## Minimal client migration

To try `2026-07-28` and fall back to an initialization-based server, select `.automatic`.
Existing code using `connect(transport:)` remains valid:

```swift
import MCP

let client = Client(
    name: "WeatherClient",
    version: "1.0.0",
    configuration: .init(protocolMode: .automatic)
)
let transport = StdioTransport()

_ = try await client.connect(transport: transport)
let (content, isError) = try await client.callTool(
    name: "weather",
    arguments: [
        "location": .string("Seattle"),
        "units": .string("metric"),
    ]
)
```

`connect(transport:)` is a compatibility wrapper. Its established `Initialize.Result` return type
requires `serverInfo`, but a per-request-metadata server may omit its identity. In that case the
wrapper returns `unknown` and `0.0.0` as compatibility placeholders; they are not peer-reported
identity. New code should use `connectWithInfo` when lifecycle or server identity matters:

```swift
let connection = try await client.connectWithInfo(transport: transport)

print("Selected MCP \(connection.protocolVersion)")
switch connection.protocolLifecycle {
case .initializationBased:
    print("Using initialize and notifications/initialized")
case .perRequestMetadata:
    print("Using per-request version, identity, and capabilities")
}
```

Do not infer lifecycle from `Version.latest`. `ConnectionInfo` reports what was actually
selected for this connection and leaves `serverInfo` as `nil` when the server did not provide it.

## Minimal server migration

Existing method handlers can serve both lifecycles without changing their signatures:

```swift
import MCP

let server = Server(
    name: "WeatherServer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true)),
    configuration: .init(protocolMode: .initializationAndPerRequestMetadata)
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [
        Tool(
            name: "weather",
            description: "Get current weather for a location",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "location": .object(["type": .string("string")]),
                    "units": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("location")]),
            ])
        )
    ])
}

await server.withMethodHandler(CallTool.self) { parameters in
    let location = parameters.arguments?["location"]?.stringValue ?? "Unknown"
    let units = parameters.arguments?["units"]?.stringValue ?? "metric"
    let weather = getWeatherData(location: location, units: units) // Your implementation

    return .init(content: [
        .text(
            text: "Weather for \(location): \(weather.temperature)°, \(weather.conditions)",
            annotations: nil,
            _meta: nil
        )
    ])
}

try await server.start(transport: StdioTransport())
```

This example explicitly accepts both lifecycles. Omit the configuration to preserve
initialization-only behavior.

## Migrate an HTTP endpoint

### Client

Keep using `HTTPClientTransport`. The client selects the HTTP behavior after negotiation:

```swift
let transport = HTTPClientTransport(
    endpoint: URL(string: "https://weather.example.com/mcp")!
)
let connection = try await client.connectWithInfo(transport: transport)
```

Initialization-based HTTP retains its session ID, standalone GET event stream, and replay
behavior. Per-request metadata sends one POST per JSON-RPC message and receives either one JSON
response or a request-scoped SSE stream. Use `enableStandaloneGetStream` to configure the
initialization-era GET stream; it does not disable request-scoped SSE. The earlier explicit
`streaming:` initializer label remains as a deprecated forwarding overload.

### Server

`StreamableHTTPServerTransport` implements only the per-request-metadata HTTP lifecycle. To keep
an existing initialization/session endpoint, route both implementations through
`LifecycleHTTPServerRouter`:

```swift
let perRequestTransport = StreamableHTTPServerTransport(
    originValidator: OriginValidator(
        allowedHosts: ["weather.example.com"],
        allowedOrigins: ["https://dashboard.example.com"]
    )
)
let perRequestServer = Server(
    name: "WeatherServer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true)),
    configuration: .init(protocolMode: .perRequestMetadataOnly)
)

// Register the same weather handlers used by the initialization-based server.
await registerWeatherHandlers(on: perRequestServer)
try await perRequestServer.start(transport: perRequestTransport)

let router = LifecycleHTTPServerRouter(
    protocolMode: .initializationAndPerRequestMetadata,
    perRequestMetadataTransport: perRequestTransport,
    initializationBasedRequestHandler: { request in
        // Keep the existing session factory responsible for session creation,
        // lookup, GET streams, replay, and shutdown.
        await existingSessionApplication.handleRequest(request)
    }
)

// Convert the web framework's request to MCP.HTTPRequest, then return:
let response = await router.handleRequest(request)
```

The router does not own either server lifecycle. Start both applications before accepting
requests and shut them down through their existing owners.

> [!WARNING]
> The default HTTP validation pipeline accepts localhost origins. A remotely hosted service
> must pass an `originValidator` appropriate for its deployment. This overload retains the
> transport's standard content-type, accept-header, protocol-version, and, where applicable,
> session validation; use `validationPipeline` only when intentionally replacing the complete
> chain.

## Full client migration: weather dashboard

The following pieces opt into the main `2026-07-28` features while retaining automatic
compatibility with earlier servers.

### Configure negotiation, input handling, and caching

```swift
let client = Client(
    name: "WeatherDashboard",
    version: "2.0.0",
    capabilities: .init(
        elicitation: .init(form: .init())
    ),
    configuration: .init(
        protocolMode: .automatic,
        multiRoundTripMode: .automatic(maxRounds: 4),
        subscriptionBufferCapacity: 64,
        responseCacheMode: .enabled(maxEntries: 256)
    )
)

await client.withElicitationHandler { parameters in
    guard case .form(let form) = parameters else {
        return .init(action: .decline)
    }

    // Present the form through your application's trusted UI.
    let response = await presentWeatherConfirmation(form)
    return response.accepted
        ? .init(action: .accept, content: response.values)
        : .init(action: .decline)
}

let connection = try await client.connectWithInfo(transport: transport)
```

Automatic multi-round trips reuse the registered elicitation, sampling, and roots handlers.
The client runs independent embedded requests concurrently, then retries the original request
with one response map and a fresh JSON-RPC ID. Set `.manual` to receive one aggregate
`MultiRoundTripContext`, or `.disabled` to reject `input_required` results.

### Use cache policies deliberately

```swift
// Reuse a matching fresh list when the server allows it.
let (tools, _) = try await client.listTools(cachePolicy: .useIfFresh)

// Force one network refresh and replace the matching entry.
let (refreshedTools, _) = try await client.listTools(cachePolicy: .reload)

// Fetch without reading or writing the SDK cache.
let advisory = try await client.readResource(
    uri: "resource://weather/seattle/advisory",
    cachePolicy: .bypass
)

// Clear all entries owned by this client.
await client.invalidateResponseCache()
```

The SDK caches only complete, cacheable `2026-07-28` responses with a valid `ttlMs` and
`cacheScope`. Notifications invalidate affected entries. Multi-round-trip responses and
request-scoped logging bypass reuse.

### Receive long-lived updates on either lifecycle

For per-request metadata, use `subscriptions/listen`:

```swift
if connection.protocolLifecycle == .perRequestMetadata {
    let subscription = try await client.listen(notifications: .init(
        toolsListChanged: true,
        resourceSubscriptions: ["resource://weather/seattle/advisory"]
    ))

    // A server may acknowledge a subset of the requested notifications.
    print(subscription.acknowledgedNotifications)

    for try await event in subscription.events {
        switch event {
        case .acknowledged(let accepted):
            print("Subscription established for \(accepted)")
        case .notification(let notification):
            print("Received \(notification.method)")
        case .disconnected:
            print("The stream ended before a graceful response")
        }
    }
}
```

For an initialization-based connection, retain the existing resource subscription and
notification handlers:

```swift
if connection.protocolLifecycle == .initializationBased {
    await client.onNotification(ResourceUpdatedNotification.self) { message in
        print("Weather advisory changed: \(message.params.uri)")
    }
    try await client.subscribeToResource(
        uri: "resource://weather/seattle/advisory"
    )
}
```

An explicit client disconnect retains a `2026-07-28` subscription registration so it can be
re-established with the same ID. `cancelSubscription` or terminating the event stream removes
it permanently.

## Full server migration: weather service

### Return structured results and cache information

```swift
await server.withMethodHandler(ListTools.self) { _ in
    .init(
        tools: weatherTools,
        ttlMs: 60_000,
        cacheScope: .public
    )
}

await server.withMethodHandler(CallTool.self) { parameters in
    let location = parameters.arguments?["location"]?.stringValue ?? "Unknown"
    let weather = getWeatherData(location: location, units: "metric")

    return .init(
        content: [.text(
            text: "\(weather.temperature)° and \(weather.conditions)",
            annotations: nil,
            _meta: nil
        )],
        structuredContent: .object([
            "location": .string(location),
            "temperature": .double(weather.temperature),
            "conditions": .string(weather.conditions),
        ])
    )
}
```

Use `.public` only when a result is safe to reuse across authorization contexts. Use `.private`
for user-, tenant-, or credential-specific data. A zero `ttlMs` is valid and prevents reuse.

### Request confirmation during a tool call

A `2026-07-28` tool, prompt, or resource read can return embedded client requests and resume
after the client supplies their results:

```swift
await server.withMultiRoundTripHandler(CallTool.self) { parameters in
    guard parameters.name == "publish_severe_weather_alert" else {
        return .complete(try await callWeatherTool(parameters))
    }

    if let response = parameters.inputResponses?["confirmation"] {
        // These application functions verify authenticity, expiry, request binding,
        // and one-time use before state influences the operation.
        try verifyProtectedState(parameters.requestState, for: parameters)
        let accepted = response.objectValue?["action"]?.stringValue == "accept"
        guard accepted else {
            return .complete(.init(content: [.text(
                text: "Alert was not published",
                annotations: nil,
                _meta: nil
            )]))
        }

        try await publishWeatherAlert(parameters)
        return .complete(.init(content: [.text(
            text: "Alert published",
            annotations: nil,
            _meta: nil
        )]))
    }

    let elicitation = CreateElicitation.Parameters.form(.init(
        message: "Publish this severe-weather alert?",
        requestedSchema: .init(
            properties: [
                "confirmed": .object(["type": .string("boolean")])
            ],
            required: ["confirmed"]
        )
    ))

    return .inputRequired(.init(
        inputRequests: [
            "confirmation": .object([
                "method": .string(CreateElicitation.name),
                "params": try Value(elicitation),
            ])
        ],
        requestState: try makeProtectedState(for: parameters)
    ))
}
```

Embedded input requests contain `method` and `params`, not a nested JSON-RPC envelope. The SDK
validates required client capabilities before sending `input_required` and preserves
`requestState` unchanged between attempts.

> [!WARNING]
> `requestState` is opaque to the SDK but untrusted when it returns from a client. If it affects
> authorization, resource selection, or business logic, authenticate it and bind it to the
> principal, method, original parameters, and expiration. Consider one-time consumption for
> operations with side effects.

### Report progress from a request handler

A handler can echo the request's progress token while its operation is still running:

```swift
await server.withMethodHandler(CallTool.self) { parameters in
    guard parameters.name == "refresh_weather_cache" else {
        return .init(content: [.text(
            text: "Unknown weather tool",
            annotations: nil,
            _meta: nil
        )], isError: true)
    }

    if let token = parameters._meta?.progressToken {
        for step in 0...2 {
            try await server.notify(ProgressNotification.message(.init(
                progressToken: token,
                progress: Double(step * 50),
                total: 100,
                message: ["Starting", "Refreshing", "Complete"][step]
            )))
            if step < 2 {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    return .init(content: [.text(
        text: "Weather cache refreshed",
        annotations: nil,
        _meta: nil
    )])
}
```

The handler sends nothing when the caller omits `progressToken`. It reuses the caller's token and
increases `progress` monotonically. On an initialization-based connection, `notify` uses the
established connection. On a per-request-metadata HTTP connection, the first related notification
selects an SSE response for that POST and precedes its final result.

Keep all progress work within the handler's structured lifetime: await each notification and any
child task before returning. A detached or otherwise unjoined task can outlive the request-scoped
response, at which point its progress can no longer be delivered correctly.

Progress migration checklist:

- Forward the request's token unchanged; do not mint a replacement inside the handler.
- Increase `progress` monotonically and keep `total` consistent when it is present.
- Await progress emission and the associated work before returning the final result.
- Register `ProgressNotification` handling on clients that send a progress token.

### Publish cache invalidations and subscriptions

Existing notification calls route to established initialization sessions or matching
`2026-07-28` subscriptions:

```swift
try await server.notify(ResourceUpdatedNotification.message(.init(
    uri: "resource://weather/seattle/advisory"
)))

try await server.notify(ToolListChangedNotification.message(.init()))
```

The first message on each per-request subscription stream is the acknowledgment. The server may
accept a subset of the requested filter. Keep producers bounded: the SDK applies backpressure
and may end a subscription when a consumer cannot keep up.

### Derive HTTP headers from a tool schema

`x-mcp-header` on an input-schema property maps that argument to an HTTP request header:

```swift
let weatherTool = Tool(
    name: "weather",
    description: "Get current weather for a location",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "location": .object([
                "type": .string("string"),
                "x-mcp-header": .string("Location"),
            ]),
            "units": .object([
                "type": .string("string"),
                "x-mcp-header": .string("Units"),
            ]),
        ]),
    ])
)

try await perRequestTransport.updateTools([weatherTool])
```

Clients learn the header plan from `tools/list`. Servers must keep the transport's tool
definitions current with `updateTools(_:)`, or provide a request-aware schema provider. Header
names are case-insensitive; decoded values are exact. The client performs at most one constrained
schema refresh and retry after error `-32020`.

Mirrored values are visible to HTTP intermediaries and can appear in proxy, gateway, tracing, and
access logs. Base64 protects the field syntax; it does not provide confidentiality. Use
`x-mcp-header` only for routing or policy inputs that are safe at those boundaries. Do not annotate
credentials, authorization codes, tokens, personal content, or unrestricted user input.

## Recommended rollout

1. Upgrade both sides while pinning `.initializationOnly`; run the existing test and conformance
   suites.
2. Change servers to `.initializationAndPerRequestMetadata` and exercise both paths.
3. Change clients to `.automatic`; record `ConnectionInfo` so telemetry distinguishes lifecycle
   and protocol version.
4. Add one feature at a time: caching, subscriptions, then multi-round-trip input and HTTP
   headers.
5. Use `.perRequestMetadataOnly` only after all required peers and operational tooling support
   `2026-07-28`.

No compile-time flag is required. Runtime modes keep one public interface while providing the
A/B boundary needed to isolate regressions.

## Migration checklist

- Use `connectWithInfo` where behavior differs by lifecycle.
- Keep initialization-only operations behind an `.initializationBased` check.
- Advertise every client capability needed by an embedded input request.
- Bound multi-round trips and protect returned `requestState`.
- Classify cached results correctly as `.public` or `.private`.
- Check the server's acknowledged subscription filter.
- Keep handler-emitted progress within the handler lifetime.
- Configure remote-origin validation before exposing an HTTP endpoint.
- Keep HTTP tool schemas synchronized when using `x-mcp-header`.
- Revalidate OAuth authorization-server issuer binding.
- Update exhaustive resource-link content pattern matches.
- Test forced initialization, forced per-request metadata, and automatic negotiation.

## Appendix A: behavior and compatibility details

### A.1 Version selection and fallback

`Version.latest` is `2026-07-28`. `Version.latestInitializationVersion` remains `2025-11-25`
and is the version used by `initialize` and established session transports.

Automatic stdio negotiation probes `server/discover` before deciding whether to initialize.
Automatic HTTP negotiation falls back after a bare compatibility response such as 400, 404, or
405, or after a correlated error to the mandatory `server/discover` probe that is not recognized
per-request-metadata evidence. The latter also applies when a deployed initialization-era peer
wraps its JSON-RPC error in HTTP 200. Authentication failures, rate limits, transient failures,
recognized protocol errors, and cancellation do not classify a peer as initialization-based.
Malformed, empty, or uncorrelated bodies returned with compatibility status 400, 404, or 405 do.
This decision applies only to the discovery probe, so ordinary failed operations are never replayed
as lifecycle detection.

An automatically selected initialization lifecycle is cached by HTTP origin on the client. A
reconnect to that origin initializes directly; a failed cached assumption is removed so the next
connection probes again. Reconnect also re-establishes retained subscriptions.

### A.2 Operations removed from the per-request lifecycle

The SDK preserves `initialize`, `notifications/initialized`, `ping`, `logging/setLevel`,
`notifications/roots/list_changed`, and the earlier resource subscribe/unsubscribe methods for
versions where they remain defined. Calling these compatibility helpers on a per-request
connection fails locally. Use request-scoped log metadata and `subscriptions/listen` for
`2026-07-28`.

### A.3 Multi-round-trip concurrency and cancellation

Each retry is a new JSON-RPC request with a fresh ID, while the SDK tracks the logical operation
for cancellation. Independent embedded requests run concurrently and their results are returned
as one keyed map. Configure a round limit appropriate for the application; the default is eight.
Cancellation stops discovery, embedded requests, retries, and request-scoped HTTP streaming
without triggering lifecycle fallback.

### A.4 Response cache boundaries

The programmatic default is a 512-entry bounded cache. Keys include method, parameters,
pagination position, selected version, client metadata and capabilities, and the applicable
authorization boundary. Private responses are reused only for the exact tracked authorization
context. Custom authorization that cannot provide a stable boundary does not store private
responses.

Treat `ttlMs` as a freshness hint, not a polling interval or correctness guarantee. A caller may
use `.reload` after an external state transition, and notifications invalidate the related SDK
entries. Pagination pages are cached independently.

### A.5 Subscription lifetime

Multiple subscriptions may run concurrently. Their acknowledgment is always the first correlated
message, and a server can narrow the requested filter. Streams have bounded buffers. An explicit
disconnect retains a registration; `cancelSubscription`, task cancellation, or stream termination
removes it permanently.

### A.6 OAuth issuer binding

Authorization-server issuer comparisons are exact, including path and trailing slash. Stored
tokens, pre-registered credentials, and dynamically registered credentials are bound to their
issuer. Dynamic client registration includes `application_type`; credentials are re-registered
when an authorization-server change requires it. Client ID Metadata Documents remain portable
only when the authorization server advertises support.

Review deployments that previously normalized issuer URLs or reused one stored token across
authorization servers. Preserve the issuing server with stored credentials. When a challenge
changes the selected authorization server, the SDK discards the old token and acquires a token for
the new issuer; it never sends the old refresh token to the new token endpoint.

### A.7 Source compatibility

- Resource-link content cases add trailing `size`, `icons`, and `_meta` associated values.
  Construction keeps defaults, but exhaustive patterns must accept the new values.
- `Client.Capabilities.experimental` is `[String: Value]?`, matching server capabilities and
  preserving object-valued settings. Dictionary literals of object values continue to work.
  Each value must be a JSON object, so convert an explicitly typed `[String: String]` by wrapping
  the settings rather than the string — for example
  `mapValues { Value.object(["value": .string($0)]) }`. A string-valued entry compiles but throws
  `EncodingError` when the capabilities are encoded.
- `Sampling.ToolResultContent.structuredContent` is `Value?` so all JSON shapes round-trip. Wrap
  an explicitly typed `[String: Value]` with `Value.object`.
- Capability `experimental` and `extensions` values must be JSON objects, and this is now enforced
  when capabilities are decoded as well as encoded. A peer that sent non-object settings — which
  earlier versions ignored — is rejected on both lifecycles. Extension identifiers use the
  prefixed MCP identifier grammar. Unknown top-level capability settings round-trip via
  `additionalCapabilities`.
- `MCPError.remote(code:message:data:)` preserves structured errors from a peer. Existing error
  cases remain available, but the new case makes an exhaustive `switch` over `MCPError`
  incomplete; add the case or an `@unknown default`. Errors that carry a `data` member — including
  codes `-32020`, `-32021`, and `-32022` — now decode as `.remote` instead of `.serverError`, so
  `catch MCPError.serverError` patterns should be widened.
- `HTTPResponse` gains a `dataWithStatus(statusCode:_:headers:)` case for responses that carry a
  JSON-RPC body with a non-200 status. Adapters that bridge this enum to an HTTP framework should
  read the `statusCode`, `headers`, and `body` properties instead of switching exhaustively, which
  keeps them source-compatible as cases are added.
- `OAuthAuthorizationError` gains `authorizationResponseMissingIssuer`,
  `authorizationResponseIssuerMismatch`, and `clientCredentialIssuerMismatch` for RFC 9207 and
  issuer-binding failures. Exhaustive patterns over this enum need the new cases.

### A.8 API documentation

Public declarations document their behavior and protocol constraints directly. Protocol revision
history belongs in this migration guide and release notes rather than a package-specific DocC
availability convention.

## Appendix B: old and new API map

| Earlier API or behavior | MCP 2026-07-28 API or behavior |
|---|---|
| `connect(transport:) -> Initialize.Result` | `connectWithInfo(transport:) -> Client.ConnectionInfo` |
| Initialization only | `Client.ProtocolMode` and `Server.ProtocolMode` |
| One request and one response | `MultiRoundTripMethod` and `MultiRoundTripResult` |
| Resource-specific subscribe/unsubscribe | `listen(notifications:)` and `SubscriptionFilter` |
| Always fetch discovery/list/read | `ResponseCachePolicy` and server `ttlMs`/`cacheScope` |
| Session-based HTTP only | `StreamableHTTPServerTransport` and `LifecycleHTTPServerRouter` |
| Object-only sampling tool-result data | `Sampling.ToolResultContent.structuredContent: Value?` |
| Ad hoc HTTP argument headers | Schema-derived `x-mcp-header` |
| Flattened remote errors | `MCPError.remote(code:message:data:)` |

## Appendix C: specification references

- [Versioning and lifecycle negotiation](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
- [Per-request metadata](https://modelcontextprotocol.io/specification/2026-07-28/basic/index#meta)
- [Multi-round-trip requests](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)
- [Subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions)
- [Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
- [Response caching](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching)
- [Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
- [Elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation)
- [OAuth client registration](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration)

Fixture provenance, compatibility tests, and conformance commands are recorded in the pull requests
that introduced them. The test fixtures under `Tests/MCPTests/Fixtures/2026-07-28/` are copied from
the specification's own examples at tag `2026-07-28`
([`5f5440bb`](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/examples)),
and the conformance runners live in `scripts/run-conformance.sh` and
`scripts/run-conformance-2026-07-28.sh`.
