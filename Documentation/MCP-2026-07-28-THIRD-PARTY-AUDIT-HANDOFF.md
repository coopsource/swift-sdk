# MCP 2026-07-28 Swift SDK third-party audit handoff

Date: 2026-08-14

> **Superseded for SHAs (2026-08-15).** The audit this document commissioned was completed and
> its Gate A applied, which restacked every branch. Every commit named below is therefore the
> pre-audit value, preserved here as the record of what was handed off and reachable through the
> `audit-20260815/*` tags. Current tips live in
> [`PullRequests/MCP-2026-07-28/README.md`](PullRequests/MCP-2026-07-28/README.md); the outcome
> is in [`MCP-2026-07-28-THIRD-PARTY-AUDIT-REPORT.md`](MCP-2026-07-28-THIRD-PARTY-AUDIT-REPORT.md).
> The runner-cache observations in "Generated SDK-matrix checkouts" are also historical: those
> caches were refreshed, and the stale and invalid ones deleted.

## Purpose

This document prepares an independent reviewer to audit the complete MCP `2026-07-28` support in
the Swift SDK. It identifies the authoritative protocol snapshot, local and remote repositories,
the stacked review units, important source and test boundaries, prior review evidence, known gaps,
and working-tree state that must not be confused with the committed implementation.

The audit target is the complete behavior on `swift-sdk-mcp-update-07-28-26`, but the implementation
must also be reviewed as twelve ordered feature deltas. The integration branch is not intended to be
submitted upstream as one pull request.

The review should prioritize:

- protocol and wire correctness against the released `2026-07-28` tag;
- compatibility with initialization-based revisions through `2025-11-25`;
- interoperability with other official SDKs;
- authentication, authorization, privacy, cache, and concurrent-request boundaries;
- cancellation, ordering, streaming, backpressure, and transport failure behavior;
- public API compatibility and idiomatic use of existing Swift SDK patterns; and
- whether each change belongs in its stated review unit.

Do not expand this work to repair an unrelated defect in the released SDK. Classify such a defect
separately and propose a new issue or independent pull request.

## Audit snapshot

The following values were verified on 2026-08-14:

| Item | Value |
| --- | --- |
| Official Swift SDK baseline | `a0ae212ebf6eab5f754c3129608bc5557637e605` (`main`, release `0.12.1`) |
| Swift aggregate branch | `swift-sdk-mcp-update-07-28-26` |
| Swift aggregate commit | `9e44edf65cb4b9780ccef3193bb3eed290a6a778` |
| Specification release tag | `2026-07-28` |
| Specification release commit | `5f5440bb26a62e2cf3440b92da5a667efa03b267` |
| Official conformance baseline | `c321dd32035556e6769d3724a8ee97d87c3faaac` (`0.2.0-alpha.11`) |
| Local conformance integration commit | `0f2796f59204d32f903879a3c91fbc39a64c86d4` |
| Initialization-based conformance pin | `@modelcontextprotocol/conformance@0.1.15` |
| 2026 conformance pin | `@modelcontextprotocol/conformance@0.2.0-alpha.11` |

The Swift aggregate contains 44 commits and changes 114 files relative to the official baseline:
22,905 insertions and 534 deletions. That size is the reason the feature-delta review is mandatory.

## Protocol authority

Use the dated release, not the mutable draft, as the normative source:

- [MCP `2026-07-28` specification](https://modelcontextprotocol.io/specification/2026-07-28)
- [versioning and compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
- [`server/discover`](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)
- [per-request metadata and result types](https://modelcontextprotocol.io/specification/2026-07-28/basic/index)
- [Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
- [multi-round-trip requests](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)
- [subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions)
- [response caching](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching)
- [authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
- [schema](https://modelcontextprotocol.io/specification/2026-07-28/schema)
- [changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
- [deprecated features](https://modelcontextprotocol.io/specification/2026-07-28/deprecated)

The exact tagged sources are available online at
[`modelcontextprotocol/modelcontextprotocol@5f5440b`](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/5f5440bb26a62e2cf3440b92da5a667efa03b267)
and locally in the sibling specification checkout described below. Relevant accepted proposals
include [SEP-2575](https://modelcontextprotocol.io/seps/2575-stateless-mcp),
[SEP-2322](https://modelcontextprotocol.io/seps/2322-MRTR),
[SEP-2243](https://modelcontextprotocol.io/seps/2243-http-standardization),
[SEP-2549](https://modelcontextprotocol.io/seps/2549-TTL-for-list-results),
[SEP-2567](https://modelcontextprotocol.io/seps/2567-sessionless-mcp),
[SEP-2468](https://modelcontextprotocol.io/seps/2468-recommend-issuer-claim-for-auth),
[SEP-2207](https://modelcontextprotocol.io/seps/2207-oidc-refresh-token-guidance),
[SEP-2133](https://modelcontextprotocol.io/seps/2133-extensions),
[SEP-2106](https://modelcontextprotocol.io/seps/2106-json-schema-2020-12), and
[SEP-2577](https://modelcontextprotocol.io/seps/2577-deprecate-roots-sampling-and-logging).

Tasks are an optional extension and are not implemented by this branch. Post-release draft changes,
including conformance scenarios added after the dated requirements were frozen, are not evidence of
a `2026-07-28` failure unless the released specification requires the behavior.

## Local repository inventory

### 1. Swift SDK: primary audit target

Local path:

`/Users/alan/projects/github/modelcontextprotocol/swift-sdk`

Remotes:

- official repository: <https://github.com/modelcontextprotocol/swift-sdk>
- contributor fork: <https://github.com/coopsource/swift-sdk>
- pushed aggregate: <https://github.com/coopsource/swift-sdk/tree/swift-sdk-mcp-update-07-28-26>

`origin` fetches from the official repository and has push disabled. `fork` is the only configured
push destination. The checked-out branch is the aggregate at `9e44edf`; it matches the fork.

The committed aggregate is based on official `main` at `a0ae212`. All twelve source review branches
are pushed to the contributor fork. Numerous `backup/...` and `restack/...` branches are local
safety points from earlier reviews; they are historical evidence, not submission branches.

### 2. MCP specification: tagged research input, locally unmodified

Local path:

`/Users/alan/projects/github/modelcontextprotocol/modelcontextprotocol`

Official repository:

<https://github.com/modelcontextprotocol/modelcontextprotocol>

The working tree is clean. Local `main` is `b25c0874bf0ba699a58e21ef06f659d839659de3`; the verified
remote `main` is `4df2d6b6e3588efb46e7542d98498e5c630a0a86`. That difference is immaterial to the audit because
the authority is the immutable `2026-07-28` tag at `5f5440b`. No specification change was made in
this checkout.

Key local tagged paths:

- `docs/specification/2026-07-28/`
- `docs/specification/2026-07-28/basic/versioning.mdx`
- `docs/specification/2026-07-28/basic/transports/streamable-http.mdx`
- `docs/specification/2026-07-28/basic/patterns/`
- `docs/specification/2026-07-28/server/discover.mdx`
- `docs/specification/2026-07-28/server/utilities/caching.mdx`
- `schema/2026-07-28/schema.ts`
- `schema/2026-07-28/schema.json`
- `schema/2026-07-28/examples/`

### 3. MCP conformance: local integration work, not pushed

Local path:

`/Users/alan/projects/github/modelcontextprotocol/conformance`

Official repository:

<https://github.com/modelcontextprotocol/conformance>

Current local branch and commit:

`codex/swift-sdk-conformance-integration` at
`0f2796f59204d32f903879a3c91fbc39a64c86d4`

The branch is clean and contains two commits above official `main` at `c321dd3`:

1. `b127936 feat: register Swift SDK for conformance`
2. `0f2796f feat: add SDK conformance matrix runner`

The first commit registers the temporary `coopsource/swift-sdk` aggregate, its two executable
fixtures, expected-failure file, checkout handling, documentation, and runner tests. The second adds
an independent SDK/revision/role matrix, result parsing, redaction at the wrapper-log layer, tests,
and Markdown/JSON reports.

The configured `fork` URL, `https://github.com/coopsource/conformance.git`, currently returns
“Repository not found.” The branch has no remote copy. Preserve this checkout until the work is
either pushed to a real fork or exported as patches. `origin` points to the official repository and
has push disabled.

The matrix runner deliberately compares SDKs independently against the same frozen requirements. It
does **not** establish direct Swift-client × other-SDK-server interoperability.

### Generated SDK-matrix checkouts

The conformance repository contains generated, reusable clones under:

`/Users/alan/projects/github/modelcontextprotocol/conformance/.sdk-under-test/`

The current cache includes:

- `coopsource__swift-sdk/swift-sdk-mcp-update-07-28-26`, detached at stale commit `584f8ff`;
- `coopsource__swift-sdk/584f8ff`, detached at `584f8ff`;
- `coopsource__swift-sdk/290b39d`, actually on baseline `a0ae212`;
- `typescript-sdk/main`, detached at `27a94b5d`.

These are disposable runner caches, not review authorities. In particular, the aggregate-named
cache has not fetched the corrected `9e44edf` tip. Do not audit it in place as if it represented the
current Swift branch. SwiftPM dependency clones under `swift-sdk/.build/**/checkouts` are also build
artifacts, not modified MCP source repositories.

## Swift review stack

The branch order, bases, and focused pull-request bodies live in
[`Documentation/PullRequests/MCP-2026-07-28/README.md`](PullRequests/MCP-2026-07-28/README.md).
Review the exact `base..head` delta in this order:

| Order | Head branch | Base | Tip | Primary responsibility |
| ---: | --- | --- | --- | --- |
| 1 | `mcp-2026-wire-models` | `main` | `8048912337d020a8bdb170e7d5c6aac15d5ed55c` | Dated wire vocabulary, errors, cache/subscription models, fixtures, ASCII extension names; no lifecycle activation. |
| 2 | `mcp-2026-oauth-issuer-validation` | `mcp-2026-wire-models` | `75a5907bf9654f356394eb5d8b763b4fb1549cc0` | Exact issuer validation and issuer-bound credentials, tokens, registration, and refresh. |
| 3 | `mcp-2026-discovery-negotiation` | `mcp-2026-oauth-issuer-validation` | `9ee677ef51b84692fb44249275522d353cf742df` | Runtime lifecycle modes, discovery, metadata, result types, fallback policy, bounded advertised-version retry, lifecycle reuse. |
| 4 | `mcp-2026-multi-round-trip` | `mcp-2026-discovery-negotiation` | `1fa6772c7a560ffec923b3e10d1e86a1c75da248` | Input-required results, embedded client requests, opaque state, retries, validation, round limits. |
| 5 | `mcp-2026-http-client` | `mcp-2026-multi-round-trip` | `22d90f56587b1264380a5ea186d71f7ec000b298` | One-POST-per-message client path, request SSE, cancellation, HTTP discovery evidence, origin identity, authorization serialization. |
| 6 | `mcp-2026-http-server` | `mcp-2026-http-client` | `bcfa1412b3fc2b14b4ae41202decdcb121d690d9` | Separate per-request HTTP server transport, validation, media parsing, request isolation, streaming and cancellation. |
| 7 | `mcp-2026-http-lifecycle-routing` | `mcp-2026-http-server` | `c3e84b1f543fb6c69e3565f4de8585ed1d5c827d` | Composition of initialization/session and per-request HTTP lifecycles at one endpoint. |
| 8 | `mcp-2026-tool-headers` | `mcp-2026-http-lifecycle-routing` | `4ad07a576074cc0b46196f9238e2e3fc0887bfed` | Standard and schema-derived request headers, exact validation, constrained schema-refresh retry. |
| 9 | `mcp-2026-subscriptions` | `mcp-2026-tool-headers` | `ae8a88e6e17213df0ea5bc768733dcd753e163a5` | Listen streams, acknowledgment-first ordering, filtering, bounded queues, reconnect, request-scoped logging. |
| 10 | `mcp-2026-response-caching` | `mcp-2026-subscriptions` | `01dc1398e9a10d9624c0df9d4461540985471f84` | Cache fields, bounded LRU, authorization partitions, pagination, policies, invalidation. |
| 11 | `mcp-2026-conformance` | `mcp-2026-response-caching` | `26f965773d0e8e4bc640867b79af55e85c5364cb` | Explicit-version conformance fixtures, NIO adapter, pinned runner, hidden subscription diagnostics. |
| 12 | `mcp-2026-defaults-release` | `mcp-2026-conformance` | `6f212923b96b7dae20442fbfdca5741fecab97a8` | `Version.latest`, compatibility-preserving runtime defaults, migration and release documentation. |

Aggregate-only review records and pull-request bodies follow PR 12 and are not part of its feature
delta.

When an earlier PR merges upstream, prepare the next submission delta on the new official `main` as
documented in the stack README. Do not submit cumulative descendant branches to official `main`, and
do not add a final correction PR for code that belongs in an unreviewed predecessor.

## Implementation map

### Wire types and lifecycle vocabulary

- `Sources/MCP/Base/Protocol20260728.swift`: dated protocol models, result types, discovery, MRTR,
  cache and error vocabulary.
- `Sources/MCP/Base/Subscriptions.swift`: listen filters, acknowledgment, and subscription models.
- `Sources/MCP/Base/Messages.swift`: type-erased message metadata boundaries.
- `Sources/MCP/Base/Versioning.swift`: version constants, preferences, and supported lifecycle sets.
- `Sources/MCP/Base/Lifecycle.swift`: initialization-based versus per-request-metadata identity.
- `Sources/MCP/Base/Error.swift`: structured remote error preservation.
- `Tests/MCPTests/Fixtures/2026-07-28/`: fifteen copied tagged fixtures plus one explicitly derived
  subscription fixture. Provenance is recorded in the implementation guide.

### Client policy and request orchestration

- `Sources/MCP/Client/Client.swift`: connection negotiation, lifecycle policy, logical attempts,
  MRTR, routing IDs, cancellation, metadata, and response validation. This is the largest and most
  important policy boundary.
- `Sources/MCP/Client/ClientSubscription.swift`: public subscription handle and event stream.
- `Sources/MCP/Client/ResponseCache.swift`: cache keys, LRU storage, partitioning, time, and
  invalidation.
- `Sources/MCP/Base/Transports/HTTPClientTransport.swift`: HTTP evidence, one-POST request handling,
  request-scoped SSE, authorization, cancellation, and lifecycle transport hooks.
- `Sources/MCP/Base/Transports/HTTPHeaders.swift`: standard and schema-derived header generation and
  validation helpers.

Client policy should decide the protocol era. HTTP code should report correlated evidence and
transport outcomes rather than silently selecting lifecycle behavior.

### Server policy and HTTP routing

- `Sources/MCP/Server/Server.swift`: request dispatch, handler context, MRTR, notification
  publication, subscriptions, bounded publisher queues, and cancellation.
- `Sources/MCP/Base/Transports/HTTPServer/StreamableHTTPServerTransport.swift`: new per-request HTTP
  transport.
- `Sources/MCP/Base/Transports/HTTPServer/LifecycleHTTPServerRouter.swift`: lifecycle composition.
- `Sources/MCP/Base/Transports/HTTPServer/HTTPRequestValidation.swift`: Origin, media, version,
  metadata, header, and JSON-RPC validation.
- `Sources/MCP/Base/Transports/HTTPServer/StatefulHTTPServerTransport.swift` and
  `StatelessHTTPServerTransport.swift`: earlier behavior retained for initialization-based users.
- `Sources/MCP/Server/Prompts.swift`, `Resources.swift`, `Tools.swift`, and `Logging.swift`: feature
  result requirements, cache fields, and lifecycle constraints.

### OAuth and authorization

- `Sources/MCP/Base/Authorization/OAuthAuthorizer.swift`: challenge handling, credential selection,
  stored-token and refresh behavior.
- `OAuthAuthorizationCodeFlow.swift`: redirect, state, and response issuer validation.
- `OAuthConfiguration.swift`, `OAuthModels.swift`, and `OAuthClientRegistrar.swift`: issuer-bound
  configuration, persisted data, and registration.
- `OAuthDiscoveryClient.swift`: protected-resource and authorization-server discovery.

### Conformance executable

- `Sources/MCPConformance/Client/main.swift`: scenario adapter for both frozen lifecycles.
- `Sources/MCPConformance/Server/main.swift`: everything-server fixture and hidden diagnostic calls.
- `Sources/MCPConformance/Server/HTTPApp.swift`: localhost NIO adapter.
- `Tests/MCPConformanceTests/HTTPHandlerTests.swift`: real asynchronous channel, cancellation,
  ordering, concurrent-request, and write-failure coverage.
- `scripts/run-conformance.sh`: initialization-based runner pinned to `0.1.15`.
- `scripts/run-conformance-2026-07-28.sh`: dated runner pinned to `0.2.0-alpha.11`.

## Focused test map

| Area | Primary tests |
| --- | --- |
| Wire models and compatibility | `Protocol20260728Tests.swift`, `PublicAPICompatibilityTests.swift`, `VersioningTests.swift` |
| OAuth | `OAuthAuthorizerTests.swift`, `OAuthAuthorizationCodeFlowTests.swift`, `OAuthClientRegistrarTests.swift`, `OAuthDiscoveryClientTests.swift` |
| Discovery and lifecycle | `ProtocolNegotiationTests.swift`, `ClientTests.swift`, `ServerTests.swift` |
| MRTR and cancellation | `MultiRoundTripTests.swift`, `CancellationTests.swift`, `ElicitationTests.swift`, `SamplingTests.swift`, `RootsTests.swift` |
| HTTP client | `PerRequestHTTPClientTransportTests.swift`, `HTTPClientTransportTests.swift` |
| HTTP server and routing | `StreamableHTTPServerTransportTests.swift`, `HTTPRequestValidationTests.swift`, `LifecycleHTTPServerRouterTests.swift`, `HTTPServerTransportTests.swift` |
| Tool headers | `HTTPHeaderMetadataTests.swift` plus HTTP client/server focused cases |
| Subscriptions | `SubscriptionTests.swift`, `LoggingTests.swift` |
| Caching | `ResponseCacheTests.swift` |
| Conformance adapter | `Tests/MCPConformanceTests/HTTPHandlerTests.swift` |

The test doubles intentionally model timing, ordering, latency, cancellation, reentrancy, stream
termination, and concurrent delivery. Do not simplify them to data-only mocks when reviewing or
adding a regression.

## Critical invariants to audit

### Lifecycle and compatibility

- Versions through `2025-11-25` use `initialize` and session-oriented behavior.
- `2026-07-28` uses mandatory per-request `_meta` and `server/discover`.
- `Version.latest` is `2026-07-28`, but new client and server configurations remain
  initialization-only until applications opt in.
- `Version.latestInitializationVersion` must be used wherever an initialization request or
  initialization-based transport requires a version.
- Recognized modern errors must not fall back to initialization. Authentication failures,
  cancellation, transient statuses, and malformed ordinary operations must not be mistaken for
  compatibility evidence.
- Automatic HTTP lifecycle reuse is client-local and keyed by canonical origin. It must not retain
  credentials, paths, queries, fragments, capabilities, or server identity.

### Discovery retry

- Only a correlated structured `UnsupportedProtocolVersionError` can select the advertised-version
  retry.
- The selected version must be mutually supported, the operation must remain `server/discover`, and
  the retry must use a fresh JSON-RPC ID.
- The retry is bounded to one attempt, including when the server advertises the same version that it
  just rejected.
- A second rejection is surfaced. It does not initialize and cannot create a retry loop.

### MRTR and request identity

- Each logical retry uses a fresh wire request ID while retaining validated opaque request state.
- Client responses must correspond exactly to embedded input requests.
- Embedded roots, sampling, and elicitation work must remain request-scoped and cancellable.
- Because the client carries `requestState`, the server must treat it as untrusted input and validate
  it before resuming work.

### HTTP

- The new lifecycle uses one POST per request or notification. GET streams and protocol-level
  sessions remain only for earlier lifecycle compatibility.
- JSON and SSE responses must retain request correlation; related notifications precede the final
  response, and disconnects cancel request-scoped work.
- Origin, `Accept`, `Content-Type`, standard headers, schema-derived headers, metadata, and version
  agreement are validated before dispatch with the specified HTTP and JSON-RPC error mapping.
- Media parameter, quality, wildcard, case, and optional-whitespace rules must agree with RFC 9110,
  not prefix matching.
- The new transport isolates colliding external JSON-RPC IDs through private routing state.

### Subscriptions and notifications

- Acknowledgment is the first stream event and carries the original listener request ID.
- Filters and subscription IDs must prevent notification leakage between concurrent listeners.
- Client and server queues are bounded; slow-consumer failure, cancellation, shutdown, and blocked
  publisher release are explicit.
- `await Server.notify(...)` means the subscription publisher accepted the notification for
  delivery. It does not promise that an asynchronous transport write has completed.

### Response caching and privacy

- Private entries are partitioned by the authorization context that completed the successful
  attempt, including an authentication retry.
- Public and private cache entries cannot share partitions accidentally.
- Untrusted or unavailable authorization identity prevents private storage.
- Pagination, caller metadata, capabilities, request-scoped logging, MRTR, reconnect generations,
  explicit invalidation, and list/resource notifications all affect reuse as documented.

### OAuth, credentials, and redirects

- Credentials, access tokens, and refresh tokens remain bound to the exact selected authorization
  server issuer.
- A refresh token from one issuer must never be sent after discovery selects another issuer.
- Redirect URI, state, RFC 9207 response issuer, protected-resource identity, metadata issuer, HTTPS,
  and the deliberate loopback exception must remain enforced.
- Logs must not include bearer tokens, refresh tokens, client secrets, authorization codes, private
  keys, or request bodies.

### Tool request headers

- `Mcp-Method`, `Mcp-Name`, and `Mcp-Param-*` values must agree with the JSON body before dispatch.
- Base64 is syntax-safe encoding, not confidentiality. Credentials, tokens, personal content, and
  unrestricted user input should not be mirrored into headers visible to proxies and logs.
- A header-mismatch schema refresh is narrowly bounded and uses a fresh request ID. It is not a
  general request retry.

## Known pre-existing or intentionally separate work

The branch deliberately does not repair older defects unrelated to the new protocol support. As of
2026-08-14, the following official Swift SDK pull requests were still open and overlap nearby code:

| Pull request | Relationship |
| --- | --- |
| [#257](https://github.com/modelcontextprotocol/swift-sdk/pull/257) | Repeated initialization; keep separate from discovery policy. |
| [#260](https://github.com/modelcontextprotocol/swift-sdk/pull/260) and [#268](https://github.com/modelcontextprotocol/swift-sdk/pull/268) | Competing/related fixes for cancelled legacy stateless HTTP exchanges. |
| [#264](https://github.com/modelcontextprotocol/swift-sdk/pull/264) and [#267](https://github.com/modelcontextprotocol/swift-sdk/pull/267) | Competing strategies for colliding legacy stateless request IDs. Do not combine both. |
| [#269](https://github.com/modelcontextprotocol/swift-sdk/pull/269) | Existing conformance resource-template correction; reconcile before PR 11 submission. |
| [#270](https://github.com/modelcontextprotocol/swift-sdk/pull/270) | Early cancellation and duplicate-request behavior in `Server.swift`. |
| [#271](https://github.com/modelcontextprotocol/swift-sdk/pull/271) | Windows guards in `HTTPClientTransport`; reconcile before PR 05 submission. |
| [#273](https://github.com/modelcontextprotocol/swift-sdk/pull/273) | Raw JSON dispatch overlap in `Server.swift`; do not absorb unrelated behavior. |

Issues [#254](https://github.com/modelcontextprotocol/swift-sdk/issues/254),
[#255](https://github.com/modelcontextprotocol/swift-sdk/issues/255), and
[#265](https://github.com/modelcontextprotocol/swift-sdk/issues/265) describe the legacy
`StatelessHTTPServerTransport` collision, hanging exchange, and cross-client HTTP-context risks. The
new per-request transport has separate private routing coverage, but this series does not claim to
resolve those existing issues.

The current implementation directly relates to the still-open umbrella and feature issues
[#245](https://github.com/modelcontextprotocol/swift-sdk/issues/245),
[#228](https://github.com/modelcontextprotocol/swift-sdk/issues/228),
[#233](https://github.com/modelcontextprotocol/swift-sdk/issues/233),
[#234](https://github.com/modelcontextprotocol/swift-sdk/issues/234),
[#236](https://github.com/modelcontextprotocol/swift-sdk/issues/236),
[#237](https://github.com/modelcontextprotocol/swift-sdk/issues/237),
[#238](https://github.com/modelcontextprotocol/swift-sdk/issues/238),
[#239](https://github.com/modelcontextprotocol/swift-sdk/issues/239),
[#240](https://github.com/modelcontextprotocol/swift-sdk/issues/240),
[#241](https://github.com/modelcontextprotocol/swift-sdk/issues/241),
[#242](https://github.com/modelcontextprotocol/swift-sdk/issues/242),
[#243](https://github.com/modelcontextprotocol/swift-sdk/issues/243), and
[#244](https://github.com/modelcontextprotocol/swift-sdk/issues/244).

Issue [#222](https://github.com/modelcontextprotocol/swift-sdk/issues/222) is only partially covered:
the branch supplies the common refresh-token grant declaration but does not expose arbitrary dynamic
registration metadata. Do not report it as completely resolved without maintainer agreement.

## External interoperability anchors

Compare behavior with the other official SDKs, but keep the dated specification authoritative when
implementations disagree:

- [TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Go SDK](https://github.com/modelcontextprotocol/go-sdk)
- [C# SDK](https://github.com/modelcontextprotocol/csharp-sdk)
- [Rust SDK](https://github.com/modelcontextprotocol/rust-sdk)

The interoperability review pins the exact files and commits used for discovery classification,
fallback, HTTP parsing, and request handling. In particular,
[Go SDK PR #989](https://github.com/modelcontextprotocol/go-sdk/pull/989) and the
[Python same-version retry test](https://github.com/modelcontextprotocol/python-sdk/blob/52ad0a8876f97f631b6e7cb973a786b253088a4d/tests/interaction/lowlevel/test_client_connect.py)
are precedents for the bounded advertised-version retry. Specification
[PR #2844](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2844) records related
legacy-fallback clarification work.

The official conformance implementation used here is
[`modelcontextprotocol/conformance@c321dd3`](https://github.com/modelcontextprotocol/conformance/tree/c321dd32035556e6769d3724a8ee97d87c3faaac).
Its [`KNOWN_SDKS`](https://github.com/modelcontextprotocol/conformance/blob/c321dd32035556e6769d3724a8ee97d87c3faaac/src/sdk-runner/known-sdks.ts)
and [SDK runner documentation](https://github.com/modelcontextprotocol/conformance/blob/c321dd32035556e6769d3724a8ee97d87c3faaac/README.md#running-against-an-sdk-at-a-specific-ref)
are the bases for the local Swift registration work.

## Prior records and recommended reading order

1. [`Documentation/PullRequests/MCP-2026-07-28/README.md`](PullRequests/MCP-2026-07-28/README.md):
   branch order, submission mechanics, and PR-body locations.
2. [`MCP-2026-07-28-IMPLEMENTATION.md`](MCP-2026-07-28-IMPLEMENTATION.md): design constraints,
   public API inventory, fixture provenance, and progressive per-unit verification.
3. [`MCP-2026-07-28-CODE-DESIGN-REVIEW.md`](MCP-2026-07-28-CODE-DESIGN-REVIEW.md): aggregate
   correctness review, security analysis, issue coordination, and final in-repository test counts.
4. [`MCP-2026-07-28-INTEROPERABILITY-REVIEW.md`](MCP-2026-07-28-INTEROPERABILITY-REVIEW.md):
   protocol ambiguity analysis and pinned comparisons with TypeScript, Python, Go, C#, and Rust.
5. [`MCP-2026-07-28-CONFORMANCE-FINDINGS.md`](MCP-2026-07-28-CONFORMANCE-FINDINGS.md) and
   [`MCP-2026-07-28-CONFORMANCE-FINDINGS-v2.md`](MCP-2026-07-28-CONFORMANCE-FINDINGS-v2.md): scored
   findings, their branch ownership, corrections, and final publication-semantics clarification.
6. [`MCP-2026-07-28-MIGRATION.md`](MCP-2026-07-28-MIGRATION.md): intended user-facing behavior and
   examples. Audit every example against the public API and compatibility defaults.
7. [`MCP-2026-07-28-SWIFT-CONFORMANCE-PLAN.md`](MCP-2026-07-28-SWIFT-CONFORMANCE-PLAN.md): useful
   local plan for conformance registration, safety, and cross-SDK work; currently untracked.

`MCP-2026-07-28-INTEROPERABILITY-HANDOFF.md` is explicitly historical, and
`MCP-2026-07-28-INTEROPERABILITY-NEXT-SESSION-PROMPT.md` is an old execution prompt. Use them for
decision history, not as current authority. Progressive test counts in the implementation guide are
also historical; later final counts below supersede them.

## Verification already completed

The corrected review stack was rebuilt and tested sequentially from PR 03 through PR 12. Every
restacked descendant had an exact unchanged `git range-diff` for its existing commits. The final
aggregate comparison against the preceding aggregate contained only the expected PR 03 test
assertions and selected documentation corrections.

Final recorded repository results:

- full `swift test`: 750 SDK tests in 51 suites plus 6 conformance-adapter tests passed;
- `swift test --filter ProtocolNegotiationTests`: 27 tests passed at the release tip;
- `swift test --filter SubscriptionTests`: 15 tests passed;
- both `mcp-everything-client` and `mcp-everything-server` built;
- DocC generation for target `MCP` passed with warnings treated as errors;
- initialization-based conformance: 223 client and 47 server checks passed with no failure or
  warning;
- 2026 client conformance: 424 passed, 13 explicitly unscored failures, zero warnings;
- 2026 server conformance: 168 passed, 25 explicitly unscored Tasks failures;
- the advertised-version retry, prompt-list-change, and tool-list-change checks each reported
  `SUCCESS`.

The compiler still reports the pre-existing `NetworkTransport` implicit-capture warning. That
unrelated implementation was intentionally not changed.

## Conformance evidence that still needs refreshing

The ignored report at
`/Users/alan/projects/github/modelcontextprotocol/conformance/results/sdk-matrix/latest.md` was
generated from Swift commit `584f8ff`, before the final corrections. It shows the three scored
warnings that prompted the retry and list-change work. It is historical evidence, not final
acceptance.

The final cross-SDK matrix requested for acceptance has not yet been rerun against the corrected
branch. From the conformance checkout, run:

```sh
npm run sdk-matrix -- \
  --sdk swift-sdk@mcp-2026-conformance \
  --requirements 2025-11-25,2026-07-28
```

That command validates the conformance review unit directly. Also run the local canonical entry,
which currently resolves to the aggregate fork branch:

```sh
npm run sdk-matrix -- \
  --sdk swift-sdk \
  --requirements 2025-11-25,2026-07-28
```

Inspect report contents rather than child-process exit status. The acceptance targets are:

- 2025 client: 18/18 clean scored scenarios;
- 2025 server: 30/30;
- 2026 client: 32/32;
- 2026 server: 37/37;
- zero scored warnings or failures.

Optional Tasks, enterprise authorization, DPoP, workload identity, and post-release JSON Schema
results remain visible but explicitly unscored. A separate aggregate run should also confirm the
checked-out Swift commit is `9e44edf`, not the stale cached `584f8ff`.

Generated wrapper logs redact common OAuth tokens, secrets, JWTs, authorization headers, and private
keys. Per-scenario conformance artifacts are lower-level diagnostic output and may not have the same
publication guarantees. Inspect them for credentials, request data, local paths, and private keys
before sharing an entire result directory.

## Reproducible audit commands

Run these from the Swift SDK root unless otherwise noted:

```sh
git status --short --branch
git rev-parse HEAD main
git diff --check
git diff --stat main..swift-sdk-mcp-update-07-28-26
git log --reverse --oneline main..swift-sdk-mcp-update-07-28-26

swift test
swift test --filter ProtocolNegotiationTests
swift test --filter MultiRoundTripTests
swift test --filter PerRequestHTTPClientTransportTests
swift test --filter StreamableHTTPServerTransportTests
swift test --filter LifecycleHTTPServerRouterTests
swift test --filter HTTPHeaderMetadataTests
swift test --filter SubscriptionTests
swift test --filter ResponseCacheTests

swift build --product mcp-everything-client
swift build --product mcp-everything-server
swift package generate-documentation --target MCP --warnings-as-errors
scripts/run-conformance.sh
scripts/run-conformance-2026-07-28.sh
```

For a review unit, use its documented predecessor rather than `main`, for example:

```sh
git diff --check mcp-2026-discovery-negotiation..mcp-2026-multi-round-trip
git diff --stat mcp-2026-discovery-negotiation..mcp-2026-multi-round-trip
git log --reverse --oneline \
  mcp-2026-discovery-negotiation..mcp-2026-multi-round-trip
```

The conformance scripts build artifacts under `.build`, start localhost processes, and use pinned
Node packages. Preserve the package pins when comparing results. Linux, static-runtime, and Swift
6.0 compatibility commands and outcomes are recorded in the implementation guide; repeat them if
the audit changes source or dependencies.

## Working-tree preservation

Before this handoff file was created, the Swift aggregate worktree contained these user-owned
changes outside the committed branch:

- modified: `Documentation/MCP-2026-07-28-FOLLOW-UP-PLAN.md`;
- untracked: `Documentation/MCP-2026-07-28-CONFORMANCE-FIX-HANDOFF.md`;
- untracked: `Documentation/MCP-2026-07-28-SWIFT-CONFORMANCE-PLAN.md`;
- untracked: `lefthook.yml`;
- untracked: `scripts/setup-conformance-development-repo.sh`.

The modification to the follow-up plan adds a link to the untracked Swift conformance plan. These
files were deliberately not committed or absorbed while restacking the feature branches. Preserve
them unless their owner explicitly asks otherwise. This handoff is an additional authorized local
documentation file and is not yet part of the pushed aggregate.

No `.rej`, `.orig`, or conflict-marker files were present after the final restack.

## Expected audit output

For each finding, record:

1. severity and observable consequence;
2. exact specification section, schema field, RFC, or interoperability evidence;
3. whether the behavior is pre-existing, introduced by this branch, or required only by the new
   lifecycle;
4. the owning review unit and smallest correct change boundary;
5. a timing-faithful reproduction or regression test;
6. compatibility and public API impact;
7. security, privacy, authorization, cache, cancellation, and concurrency impact; and
8. whether the issue blocks its PR or can remain a separately tracked follow-up.

If a finding belongs to an unreviewed feature branch, amend that branch and restack its descendants.
If it is genuinely unrelated to this protocol support, propose a separate issue or PR instead of
placing it anywhere in this stack.
