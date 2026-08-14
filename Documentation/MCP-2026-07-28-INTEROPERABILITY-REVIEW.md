# MCP 2026-07-28 interoperability review

Date: 2026-08-13

Status: verified design review at the recorded revision; findings were subsequently implemented
and folded into their owning review units

Swift SDK revision: `8e8f00854070c4cedf86e8702ce195d28e44c0f0`

Specification revision: `b25c0874bf0ba699a58e21ef06f659d839659de3`

Official conformance revision: `c321dd32035556e6769d3724a8ee97d87c3faaac`

## Executive decision

The downstream review identified four useful areas, but two of its conclusions are materially
wrong:

| Area | Verified disposition | Priority |
| --- | --- | ---: |
| HTTP `server/discover` fallback | **Change Swift.** A correlated `-32601` response to the mandatory discovery probe is legacy evidence even when a deployed legacy server wraps it in HTTP 200. The report was wrong to call that legacy response spec-conforming and wrong that C# does not fall back, but the interoperability failure is real. | P0 |
| `streaming` under the modern lifecycle | **Do not reject or warn.** The session and standalone GET stream are forbidden by the modern binding, so clearing them is correct. Rename the API to say what it actually controls and retain a deprecated compatibility initializer for the already-shipped label. | P1 API clarity |
| HTTP media-type validation | **Change Swift.** `Accept` and `Content-Type` compare media types case-sensitively; `Accept` also uses unsafe prefix matching. Implement one HTTP-aware parser and test quality values and wildcards rather than accepting the proposed patch verbatim. | P1 |
| Handler-emitted progress documentation | **Add documentation.** Base it on the compiled conformance handler and correct the proposed detached-task guidance. Progress must finish before the handler returns. | P1 docs |

The implementation followed this disposition. Because none of the affected units had begun
upstream review, each behavior change was folded into the unit that introduced its boundary and all
successors were restacked.

## What “breaking release” means for `streaming`

It means a Swift source/API break between releases of this package, not a protocol-version break
between `2025-11-25` and `2026-07-28`, and not merely a break between experimental builds of the
new protocol work.

The `streaming:` initializer label exists on `origin/main`, before the 2026 implementation. A hard
rename would therefore break an existing application when it upgrades the SDK even if that
application only speaks an initialization-era MCP revision. Your experimental 2026 call sites do
not need compatibility, but an upstream-quality PR still needs to account for the public API that
has already shipped.

The recommended source-compatible cleanup can be made now:

```swift
public init(
    endpoint: URL,
    configuration: URLSessionConfiguration = .default,
    enableStandaloneGetStream: Bool = true,
    // ...
)

@available(*, deprecated, renamed: "init(endpoint:configuration:enableStandaloneGetStream:sseInitializationTimeout:protocolVersion:authorizer:requestModifier:logger:)")
public init(
    endpoint: URL,
    configuration: URLSessionConfiguration = .default,
    streaming: Bool,
    // ...
)
```

The old overload must not retain a default for `streaming`; otherwise a call containing only
`endpoint:` would be ambiguous. It forwards to the canonical initializer. The canonical value can
also be exposed as a read-only property:

```swift
public nonisolated let enableStandaloneGetStream: Bool
```

That is clearer than adding a differently named `standaloneSSEEnabledForInitialization` property
while leaving `streaming` as the canonical initializer label. A hard rename is acceptable on a
private experimental fork, but the forwarding form costs little and is suitable upstream.

## Evidence and authority

The order of authority used here is:

1. the dated MCP specification and schema;
2. HTTP's normative semantics where MCP uses HTTP fields;
3. the official conformance suite and its scenario/reference endpoints;
4. official SDK implementations as interoperability evidence, not as a replacement for the spec;
5. downstream observations as reproducers.

The local dated spec lists ten official SDKs: TypeScript, Python, C#, Go, Java, Rust, Ruby, Swift,
PHP, and Kotlin.[^official-sdks] The detailed code comparison below uses pinned TypeScript, Python,
Go, C#, and Rust snapshots because those five have complete 2026-era client/server work and were
already surveyed locally. This is sufficient to establish consensus for the specific fallback
case. The proposed compatibility harness expands to every official SDK in phases rather than
pretending the smaller source survey is a complete ecosystem result.

## 1. Automatic fallback after HTTP 200 plus `-32601`

### What Swift does now

`Client.connectWithInfo` starts `.automatic` connections on the per-request lifecycle and calls
`discoverConnection`. It falls back only when the transport throws
`ProtocolLifecycleProbeError.initializationBasedResponse`; ordinary errors from an
`HTTPProtocolNegotiationTransport` are not eligible for the generic fallback path:

- `Sources/MCP/Client/Client.swift:673-686` selects the modern lifecycle before connect;
- `:760-777` handles the automatic decision;
- `:1843-1870` sends and awaits `server/discover`;
- `:1974-1987` recognizes three modern error codes and disables generic fallback for HTTP.

`HTTPClientTransport.processPerRequestMetadataResponse` only classifies HTTP 400, 404, or 405 as
an initialization-era response, and it does that inside the non-200 branch
(`Sources/MCP/Base/Transports/HTTPClientTransport.swift:843-890`). A JSON-RPC error returned with
HTTP 200 follows the normal response path and eventually surfaces as `MCPError.remote`.

There is an additional discovery-specific error in `:1135-1143`: HTTP 404 plus JSON-RPC
`-32601` is currently treated as proof of a modern server. The corresponding regression test at
`Tests/MCPTests/PerRequestHTTPClientTransportTests.swift:1203-1234` explicitly expects no fallback.
That rule is valid for an arbitrary unknown modern RPC method, but not for `server/discover`, which
every modern server MUST implement.

### What the spec actually says

The downstream report calls a 2025 server's HTTP 200 response “legal” under MCP. That is too
strong. A 2025-11-25 Streamable HTTP server receiving the unsupported `MCP-Protocol-Version:
2026-07-28` header MUST return HTTP 400, not 200.[^spec-2025-header] Such a server is a common and
understandable deployed JSON-RPC implementation, but its response does not conform to that MCP
transport requirement.

The new spec nevertheless intends dual-era clients to tolerate legacy variation:

- stdio says any error other than a recognized modern error, or a timeout, identifies a legacy
  server, and explicitly forbids keying fallback to one error code;
- the general versioning page says a recognized modern error identifies modern and “anything else”
  identifies legacy;
- the HTTP binding describes the inspection specifically for HTTP 400;
- the compatibility matrix describes HTTP fallback on an unrecognized `4xx`;
- the deprecated HTTP+SSE transition text names 400, 404, and 405.[^spec-fallback]

Those statements are internally narrower and broader in different places. In addition,
`server/discover` is mandatory for a modern server,[^spec-discover] while the HTTP method rule says
an unknown method is returned as HTTP 404 plus `-32601`. The latter cannot be modern evidence when
the method being tested is the mandatory discovery method.

This is therefore both a Swift bug and a small specification-clarity issue. Client tolerance does
not make the legacy server's HTTP 200 response conforming.

### What the official SDKs do

All five inspected SDKs classify the specific correlated `-32601` discovery result as legacy,
including an in-band error that an HTTP transport received with status 200:

| SDK and pinned revision | Evidence | Result |
| --- | --- | --- |
| TypeScript `cc4b416` | `probeClassifier.ts:211-243`; test explicitly names “200-bodied HTTP” | legacy |
| Python `6e30452` | `_probe.py:67-103`; every non-actionable `MCPError` falls back | legacy |
| Go `64e454e` | `client.go:319-378`; `streamable_client_test.go:1443-1485` uses HTTP 200 + MethodNotFound | legacy |
| C# `6fa3825` | `McpClientImpl.cs:321-400`; ordinary `McpProtocolException` falls back and the HTTP transport decodes a 200 JSON-RPC error | legacy |
| Rust `f713ebd` | `service/client.rs:917-1024`; correlated non-modern JSON-RPC errors return `DiscoverOutcome::Legacy` | legacy |

The downstream survey's statement that C# only falls back on HTTP 400 is contradicted by its code.
C# has a separate catch for bare HTTP 400/404, but a JSON-RPC error decoded from an HTTP 200 enters
the broader `McpProtocolException` fallback arm.[^sdk-fallback]

The broader fallback classifiers are not identical. In particular, the SDKs differ on malformed
modern errors, timeout policy, and some `-32020`/`-32021` cases. The consensus asserted here is only
the isolated `server/discover` plus correlated `-32601` case.

### Smallest isolated reproducer

Request:

```http
POST /mcp HTTP/1.1
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: server/discover

{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
```

Deployed legacy response:

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
```

The isolated question is: should a dual-era HTTP client treat a correlated, non-modern JSON-RPC
error to the mandatory discovery probe as legacy evidence when the legacy peer used a nonconforming
HTTP status?

### Available fixes and tradeoffs

1. **Documentation only.** This preserves current behavior but contradicts every inspected official
   SDK and makes `.automatic` unsuitable for heterogeneous deployments. Rejected.
2. **Fallback only for HTTP 200 plus exactly `-32601`.** This fixes the measured case with the
   narrowest behavior change, but recreates the mistake corrected by spec PR #2844: legacy servers
   use other implementation-defined errors.[^spec-pr-2844]
3. **For a correlated `server/discover` response, treat every JSON-RPC error that is not recognized
   modern evidence as legacy evidence, independent of HTTP status.** Keep authorization failures,
   transport failures, and transient 5xx failures inconclusive. Malformed or uncorrelated bodies on
   compatibility status 400, 404, or 405 are legacy evidence under the dated HTTP binding. This
   follows the probe's semantics and the official SDK consensus. **Recommended.**
4. **Fallback after any failed HTTP request.** This can replay after auth, rate limiting, or an
   outage and can misclassify gateways as legacy. Rejected.

Implementation should centralize the decision in a discovery-outcome classifier rather than split
it between status handling in the transport and error handling in `Client`. Tests should cover HTTP
200 and 404 with `-32601`, another non-modern correlated error, all three modern errors, auth,
408/429/5xx, cancellation, malformed and mismatched-ID compatibility responses, and an initialization
control that proves the same endpoint works after fallback.

### Specification PR recommendation

File a small documentation PR using the reproducer above. The chosen clarification should say that
when a dual-era HTTP client uses `server/discover` as its era probe, any correlated JSON-RPC error
that is not recognized modern evidence can identify a legacy server even if a deployed legacy peer
wrapped it in a success status. It should explicitly preserve the server-side requirement to use
the specified HTTP error status. It should also reconcile “400”, “4xx”, and “400/404/405” across the
three compatibility sections.

## 2. Standalone SSE and session state

### Why the current lifecycle behavior is correct

The modern Streamable HTTP binding has no session, standalone GET stream, DELETE termination,
`Last-Event-ID` resumption, or unsolicited server stream. Those are explicitly described as
earlier-revision mechanisms that are absent in 2026-07-28.[^spec-http-era]

Accordingly, `HTTPClientTransport.updateProtocolLifecycle` cancels the standalone GET task and
clears `sessionID` and `lastEventID` when the client selects `.perRequestMetadata`
(`Sources/MCP/Base/Transports/HTTPClientTransport.swift:445-465`). Request-scoped POST responses
can still use SSE. They are not controlled by the `streaming` flag.

Rejecting `streaming: true` with `.automatic` or `.perRequestMetadataOnly` would make the
transport's default initializer invalid in the normal modern configuration because `streaming`
defaults to true. A warning would likewise report a correct lifecycle transition as a problem.
Adding a `ConnectionInfo` “transport adjustment” is unnecessary: `ConnectionInfo.protocolLifecycle`
already tells the application which lifecycle was selected, and the renamed read-only transport
property tells it whether a standalone GET would be enabled on the initialization lifecycle.

### Recommended API change

- Rename the stored property and canonical initializer label to
  `enableStandaloneGetStream`.
- Make the property public and read-only.
- Keep the old explicit `streaming:` initializer as a deprecated forwarding overload because the
  label predates this protocol work.
- Update comments to use “standalone GET event stream” for initialization-era behavior and
  “request-scoped SSE response” for the modern behavior.
- Do not throw, warn, or add a `transportAdjustments` field.

Tests should prove that the old and new initializers configure the same behavior; standalone GET
starts only under initialization; an automatic fallback starts it; selecting modern clears session
state; and request-scoped SSE still works regardless of the standalone option.

## 3. `Accept` and `Content-Type` parsing

### Verified Swift defects

`AcceptHeaderValidator` splits on commas and uses case-sensitive `hasPrefix`
(`Sources/MCP/Base/Transports/HTTPServer/HTTPRequestValidation.swift:79-86`). Consequently:

- `Application/JSON` and `Text/Event-Stream` are rejected even though media type and subtype tokens
  are case-insensitive;
- `application/jsonwhatever` and `text/event-streamx` are accepted;
- parameters happen to work only because of the unsafe prefix match;
- quality `q=0` is ignored and therefore treated as acceptance.

The adjacent `ContentTypeValidator` strips parameters but compares the remaining token
case-sensitively (`:139-151`). It rejects `Application/JSON; charset=utf-8` for the same reason.
RFC 9110 defines the case rule in section 8.3.1, the Accept grammar and wildcard precedence in
section 12.5.1, and `q=0` as not acceptable in section 12.4.2.[^rfc-9110]

The downstream patch fixes case and prefix matching but should not be merged verbatim. It adds
wildcards while ignoring quality values and precedence; for example, a naive wildcard check would
accept `Accept: */*;q=1, application/json;q=0` even though the more specific JSON range makes JSON
unacceptable.

### Official SDK behavior

The official SDKs are not consistent enough to substitute for HTTP semantics:

| SDK | Current implementation |
| --- | --- |
| Go | lowercases, strips parameters, accepts exact and wildcard ranges; does not evaluate `q` |
| Python | same broad behavior as Go; does not evaluate `q` |
| C# | uses ASP.NET's typed `MediaTypeHeaderValue.MatchesMediaType`, including framework parsing |
| TypeScript | raw, case-sensitive substring checks; an open issue reports the same suffix/case defect |
| Rust | raw substring/`starts_with` checks; case-sensitive |

The TypeScript issue independently proposes parsed, case-insensitive media-type essence matching,
which corroborates the Swift defect but does not resolve wildcard or quality semantics.[^ts-accept]

### Recommended implementation

Add one small internal parser shared by `AcceptHeaderValidator` and `ContentTypeValidator`:

- parse comma-separated Accept media ranges;
- normalize type and subtype case only;
- parse parameters and a valid quality value;
- determine the effective quality for each required representation using exact > type wildcard >
  global wildcard precedence;
- consider the representation acceptable only when its effective quality is greater than zero;
- parse Content-Type as one media type, allow parameters, and require an exact
  `application/json` essence;
- reject invalid syntax and suffix matches conservatively.

This follows HTTP and makes wildcard handling principled. If maintainers prefer MCP to require the
two literal ranges rather than ordinary HTTP wildcard semantics, the spec must say that explicitly;
today the phrase “listing both” is ambiguous. A minimal spec issue can ask whether `Accept: */*`
counts and use `Accept: */*;q=1, application/json;q=0, text/event-stream` to expose the quality and
precedence question. The preferred clarification is that each required response type must have an
effective nonzero quality under RFC 9110; a wildcard may satisfy that rule and `q=0` may not.

Tests should cover mixed case, optional whitespace, multiple field values, parameters, exact
suffix rejection, malformed quality, `q=0`, exact-over-wildcard precedence, type wildcard, global
wildcard, missing fields, and mixed-case parameterized Content-Type.

## 4. Handler-emitted progress documentation

The documentation gap is real. The migration guide shows `Server.notify` only for cache
invalidation and subscription broadcasts. A reader can therefore miss the request-scoped path.
All five surveyed official SDKs show progress from inside a handler, and four source those snippets
from compiled examples.

Swift already has the correct mechanism:

- the compiled conformance handler reads `params._meta?.progressToken` and sends three increasing
  `ProgressNotification` values (`Sources/MCPConformance/Server/main.swift:383-432`);
- `Server.notify` sends an initialization-era notification on the established connection, or uses
  `RequestScopedSending.send(_:relatedTo:)` for a modern request
  (`Sources/MCP/Server/Server.swift:711-768`);
- the HTTP server test proves the related notification precedes the final response on the same SSE
  response (`Tests/MCPTests/StreamableHTTPServerTransportTests.swift:752-792`);
- the progress spec requires the original token, monotonically increasing values, and no
  notification after completion.[^spec-progress]

The proposed Graph snippet should be revised before inclusion:

1. Derive the published snippet from the compiled conformance pattern or add a compile-checked
   migration example. Do not land an explicitly uncompiled block.
2. Preserve one token for the operation and increase progress across all rounds/authors.
3. Await progress emission from the handler task or from structured child tasks before returning.
4. Do not advise merely capturing `Server.currentHandlerContext` for `Task.detached`. Detached tasks
   do not inherit the task-local, and manually restoring a captured context after the handler
   returns can target an already-closed request stream. An unstructured `Task {}` can inherit the
   context but has the same lifetime problem if it is not joined.
5. State that absent `progressToken` means no notification, and that initialization-era and modern
   delivery differ even though handler source is the same.

This is documentation, not a new progress API. Python's context helper is convenient, but Swift's
token-plus-notify shape matches TypeScript, C#, and Go and is already exercised.

## 5. Complete compatibility matrix harness

### What exists today

The official `modelcontextprotocol/conformance` runner is the correct foundation. At pinned
revision `c321dd3` it:

- owns client and server scenarios, checks, wire-schema validation, result files, and expected
  failure baselines;
- can clone an SDK at an exact ref, build it, and run either its client or its server adapter;
- supports per-spec command/URL overrides;
- has `KNOWN_SDKS` entries for TypeScript v2/v1, Python main/v1, Go, C#, and Rust.[^conformance]

It does not currently contain a Swift entry, Java/Ruby/PHP/Kotlin entries, or an arbitrary
client-SDK × server-SDK pair command. “Cross-SDK CI” in its README currently means applying the
same reference conformance scenarios to multiple SDKs independently. Its own CI only tests the
runner. Pairwise interoperability is therefore a genuine additional layer.

### Scope and matrix size

Do not define “popular” ad hoc. Use the official SDK list and stage it by tier:

- Wave 1: Swift plus TypeScript, Python, C#, Go, and Rust. This covers every Tier 1 SDK, the Swift
  SDK under development, and the other mature 2026 implementation already surveyed.
- Wave 2: Java, Ruby, PHP, and Kotlin, completing all ten official SDKs as their adapters can expose
  the required lifecycle modes.

For each implementation keep two pinned generations: the last initialization-era release and the
selected 2026-capable ref/release. Wave 1 is 12 directional client/server variants: 144 pair cells
per transport, or 288 across HTTP and stdio before scenario multiplication. The complete ten-SDK
matrix is 20 variants: 400 cells per transport, or 800 across both. This is a nightly/release suite,
not a single blocking PR job.

The axes must be explicit:

- client SDK, exact ref, and mode: legacy-only, automatic/dual, modern-only;
- server SDK, exact ref, and mode: legacy-only, dual endpoint, modern-only;
- transport: Streamable HTTP and stdio; deprecated HTTP+SSE is a separate legacy lane;
- expected negotiated lifecycle/version;
- scenario profile: discovery/initialize, core calls, JSON/SSE response, progress, cancellation,
  session GET/DELETE, subscriptions, and representative structured errors.

The initial normative era matrix should be generated into every SDK-pair report before any
implementation-specific deviations are applied:

| Client mode | Legacy server | Dual-era server | Modern server |
| --- | --- | --- | --- |
| Legacy-only | Works on the negotiated initialization revision | Works on the initialization leg | Expected rejection; there is no fall-forward mechanism |
| Automatic / dual-era | Works after a conclusive legacy probe and `initialize` fallback | Works; normally selects modern after discovery | Works on modern |
| Modern-only | Expected rejection; no fallback was requested | Works on modern | Works on modern |

Each concrete cell refines “works” with a negotiated version, carrier, and feature profile. For
example, progress on initialization-era HTTP uses the session connection, whereas modern HTTP uses
the originating POST's request-scoped SSE response. An SDK that lacks a requested transport or
mode is `unsupported`, not a protocol failure.

### Expectations must not be overwritten by observations

Maintain three separate artifacts:

1. `expectations`: a reviewed normative outcome with a spec citation, such as
   `modern`, `legacy-fallback`, `expected-rejection`, or `unsupported`;
2. `observations`: immutable machine output recording actual status, negotiated version/lifecycle,
   timing, exit/cancellation behavior, and sanitized wire evidence;
3. `deviations`: a reviewed explanation linking an SDK or spec issue, owner, expiry/recheck date,
   and whether the deviation is tolerated in CI.

Never update expectations automatically from an observed run. Generate the human-readable matrix
from these sources and make reconciliation produce a proposed diff. Otherwise a regression can
silently redefine itself as expected behavior.

### Test fidelity

Adapters must use the real SDK transports and real process/network boundaries. A test double that
only matches JSON shape is insufficient for the compatibility problems at issue: ordering,
request-scoped streaming, EOF, cancellation, task lifetime, and reconnection are part of the
contract.

- HTTP pairs should communicate over a real loopback TCP connection. Containers may isolate
  runtimes, but the harness must not replace streaming with buffered request/response fixtures.
- stdio pairs should use a real spawned child process with real pipes, closure, exit, and signal
  handling. A TCP relay pretending to be stdio would erase exactly the EOF and cancellation
  behavior the matrix needs to measure.
- Record multiple ordered events and monotonic timestamps, not only a final result.
- Retry infrastructure failures only. A protocol timeout or ordering failure is an observation,
  not flakiness to hide.

### Docker, VMs, or UTM

Use a hybrid CI design:

- **Docker/OCI for the primary Linux HTTP matrix.** Images give repeatable runtimes, cached builds,
  unprivileged isolation, and natural pair networking. Pin source refs and base-image digests.
- **Native CI processes for stdio.** Install/pin the two required toolchains in a shard and let the
  real client adapter spawn the real server command. This preserves process semantics more
  faithfully than joining two containers with a relay.
- **A native macOS lane for Swift Foundation/URLSession and EventSource behavior.** Linux-only
  containers cannot establish Apple-platform transport parity.
- **Optional Windows jobs** when a .NET/Java/Kotlin or process-lifecycle issue is Windows-specific.
- **Do not use UTM or general VMs for the baseline matrix.** They add slow image management and
  nested virtualization without improving protocol fidelity. Reserve VMs for reproducing an
  OS-specific defect that native hosted CI cannot cover.

The PR gate should run Swift self-pairs plus a star topology: Swift current client against each
pinned server, and each pinned client against Swift current server. Run current-current full
pairwise nightly, all legacy/current combinations on a slower nightly or weekly schedule, and the
complete matrix before release.

### Recommended PR decomposition

1. **Swift PR 11 amendment (or Swift follow-up):** stabilize the Swift everything-client/server
   adapter interface, expose explicit lifecycle/transport selection, and add adapter contract tests.
2. **Official conformance PR:** add `swift-sdk` and its exact build/client/server/spec overrides to
   `KNOWN_SDKS`. This is useful independently of pairwise testing.
3. **Official conformance PR:** add a pairwise `interop` command that resolves two known-SDK refs,
   starts the selected server adapter, runs the selected client scenario, and emits the existing
   check/result schema plus negotiated-era observations.
4. **Official conformance PR(s):** add compatibility profiles, normative expectations, deviations,
   sharding, and generated Markdown/JSON matrix output. Start with HTTP Wave 1.
5. **Follow-up PRs:** add stdio process contracts and Wave 2 SDK adapters; then CI schedules and
   artifact publication.

Keeping the generic pair runner in the official conformance repository prevents every SDK from
building its own incompatible matrix. The Swift repository should keep only its adapters, local
smoke invocation, pins/baseline for Swift-specific CI, and links to upstream observed results.

## 6. PR ownership and implementation order

| Change | Existing review unit | Submission rule |
| --- | --- | --- |
| Discovery outcome classifier and automatic fallback tests | PR 03, discovery/negotiation; HTTP status/body plumbing in PR 05 | Amend both source review units before upstream review; otherwise one focused interoperability PR after PR 05 |
| `enableStandaloneGetStream` plus deprecated `streaming:` forwarder | PR 05, HTTP client | Keep with HTTP client unless PR 05 is already under review |
| Accept and Content-Type parser/tests | PR 06, HTTP server | Keep with server validation unless PR 06 is already under review |
| Progress migration example/checklist | PR 12, defaults/release docs | Keep with migration guide; no implementation dependency |
| Swift adapter contract and local matrix smoke | PR 11, conformance | Keep generic pairwise orchestration out of Swift PR 11 |
| Fallback and Accept wording clarifications | MCP specification repository | Two isolated docs PRs/issues; do not couple them to Swift implementation review |
| Pairwise orchestrator and official SDK registrations | MCP conformance repository | New upstream PR series |

Implementation order for the next phase:

1. fix and test discovery classification, because Graph currently cannot safely trial `.automatic`;
2. rename/observe the standalone GET option with compatibility forwarding;
3. correct Accept and Content-Type parsing;
4. land the compiled progress example;
5. run focused and full Swift tests plus both conformance versions;
6. register Swift in the official conformance runner;
7. bootstrap the star compatibility matrix, then expand to full pairwise.

## Sources

[^official-sdks]: [MCP 2026-07-28 official SDK list](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/b25c0874bf0ba699a58e21ef06f659d839659de3/docs/docs/2026-07-28/sdk.mdx).

[^spec-2025-header]: [MCP 2025-11-25 Streamable HTTP, Protocol Version Header](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/b25c0874bf0ba699a58e21ef06f659d839659de3/docs/specification/2025-11-25/basic/transports.mdx#protocol-version-header).

[^spec-fallback]: [MCP 2026-07-28 versioning and compatibility](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/b25c0874bf0ba699a58e21ef06f659d839659de3/docs/specification/2026-07-28/basic/versioning.mdx#backward-compatibility-with-initialization-based-versions), [stdio backward compatibility](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/b25c0874bf0ba699a58e21ef06f659d839659de3/docs/specification/2026-07-28/basic/transports/stdio.mdx#backward-compatibility), and [Streamable HTTP backward compatibility](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/b25c0874bf0ba699a58e21ef06f659d839659de3/docs/specification/2026-07-28/basic/transports/streamable-http.mdx#backward-compatibility).

[^spec-discover]: [MCP 2026-07-28 `server/discover`](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/b25c0874bf0ba699a58e21ef06f659d839659de3/docs/specification/2026-07-28/server/discover.mdx) and [dated schema declaration](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/b25c0874bf0ba699a58e21ef06f659d839659de3/schema/2026-07-28/schema.ts#L653-L668).

[^sdk-fallback]: [TypeScript classifier](https://github.com/modelcontextprotocol/typescript-sdk/blob/cc4b41617ce3601b1290d67216ea0b194a3cd9ac/packages/client/src/client/probeClassifier.ts#L211-L243), [TypeScript 200-bodied test](https://github.com/modelcontextprotocol/typescript-sdk/blob/cc4b41617ce3601b1290d67216ea0b194a3cd9ac/packages/client/test/client/probeClassifier.test.ts#L164-L173), [Python negotiation](https://github.com/modelcontextprotocol/python-sdk/blob/6e304527a54a702fed84066bde8b7d8ce9cfeba7/src/mcp/client/_probe.py#L67-L112), [Go fallback fixture](https://github.com/modelcontextprotocol/go-sdk/blob/64e454e35c23c473e1fcf1e1c3a6f623260ca773/mcp/streamable_client_test.go#L1443-L1485), [C# negotiation](https://github.com/modelcontextprotocol/csharp-sdk/blob/6fa3825973949a9c4f0cd8af344e15a8db09dc35/src/ModelContextProtocol.Core/Client/McpClientImpl.cs#L321-L400), and [Rust discovery outcome](https://github.com/modelcontextprotocol/rust-sdk/blob/f713ebd1a6feab492fb730a8bc13026be114d82f/crates/rmcp/src/service/client.rs#L917-L1024).

[^spec-pr-2844]: [MCP specification PR #2844](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2844), “Fix stdio legacy-fallback rule and add a compatibility matrix.”

[^spec-http-era]: [MCP 2026-07-28, Earlier Streamable HTTP Revisions](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/b25c0874bf0ba699a58e21ef06f659d839659de3/docs/specification/2026-07-28/basic/transports/streamable-http.mdx#earlier-streamable-http-revisions).

[^rfc-9110]: [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html), sections 8.3.1, 12.4.2, and 12.5.1.

[^ts-accept]: [TypeScript SDK issue #2480, Streamable HTTP server accepts invalid media types](https://github.com/modelcontextprotocol/typescript-sdk/issues/2480).

[^spec-progress]: [MCP 2026-07-28 progress](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/b25c0874bf0ba699a58e21ef06f659d839659de3/docs/specification/2026-07-28/basic/patterns/progress.mdx).

[^conformance]: [Official MCP conformance repository at `c321dd3`](https://github.com/modelcontextprotocol/conformance/tree/c321dd32035556e6769d3724a8ee97d87c3faaac), especially [`KNOWN_SDKS`](https://github.com/modelcontextprotocol/conformance/blob/c321dd32035556e6769d3724a8ee97d87c3faaac/src/sdk-runner/known-sdks.ts) and the [SDK runner documentation](https://github.com/modelcontextprotocol/conformance/blob/c321dd32035556e6769d3724a8ee97d87c3faaac/README.md#running-against-an-sdk-at-a-specific-ref).
