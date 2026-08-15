# MCP 2026-07-28 Conformance Corrections: Second Review

Date: 2026-08-14

## Purpose

This document records the second review of the conformance corrections and the resolution of its
three findings. The initial review covered the delta from the pre-correction aggregate at `c2c2558`
to the corrected aggregate at `db6bb93`; the follow-up reviewed and restacked the resulting PRs in
their final context.

The review emphasized protocol correctness, interoperability, separation of concerns, and the
smallest defensible blast radius. It did not identify a reason to change public API, wire models,
compatibility defaults, authentication behavior, or unrelated released code. No finding required a
new PR outside the existing feature-oriented stack.

## Current state

The corrections remain assigned to their original review units. These are the corrected local tips
immediately before the final push:

| Review unit | Corrected local tip | Correction |
| --- | --- | --- |
| PR 03, discovery negotiation | `9ee677ef51b84692fb44249275522d353cf742df` | Keep the bounded retry and state both discovery-method assertions directly. |
| PR 05, HTTP client | `22d90f56587b1264380a5ea186d71f7ec000b298` | Retain HTTP 400 transport-boundary coverage; restacked without a new feature change. |
| PR 09, subscriptions | `ae8a88e6e17213df0ea5bc768733dcd753e163a5` | Retain prompt/tool ordering, correlation, and filter coverage; restacked without a production change. |
| PR 11, conformance | `26f965773d0e8e4bc640867b79af55e85c5364cb` | Retain the hidden diagnostics; restacked without changing publisher semantics. |
| PR 12, defaults and release | `6f212923b96b7dae20442fbfdca5741fecab97a8` | Restacked release tip with no additional behavior. |
| Aggregate | commit containing this record | Restacked code plus precise lifecycle and notification-publication documentation. |

The aggregate correction delta changes only these production files:

- `Sources/MCP/Client/Client.swift`: one retry-policy predicate removed;
- `Sources/MCPConformance/Server/main.swift`: two hidden diagnostic handler cases added.

All other source changes in the correction delta are tests or documentation. A tree comparison from
`c2c2558` to `db6bb93` contains 12 intended files and no unrelated source movement.

## Independent verification

The second review reran the exact focused paths on the aggregate without changing source files.

### Focused Swift tests

```sh
swift test --filter \
  'ProtocolNegotiationTests|SubscriptionTests|PerRequestHTTPClientTransportTests'
```

Result: 79 tests in three suites passed.

### Pinned client conformance

```sh
scripts/run-conformance-2026-07-28.sh \
  --mode client \
  --results /private/tmp/swift-sdk-conformance-review-20260814
```

Result: 424 passed, 13 unscored failures, and zero warnings. The exact
`sep-2575-client-retry-supported-version` check reported `SUCCESS` with all three values equal to
`2026-07-28`:

- first request header version;
- retry request header version;
- retry request `_meta` version.

### Pinned server conformance

```sh
scripts/run-conformance-2026-07-28.sh \
  --mode server \
  --results /private/tmp/swift-sdk-conformance-review-20260814
```

Result: 168 passed and 25 unscored Tasks failures. The scored `server-stateless` scenario passed
30/30. Both of the previously warning checks reported `SUCCESS` and included correctly correlated
frames:

- `sep-2575-server-sends-prompts-list-changed-on-subscription`;
- `sep-2575-server-sends-tools-list-changed-on-subscription`.

The temporary review output is evidence only and must not be committed.

## Review conclusions

### Advertised-version retry

The production change in PR 03 is correct and has the desired blast radius. Removing only the
`retryVersion != requestedVersion` condition preserves all of the existing controls:

- only a correlated structured `UnsupportedProtocolVersionError` can select a retry version;
- `mutuallySupportedVersion` still restricts selection to versions supported by Swift;
- `mayRetryVersion` still bounds the operation to one retry;
- the recursive discovery call creates a fresh JSON-RPC ID;
- authentication, transient transport, malformed-data, and cancellation failures do not retry;
- a second structured rejection is surfaced without initialization fallback;
- the operation being retried is the idempotent `server/discover` method.

PR 05 covers the important transport boundary. The HTTP test proves that a correlated JSON-RPC error
inside HTTP 400 survives transport classification, reaches client policy, and causes two discovery
POSTs with fresh IDs and matching header/body version metadata. It also proves no initialization
request is sent.

No additional retry production logic is warranted.

### Subscription routing and diagnostic calls

The PR 09 test is focused and readable. It opens prompt-only and tool-only listeners concurrently,
consumes both acknowledgments before publication, publishes through `Server.notify`, verifies the
original subscription IDs, and drains both streams after cancellation so an extra cross-filter frame
cannot remain unnoticed.

The PR 11 handler additions are appropriately confined to the conformance executable. They are not
listed by `tools/list`, retain no persistent state, upgrade the weak server reference before use, and
do not introduce a delay or direct transport write. The exact pinned server scenario confirms that
the hidden names are reachable and that both expected notifications arrive.

No core subscription-routing change is needed to satisfy the protocol or current conformance
requirements.

## Findings and resolutions

### 1. Make the second-rejection test state the method invariant directly

Priority: P3

Owner: PR 03, `mcp-2026-discovery-negotiation`

File: `Tests/MCPTests/ProtocolNegotiationTests.swift`

Status: resolved in PR 03

The successful retry test directly asserts that both requests use `Discover.name`. The
second-rejection test proves two requests, fresh IDs, unchanged parameters, unchanged version
metadata, and no third request, but it leaves the method invariant implicit.

The following two assertions now appear after decoding the second request:

```swift
#expect(firstRequest.method == Discover.name)
#expect(secondRequest.method == Discover.name)
```

This test-only correction makes the stated “exactly two discovery requests and no initialize”
guarantee obvious to a reviewer. No production logic was added for this finding.

### 2. Correct the lifecycle wording in the conformance record

Priority: P3

Owner: aggregate documentation

File: `Documentation/MCP-2026-07-28-CONFORMANCE-FINDINGS.md`

Status: resolved in the aggregate documentation

Before correction, the retry checklist said:

> initialization continues successfully after that retry

The corrected path never initializes. The text now says:

> the per-request connection succeeds after that retry

The adjacent statement that there is no initialization fallback remains intact.

### 3. Describe `Server.notify` completion precisely

Priority: P2 documentation/design precision; not a scored interoperability failure

Owners: aggregate documentation and the PR 11 description

Status: resolved in documentation; production behavior intentionally unchanged

Relevant files:

- `Documentation/MCP-2026-07-28-CONFORMANCE-FINDINGS.md`;
- `Documentation/MCP-2026-07-28-CODE-DESIGN-REVIEW.md`;
- `Documentation/PullRequests/MCP-2026-07-28/11-conformance.md`;
- `Sources/MCP/Server/Server.swift`, for the existing queue semantics.

Before correction, the records said that the hidden handler returns only after publication succeeds
or completes. That is stronger than the current publisher contract. When a subscription queue has
capacity, `enqueueSubscriptionMessage` appends the frame, starts `drainSubscription` in another
task, and returns. `Server.notify` has therefore accepted the notification for delivery, but the
eventual transport write can still fail asynchronously.

The existing `serverBackpressure` test demonstrates this intentionally: the first notification call
returns while a gated transport send is still blocked. This is part of PR 09's bounded FIFO publisher
design, not a new released-code bug.

The smallest correct resolution is documentation-only. The records now use this contract:

> Each diagnostic upgrades the weak server reference, awaits `Server.notify`, and returns success
> only after the subscription publisher accepts the notification for delivery.

The public `Server.notify` behavior was not changed merely to make the conformance fixture wait for
a transport write. The specification check waits for the correlated notification and passes; there
is no client acknowledgment that could establish delivery. Changing all notification publishers to
await transport writes would alter latency, error propagation, cancellation, and backpressure
across the SDK.

If a hard transport-write guarantee is explicitly required later, treat it as a deliberate PR 09
design change rather than a PR 11 fixture workaround. It would require per-message completion state,
send-error propagation to every selected publisher, cancellation behavior, and a gated transport test
that accurately models write timing. Do not use a delay or a direct transport write.

## Completed implementation and restacking

The findings stayed within their owning review units; no correction PR was added.

1. Local and fork SHAs, dirty aggregate state, and protected-file checksums were recorded.
2. The two method assertions were folded into PR 03's existing
   `Retry an advertised protocol version once` commit. No production source changed.
3. PRs 04 through 12 were rebased sequentially in a disposable worktree. Every old-to-new
   `git range-diff` reported the existing commits as unchanged.
4. Each branch passed `git diff --check`, its focused tests, and full `swift test`. PR 03 passed 21
   focused negotiation tests and 605 full-suite tests. The final PR 12 tip passed 750 SDK tests in
   51 suites plus six conformance-adapter tests.
5. PR 11 also built both conformance products. PR 12 passed DocC generation with warnings as errors,
   the pinned baseline conformance run, and the pinned 2026-07-28 conformance run.
6. The aggregate documentation commits were rebased with automatic tracked-change preservation.
   The lifecycle sentence and publisher contract were corrected only in the aggregate records.
7. The aggregate tree was audited against `db6bb93`: the only code delta is the two PR 03 test
   assertions; the remaining selected changes are documentation, including this record.

The final pinned 2026-07-28 run reported 424 client checks passed, 13 unscored failures, and zero
warnings; the server reported 168 checks passed and 25 unscored Tasks failures. The exact retry,
prompt-change, and tool-change checks all reported `SUCCESS`.

## Recorded pre-rewrite fork SHAs

These are the expected remote values recorded immediately before the restack and are the leases for
the corresponding pushes:

| Branch | Current fork SHA |
| --- | --- |
| `mcp-2026-discovery-negotiation` | `8b5ee93e24e27169cdb0fbfd7ffe3c82279e5026` |
| `mcp-2026-multi-round-trip` | `a3e2bba291e23404d49f110394a003222322686d` |
| `mcp-2026-http-client` | `13a519617e8730e81e844ed8f16b97cd74f4263d` |
| `mcp-2026-http-server` | `98839ed26efaea16b2c1e257bc39f0ae107db051` |
| `mcp-2026-http-lifecycle-routing` | `f029605ec75fe9abdb99f917a9ccf784ba85dfcc` |
| `mcp-2026-tool-headers` | `2e10f022922952d9809530e5b9c396aa6b4836b2` |
| `mcp-2026-subscriptions` | `95fad7745e2a75494ae8a264cdd97225d5dc626f` |
| `mcp-2026-response-caching` | `d721e978dc8bec3ad64e351cb206546cfa9b7eca` |
| `mcp-2026-conformance` | `9cb2fd27570123eabf36146f198c92891d2c8f2a` |
| `mcp-2026-defaults-release` | `30afa8ddeb7e7287e75ad9579b2e33dd8b1c68cb` |
| `swift-sdk-mcp-update-07-28-26` | `db6bb930cfd04d8a97f72dc72a57a6f731e81deb` |

> **Superseded (2026-08-15).** The third-party audit restacked every unit, so all SHAs below
> are historical. The current tips are listed in
> [`PullRequests/MCP-2026-07-28/README.md`](PullRequests/MCP-2026-07-28/README.md).

## Corrected local branch tips before push

| Branch | Corrected local SHA |
| --- | --- |
| `mcp-2026-discovery-negotiation` | `9ee677ef51b84692fb44249275522d353cf742df` |
| `mcp-2026-multi-round-trip` | `1fa6772c7a560ffec923b3e10d1e86a1c75da248` |
| `mcp-2026-http-client` | `22d90f56587b1264380a5ea186d71f7ec000b298` |
| `mcp-2026-http-server` | `bcfa1412b3fc2b14b4ae41202decdcb121d690d9` |
| `mcp-2026-http-lifecycle-routing` | `c3e84b1f543fb6c69e3565f4de8585ed1d5c827d` |
| `mcp-2026-tool-headers` | `4ad07a576074cc0b46196f9238e2e3fc0887bfed` |
| `mcp-2026-subscriptions` | `ae8a88e6e17213df0ea5bc768733dcd753e163a5` |
| `mcp-2026-response-caching` | `01dc1398e9a10d9624c0df9d4461540985471f84` |
| `mcp-2026-conformance` | `26f965773d0e8e4bc640867b79af55e85c5364cb` |
| `mcp-2026-defaults-release` | `6f212923b96b7dae20442fbfdca5741fecab97a8` |
| `swift-sdk-mcp-update-07-28-26` | commit containing this record |

PRs 01 and 02 are unchanged and must not be rewritten for this work.

## Aggregate worktree preservation

Before the restack, the aggregate branch had the following pre-existing modified or untracked files.
They were preserved byte-for-byte and were not staged or absorbed:

| File | State | SHA-256 before this v2 file was created |
| --- | --- | --- |
| `Documentation/MCP-2026-07-28-FOLLOW-UP-PLAN.md` | tracked, modified | `a5238a2c77583bc1f31b18c95d943d91a019089b345dcda74d090ff87a5f0e8d` |
| `Documentation/MCP-2026-07-28-CONFORMANCE-FIX-HANDOFF.md` | untracked | `d79c24110c6b6ee3ae633815dfc9e744cce4abd4637969fd20daf95daa623ac9` |
| `Documentation/MCP-2026-07-28-SWIFT-CONFORMANCE-PLAN.md` | untracked | `ba3a3509bf121f0facc37736fb054ff2b45d86aa75b344cd1bf51018c0bfa645` |
| `lefthook.yml` | untracked | `89951797a15ac7f78e2e2979735a29377eace45f27154120d970dbf3b253669d` |
| `scripts/setup-conformance-development-repo.sh` | untracked | `ff56177a9e1480d4437518a7e4e4c4535c8f6320c8876d715acc1623d056ed17` |

This separately authorized v2 document is committed as an aggregate contributor record. That
authorization does not extend to the unrelated files above.

No `.rej`, `.orig`, or conflict-marker files were present.

## Security, privacy, and authorization impact

The completed follow-up is test-only and documentation-only. It adds no credential path, logging,
persistent mutation, public API, or new network behavior.

The hidden diagnostics remain in a conformance executable bound to `127.0.0.1`. They do not appear in
`tools/list`, retain request data, or alter prompt/tool state. Keeping the existing queued publisher
semantics also avoids a broad change to cancellation and transport-error propagation.

No OAuth, token, issuer, cache-partitioning, or mirrored-header behavior changed during this
follow-up.

## Final acceptance

After the corrected stack is pushed, Alan's cross-SDK matrix remains the final acceptance gate:

```sh
npm run sdk-matrix -- \
  --sdk swift-sdk@mcp-2026-conformance \
  --requirements 2025-11-25,2026-07-28
```

Inspect the report rather than relying on exit status. Accept only:

- 2025 client: 18/18 clean scored scenarios;
- 2025 server: 30/30;
- 2026 client: 32/32;
- 2026 server: 37/37;
- zero scored warnings or failures.

Optional Tasks, authorization extensions, and post-release JSON Schema findings remain explicitly
unscored and out of scope.
