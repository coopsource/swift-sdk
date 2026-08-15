# MCP 2026-07-28 implementation

This document is the implementation and review guide for adding MCP protocol version
`2026-07-28` to the Swift SDK. It is updated as each review unit is completed.

## Source of truth

- Specification tag: `2026-07-28`
- Specification commit: `5f5440bb26a62e2cf3440b92da5a667efa03b267`
- Introduction: <https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro>
- Versioning: <https://modelcontextprotocol.io/docs/2026-07-28/learn/versioning>
- Swift SDK base commit: `a0ae212ebf6eab5f754c3129608bc5557637e605`
- Initialization-based conformance runner: `v0.1.15`
- 2026-07-28 conformance runner: `0.2.0-alpha.11`

The sibling `modelcontextprotocol` repository is research input only. All implementation,
fixtures, tests, and documentation are contained in the Swift SDK repository.

## Terminology

SDK symbols describe the protocol lifecycle mechanism rather than relative age:

- **Initialization-based**: versions through `2025-11-25`, which use `initialize` and
  `notifications/initialized`.
- **Per-request metadata**: version `2026-07-28`, which carries the version, client identity,
  and client capabilities on each request.
- **Automatic**: a client detects and selects between those lifecycle mechanisms.
- **Initialization and per-request metadata**: a server accepts both lifecycle mechanisms.

The 2026-07-28 specification calls these mechanisms “legacy” and “modern”, respectively.
Those relative labels are recorded here only to make the specification text easy to map to
the SDK. They are not used in SDK symbol names.

## Design constraints

1. Keep `Transport: Actor` and its raw `Data` send/receive interface unchanged.
2. Continue representing method-specific `_meta` in parameter and result types. Add mandatory
   per-request fields at the existing type-erased wire boundary.
3. Extend `Server.HandlerContext` for request-scoped information instead of changing all
   method-handler signatures.
4. Preserve the current HTTP transports for initialization-based behavior. Isolate
   2026-07-28 behavior where the wire lifecycle is incompatible.
5. Preserve permissive behavior for earlier versions and public source compatibility where
   feasible.
6. Avoid unrelated refactoring, file movement, formatting, or naming cleanup.
7. Inspect relevant history before changing a long-standing design and record any required
   departure below.
8. Add no production dependency, Swift requirement, or platform requirement.

When a change is required, prefer this order:

1. Extend the current type or path additively.
2. Add a narrow internal adapter using existing public abstractions.
3. Add a separate public type when the lifecycle mechanisms cannot coexist safely.
4. Change a long-standing public abstraction only when the earlier options cannot implement
   the specification correctly.

## Runtime controls

- `Client.ProtocolMode`: `initializationOnly`, `automatic`, `perRequestMetadataOnly`
- `Server.ProtocolMode`: `initializationOnly`, `initializationAndPerRequestMetadata`,
  `perRequestMetadataOnly`
- `ProtocolLifecycle`: `initializationBased`, `perRequestMetadata`
- `Client.MultiRoundTripMode`: `automatic(maxRounds:)`, `manual`, `disabled`
- `Client.ResponseCacheMode`: `enabled(maxEntries:)`, `disabled`

Programmatic and decoded configurations default to `initializationOnly`, preserving existing wire
behavior across an SDK upgrade. Applications explicitly select automatic, combined, or
per-request-only modes when they are ready to adopt the new lifecycle.

SwiftPM traits and conditional-compilation feature flags are intentionally not used. Public
traits require Swift 6.1 while the package retains a Swift 6.0 manifest, and conditional
compilation would create multiple public interfaces for wire behavior that is mandatory when
2026-07-28 is selected. Runtime modes provide direct A/B coverage without that divergence.

## Public API additions

- Protocol version `2026-07-28`, an ordered internal preference list, and
  `Version.latestInitializationVersion`.
- Discovery, result-type, cache-policy, subscription, multi-round-trip, standard-header, and
  structured protocol-error models.
- Capability `extensions` maps using JSON `Value` objects, without replacing `experimental`.
- `MCPError.remote(code:message:data:)`, retaining the existing error cases.
- 2026-07-28 resource-link fields as trailing values with defaults. Construction remains
  compatible; exhaustive enum patterns require updating and are tested explicitly.
- `Client.ConnectionInfo` and `connectWithInfo(transport:)`.
- Existing `connect(transport:) -> Initialize.Result` retained as a compatibility wrapper.
- Protocol options added to the existing `Client.Configuration` and `Server.Configuration`
  value types while retaining `Hashable`, `Codable`, and `Sendable`.
- `SubscriptionFilter`, `SubscriptionsListen`, and
  `SubscriptionsAcknowledgedNotification` wire models.
- `Client.listen(notifications:)`, `Client.Subscription`, its asynchronous event stream, and
  `Client.cancelSubscription(_:reason:)`. An established registration is retained across an
  explicit disconnect and is re-sent with the same JSON-RPC id after the client connects again.
- Cache fields on complete discovery, tool-list, prompt-list, resource-list,
  resource-template-list, and resource-read results. Existing list and read result initializers
  retain their earlier construction forms.
- `Client.ResponseCacheMode`, `Client.ResponseCachePolicy`, cache-policy overloads for the
  cacheable convenience methods and generic `send`, and `Client.invalidateResponseCache()`.
- An additive `Client.send(_:logLevel:)` overload and request-scoped `logLevel`, `requestID`,
  and `method` values on `Server.HandlerContext`.
- `StreamableHTTPServerTransport` for per-request-metadata HTTP behavior.
- `LifecycleHTTPServerRouter` for composing initialization-based sessions with a
  per-request-metadata server.

The public `Transport` protocol is not expanded. Request-scoped routing, cancellation, and
selected-lifecycle updates use narrow package-level protocols implemented only by transports
that need them.

## Review sequence

The cumulative integration branch is `swift-sdk-mcp-update-07-28-26`. Each review branch is
based on its predecessor so its pull request can target that predecessor and show only the
feature delta. The integration branch is not intended to be submitted as one large pull
request.

| Order | Branch | Logical dependency | Review unit |
| --- | --- | --- | --- |
| 1 | `mcp-2026-wire-models` | Current SDK | Wire vocabulary, version constants, errors, metadata helpers, extensions, resource-link fields, and fixtures. No lifecycle activation. |
| 2 | `mcp-2026-oauth-issuer-validation` | Current authorization design | Exact `iss`, DCR `application_type`, and issuer-bound credentials. |
| 3 | `mcp-2026-discovery-negotiation` | 1 | Runtime modes, discovery, request metadata, `resultType`, protocol errors, stdio fallback, lifecycle caching, connection information, and handler context. |
| 4 | `mcp-2026-multi-round-trip` | 1, 3 | Logical request attempts, embedded input handling, opaque state, response validation, fresh request IDs, and round limits. |
| 5 | `mcp-2026-http-client` | 3 | One POST per message, JSON/request SSE responses, Linux streaming, cancellation, validation, lifecycle detection, and serialized authorization. |
| 6 | `mcp-2026-http-server` | 1, 3 | Per-request-metadata Streamable HTTP server transport. |
| 7 | `mcp-2026-http-lifecycle-routing` | 5, 6 | HTTP routing between per-request metadata and initialization/session handling. |
| 8 | `mcp-2026-tool-headers` | 3, 5 | Standard and schema-derived headers, exact encoding, agreement validation, and constrained `-32020` retry. |
| 9 | `mcp-2026-subscriptions` | 5–7 | `subscriptions/listen`, acknowledgment ordering, filters, concurrent listeners, correlation, reconnect, and request-scoped logging. |
| 10 | `mcp-2026-response-caching` | 3, 9 | Required cache fields, bounded cache, test clock, page keys, authorization partitions, invalidation, and call policies. |
| 11 | `mcp-2026-conformance` | All prior units | Conformance adapters and tests, pinned runners, readiness checks, and CI evidence. Uses explicit lifecycle modes. Platform verification and the source-compatibility audit are recorded in this document, which is aggregate-only. |
| 12 | `mcp-2026-defaults-release` | 11 | Programmatic default changes, `Version.latest`, migration guidance, and release documentation. |

Pull-request descriptions and the filing script are aggregate review material added only after
unit 12. They do not belong to any feature delta.

## Test requirements

Each review unit must pass all preceding tests and add focused coverage. The final result must:

- Preserve the existing 551-test initialization-based baseline.
- Verify 2026-07-28 and earlier JSON against fixtures copied from the tagged specification.
- Cover missing or malformed request metadata, unsupported versions, missing capabilities,
  mismatched headers, invalid cache policy, and incorrect input-response maps.
- Preserve initialize/initialized, HTTP sessions, GET streams, replay, ping, logging, and
  resource subscriptions for initialization-based versions.
- Use explicit scripted peers for ordering, latency, cancellation, reentrancy, stream
  termination, and authorization challenges.
- Cover simultaneous requests completing out of order, cancellation before and during
  streaming, concurrent authorization refresh, and subscription acknowledgment ordering.
- Exercise automatic clients against initialization-only, per-request-metadata-only, and
  combined-lifecycle servers.
- Ensure authentication and transient HTTP failures do not select initialization-based
  behavior, and recognized 2026-07-28 errors do not cause initialization fallback.
- Retry `-32022` only with a mutually supported version.
- Run on macOS and Linux, including static Linux and the Swift 6.0 manifest.

If correct Linux streaming cannot be implemented with supported Foundation APIs, the HTTP
client review unit stops and records measured alternatives. It must not silently add a
dependency, reduce platform support, or raise the Swift requirement.

## Implementation record

### Existing patterns retained

- Review unit 1 keeps `Version.supported` limited to implemented lifecycle behavior. The
  `2026-07-28` constant and preference order are present for the new models, but existing
  initialization and HTTP validation do not advertise support before request dispatch exists.
- `_meta` remains part of method parameter and result types. Reserved key constants are added
  without moving metadata to the JSON-RPC envelope.
- Capability additions are trailing initializer parameters with defaults.
- Existing resource-link enum cases are extended with trailing defaulted fields rather than
  replaced by a new content hierarchy.
- Review unit 2 keeps OAuth responsibilities at their existing boundaries: authorization
  response validation remains in `OAuthAuthorizationCodeFlow`, dynamic registration fields
  remain in `OAuthClientRegistrar`, and credential and token state remain in
  `OAuthAuthorizer` and the existing `TokenStorage` abstraction.
- Existing authorization-code flow entry points remain as compatibility wrappers. The issuer
  requirement is carried by a new overload so callers that use the flow directly continue to
  compile.
- Review unit 3 keeps `Transport` on its raw `Data` boundary. Required request metadata and
  successful-response fields are merged at the existing type-erased encoding boundary, so
  method parameter and result types do not each acquire lifecycle plumbing.
- `Client.connect(transport:)` remains the compatibility entry point returning
  `Initialize.Result`. `connectWithInfo(transport:)` reports the selected lifecycle without
  removing the automatic-connect behavior introduced in commit `a59b50b`.
- Per-request client identity, capabilities, and protocol version extend the existing
  task-local `Server.HandlerContext`; registered method-handler signatures are unchanged.
- Review unit 4 retains the existing type-erased client method-handler registry for
  elicitation, sampling, and roots. Automatic embedded input dispatch therefore has the same
  validation and application behavior as the corresponding standalone server-to-client
  request, without introducing a second set of feature handlers.
- Tool, prompt, and resource-read parameter types receive trailing optional `inputResponses`
  and `requestState` values. Their existing initializers and initialization-based encodings are
  unchanged when those values are absent.
- A logical multi-round-trip call retains the caller-visible request ID while every retry uses
  a fresh wire ID. Existing cancellation remains caller-facing and is translated to the active
  wire attempt without changing `RequestContext` or `Transport`.
- Review unit 5 keeps the existing `HTTPClientTransport` session, standalone GET stream,
  `Mcp-Session-Id`, and `Last-Event-ID` path unchanged for initialization-based connections.
  Per-request-metadata behavior is selected through the package-level lifecycle hook and uses a
  separate delegate-backed `URLSession` for request-scoped response delivery.
- The HTTP client retains its `Transport` conformance. Its canonical
  `enableStandaloneGetStream` option controls only the initialization-based standalone GET event
  stream; the earlier explicit `streaming:` label forwards through a deprecated overload. A
  2026-07-28 response independently chooses JSON or request-scoped SSE.
- Request cancellation uses a package-level optional transport hook, allowing the client to
  close an HTTP response stream without adding a requirement to every public transport.
- Direct `HTTPClientTransport` construction continues to default to
  `Version.latestInitializationVersion`; selecting 2026-07-28 remains a client lifecycle
  decision. The existing authorization retry limit keeps its documented meaning as the number
  of retries after the initial HTTP attempt in both lifecycle paths.
- Review unit 6 adds a separate `StreamableHTTPServerTransport` and leaves the established
  stateless and stateful transports unchanged. The new actor uses the existing framework-neutral
  `HTTPRequest`, `HTTPResponse`, validation-pipeline, raw `Data` stream, and
  `HTTPContextProviding` patterns.
- The per-request server waits for the first related output. A final response selects direct
  JSON; a preceding related notification selects request-scoped SSE. This preserves incremental
  progress and logging while allowing an unknown method to retain its required HTTP 404 status.
- Request-scoped notification routing and response-stream cancellation use package-level
  optional transport hooks. The existing public `Transport` requirements and all registered
  method-handler signatures remain unchanged. Cancellation that races with server dispatch is
  remembered until the corresponding handler task is registered.
- The transport substitutes a private routing id during server dispatch and restores the
  caller's id in the encoded response. Request ids are scoped to a JSON-RPC client, while one
  HTTP server serves independent clients that may concurrently choose the same id; a global
  id-keyed waiter would otherwise overwrite valid requests. HTTP context and cancellation use
  the private id internally, and no substituted value appears on the wire.
- The new server validates the required protocol-version header against request metadata and
  rejects client responses and batches. Review unit 8 extends that same transport boundary with
  `Mcp-Method`, `Mcp-Name`, and schema-derived parameter validation; the public `Transport`
  protocol remains unchanged.
- Review unit 7 adds only the lifecycle-selection layer. Its initialization-based handler is a
  closure over the application's existing session router, so session creation, expiry, GET
  streams, replay, and DELETE remain owned by the established path. The one
  `StreamableHTTPServerTransport` continues to serve per-request-metadata traffic without session
  state.
- Following `basic/versioning#backward-compatibility-with-initialization-based-versions`, combined
  mode gives lifecycle metadata precedence over an old session header. An
  `initialize` opening without that metadata selects initialization-based handling. A known
  initialization-based protocol header stays on that path; an unrecognized header is sent to
  per-request validation so the server can return a structured error rather than silently
  selecting a different lifecycle.
- The same router accepts all three `Server.ProtocolMode` values. This lets maintainers isolate
  either HTTP lifecycle at runtime without conditional compilation or a second public interface.
  An `initialize` method carrying per-request metadata is routed statelessly and rejected because
  that method is not defined by the per-request-metadata lifecycle.
- Review unit 8 retains `Tool.inputSchema` as a JSON `Value`. A narrow package-level parser reads
  only the statically reachable `properties` chains used by `x-mcp-header`; it does not add a JSON
  Schema dependency, follow references or composition keywords, or reinterpret the rest of a
  tool schema.
- Standard and schema-derived request headers are generated from the raw JSON request at the HTTP
  boundary. This preserves exact JSON strings and integer semantics without moving HTTP concerns
  into method parameter models. The existing request modifier still runs after required headers
  are constructed, so servers can detect a modifier that deliberately changes them.
- Invalid `x-mcp-header` annotations exclude only the affected tool from an HTTP `tools/list`
  result. The filtering is performed by the HTTP transport for both convenience methods and
  generic `Client.send` calls; non-HTTP transports continue to expose the original tool model.
- A server can preload stable tool definitions with `updateTools`. It does not infer global
  validation state from a `tools/list` response, which may depend on the caller or page. Servers
  with request-dependent schemas can provide a trailing `toolHeaderSchemaProvider` when creating
  the transport; its result is used only for that HTTP request. Client header plans remain
  actor-confined and are cleared when the connection terminates or the client receives
  `notifications/tools/list_changed`.
- Review unit 9 keeps the initialization-based resource subscription methods, standalone HTTP
  GET stream, logging level request, ping, and roots-list notification unchanged. The client and
  server reject those operations only after selecting the per-request-metadata lifecycle, where
  `subscriptions/listen` replaces them.
- Subscription handling extends the server's established default dispatch path instead of adding
  a required application handler. Each active stream has a bounded FIFO output queue so its
  acknowledgment is enqueued before selected notifications even when application tasks run
  concurrently. A full queue suspends a bounded number of publishers; cancellation, closure, and
  send failure release them. Different subscriptions remain independent and can complete out of
  order.
- Selected tool, prompt, resource-list, and exact-resource notifications continue through the
  existing type-erased notification boundary. Correlation metadata is added there, and a
  notification may still reach an application's existing client notification handler after it
  appears on the subscription event stream.
- Per-request logging uses the existing `Server.currentHandlerContext` and `Server.log` path.
  The server emits only levels at or above that request's metadata value, emits no log when the
  value is absent, and does not place log notifications on the `subscriptions/listen` stream.
- The existing public roots capability keeps its initialization-based `listChanged` field. Only
  the per-request-metadata wire representation removes that field, preserving old construction
  patterns while encoding the 2026-07-28 capability as an empty object.
- Request-scoped HTTP routing continues to substitute private ids internally. A package-level
  optional adapter exposes the original client id to `HandlerContext` so subscription correlation
  never leaks a private routing id onto the wire.
- Review unit 10 keeps list and resource-read result types source-compatible by adding cache
  fields after their existing initializer arguments with nil defaults. The fields remain
  decodable from earlier protocol responses. At the per-request-metadata response boundary, an
  existing handler that supplies neither field is encoded with `ttlMs: 0` and a private scope.
  This satisfies the 2026-07-28 cacheable-result model without reusing the response. Partial,
  malformed, and negative policies remain errors.
- Response caching is actor-confined inside `Client` and adds only optional package-level
  transport hooks. Cache keys are derived from the exact encoded request attempt. They retain
  caller metadata, protocol version, and client capabilities, remove only client identity,
  request-scoped log level, and progress token, include each pagination cursor independently,
  and exclude all input-response retries. A monotonic clock prevents wall-clock changes from
  extending freshness.
- Public entries may be reused across authorization contexts. Private entries are partitioned by
  the Authorization value applied to the completed HTTP attempt, including a successful retry,
  rather than authorization state read after the response. The attempt value is consumed by the
  client and cleared on failure, cancellation, or disconnect. Private responses are not stored
  when the transport cannot report an exact value or a request modifier changes Authorization;
  public caching remains available. Caches are cleared on connect and disconnect, and callers can
  explicitly invalidate after an application-managed authorization change.
- List-change notifications invalidate every cached page for the affected method. Resource-update
  notifications invalidate only cache keys with the matching URI. The existing type-erased
  notification path remains responsible for delivery and performs invalidation before registered
  application handlers run.
- Existing convenience-method signatures remain wrappers over additive cache-policy overloads.
  This preserves uses that depend on the original function type while permitting request-level
  `useIfFresh`, `reload`, and `bypass` behavior.

### Required departures

- Client capability maps now use `Value` for both experimental and extension settings, matching
  the JSON-object values required by `ClientCapabilities` and `ServerCapabilities` in the tagged
  schema. Dictionary literals containing strings remain source-compatible because `Value`
  supports string literals; separately typed `[String: String]` values require an explicit
  `mapValues(Value.string)` conversion. Encoding and decoding reject scalar settings and reject
  extension identifiers that do not follow the mandatory-prefixed `_meta` key grammar from
  `basic/versioning#extensions` and `basic/index#meta`.
- Capability objects preserve settings carried by the sampling, elicitation, logging, and
  completion capability objects. Unknown top-level capabilities round-trip through the trailing
  `additionalCapabilities` map because `schema#clientcapabilities` and
  `schema#servercapabilities` explicitly define those objects as open sets. Known SDK fields
  remain authoritative and colliding additional names fail during encoding.
- `Sampling.ToolResultContent.structuredContent` is a `Value` because
  `schema#toolresultcontent-structuredcontent` permits every JSON type. Its decoder distinguishes
  an absent field from an explicit JSON `null`; an object-specific initializer preserves common
  existing construction with `[String: Value]` values. `CallTool.Result` uses the same absent
  versus explicit-null decoding rule for `structuredContent`.
- Resource-link enum patterns now have three additional associated values (`size`, `icons`, and
  `_meta`). Existing construction remains source-compatible because the values default to nil,
  but exhaustive pattern matches must bind or ignore them. Encoding those fields at their
  specified wire location cannot be achieved through annotations without producing invalid
  protocol messages.
- Unknown remote errors with structured `data` now decode as `MCPError.remote` instead of
  discarding the data through `serverError`. Errors without structured data retain the existing
  case.
- `OAuthAuthorizationServerMetadata` retains the issuer's decoded JSON string in addition to
  its parsed `URL`. RFC 9207 requires exact string comparison for the authorization response
  `iss` parameter, so reconstructing the value from `URL` could incorrectly normalize a case,
  slash, port, or percent-encoding difference.
- Stored access tokens record the exact authorization-server issuer additively. Tokens created
  by existing code remain readable and use the previous URL comparison fallback until they are
  replaced.
- Preconfigured credentials select only their exact advertised authorization-server issuer.
  Dynamically registered credentials retain their issuing-server provenance, while Client ID
  Metadata Document credentials remain portable when the server advertises that support. An
  unregistered client considers later advertised servers when an earlier server has no dynamic
  registration endpoint. These rules implement `basic/authorization/client-registration`
  (client-registration priority, Client ID Metadata Documents, failure handling, and
  authorization-server binding) and `basic/authorization/authorization-server-discovery`
  (authorization-server selection and state).
- `Version.supported` includes `2026-07-28` once per-request dispatch is implemented, while
  `Version.latest` remains `2025-11-25` until the final default-change review unit. Initialization
  negotiation explicitly excludes the per-request revision so an `initialize` request cannot
  select lifecycle-incompatible semantics.
- Successful responses emitted for 2026-07-28 include `resultType`. On decode, an absent field is
  treated as `complete` as required by `basic/index#resulttype`; a present non-string field is
  rejected.
- `Client.Configuration.discoveryProbeTimeout` controls the stdio-style discovery timeout. HTTP
  discovery does not use that timer and HTTP failures do not select initialization-based behavior;
  the HTTP binding makes its fallback decision from the required response status and body. A timed
  out or cancelled stdio-style probe is retired and sends `notifications/cancelled` before any
  initialization fallback, following `basic/versioning#backward-compatibility-with-initialization-based-versions`
  and `basic/patterns/cancellation#transport-specific-cancellation`. Caller cancellation remains
  effective when the SDK timeout is disabled; it never starts an initialization attempt.
- Strict combined-lifecycle servers track initialize handling, response delivery, and the ready
  notification separately. This preserves the initialization ordering in the 2025-11-25 lifecycle
  while allowing cancellation that is correlated to an active 2026-07-28 request. Per-request-only
  servers reject `notifications/initialized`, which that lifecycle removes.
- Multi-round-trip server handlers use a separate additive registration overload because a
  single typed handler can return either its normal method result or `InputRequiredResult`.
  Changing every existing handler to return a union would break source compatibility. The
  overload uses the existing handler box and rejects `input_required` on an initialization-based
  request.
- `basic/patterns/mrtr` removes standalone server-to-client roots, sampling, and elicitation
  requests for 2026-07-28. The shared server request boundary rejects them in a per-request
  handler or per-request-only server, and the client independently rejects a peer that sends one.
  Initialization-based behavior remains available, including ping before the ready notification.
- Unknown `resultType` strings remain decodable in the wire model for forward compatibility but
  are rejected by single, batch, and multi-round-trip response dispatch until the SDK implements
  their semantics. Manual embedded responses are decoded against the requested roots, sampling,
  or elicitation result before retrying the logical request.
- A second internal `URLSession` is used for per-request-metadata responses. Foundation's
  buffered `data(for:)` cannot implement incremental SSE delivery on Linux, while a
  `URLSessionDataDelegate` supplies response headers, incremental data, completion, and
  cancellation on both Linux and Apple platforms. The public transport interface and package
  dependencies remain unchanged.
- `basic/transports/streamable-http#message-flow` and `#cancellation` require one response stream
  per request and define closing it as the cancellation signal. The transport records a
  cancellation that arrives before its `URLSessionDataTask` is registered, and cancellation of
  an HTTP discovery request cannot be reclassified as initialization-based compatibility. The
  request-scoped parser also follows the linked Server-Sent Events parsing algorithm by ignoring
  exactly one leading U+FEFF, including when its UTF-8 bytes span network chunks.
- The per-request protocol fields in `basic/index#meta` require both the protocol version and client
  capabilities on every request. The server decodes and validates those fields before comparing
  the mirrored HTTP version header; missing or malformed required metadata returns JSON-RPC
  `-32602` with HTTP 400, including when the error is produced by normal server dispatch.
- Review unit 5 sends the mandatory `MCP-Protocol-Version` header. Standard `Mcp-Method`,
  `Mcp-Name`, and schema-derived headers remain deliberately deferred to review unit 8 so their
  client generation, server validation, schema lookup, and constrained retry policy are reviewed
  together. The stacked branch does not claim complete 2026-07-28 HTTP conformance until that
  review unit is applied.
- Review unit 8 routes every per-request-metadata client call through the existing logical-request
  attempt loop, even when automatic embedded input handling is disabled. This does not enable
  multi-round-trip handling; it permits the distinct `HeaderMismatch` recovery rule to refresh a
  tool schema and make one retry with a fresh wire id. Keeping the old one-shot branch would have
  duplicated cancellation, response validation, and retry-id handling.
- `HeaderMismatch` has no machine-readable field identifying which header failed. The client
  therefore applies the specification's optional recovery only when error code `-32020` also
  names an `Mcp-Param-*` header, the original request is `tools/call`, a refreshed paginated
  `tools/list` changes that tool's valid header plan, and no header retry has occurred. Standard
  header failures, unchanged schemas, invalid refreshed schemas, and a second mismatch are
  returned without retry.
- Header validation follows `basic/transports/streamable-http#case-sensitivity` and the linked
  RFC 9110 field-value grammar: field names compare case-insensitively, field values retain their
  specified case, and leading or trailing HTTP optional whitespace is ignored before decoding.
- `HTTPResponse.dataWithStatus` is an additive case used when the HTTP binding requires a
  non-200 status but must preserve the server's complete encoded JSON-RPC response, including
  its original id and structured error data. The existing `.error` case always constructs an
  error with a null id and cannot represent the required 404 method response or structured
  `-32022` response. As with any public enum case addition, downstream exhaustive switches must
  add the new case; framework adapters that rely on `statusCode`, `headers`, and `bodyData`
  continue to work without case-specific changes.
- A subscription is represented by an `AsyncThrowingStream` because it must carry an
  acknowledgment, any number of selected notifications, an unexpected disconnect, and a final
  result over one logical request. Reusing a single `RequestContext` would expose only the final
  result and lose the protocol's required ordering. The client uses a bounded oldest-first
  buffer and checks every yield. Overflow fails the stream and cancels the remote subscription
  once instead of silently dropping an ordered notification. Explicit cancellation and stream
  termination use the same idempotent removal path.
- The bounded subscription behavior implements the ordering and termination rules in
  `basic/patterns/subscriptions#acknowledgment`, `#multiple-concurrent-subscriptions`,
  `#cancellation`, and `#graceful-closure`. Buffer capacity is an SDK resource policy rather than
  a wire field. Older serialized configurations default to 32 entries; nonpositive decoded or
  active values are rejected. The server also bounds waiting publishers to the same capacity and
  reports overload rather than retaining unbounded work.
- Unexpected subscription transport closure is recoverable only after an explicit client
  disconnect/connect cycle, matching the SDK's existing connection ownership. Transport errors
  yield `Client.SubscriptionEvent.disconnected` and retain the registration. Malformed ordering,
  correlation, filter expansion, and remote JSON-RPC errors terminate the stream instead of being
  misclassified as reconnectable failures.
- Cache fields are optional in the Swift result models even though complete cacheable
  2026-07-28 results require them. Making the fields nonoptional would prevent decoding earlier
  protocol responses and break every existing construction site. The per-request-metadata wire
  boundary supplies the conservative `ttlMs: 0` and private scope only when both fields are
  absent; this keeps existing handlers valid without enabling reuse. Runtime validation and
  injection are limited to that lifecycle so initialization-based behavior stays permissive.
- The HTTP authorization cache hook stores the exact header value in actor-confined memory rather
  than a derived hash. Exact values avoid collision-based cross-principal reuse, and the value is
  never logged or placed in an error. Values are keyed by the JSON-RPC attempt id, overwritten by
  an authorization retry, and consumed once with the matching response. When a custom request
  modifier changes Authorization after the authorizer runs, private caching is conservatively
  disabled because the transport cannot identify that external credential safely; public caching
  remains available. This implements `server/utilities/caching#cache-key`, `#cache-scope-field`,
  and `#security-considerations` without changing the public `Transport` contract.
- Requests carrying a request-scoped log level bypass cache lookup and storage. Returning a cached
  value would suppress the server-side log behavior explicitly requested for that call. Final
  multi-round-trip responses are also not stored because the logical result depends on embedded
  input and opaque request state that are deliberately absent from ordinary cache keys.
- Review unit 11 keeps the conformance executables in their existing source directories. A
  package-only support target compiles the existing NIO adapter separately so focused tests can
  exercise it without linking the executable entry point or moving files. It adds no product or
  production dependency.
- The NIO adapter continues to translate only between NIO and the existing framework-neutral HTTP
  request and response types. It now retains each request task until completion, awaits every
  response write, and cancels request-scoped work when a channel closes or fails. This implements
  `basic/transports/streamable-http#cancellation` and
  `basic/patterns/cancellation#transport-specific-cancellation` at the conformance executable
  boundary without changing an SDK transport.
- Both conformance executables select an explicit lifecycle from their environment. This keeps
  the initialization-based `v0.1.15` run independent of the 2026-07-28 run and avoids relying on
  a programmatic default for conformance behavior.
- Review unit 12 makes `Version.latest` identify `2026-07-28`. A follow-up compatibility review
  keeps both newly constructed and decoded configurations initialization-only; automatic and
  combined lifecycle behavior requires an explicit mode.
- Initialization models, client initialization, direct HTTP transport construction, and
  initialization-session fallbacks use `Version.latestInitializationVersion` explicitly. This
  prevents the `Version.latest` change from placing `2026-07-28` on an `initialize` request or an
  established session stream where that lifecycle is not defined. Existing tests that exercise
  initialization-only methods declare `.initializationOnly`; tests for default behavior use the
  new defaults directly.

### Git-history findings

- Commit `a59b50b` deliberately moved initialization into `Client.connect(transport:)` and made
  the result discardable. The compatibility wrapper is therefore retained rather than making
  callers perform a separate negotiation step.
- Commit `720a810` centralized initialization version selection in `Version.negotiate`. The new
  per-request preference list remains beside that code, but initialization negotiation continues
  to select only initialization-based revisions.
- Commit `a0ae212` replaced a request-ID-only task local with public `Server.HandlerContext` so
  handlers could observe request-scoped HTTP state without new handler overloads. Per-request
  protocol state extends that same context rather than introducing a parallel dispatch API.
- The original request-handler box in `be1e958` and its generic encoding adjustments in
  `e0186b5` established the SDK's current typed-to-type-erased dispatch boundary. Review unit 4
  adds one sibling handler box at that boundary rather than changing the established handler
  interface.
- Sampling was added in `fac4df6`, while roots and elicitation registrations were consolidated
  with the 2025-11-25 work in `6112a39`. Their existing client handlers are reused for embedded
  requests so host policy is not duplicated or bypassed.
- The initial HTTP client in `d583151` established one actor with a raw `Data` transport boundary.
  `3ff1085` adopted EventSource for Apple-platform standalone SSE, `bdaa258` delayed that GET until
  the session ID exists, and `f6e401a` fixed CRLF parsing. Review unit 5 therefore adds an isolated
  request-scoped parser and leaves that established session stream intact.
- `0121dcc` made request modification an HTTP transport concern. The per-request path applies the
  same modifier after constructing its required request fields, matching the existing path.
- OAuth support added in `6132fd4` relies on the HTTP transport actor to confine authorizer state.
  Actor methods can interleave at `await`, so review unit 5 explicitly serializes preparation and
  challenge handling. Concurrent requests compare the challenged Authorization value with the
  current value and share a completed refresh instead of starting a duplicate flow.
- Commit `6112a39` introduced the HTTP server transports as separate actors over common
  framework-neutral request, response, validation, and SSE types. Its stateless transport
  deliberately drops server-initiated messages, while its stateful transport owns session IDs,
  standalone GET streams, event IDs, and replay. Those are intentional lifecycle choices, so
  review unit 6 adds a sibling actor instead of conditionally changing either implementation.
- Commit `973b46b` tightened HTTP method status and `Allow` headers and made every stateful method
  pass through the configured validation pipeline. The new transport retains both conventions:
  non-POST requests return 405 with `Allow: POST`, and accepted POSTs use the same pipeline.
- Commit `a0ae212` added request-id-keyed HTTP context and explicitly clears it when a response
  is delivered or a stream closes. Review unit 6 follows that lifetime and uses the extended
  handler context to associate server notifications with exactly one response stream.
- Commit `6112a39` placed HTTP session lookup, creation, expiry, and cleanup in the framework
  application rather than either server transport. Review unit 7 preserves that ownership with
  an initialization-based request-handler closure; the SDK router decides only which lifecycle
  receives a request and does not introduce a competing session store.
- Commit `f3b9ba4` made `Tool.inputSchema` a required JSON `Value`, preserving arbitrary schema
  vocabulary without adding a schema-model dependency. Review unit 8 keeps that design and
  derives only the header fields that the protocol defines as statically reachable.
- Commit `0121dcc` established the public request modifier as the application escape hatch for
  HTTP headers. Review unit 8 does not add method-specific header callbacks; it constructs the
  required protocol headers first and retains the modifier's existing final say over the request.
- `ResourceSubscribe`, `ResourceUnsubscribe`, their update notification, and the original list
  change notifications date to the initial implementation in `be1e958`. Review unit 9 preserves
  those public models and initialization-based dispatch rather than renaming or repurposing them
  for the new subscription lifecycle.
- Commit `6112a39` established request-scoped server output routing and server-initiated HTTP
  streams. Subscription delivery builds on those boundaries; it does not move stream semantics
  into the raw public `Transport` protocol.
- Tool, prompt, resource, and resource-template result types originated in the initial typed
  method implementation and have subsequently grown through additive fields and initializer
  defaults. Review unit 10 follows that pattern instead of replacing them with a cacheable-result
  wrapper.
- Commit `0121dcc` intentionally made `HTTPClientTransport.requestModifier` the final application
  escape hatch for request headers. Response caching observes the post-modifier Authorization
  value only to detect that it differs from transport-managed authorization; it does not reorder
  or constrain the modifier.
- Commit `6112a39` introduced the NIO conformance application as a thin adapter over the SDK's
  framework-neutral HTTP types. Review unit 11 preserves that boundary and source layout; the
  package-only support target exists solely to test the adapter's cancellation and write-ordering
  behavior directly.
- Commit `720a810` used `Version.latest` for initialization negotiation when the newest protocol
  version also used `initialize`. Review unit 12 retains that established fallback through
  `Version.latestInitializationVersion` while allowing `Version.latest` to describe the newest
  supported revision across both lifecycle mechanisms.

### Fixture provenance

- `discover-result.json`:
  `schema/2026-07-28/examples/DiscoverResult/server-capabilities-discovery.json`
- `discover-request.json`:
  `schema/2026-07-28/examples/DiscoverRequest/server-discover-request.json`
- `unsupported-version.json`:
  `schema/2026-07-28/examples/UnsupportedProtocolVersionError/unsupported-version.json`
- `resource-link.json`:
  `schema/2026-07-28/examples/ResourceLink/file-resource-link.json`
- `input-required-result-with-elicitation-and-sampling-and-request-state.json`:
  `schema/2026-07-28/examples/InputRequiredResult/input-required-result-with-elicitation-and-sampling-and-request-state.json`
- `input-required-result-with-request-state-only.json`:
  `schema/2026-07-28/examples/InputRequiredResult/input-required-result-with-request-state-only.json`
- `header-mismatch.json`:
  `schema/2026-07-28/examples/HeaderMismatchError/header-mismatch.json`
- `subscriptions-listen-request.json`:
  `schema/2026-07-28/examples/SubscriptionsListenRequest/listen-for-list-changes.json`
- `subscriptions-acknowledged.json`:
  `schema/2026-07-28/examples/SubscriptionsAcknowledgedNotification/listen-acknowledged.json`
- `subscriptions-listen-result.json`:
  `schema/2026-07-28/examples/SubscriptionsListenResult/listen-closed.json`
- `tools-list-with-cursor-and-ttl.json`:
  `schema/2026-07-28/examples/ListToolsResult/tools-list-with-cursor-and-ttl.json`
- `prompts-list-with-cursor-and-ttl.json`:
  `schema/2026-07-28/examples/ListPromptsResult/prompts-list-with-cursor-and-ttl.json`
- `resources-list-with-cursor-and-ttl.json`:
  `schema/2026-07-28/examples/ListResourcesResult/resources-list-with-cursor-and-ttl.json`
- `resource-templates-list-with-cursor-and-ttl.json`:
  `schema/2026-07-28/examples/ListResourceTemplatesResult/resource-templates-list-with-cursor-and-ttl.json`
- `read-resource-with-ttl.json`:
  `schema/2026-07-28/examples/ReadResourceResult/file-resource-contents.json`
- The fifteen fixtures above are copied without modification from specification commit
  `5f5440bb26a62e2cf3440b92da5a667efa03b267`.
- `subscription-tool-list-changed.json` is a focused fixture derived from the subscription
  correlation example in the tagged specification prose. It is not represented as an official
  schema example and is identified separately to avoid implying copied provenance.

### Toolchain and platform results

- Baseline before changes: 551 tests in 40 suites passed with `swift test`.
- `swift package dump-package` continues to validate the package manifest after review unit 3;
  neither manifest was changed.
- The Swift 6.0 compatibility manifest parses successfully with
  `swiftc -parse -package-description-version 6.0.0`; neither manifest changed in review unit 5.
- The Swift 6.0 Linux compiler requires the multi-round-trip cancellation closure to state its
  existing `@Sendable` contract explicitly. This is a source annotation only; it adds no API,
  runtime, language, or platform requirement.
- A Docker `--scratch-path` isolates build products but does not prevent SwiftPM from updating a
  writable host-mounted `Package.resolved`. Linux release and static-link checks therefore use
  `--disable-automatic-resolution`; the repository's pins remain unchanged.
- Additional results are recorded by review unit below.

### Review-unit results

- Review unit 1, `mcp-2026-wire-models`: `swift test` passed 563 tests in 42 suites on
  macOS. Existing compiler warnings remain unchanged. No package requirement or dependency was
  added.
- Review unit 2, `mcp-2026-oauth-issuer-validation`: exact RFC 9207 authorization-response
  issuer checks, DCR `application_type`, persisted-token issuer binding, registration retry,
  multi-server selection, and configured, dynamically registered, and Client ID Metadata
  Document credential provenance are covered by focused tests. `swift test` passed 577 tests in
  42 suites on macOS. No package requirement or dependency was added.
- Review unit 3, `mcp-2026-discovery-negotiation`: runtime lifecycle modes, discovery probing,
  required per-request metadata, response `resultType`, structured version errors,
  `ConnectionInfo`, and request-scoped handler context are covered with paired in-memory and
  scripted transports. Focused coverage includes every supported initialization revision, both
  incompatible lifecycle-only client/server combinations, automatic selection of either server
  lifecycle, every recognized per-request error code, no-mutual-version failure, timeout fallback,
  and caller cancellation with and without an SDK timeout. The combined version and negotiation
  run passed 29 tests, the official discovery request fixture has a separate encoding check, and
  `swift test` passed 600 tests in 43 suites on macOS. Existing HTTP transport behavior remains
  initialization-based by default; its
  isolated per-request request/stream path is review unit 5. No package requirement or
  dependency was added.
- Review unit 4, `mcp-2026-multi-round-trip`: focused tests use paired in-memory peers to verify
  fresh retry IDs, exact opaque-state echoing, state-only retries, concurrent embedded handlers,
  concurrent logical requests completing out of order, cancellation during embedded input,
  capability validation, aggregate manual handling, response-map validation, and round limits.
  The unknown-result-type negative test uses `tools/list`, which remains defined in 2026-07-28;
  using the removed `ping` method would fail at lifecycle validation before exercising the result
  decoder.
  The focused multi-round-trip run passed 13 tests in 1 suite, and `swift test` passed 614 tests
  in 44 suites on macOS. No package requirement or dependency was added.
- Review unit 5, `mcp-2026-http-client`: the per-request path uses one POST per request or
  notification, ignores session state, streams request-scoped SSE incrementally, closes the
  response for cancellation, and supports concurrent responses completing out of order. Focused
  tests also cover split CR/LF boundaries, malformed responses, missing final responses, server
  requests on SSE, cancellation before headers and during streaming, automatic lifecycle
  selection, cancelled discovery, guarded fallback for HTTP 400, 404, and 405, every recognized
  per-request error, non-fallback authentication and transient statuses, serialized authorization
  preparation, retry limits, a split leading byte-order mark, and shared concurrent token refresh.
  The test protocol is isolated from the older suite and models delayed headers,
  data chunks, termination, and cancellation; sharing the older global handler caused valid tests
  in independently serialized suites to interfere when the runner executed them concurrently.
  The focused run passed 21 tests, the combined old and new HTTP client run passed 73 tests, and
  `swift test` passed 635 tests in 45 suites on macOS. The same 21 focused tests passed with the
  official Swift 6.1.3 image on `aarch64-unknown-linux-gnu`, including incremental SSE and both
  cancellation timings. The MCP target also builds with the official Swift 6.0 Linux image after
  making the stored cancellation closure's existing `@Sendable` contract explicit.
  `mcp-everything-client` links successfully with `--static-swift-stdlib` in the Swift 6.1 Linux
  image; the linker emits only its existing Foundation `mktemp` warnings.
  `swift package dump-package` and the Swift 6.0 manifest parse both passed. No package requirement
  or dependency was added.
- Review unit 6, `mcp-2026-http-server`: focused tests cover POST-only behavior, notifications,
  Origin/Accept/Content-Type validation, missing and mismatched version metadata, structured
  unsupported-version errors, missing client capabilities, rejected batches/client responses,
  direct JSON, HTTP context, exact method-not-found status, request-scoped SSE ordering, forbidden
  server requests, concurrent clients reusing an id while completing out of order, and
  cancellation before headers and during streaming. The focused run passed 15 tests on macOS
  and the official Swift 6.1.3 Linux image;
  `swift test` passed 650 tests in 46 suites on macOS. The MCP target builds with the official
  Swift 6.0 Linux image. The server executable links with `--static-swift-stdlib` against the
  repository's pinned dependencies in the Swift 6.1 image, with only Foundation's existing
  `mktemp` linker warnings. `swift package dump-package` and the Swift 6.0 manifest parse passed.
  No package requirement or dependency was added.
- Review unit 7, `mcp-2026-http-lifecycle-routing`: focused tests cover routing by opening
  mechanism, lifecycle-metadata precedence over session headers, known initialization-version
  headers and session methods, malformed metadata without fallback, structured unknown-version
  errors, per-request `initialize` rejection, and isolation through each runtime protocol mode.
  The focused run passed 7 tests on macOS and the official Swift 6.1.3 Linux image;
  `swift test` passed 657 tests in 47 suites on macOS. The MCP target builds with the official
  Swift 6.0 Linux image, and the server executable links with `--static-swift-stdlib` in the
  Swift 6.1 image with only Foundation's existing `mktemp` warnings. `swift package dump-package`
  and the Swift 6.0 manifest parse passed. No package requirement or dependency was added.
- Review unit 8, `mcp-2026-tool-headers`: focused tests cover every standard name source,
  case-insensitive header names, case-sensitive values, exact visible-ASCII and Base64 sentinel
  encoding, safe integer and boolean formatting, null omission, numeric comparison, static nested
  schema reachability, invalid-schema filtering, the official structured-error fixture, server
  schema activation, and the constrained refresh/retry path. Scripted HTTP peers verify a fresh
  retry id, full paginated refresh, no retry for standard headers or unchanged schemas, and
  generic `tools/list` filtering. The focused runs passed 11 header-model tests, 25 HTTP-client
  tests, and 18 HTTP-server tests; `swift test` passed 675 tests in 48 suites on macOS.
  The combined 54 focused tests passed with the official Swift 6.1.3 image on
  `aarch64-unknown-linux-gnu`. The MCP target builds with the official Swift 6.0 Linux image,
  and the server executable links with `--static-swift-stdlib` in the Swift 6.1 image with only
  Foundation's existing `mktemp` warnings. `swift package dump-package` and the Swift 6.0
  manifest parse passed. No package requirement or dependency was added.
- Review unit 9, `mcp-2026-subscriptions`: focused tests cover the three official fixtures,
  acknowledgment-first ordering, accepted-filter validation, selected-notification correlation,
  exact resource filtering, concurrent independent listeners, explicit reconnect with a stable
  id, bounded slow-consumer failure, FIFO publisher backpressure, cancellation and shutdown of
  blocked publishers, graceful server closure, request-scoped log filtering, removed-method
  rejection, roots capability encoding, strict request-scoped SSE correlation, and original-id
  preservation through HTTP routing. A protocol error after acknowledgment terminates the event
  stream, while transport closure remains reconnectable. The timing-aware test transport holds
  an acknowledgment write open to verify that the next publisher suspends, ordering is retained,
  overflow is explicit, and cancellation or shutdown releases blocked work. The 98 affected
  tests passed on macOS and with the official Swift 6.1.3 image on
  `aarch64-unknown-linux-gnu`; `swift test` passed 699 tests in 49 suites on macOS. The MCP target
  builds with the official Swift 6.0 Linux image. No manifest, package requirement, platform
  requirement, or dependency was added.
  Closing a subscription during server shutdown exposed a waiter race: removing a pending waiter
  before response dispatch could leave the request task suspended, so closure now signals that
  waiter and lets the normal dispatch path remove it. The cancellation test also records that a
  custom `URLProtocol` may report `stopLoading()` asynchronously; it uses a short bounded wait
  for that callback instead of assuming cancellation completion and callback delivery are the
  same event. No package requirement or dependency was added.
- Review unit 10, `mcp-2026-response-caching`: focused tests cover the five official cacheable
  result fixtures, monotonic freshness, per-call policies, zero and negative peer TTL handling,
  the 512-entry configuration bound, least-recently-used eviction, disabled mode, pagination
  keys and scope consistency, public and private authorization partitions, exact completed-attempt
  authorization, unavailable custom authorization, caller-metadata and capability keys, list and
  exact-resource notification invalidation, malformed server policies, conservative defaults for
  existing handlers, and exclusion of multi-round-trip results. Pagination scope tracking follows
  cursor chains rather than applying one scope to every independent call of a list method; public
  chains remain consistent across authorization changes, while private chains retain their exact
  attempt partition. Requests with request-scoped logging bypass reuse so the requested server log
  side effects are not lost. The 15 focused tests and the complete 715 tests in 50 suites passed
  on macOS. The 49 affected cache, subscription, negotiation, and HTTP-attempt tests passed with
  the official Swift 6.1.3 image on `aarch64-unknown-linux-gnu`. The MCP target builds with the
  official Swift 6.0 Linux image, and the server executable links with
  `--static-swift-stdlib` in the Swift 6.1 image with only Foundation's existing `mktemp` linker
  warnings. `swift package dump-package` and the Swift 6.0 compatibility-manifest parse passed.
  The result models remain optional for earlier-version decoding, while the per-request-metadata
  server boundary supplies a non-reusable policy for unchanged handlers and rejects partial or
  invalid policies. This unit implements `server/utilities/caching#cacheable-results`,
  `#cache-key`, `#cacheable-model`, `#cache-scope-field`, `#interaction-with-notifications`,
  `#interaction-with-pagination`, and `#security-considerations`. No package requirement or
  dependency was added.
- Review unit 11, `mcp-2026-conformance`: the 2026-07-28 runner is pinned to
  `@modelcontextprotocol/conformance@0.2.0-alpha.11` and uses that release's
  `--requirements 2026-07-28` interface. It waits for a live, responsive server instead of using
  a fixed delay, captures logs and per-scenario results, preserves the runner's exit status, and
  accepts an expected-failures file only when one is supplied explicitly. The existing
  initialization-based runner is independently pinned to `v0.1.15`.
  The client run completed all 39 scenarios with every scored requirement passing. The runner
  reported 423 passed checks, 13 failed checks, and one warning overall; all 13 failures belong
  to five unscored extension or added-after-release scenarios. The server run completed all 50
  scenarios with every scored requirement passing. It initially reported 160 passed and 31 failed
  checks. Six pending custom-header failures exposed a real server-configuration defect despite
  not being scored. After the aggregate review fixed that wiring, the 2026-08-14 rerun reported
  166 passed and 25 failed checks; all custom-header checks passed and the remaining failures are
  confined to the Tasks extension. No baseline suppresses either result. Unsupported task, DPoP,
  enterprise authorization, workload identity, and
  post-release JSON Schema scenarios remain visible in the artifacts rather than being presented
  as 2026-07-28 support.
  Six focused NIO adapter tests pass on macOS. The original five also pass on the official Swift
  6.1.3 Linux image. They use
  the real `StreamableHTTPServerTransport` and asynchronous NIO channel to cover disconnection
  before routing completes, disconnection during request-scoped SSE, failed body writes, exact
  head/body/end ordering, and cancellation of two concurrent requests. This directly exercises
  `basic/transports/streamable-http#cancellation`,
  `basic/patterns/cancellation#transport-specific-cancellation`, and the streaming order in
  `basic/transports/streamable-http#receiving-messages`. The complete macOS run passed the 715 SDK
  tests in 50 suites plus the 5 adapter tests in their separate suite. Both conformance
  executables build as part of that run. The package-only support target adds no product,
  production dependency, platform requirement, or minimum Swift requirement.
- Review unit 12, `mcp-2026-defaults-release`: `Version.latest` is `2026-07-28`, while a follow-up
  compatibility review keeps new clients and servers initialization-only by default. Focused tests
  verify default-to-default initialization, explicit automatic/per-request selection, and matching
  programmatic and decoded configuration defaults.
  `connect(transport:)` keeps its established `Initialize.Result` return type. When a
  per-request-metadata server omits its optional identity, that wrapper supplies the documented
  `unknown` / `0.0.0` placeholder required by the older result shape; `connectWithInfo` preserves
  the omission as `nil`. A paired regression test covers both entry points.
  The complete macOS run passed 717 SDK tests in 50 suites plus 5 conformance-adapter tests. The
  official Swift 6.1.3 Linux image passed all 638 tests available on that platform, including the
  adapter suite. The MCP target builds with the Swift 6.0.3 Linux image, and the server executable
  links with the static Swift runtime in the Swift 6.1.3 image with only Foundation's existing
  `mktemp` linker warning. Both pinned
  `2026-07-28` conformance legs pass every scored requirement with the unscored results described
  in review unit 11 unchanged. The separately pinned `v0.1.15` initialization-based run passed
  223 client checks and 47 server checks with no unexpected failure. This implements
  `basic/versioning#protocol-version-negotiation` and
  `#backward-compatibility-with-initialization-based-versions`. The README and migration guide
  document minimal and full weather-client and weather-server migrations, staged runtime
  isolation, source-compatibility considerations, security boundaries, and the absence of a new
  package, platform, or Swift requirement. Public APIs introduced or changed by this revision use
  the repository's existing DocC style. The warnings-as-errors DocC build passes, and the guide's
  client, server, multi-round-trip, cache, subscription, and tool-header examples type-check with
  compiler warnings treated as errors.

## Protocol coverage audit (2026-08-11)

The final test matrix covers:

- every supported initialization-based revision, the `2026-07-28` per-request-metadata revision,
  `Version.latest`, and the initialization-safe model and transport defaults;
- automatic selection against initialization-only, per-request-metadata-only, and combined
  servers, plus both incompatible lifecycle-only client/server pairs;
- stdio-style timeout fallback, caller cancellation with and without a timeout, HTTP 400/404/405
  compatibility fallback, and non-fallback behavior for HTTP 401/403/408/429/500 and protocol
  errors `-32020`, `-32021`, and `-32022`;
- newly constructed client and server defaults, conservative decoding of stored configurations,
  and all new configuration fields; and
- discovery, metadata and result validation, multi-round trips, both HTTP server paths and their
  router, request headers, subscriptions and request-scoped logging, response caching, OAuth
  issuer binding, and both conformance adapters.

Only one per-request-metadata revision is defined and supported at this tag. A successful
`-32022` retry to a different mutually supported per-request revision therefore cannot be
constructed without inventing a protocol version. Tests instead verify that `-32022` never falls
back to initialization, that no-common-version discovery fails, and that the server returns its
exact supported preference list. When another per-request-metadata revision is added, its review
unit must add the successful alternate-version retry case.

## Deep review record (2026-08-11)

A full-stack code review was performed against both the final aggregate branch and every
individual feature delta. The review used three independent passes covering protocol/client
behavior, HTTP/OAuth/server behavior, and stack boundaries/dependencies. The resulting fixes and
focused tests were placed in their owning review units rather than accumulated at the end of the
stack:

- Unit 1 now preserves open capability objects, validates object-valued capability settings and
  extension identifiers, and accepts every JSON shape allowed for sampling tool results.
- Unit 2 binds stored tokens and credential provenance to the exact authorization-server issuer,
  selects the correct advertised issuer, distinguishes CIMD from DCR, and scopes retryable DCR
  attempts to an issuer.
- Unit 3 confines discovery timeouts to stdio-style probing, retires cancelled probes before
  fallback even when no timeout is configured, validates result types, handles `-32022`
  negotiation, and preserves strict
  initialization ordering on combined servers.
- Unit 4 rejects standalone roots, sampling, and elicitation requests in the per-request-metadata
  lifecycle.
- Units 5, 6, and 8 preserve initialization-version defaults, correct authorization retry and SSE
  BOM behavior, validate required HTTP metadata with the specified error mapping, normalize HTTP
  optional whitespace, and isolate learned tool-header schemas by client context.
- Unit 9 bounds both client delivery and server waiting publishers and tests slow-consumer,
  cancellation, shutdown, and ordering behavior.
- Unit 10 binds private cache partitions to the exact request attempt, retains caller metadata
  and capability context in keys, and supplies a conservative non-reusable policy for unchanged
  handlers.
- Unit 11 cancels conformance adapter work on channel and write failure and tests concurrent
  cancellation and exact streaming order directly.
- Unit 12 contains only the default flip, initialization-safe version selection, associated
  compatibility tests, and release documentation. It also documents and tests the established
  `connect(transport:)` result placeholder used when a per-request server omits its identity.

The completed review-unit aggregate passed 717 SDK tests in 50 suites plus 5 adapter tests on
macOS and all 638 tests available in the Swift 6.1.3 Linux image. Post-review compatibility and
HTTP policy corrections bring the macOS aggregate to 730 SDK tests plus the same 5 adapter tests;
the Linux matrix was not repeated for that follow-up. The MCP target also builds in the official
Swift 6.0.3 Linux image. Both `2026-07-28` conformance legs pass every scored alpha.11 requirement,
and the separately pinned `v0.1.15` run has no unexpected failure. Unscored conformance results
remain recorded in unit 11 rather than being suppressed.

The 2026-08-14 aggregate corrections bring the current macOS result to 746 SDK tests in 51 suites
plus 6 adapter tests in 1 suite. The pinned server run reports 166 passes and 25 unscored Tasks
extension failures; all ten custom-header checks now pass. These current counts supersede the
progressive macOS counts above without implying that the Linux matrix was rerun.

The warnings-as-errors documentation build found two undocumented public OAuth configuration
parameters. Their descriptions now live with the initializer in review unit 2, and the final
documentation archive builds successfully. The aggregate review later removed the proposed
package-specific protocol availability callouts in favor of the repository's existing DocC style.
Review unit 12 retains the affected specification links. The compiler still reports the pre-existing
`NetworkTransport` capture warning; this stack does not change that unrelated implementation.

Editable pull request bodies and the exact stacked base/head mapping live in
`Documentation/PullRequests/MCP-2026-07-28`. The helper script
`scripts/create-mcp-2026-pull-requests.sh` previews the stack by default, never pushes branches,
creates drafts only after an explicit `--submit`, and verifies the local base/head ancestry before
submission. These review materials live only on the aggregate branch so feature diffs are not
polluted with submission bookkeeping.

No package dependency, Swift language requirement, or platform minimum was added by the review
or its pull request preparation.

## Writing and commit conventions

Names, comments, documentation, and commits use plain English plus established MCP,
JSON-RPC, HTTP, OAuth, Swift, and concurrency terminology. Comments explain protocol
requirements, compatibility constraints, or non-obvious ordering. They do not narrate the
implementation. Documentation distinguishes specification requirements from SDK policy.

Do not add copyright notices, generated-by statements, assistant or tool attribution, or
attribution trailers.
