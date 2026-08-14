# MCP 2026-07-28 follow-up plan

Status: Phases 7 and 8 complete; 12-unit review stack regenerated and verified, as of 2026-08-14

Branch: `swift-sdk-mcp-update-07-28-26`

Starting commit: `290b39d`
Baseline: 67 focused versioning, routing, and HTTP transport tests passed before these changes.

> Final disposition: the review stack contains only protocol-revision work. The earlier
> `Package.resolved` refresh was omitted while regenerating the branches because it was unrelated
> dependency lockfile churn. The handoff and next-session prompt are retained only as historical
> working records.

## Scope and decisions

This plan records the verified disposition of five review observations about the Swift SDK's MCP 2026-07-28 support. The peer specification is in `../modelcontextprotocol`, principally:

- `docs/specification/2026-07-28/basic/versioning.mdx`
- `docs/specification/2026-07-28/basic/transports/streamable-http.mdx`

The specification distinguishes initialization-era requests from 2026-07-28 per-request-metadata requests, but does not prescribe an SDK's programmatic defaults. Official SDK behavior is therefore comparative evidence, not a normative requirement.

The second downstream review is analyzed in
[`MCP-2026-07-28-INTEROPERABILITY-REVIEW.md`](MCP-2026-07-28-INTEROPERABILITY-REVIEW.md). That
report is the evidence and design record for Phases 7 and 8. Its authority order is the dated
specification, HTTP semantics, the official conformance runner, pinned official SDK snapshots, and
finally the downstream reproductions.

### 1. Restore compatibility-preserving configuration defaults

Verified: the public `Server.Configuration` initializer defaults to `.initializationAndPerRequestMetadata`, while decoding a missing mode defaults to `.initializationOnly`. The corresponding `Client.Configuration` values are `.automatic` and `.initializationOnly`. Static `.default` and `.strict` use the public initializers, so constructing a server or client opts into new wire-visible behavior while decoding the same shape does not.

Decision: change both public initializer defaults to `.initializationOnly`. Keep the default arguments rather than introducing a source break. Explicit `.automatic`, `.perRequestMetadataOnly`, and `.initializationAndPerRequestMetadata` remain the opt-in mechanisms. `Version.latest` remains 2026-07-28.

Rationale: existing source-compatible deployments should not begin advertising or serving a new lifecycle merely by upgrading the package. This also removes the memberwise/decoder asymmetry. TypeScript v2 and Rust provide compatibility-oriented precedents; Go, C#, and Python make more automatic choices, confirming that the spec leaves this as SDK policy.

Targets:

- `Sources/MCP/Server/Server.swift`
- `Sources/MCP/Client/Client.swift`
- `Tests/MCPTests/ProtocolNegotiationTests.swift`
- `README.md`
- `Documentation/MCP-2026-07-28-MIGRATION.md`
- relevant implementation and pull-request notes

Tests must cover constructed, decoded, `.default`, and `.strict` configurations, plus explicit opt-in to the 2026 lifecycle.

### 2. Give established sessions routing precedence over a conflicting version header

Verified: `LifecycleHTTPServerRouter` examines request-body lifecycle metadata and the protocol-version header, but never examines `Mcp-Session-Id`. `StreamableHTTPServerTransport` is sessionless and rejects non-POST requests. A session-bearing GET or DELETE with an unknown or 2026 header can consequently be routed to the sessionless transport and receive 405 instead of reaching the initialization-era stateful handler.

Decision: update routing precedence to:

1. A body carrying any per-request lifecycle metadata field selects the per-request handler, so
   malformed modern requests reach modern validation rather than falling back.
2. Otherwise, a non-empty `Mcp-Session-Id` selects the initialization handler.
3. Otherwise, an `initialize` request selects the initialization handler.
4. Otherwise, classify a recognized version header by lifecycle.
5. An unrecognized version without a session selects the per-request handler so it can return the structured unsupported-version error.

The body check must remain first so existing `metadataTakesPrecedenceOverSession` behavior is preserved. Do not add a general injectable routing closure now; the protocol-defined precedence is sufficient and safer.

Targets:

- `Sources/MCP/Base/Transports/HTTPServer/LifecycleHTTPServerRouter.swift`
- `Tests/MCPTests/LifecycleHTTPServerRouterTests.swift`

Add session-bearing GET, DELETE, and POST cases with conflicting or unknown version headers, plus an empty-session-header case. TypeScript exposes body-aware legacy routing; Python currently has a similar header-first weakness, so it is not a model to copy here.

### 3. Make version support lifecycle-specific and consistently enforced

Verified: both `StatefulHTTPServerTransport` and the older `StatelessHTTPServerTransport` build validation contexts with all of `Version.supported`. The sessionless `StreamableHTTPServerTransport` correctly accepts only the per-request-metadata version. A transport-only custom allowlist is not, by itself, a correct exact-pinning mechanism because initialization negotiation happens in `Server` and the standard protocol-version validator intentionally skips initialization requests.

Decision:

- Default the stateful and older stateless transports to the initialization-based Streamable HTTP
  revisions (`2025-03-26` through `2025-11-25`). Do not treat `2024-11-05` as Streamable HTTP;
  that revision uses the deprecated HTTP+SSE binding.
- Keep the sessionless streamable transport fixed to per-request-metadata versions.
- Add a public lifecycle-specific version partition (item 4) and use it instead of hand-maintained subtraction.
- Add a package-only transport hook that reports binding-specific version support. `Server`
  intersects that set with its configured lifecycle modes for discovery and initialization
  negotiation, so the transport edge cannot contradict the version selected by `Server`.
- Do not add the proposed public transport-only `supportedProtocolVersions` initializer parameter
  unless an authoritative server configuration allowlist is implemented at the same time.

Targets:

- `Sources/MCP/Base/Transports/HTTPServer/StatefulHTTPServerTransport.swift`
- `Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift`
- their tests and version-negotiation tests

Go, C#, and Rust likewise distinguish stateful/legacy handling from the modern stateless lifecycle.

### 4. Publish lifecycle-specific supported version sets

Verified: `Version.supported` is public, but `preferenceOrder`, `perRequestMetadataSupported`, and `negotiate` are internal. Adopters therefore re-derive the initialization-era set manually.

Decision: add an additive public API:

```swift
Version.supported(for: .initializationBased)
Version.supported(for: .perRequestMetadata)
```

Keep negotiation and preference ordering internal implementation details. Tests must prove the partitions are disjoint, their union equals `Version.supported`, and each contains its corresponding latest version.

Target: `Sources/MCP/Base/Versioning.swift` and `Tests/MCPTests/VersioningTests.swift`.

#### 4a. Follow-up: `streamableHTTPSupported(for:)` is also published

Reported by the first external adopter of item 5. Item 3 introduced `streamableHTTPSupported(for:)` as `package`, which left a gap the original item 4 did not close: an application that supplies its own `HTTPRequestValidator` — the supported path for the wide-open and custom-origin deployments item 5 exists to serve — cannot enforce the same version set this package's own transports enforce. Its only options were to approximate with the broader `supported(for:)` (admitting `2024-11-05` on a Streamable HTTP endpoint, which this package's transports reject) or to hand-copy the literal set, which silently drifts as revisions are added.

Decision: promote it to `public`, additively. The lifecycle partition remains the API to reach for by default; this one answers the narrower and genuinely different question of what a *Streamable HTTP endpoint* implements. Negotiation and preference ordering stay internal.

Note on verification: `Tests/MCPTests` uses `@testable import MCP`, so its existing coverage of this function passes under either access level and cannot discriminate the change. The behavioral contract is already pinned there ("Streamable HTTP excludes the deprecated HTTP+SSE revision"); the access change is proven by an external module compiling against it.

Target: `Sources/MCP/Base/Versioning.swift`.

### 5. Add a safe origin-only customization path

Verified: supplying a custom validation pipeline replaces a transport's complete default chain. A remotely deployed service that only needs a different origin policy must therefore reconstruct Accept, Content-Type, protocol-version, and session validation correctly for that particular transport.

Decision: add required-label `originValidator:` initializer overloads for the stateful, older stateless, and sessionless streamable server transports. Each overload must rebuild that transport's normal validation pipeline and replace only its origin validator. Retain `validationPipeline:` as the explicitly advanced, wholesale-replacement API. Avoid an initializer where optional `originValidator` and optional `validationPipeline` can both be supplied or one silently wins.

Tests must show that a custom remote origin is accepted, disallowed Host and Origin values remain
rejected, and invalid Accept, Content-Type, version, and (where applicable) session inputs remain
rejected. TypeScript, Python, and Go expose origin/security policy independently from core protocol
validation, supporting this shape.

## Implementation phases

- [x] Phase 1: restore initialization-only client/server defaults; update affected tests and documentation.
- [x] Phase 2: fix session-aware lifecycle routing precedence and add regression tests.
- [x] Phase 3: publish lifecycle-specific supported-version sets and use them in legacy transport validation contexts.
- [x] Phase 4: add safe origin-validator overloads and invariant-preserving tests.
- [x] Phase 5: run focused suites, the full `swift test`, and any relevant conformance checks; record the results below.
- [x] Phase 6: apply deep-review corrections for HTTP binding-aware version negotiation, negative
  origin-policy coverage, opt-in migration examples, semantic default-mode tests, and current test
  counts.
- [x] **Phase 7: address the downstream interoperability findings.** Keep each change in the
  review unit that owns the affected boundary when that unit has not entered upstream review. If it
  has, create one focused interoperability follow-up instead of rewriting reviewed history.
  - [x] 7.1: classify a correlated, non-modern JSON-RPC error to the mandatory `server/discover`
    probe as initialization-era evidence whether an HTTP legacy peer used status 200 or a
    compatibility status such as 400, 404, or 405. A malformed, empty, or uncorrelated body on a
    compatibility status is also initialization-era evidence. Preserve non-fallback behavior for
    recognized modern errors, auth, transient failures, and cancellation. This belongs to PR 03's
    discovery classifier with HTTP response plumbing/tests in PR 05.
  - [x] 7.2: make `enableStandaloneGetStream` the canonical HTTP-client initializer label and a
    public read-only property. Retain the already-shipped explicit `streaming:` label as a deprecated
    forwarding initializer without a default argument. Do not reject or warn when a modern lifecycle
    correctly disables session state and standalone GET; request-scoped POST SSE remains active.
    This belongs to PR 05.
  - [x] 7.3: replace case-sensitive/prefix media checks with one HTTP-aware `Accept` and
    `Content-Type` parser. Cover parameters, suffix rejection, quality values including `q=0`, and
    exact/type/global wildcard precedence. This belongs to PR 06.
  - [x] 7.4: add a compile-grounded handler-emitted progress example before the migration guide's
    broadcast/subscription section. Require progress work to finish before the handler returns; do
    not recommend detached or unjoined tasks. This belongs to PR 12.
  - [x] 7.5: run the affected client, HTTP validation, request-scoped SSE, and progress suites; then
    run full `swift test`, DocC with warnings as errors, the pinned 2025 conformance suite, and the
    pinned 2026 conformance suite. Record exact results here.
  - [x] 7.6: prepare two smallest-possible specification clarifications: discovery fallback for a
    correlated non-modern JSON-RPC response returned with HTTP 200, and effective Accept quality /
    wildcard semantics. Keep these independent from the Swift implementation PRs. Candidate text
    and smallest reproducers are recorded in `MCP-2026-07-28-INTEROPERABILITY-REVIEW.md`; submitting
    specification changes remains intentionally separate from this Swift implementation phase.
- [x] **Phase 8: complete a security, privacy, and authorization analysis before submission.**
  Treat this as a release gate for every review unit that handles HTTP metadata, request routing,
  authorization state, or cached data.
  - [x] 8.1: trace OAuth credentials, authorization codes, access tokens, and refresh tokens across
    discovery, issuer changes, retries, persistence, and logging. Require exact authorization-server
    binding before transmitting a stored refresh token.
  - [x] 8.2: review protected-resource and authorization-server discovery for SSRF, HTTPS/loopback
    policy, redirects, issuer equality, and endpoint overrides. Keep configured client credentials
    bound to one validated issuer; treat client metadata document identifiers as portable only when
    the authorization server advertises that mechanism.
  - [x] 8.3: review HTTP request metadata as potentially sensitive routing data. Base64 is an
    encoding, not confidentiality; applications should annotate only parameters that are safe for
    proxy, gateway, access-log, and tracing infrastructure. Reject missing, malformed, or mismatched
    mirrored values before dispatch.
  - [x] 8.4: verify that request contexts, response streams, cancellation, and internal routing IDs
    remain isolated across concurrent clients even when external JSON-RPC IDs collide. Reconcile the
    older stateless transport with the active upstream collision and cancellation fixes before its
    review unit is submitted.
  - [x] 8.5: verify cache privacy boundaries: private entries are partitioned by the authorization
    context of the completed attempt, public entries contain no credential-derived key material,
    reconnects invalidate connection-scoped state, and authentication retries cannot reuse a result
    from an earlier identity.
  - [x] 8.6: document the analysis, add negative tests for issuer changes and custom-header
    validation, and run the focused security-sensitive suites. Older stateless request-ID and
    cancellation risks remain explicitly separate upstream work; they do not block this series.
- [ ] **Phase 9: build the official-SDK compatibility matrix in a separate PR series.** Begin the
  Swift adapter inventory after Phase 7 behavior is stable; do not block the Graph application trial
  on the complete N×N suite.
  - [ ] 9.1 (Swift PR 11 amendment or follow-up): stabilize the Swift everything-client/server
    command contracts, add explicit lifecycle and transport selection, and test adapter process,
    ordering, cancellation, and shutdown behavior.
  - [ ] 9.2 (official conformance PR): add `swift-sdk` with exact build/client/server and per-spec
    overrides to the official runner's `KNOWN_SDKS`. Reuse its checkout, result, wire-schema, and
    expected-failure mechanisms.
  - [ ] 9.3 (official conformance PR): add an `interop` command that pairs arbitrary known-SDK client
    and server refs. Keep normative expectations, immutable observations, and reviewed deviations as
    separate data; generate the Markdown matrix rather than hand-maintaining it.
  - [ ] 9.4: implement Wave 1 over Swift, TypeScript, Python, C#, Go, and Rust. Pin one legacy and one
    2026-capable generation per SDK. Gate PRs with Swift self-tests and a Swift-centered star; run
    full current/current pairwise nightly and all legacy/current combinations nightly or weekly.
  - [ ] 9.5: use real loopback TCP and Docker/OCI isolation for the Linux HTTP matrix, native child
    processes and pipes for stdio, and a native macOS Swift lane for Foundation/URLSession behavior.
    Do not use a TCP relay as a stdio mock. Reserve UTM/VMs for an OS-specific reproduction rather
    than the baseline matrix.
  - [ ] 9.6: add Java, Ruby, PHP, and Kotlin adapters to complete the ten-SDK official list, marking
    genuinely unsupported cells explicitly rather than treating them as failures.

## Verification log

- 2026-08-12, before implementation: `swift test --filter 'ProtocolNegotiationTests|LifecycleHTTPServerRouterTests|StatefulHTTPServerTransportTests|VersioningTests'` passed 67 tests in 4 suites.
- 2026-08-12, Phase 1: `swift test --filter ProtocolNegotiationTests` passed 25 tests. The build emitted pre-existing unused unstructured-task warnings from `HTTPServerTransportTests.swift`.
- 2026-08-12, Phase 2: `swift test --filter LifecycleHTTPServerRouterTests` passed 9 tests.
- 2026-08-12, Phase 3: `swift test --filter 'VersioningTests|StatefulHTTPServerTransportTests|StatelessHTTPServerTransportTests|StreamableHTTPServerTransportTests'` passed 69 tests in 4 suites.
- 2026-08-12, Phase 4: `swift test --filter 'StatefulHTTPServerTransportTests|StatelessHTTPServerTransportTests|StreamableHTTPServerTransportTests'` passed 61 tests in 3 suites. An earlier run failed only because a new assertion omitted Swift string-interpolation escaping; the corrected assertion passed.
- 2026-08-12, final: `swift test` passed 725 SDK tests in 50 suites and 5 conformance HTTP-adapter tests in 1 suite.
- 2026-08-12, final: `swift package generate-documentation --target MCP --warnings-as-errors` succeeded. Compilation emitted the pre-existing implicit-strong-capture warning in `NetworkTransport.swift`.
- 2026-08-12, final: `scripts/run-conformance-2026-07-28.sh` exited successfully. All scored 2026-07-28 requirements passed. The client run reported 423 passes, 13 failures, and 1 warning; all 13 failures were in unscored extension or post-release scenarios. The server run reported 160 passes and 31 failures; all 31 failures were in unscored extension or pending scenarios.
- 2026-08-12, post-review focused verification: 108 tests in versioning, protocol negotiation,
  server HTTP context, and all three HTTP server transport suites passed. The suite includes an
  end-to-end check that Streamable HTTP does not negotiate the `2024-11-05` HTTP+SSE revision and
  negative Host/Origin checks for every origin-only initializer.
- 2026-08-12, post-review full verification: `swift test` passed 730 SDK tests in 50 suites and
  5 conformance HTTP-adapter tests in 1 suite. The build emitted only the previously recorded
  `NetworkTransport` implicit-capture warning and unused unstructured-task warnings in existing
  HTTP transport tests.
- 2026-08-12, post-review conformance verification: `scripts/run-conformance-2026-07-28.sh`
  exited successfully and every scored requirement passed. Results remained 423 client passes,
  13 unscored failures, and 1 warning; and 160 server passes with 31 unscored failures.
- 2026-08-13, Phase 7 focused client and transport verification:
  `swift test --filter 'PerRequestHTTPClientTransportTests|HTTPClientTransportTests|ProtocolNegotiationTests|StreamableHTTPServerTransportTests|ProgressTests'`
  passed 154 tests in 5 suites.
- 2026-08-13, Phase 7 focused server verification:
  `swift test --filter 'HTTPServerTransportTests|StreamableHTTPServerTransportTests'` passed 70
  tests in 4 suites, and `swift test --filter HTTPRequestValidationTests` passed 7 tests in 1 suite.
- 2026-08-13, Phase 7 full verification: `swift test` passed 743 SDK tests in 51 suites and 5
  conformance HTTP-adapter tests in 1 suite.
- 2026-08-13, Phase 7 documentation verification:
  `swift package generate-documentation --target MCP --warnings-as-errors` succeeded and generated
  `.build/plugins/Swift-DocC/outputs/MCP.doccarchive`. Compilation emitted the previously recorded
  implicit-strong-capture warning in `NetworkTransport.swift`.
- 2026-08-13, Phase 7 pinned initialization conformance: `scripts/run-conformance.sh` completed
  successfully with 223 client passes and 47 server passes, with no scored failures or warnings.
  Node emitted its existing `DEP0190` deprecation warning.
- 2026-08-13, Phase 7 pinned 2026 conformance:
  `scripts/run-conformance-2026-07-28.sh` exited successfully. The client reported 423 successes,
  13 unscored failures, and 1 warning; the server reported 160 successes, 31 unscored failures, and
  2 non-failing SHOULD-level warnings. The failures remain confined to the known unimplemented
  DPoP, workload identity, token exchange, task-extension, and newer routed-header scenarios.
- 2026-08-13, review-unit disposition: GitHub reported no upstream pull request for the PR 03, 05,
  06, or 12 source branches, so later corrections could be moved into the owning units without
  rewriting reviewed work.
- 2026-08-14, aggregate security and interoperability review: the server custom-header schema is
  now installed from the same tool definition returned by `tools/list`. The pinned server run
  reported 166 successes and 25 failures; all ten custom-header checks passed, and the remaining
  failures are confined to nine Tasks-extension scenarios. Focused OAuth, HTTP negotiation, media
  validation, identifier, and adapter tests also passed.
- 2026-08-14, final aggregate verification: `swift test` passed 746 SDK tests in 51 suites and 6
  conformance HTTP-adapter tests in 1 suite. DocC generation with `--warnings-as-errors` succeeded
  and produced `.build/plugins/Swift-DocC/outputs/MCP.doccarchive`. Compilation emitted only the
  previously recorded implicit-capture warning in `NetworkTransport.swift`; this protocol series
  does not change that unrelated implementation.
- 2026-08-14, review-stack verification: corrections were folded into units 01, 02, 03, 05, 06,
  and 11; every successor was restacked. Focused suites passed at each branch boundary, followed by
  the complete aggregate test and documentation runs. The unrelated `Package.resolved` refresh and
  branch-added protocol-history comments were omitted.

## Official SDK references

- TypeScript protocol versions: <https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/protocol-versions.md>
- TypeScript legacy routing: <https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/serving/legacy-clients.md>
- Rust releases: <https://github.com/modelcontextprotocol/rust-sdk/releases>
- Go releases: <https://github.com/modelcontextprotocol/go-sdk/releases>
- C# releases: <https://github.com/modelcontextprotocol/csharp-sdk/releases>
- Python release notes: <https://github.com/modelcontextprotocol/python-sdk/blob/main/docs/whats-new.md>
- Python transport security: <https://github.com/modelcontextprotocol/python-sdk/blob/main/src/mcp/server/transport_security.py>
- Go streamable transport: <https://github.com/modelcontextprotocol/go-sdk/blob/main/mcp/streamable.go>
- Official SDK list: <https://modelcontextprotocol.io/docs/sdk>
- Official conformance runner: <https://github.com/modelcontextprotocol/conformance>
- Detailed pinned interoperability review:
  [`MCP-2026-07-28-INTEROPERABILITY-REVIEW.md`](MCP-2026-07-28-INTEROPERABILITY-REVIEW.md)
