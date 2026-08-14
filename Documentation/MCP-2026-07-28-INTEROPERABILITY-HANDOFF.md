# MCP 2026-07-28 interoperability implementation handoff (historical)

Date: 2026-08-13

Status: archived pre-implementation handoff; Phase 7 and the security review are complete

This document preserves the exact state and instructions at the 2026-08-13 handoff. It is not a
current continuation guide. The final disposition and verification results are in
[`MCP-2026-07-28-FOLLOW-UP-PLAN.md`](MCP-2026-07-28-FOLLOW-UP-PLAN.md) and
[`MCP-2026-07-28-CODE-DESIGN-REVIEW.md`](MCP-2026-07-28-CODE-DESIGN-REVIEW.md). The regenerated
review stack deliberately omits the dependency lockfile refresh recorded below.

## Objective

Complete Phase 7 of the MCP 2026-07-28 follow-up plan so the Graph application can trial the
corrected Swift SDK behavior. Keep each change logically separable by the pull-request review unit
that owns it. Phase 8, the cross-SDK compatibility matrix, is a separate follow-up and must not
delay Phase 7.

Do not repeat the ecosystem survey before beginning. The verified evidence, tradeoffs, smallest
reproducers, and pinned source references are already recorded in
[`MCP-2026-07-28-INTEROPERABILITY-REVIEW.md`](MCP-2026-07-28-INTEROPERABILITY-REVIEW.md).

## Repository state at handoff

- Repository: `/Users/alan/projects/github/modelcontextprotocol/swift-sdk`
- Branch: `swift-sdk-mcp-update-07-28-26`
- Tracking branch: `fork/swift-sdk-mcp-update-07-28-26`
- HEAD: `8e8f00854070c4cedf86e8702ce195d28e44c0f0`
- HEAD subject: `Refresh SwiftPM dependency resolution`
- Allowed push remote: `fork` (`https://github.com/coopsource/swift-sdk.git`)
- Forbidden push remote: `origin`; its push URL is deliberately disabled

The worktree intentionally contains these documentation changes:

```text
 M Documentation/MCP-2026-07-28-FOLLOW-UP-PLAN.md
?? Documentation/MCP-2026-07-28-INTEROPERABILITY-REVIEW.md
?? Documentation/MCP-2026-07-28-INTEROPERABILITY-HANDOFF.md
?? Documentation/MCP-2026-07-28-INTEROPERABILITY-NEXT-SESSION-PROMPT.md
```

Preserve them. They are not unrelated user changes and must not be restored or discarded.
`Package.resolved` is clean and was deliberately committed in `8e8f008`; do not reopen that issue
unless dependency resolution changes again.

Before editing, confirm the state with:

```bash
pwd
git status --short --branch
git remote -v
git log -5 --oneline
```

## Read these first

1. [`MCP-2026-07-28-INTEROPERABILITY-REVIEW.md`](MCP-2026-07-28-INTEROPERABILITY-REVIEW.md)
2. [`MCP-2026-07-28-FOLLOW-UP-PLAN.md`](MCP-2026-07-28-FOLLOW-UP-PLAN.md), especially Phase 7
3. [`MCP-2026-07-28-IMPLEMENTATION.md`](MCP-2026-07-28-IMPLEMENTATION.md)
4. [`MCP-2026-07-28-MIGRATION.md`](MCP-2026-07-28-MIGRATION.md)
5. [`PullRequests/MCP-2026-07-28/README.md`](PullRequests/MCP-2026-07-28/README.md)
6. Pull-request notes `03-discovery-negotiation.md`, `05-http-client.md`,
   `06-http-server.md`, `11-conformance.md`, and `12-defaults-release.md` in that directory
7. The downstream issue index at
   `/Users/alan/projects/avp/graph/docs/research/mcp-swift-sdk-suggestions-index-20260813.md`

The downstream Graph repository is evidence and a consumer, not an edit target for this phase.

## Authority and pinned evidence

Use this authority order:

1. the dated local MCP specification and schema;
2. the applicable HTTP RFC semantics;
3. the official MCP conformance runner and reference scenarios;
4. official SDK implementations as interoperability evidence;
5. downstream reproductions.

The local specification peer is:

- `/Users/alan/projects/github/modelcontextprotocol/modelcontextprotocol`
- revision `b25c0874bf0ba699a58e21ef06f659d839659de3`

The review used these exact external snapshots:

| Repository | Revision |
| --- | --- |
| official conformance | `c321dd32035556e6769d3724a8ee97d87c3faaac` |
| TypeScript SDK | `cc4b41617ce3601b1290d67216ea0b194a3cd9ac` |
| Python SDK | `6e304527a54a702fed84066bde8b7d8ce9cfeba7` |
| Go SDK | `64e454e35c23c473e1fcf1e1c3a6f623260ca773` |
| C# SDK | `6fa3825973949a9c4f0cd8af344e15a8db09dc35` |
| Rust SDK | `f713ebd1a6feab492fb730a8bc13026be114d82f` |

They were cloned under `/private/tmp/mcp-conformance-review-20260813` and
`/private/tmp/mcp-official-sdk-review-20260813`. Temporary directories may not survive a new
session. Reclone only a missing source that is needed to resolve an implementation question, and
check out the pinned revision. The report contains the durable evidence and upstream links.

## Settled design decisions

### 1. Discovery fallback is a Swift interoperability bug

For `.automatic`, a valid, correlated JSON-RPC error returned by the mandatory
`server/discover` probe is legacy evidence when it is not a recognized modern error. This applies
when a legacy HTTP peer wraps the response in status 200 as well as compatibility statuses such as
400, 404, and 405. All five inspected official SDKs fall back for the isolated HTTP 200 plus
`-32601` case.

Do not generalize this into fallback after arbitrary failed operations. Authorization failures,
transient failures, cancellation, and transport/network failures do not prove a legacy server.
Malformed or uncorrelated bodies returned with HTTP 400, 404, or 405 do.

### 2. Clearing standalone GET state in the modern lifecycle is correct

The `streaming` option controls the initialization-era standalone GET SSE stream; it does not
control request-scoped POST SSE. The canonical public spelling should become
`enableStandaloneGetStream`, with a public read-only property. Preserve the already-shipped
explicit `streaming:` label as a deprecated forwarding initializer without a default argument.

“Breaking release” meant a source/API break for existing users of the shipping Swift package, not
a break between experimental 2026 protocol builds. The forwarding initializer is therefore still
appropriate even though the new protocol work currently has one adopter.

Do not throw, warn, or alter `ConnectionInfo` merely because modern negotiation clears session and
standalone GET state.

### 3. HTTP media validation needs an RFC-aware parser

Use one parser for `Accept` and `Content-Type` media ranges. Media type and subtype comparison is
case-insensitive; parameters are parsed rather than compared as part of a prefix. Reject suffix
lookalikes. Honor `q=0` and the precedence of exact, type wildcard, and global wildcard matches.
Be conservative with invalid syntax. Do not paste the downstream patch verbatim.

### 4. Progress guidance must reflect handler lifetime

Add a compiling handler-emitted progress example based on the conformance server. Progress work
must finish before the request handler returns. Do not recommend a detached or unjoined task that
can outlive the request-scoped responder.

## Phase 7 implementation ledger

### 7.1 Centralize discovery outcome classification

Primary files:

- `Sources/MCP/Client/Client.swift`
- `Sources/MCP/Base/Transports/HTTPClientTransport.swift`
- `Sources/MCP/Base/Transport.swift` if a shared classifier belongs there
- `Tests/MCPTests/PerRequestHTTPClientTransportTests.swift`
- `Tests/MCPTests/ProtocolNegotiationTests.swift`

Existing code landmarks at the reviewed revision:

- `Client.swift:673-686`: lifecycle selection before connect
- `Client.swift:760-777`: automatic discovery decision
- `Client.swift:1843-1870`: send and await `server/discover`
- `Client.swift:1974-1987`: modern-error recognition and HTTP fallback handling
- `HTTPClientTransport.swift:843-890`: non-200 per-request response handling
- `HTTPClientTransport.swift:1135-1143`: HTTP 404 plus `-32601` special case
- `PerRequestHTTPClientTransportTests.swift:1203-1234`: currently asserts that 404 plus method-not-found does not fall back; this expectation must change for the mandatory discovery probe

Required behavior:

- `.automatic` falls back on a correlated, non-modern discovery error returned with HTTP 200 or
  the supported compatibility statuses.
- `.perRequestMetadataOnly` still throws and never falls back.
- Recognized modern errors keep the current no-fallback behavior, including the existing
  unsupported-version retry path.
- Keep no-fallback behavior for 401/403, 408/429/5xx, network failure, and cancellation. Fall back
  for malformed JSON, mismatched IDs, and otherwise uncorrelated bodies on HTTP 400/404/405.
- Preserve the existing bare-405 legacy fallback.
- Include an initialization-era control proving that the same endpoint connects and can perform a
  normal operation after fallback.

Prefer one discovery-outcome classifier over status-only decisions spread between client and
transport. Keep the decision scoped to the discovery probe.

### 7.2 Clarify the standalone GET API

Primary files:

- `Sources/MCP/Base/Transports/HTTPClientTransport.swift`
- `Tests/MCPTests/HTTPClientTransportTests.swift`
- `Tests/MCPTests/PerRequestHTTPClientTransportTests.swift`

Add the canonical initializer argument:

```swift
enableStandaloneGetStream: Bool = true
```

and expose:

```swift
public nonisolated let enableStandaloneGetStream: Bool
```

Retain a deprecated forwarding overload with `streaming: Bool` and no default value. Update
internal call sites to the canonical spelling while keeping a compile/behavior compatibility test
for the old explicit overload. Test initialization-based operation, automatic fallback starting
the standalone GET stream, modern lifecycle state clearing, and the independence of request-scoped
POST SSE.

### 7.3 Replace media-type prefix checks

Primary file:

- `Sources/MCP/Base/Transports/HTTPServer/HTTPRequestValidation.swift`

Add focused tests either to the transport suites that exercise the default pipeline or to a new
validator test suite. At minimum, cover:

- case-insensitive type/subtype matching;
- valid parameters and optional whitespace;
- rejection of suffix lookalikes;
- exact, `type/*`, and `*/*` ranges;
- `q=0` exclusion;
- exact-match precedence over broader wildcards;
- duplicate ranges and conflicting quality values;
- invalid quality and malformed media-range syntax;
- both `Accept` and `Content-Type` behavior.

The relevant existing default-validation coverage begins near
`StreamableHTTPServerTransportTests.swift:305` at the reviewed revision.

### 7.4 Add handler-emitted progress guidance

Update `Documentation/MCP-2026-07-28-MIGRATION.md` before the “Publish cache invalidations and
subscriptions” section. Ground the example in:

- `Sources/MCPConformance/Server/main.swift:383-432`
- `Sources/MCP/Server/Server.swift:711-768`
- `Tests/MCPTests/StreamableHTTPServerTransportTests.swift:752-792`

The example must compile, await progress before returning, explain request-scoped SSE behavior,
and include a short migration checklist. Avoid detached/unjoined task guidance.

### 7.5 Verify and record exact results

Start with focused tests:

```bash
swift test --filter 'PerRequestHTTPClientTransportTests|HTTPClientTransportTests|ProtocolNegotiationTests|StreamableHTTPServerTransportTests|ProgressTests'
swift test --filter 'HTTPServerTransportTests|StreamableHTTPServerTransportTests'
```

Then run:

```bash
swift test
swift package generate-documentation --target MCP --warnings-as-errors
scripts/run-conformance.sh
scripts/run-conformance-2026-07-28.sh
```

Record exact commands, pass/fail counts, known unscored failures, and warnings in the verification
log in `MCP-2026-07-28-FOLLOW-UP-PLAN.md`. Do not copy earlier counts forward as if they validate
the new implementation.

### 7.6 Keep specification clarifications isolated

The two candidate clarifications are:

1. discovery fallback for a correlated non-modern JSON-RPC error carried by HTTP 200; and
2. effective `Accept` quality and wildcard precedence.

The report already contains the smallest reproducer, available fixes, recommended wording, and
tradeoffs. Draft each independently from Swift changes. Do not mix specification commits into the
Swift branch, and do not push the specification repository without an explicit destination and
authorization.

## Pull-request ownership and commit strategy

| Change | Owning review unit |
| --- | --- |
| Core discovery classification and negotiation tests | PR 03 |
| HTTP discovery response plumbing/tests | PR 05 |
| `enableStandaloneGetStream` API | PR 05 |
| `Accept` and `Content-Type` parser | PR 06 |
| Progress migration documentation | PR 12 |
| Swift compatibility-adapter contract, later | PR 11 |

Implement and verify on the aggregate branch with small, independently cherry-pickable commits.
Keep unrelated ownership boundaries in separate commits. Do not mutate the twelve source review
branches until the aggregate passes. Then inspect whether any corresponding upstream PR is already
under review:

- if it is not under review and propagation is safe, port the minimal commit to its owning review
  branch and restack successors using backup refs;
- if it is already under review, or a split would make the fix incoherent, use one focused
  interoperability follow-up after the latest owning unit and document the dependency.

Never rewrite or force-push reviewed history blindly. Push completed Swift work only to `fork`,
never `origin`.

Suggested logical commits are:

1. interoperability report, follow-up plan, and handoff documentation;
2. discovery classifier and fallback tests;
3. standalone GET naming and compatibility overload;
4. HTTP media-range parsing and tests;
5. progress migration documentation and verification-log update.

The discovery fix crosses PR 03 and PR 05. Split core semantics from HTTP plumbing only if the
intermediate commits remain compiling and testable; otherwise keep it as one focused follow-up.

## Phase 7 completion criteria

Phase 7 is complete only when:

- all four settled changes are implemented and documented;
- focused and full Swift tests pass;
- DocC succeeds with warnings as errors, apart from clearly recorded existing compiler warnings;
- both pinned conformance commands have run and their exact results are recorded;
- the plan checkboxes and verification log reflect reality;
- commits remain traceable to their owning review units;
- the aggregate branch is pushed to `fork`, not `origin`;
- the final handoff identifies any intentionally deferred spec PR or branch propagation work.

## Phase 8 preview: compatibility matrix

Do not try to finish Phase 8 in the same implementation pass. Its target architecture is already
decided:

- extend the official conformance runner rather than inventing a Swift-only harness;
- add a Swift known-SDK adapter and stable everything-client/server contracts;
- add a generic `interop` command pairing arbitrary known client/server refs;
- separate normative expectations, immutable observations, and reviewed deviations;
- generate the Markdown result matrix;
- use real loopback TCP plus Docker/OCI for Linux HTTP, native child processes and pipes for stdio,
  and a native macOS Swift lane for Foundation/URLSession behavior;
- do not use UTM as the baseline; reserve VMs for an OS-specific reproduction;
- model test doubles with real timing, ordering, cancellation, reentrancy, delivery, and concurrency
  behavior, not merely matching JSON shape.

Wave 1 contains Swift, TypeScript, Python, C#, Go, and Rust with one legacy and one 2026-capable
generation each: 12 variants, 144 ordered pairs per transport, or 288 across stdio and HTTP. Wave 2
adds Java, Ruby, PHP, and Kotlin: 20 variants, 400 ordered pairs per transport, or 800 across both.
Unsupported cells must be explicit rather than counted as failures. Expected results must be
reviewed data and must never be overwritten automatically by an observation run.
