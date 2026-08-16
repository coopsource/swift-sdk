# MCP 2026-07-28 Swift SDK — third-party audit report

Date: 2026-08-15 (audit) · 2026-08-15 (Gate A remediation applied — see §0)

> **§0 Status: Gate A is complete.** The blocker and the two recommended fixes are implemented, the
> cross-unit hunks are restacked into their owning units, and the PR bodies and review records are
> corrected. The stack was rebuilt from unit 01 upward; every unit was re-verified at its own tip
> and the whole stack re-verified at the aggregate. New tips are in §0.1; what changed is in §0.2;
> verification is in §0.3. Findings in §5 keep their original text — their remediation status is
> recorded in §0.4, and what still needs a human is in §0.5.
Auditor: independent third-party review (Claude, 21-agent audit: 12 per-unit reviews, 6 cross-cutting
passes, adversarial verification, full dynamic verification), commissioned via
[`MCP-2026-07-28-THIRD-PARTY-AUDIT-HANDOFF.md`](MCP-2026-07-28-THIRD-PARTY-AUDIT-HANDOFF.md).

## 0. Gate A remediation (applied 2026-08-15)

### 0.1 New stack tips

The rewritten stack is linear, every unit is an ancestor of the aggregate, and the aggregate's
`Sources/`, `Tests/`, and manifests are identical to unit 12's.

| Unit | Pre-remediation | Now | Unit | Pre-remediation | Now |
| --- | --- | --- | --- | --- | --- |
| 01 wire-models | `8048912` | `fd8b815` | 07 lifecycle-routing | `c3e84b1` | `853cd14` |
| 02 oauth | `75a5907` | `f50a56c` | 08 tool-headers | `4ad07a5` | `bf8eac5` |
| 03 discovery | `9ee677e` | `3776cc5` | 09 subscriptions | `ae8a88e` | `38397dc` |
| 04 mrtr | `1fa6772` | `6602fa1` | 10 caching | `01dc139` | `4431fa8` |
| 05 http-client | `22d90f5` | `6cb1c3f` | 11 conformance | `26f9657` | `7b97662` |
| 06 http-server | `bcfa141` | `05f2276` | 12 defaults-release | `6f21292` | `af3d4f0` |
| | | | aggregate | `9e44edf` | `5da6fc1` |

Aggregate: 46 commits / 114 files (was 44; the extra commits are the review-record corrections
described in §0.2). The pre-remediation state remains reachable
through the `audit-20260815/*` tags.

Per-unit `git range-diff` against those tags shows changes confined to the intended commits:
units 02, 05, 08, and 11 are unchanged rebases; 01, 06, 07, 09, and 10 each have one changed
commit; 03 has three; 04 has two; 12 has two (one of them a ripple from a test that moved to 03).

### 0.2 What changed

**Code fixes**

- **AUD-01 (blocker), unit 04** — `cancelRequest` now gates on the cancellation action that `send`
  registers synchronously, instead of the attempt map that `performLogicalRequest` populates later.
  A cancellation issued before the first attempt is now recorded and honored.
- **AUD-03, unit 06** — the header parser skips empty list elements and empty parameters instead of
  rejecting the whole value, per RFC 9110 §5.6.1 and §5.6.6. `nil` still means malformed (for
  example an unterminated quoted string), and a value carrying no media range at all is still
  unacceptable.
- **AUD-04, units 09 and 10** — a received change notification now invalidates the response cache
  and clears tool-header plans *before* subscription delivery, so a notification that is dropped,
  filtered out, or unmatched still expires connection-scoped state. Unit 09 stopped pushing the
  pre-existing header-plan clear below its new guard; unit 10 inserted its invalidation above it.

**Cross-unit hunks restacked into their owning units (AUD-18)**

- The `Discover.Result` decoder that treats an absent `resultType` as `complete` moved from unit 03
  into unit 01, where the type is defined.
- The unrecognized-`resultType` rejection moved from unit 04 into unit 03, split so that unit 03
  owns the recognized/unrecognized decision and unit 04 adds only the multi-round-trip disposition.
  Unit 03's tip is no longer briefly non-conformant with `basic/index#resulttype`.
- `Version.streamableHTTPSupported(for:)` and the pinning of the initialization-era Streamable HTTP
  transports moved from unit 06 into unit 03, in the same commit that widens `Version.supported`.
  The mid-stack window in which those transports accepted a `2026-07-28` version header is gone.
- The rejection of `initialize` on a request carrying per-request metadata moved from unit 07 into
  unit 03. It is server lifecycle policy that applies on any transport, so unit 07 is now exactly
  the router and its tests (two files) and no longer touches `Server.swift`.
- The client-side gating of methods the dated revision removes stays in unit 09, where it arrived
  with subscriptions; it is new policy rather than a correction of unit 03, and unit 09's body now
  discloses it. Extracting it from a 425-line commit was judged higher risk than the disclosure.

**Tests added (6; suite is now 756)**

Two are demonstrated regression tests — each was confirmed to fail against the pre-fix code and
pass against the fix:

- `ResponseCacheTests.cancellationBeforeCachedAttempt` — a gated clock parks a cacheable request at
  the cache lookup, which is the suspension that opens the AUD-01 window. Without the fix the
  cancelled request runs to completion, returns normally, and is cached; with it the request throws
  `CancellationError` and never reaches the server.
- `ResponseCacheTests.undeliverableNotificationInvalidatesCache` — a one-message subscription queue
  makes the list-change notification undeliverable. Without the AUD-04 hoist the stale list is
  served for the full TTL.

The other four pin behavior that was previously unasserted: unrecognized `resultType` rejection and
`initialize`-with-metadata rejection (unit 03), Accept empty-element tolerance (unit 06), and
cancel-immediately-after-send at the multi-round-trip boundary (unit 04). The last one passes
before and after the fix at unit 04's own tip — the window only opens once caching adds a
suspension — so it is a contract test, not a regression test.

**Documentation**

`MIGRATION.md` A.7 now gives a remedy for `experimental` that the SDK's own validation accepts, and
adds the `HTTPResponse.dataWithStatus`, `MCPError.remote` (including the `.serverError` reroute),
and `OAuthAuthorizationError` source breaks; the guide's rollout callout documents the deliberate
decode-versus-construction difference for `multiRoundTripMode` and `responseCacheMode`; the broken
link to the aggregate-only implementation guide is replaced with the information it pointed at.
PR bodies 01, 03, 04, 05, 06, 07, 09, 10, and 11 were corrected — PR 03 most substantially, since
it claimed HTTP classification, lifecycle caching, and tests that live in PR 05. `IMPLEMENTATION.md`
no longer attributes aggregate-only material to units 01 and 11, `CONFORMANCE-FINDINGS.md` marks
its superseded stack tip, and the stack README lists every unit that now owns a correction.

### 0.3 Post-remediation verification (all PASS)

| Check | Before remediation | After |
| --- | --- | --- |
| `swift test` | 750 / 51 suites + 6 adapter | **756 / 51 suites + 6 adapter, 0 failures** |
| Product builds | both | both |
| DocC `--warnings-as-errors` | pass | pass (same pre-existing `NetworkTransport` warning) |
| `run-conformance.sh` (0.1.15) | 223 client + 47 server, clean | **223 + 47, 0 failed, 0 warnings** |
| `run-conformance-2026-07-28.sh` | 424 / 13 unscored / 0 warn; 168 / 25 unscored | **identical** |
| Requirements leg 2025 client | 18/18 scored clean | **all scored clean; 272 checks passed, every ✗ explicitly not scored** |
| Requirements leg 2025 server | 30/30 | **30/30 scored scenarios, 0 scored issues** |
| Requirements leg 2026 client | 32/32 | **all scored clean; 424 checks passed, 0 warnings** |
| Requirements leg 2026 server | 37/37 | **37/37 scored scenarios, 0 scored issues** |

The four requirement legs ran through the conformance runner's `--path` mode against this working
tree (see §0.5 on why the fork-cloning matrix could not be used). Every failing scenario in every
leg is one the requirement set marks not-scored — the same DPoP, enterprise-authorization, WIF,
JSON-Schema-preservation, and Tasks-extension backlog as before. Per-scenario artifacts are under
`../conformance/results/audit-postfix/` and remain unredacted.

Each unit was also verified at its own tip during the restack (units 03, 04, 06, 07, 09, and 10
ran their focused suites immediately after amendment), so no unit depends on a later one to
compile or pass.

**Linux, in Docker** — the lane the earlier records could only cite from history:

| Lane | Result |
| --- | --- |
| `swift build` + `swift test`, `swift:6.1-noble` (Swift 6.1.3, aarch64) | **678 tests passed, 0 failures** |
| Both conformance products, same image | build |
| Static Linux SDK build, `swift:6.1.2-noble` (the CI lane's own script) | **`✅ Swift build with Static Linux Swift SDK completed successfully`** |
| `MCP` target under `swift:6.0.3-noble` (the Swift 6.0 manifest) | build |

678 on Linux versus 756 on macOS is the platform split: the `EventSource`-backed suites are
Apple-only by manifest condition. The Docker runs rewrote `Package.resolved` (the Swift 6.0
manifest resolves without NIO); that churn was reverted, since the stack deliberately excludes
lockfile changes.

**Cross-SDK matrix, at the pushed tips** — `results/sdk-matrix/latest.md`, conformance
`04c8dc0` (clean tree):

| SDK | 2025 client | 2025 server | 2026 client | 2026 server |
| --- | --- | --- | --- | --- |
| `swift-sdk` @ `5da6fc15` | 18/18 | 30/30 | 32/32 | 37/37 |
| `swift-sdk@mcp-2026-conformance` @ `7b97662d` | 18/18 | 30/30 | 32/32 | 37/37 |
| `typescript-sdk` @ `27a94b5d` | 17/18 | 30/30 | 32/32 | 37/37 |

Swift has **zero scored findings** in every cell. The single scored warning in the whole report is
TypeScript's `sse-retry:client-sse-retry-timing` (reconnected at ~800ms against a 500ms
expectation), which is theirs and pre-existing. Every ⚠️ on the Swift rows is the known not-scored
backlog.

### 0.4 Finding dispositions after remediation

| Status | Findings |
| --- | --- |
| Fixed in code | AUD-01, AUD-03, AUD-04 |
| Restacked into the owning unit | AUD-18 (all four items; the fourth by disclosure) |
| Fixed in documentation | AUD-02, AUD-15, AUD-16, AUD-27 (round-limit wording), AUD-28 (documented), §9 items 1–8 |
| Unchanged, open as follow-ups | AUD-05 – AUD-14, AUD-17, AUD-19 – AUD-26, AUD-29 – AUD-38 |
| Found later, fixed in unit 06 | server-side cancellation ordering (the stdio mirror of AUD-01) |
| Conformance repo, unchanged | AUD-C1, AUD-C2 (that repository was not modified) |
| Pre-existing upstream, unchanged | §8 items 1–8 |

### 0.5 What still needs a human

All 13 branches are pushed to `coopsource/swift-sdk` and the matrix was re-run against them, so
nothing in Gate A is outstanding. What remains is unchanged from the original audit:

- Gate B coordination: reconcile the overlapping upstream pull requests — now triaged in
  [`MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md`](MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md), with drafted
  comments in `UPSTREAM-COMMENTS-DRAFT.md` awaiting review — coordinate the conformance registration
  through PR #432, and file the two prepared specification clarifications.
- Gate C follow-ups: the medium findings listed in §0.4 as open.

Note for Gate B: the conformance repository's own fixes (below) are committed locally at `04c8dc0`
on `codex/swift-sdk-conformance-integration` and have no remote — that branch still needs a fork
or patch export before it can be offered upstream.

## 1. Audit snapshot

| Item | Value | Verified |
| --- | --- | --- |
| Swift aggregate | `swift-sdk-mcp-update-07-28-26` @ `9e44edf65cb4b9780ccef3193bb3eed290a6a778` | ✅ exact |
| Official baseline | `main` @ `a0ae212ebf6eab5f754c3129608bc5557637e605` (v0.12.1) | ✅ exact |
| 12 unit tips | 01 `8048912` → 02 `75a5907` → 03 `9ee677e` → 04 `1fa6772` → 05 `22d90f5` → 06 `bcfa141` → 07 `c3e84b1` → 08 `4ad07a5` → 09 `ae8a88e` → 10 `01dc139` → 11 `26f9657` → 12 `6f21292` | ✅ all exact, linear, ancestry proven |
| Aggregate delta | 44 commits / 114 files / +22,905 / −534; last 4 commits doc/script-only (Sources tree hash identical to unit-12 tip) | ✅ |
| Spec authority | tag `2026-07-28` @ `5f5440bb26a62e2cf3440b92da5a667efa03b267`; local tree = tag except cosmetic URL rewrites; `schema/2026-07-28/**` byte-identical | ✅ |
| Conformance integration | `codex/swift-sdk-conformance-integration` @ `0f2796f` = official `main` `c321dd3` (0.2.0-alpha.11) + 2 commits | ✅ |
| Runner pins | `@modelcontextprotocol/conformance@0.1.15` and `@0.2.0-alpha.11` | ✅ immutable |
| Matrix tested SHAs (fresh, this audit) | `mcp-2026-conformance` run: `26f9657`; aggregate run: `9e44edf` (cache verified moved off stale `584f8ff`) | ✅ |
| Checkpoints | 17 local `audit-20260815/*` tags across the 3 repos + working-tree backups + MANIFEST at `../audit-checkpoints-2026-08-15/` | created before any execution |

All 16 test fixtures under `Tests/MCPTests/Fixtures/2026-07-28/` verified **byte-identical** to the
tagged `schema/2026-07-28/examples/` counterparts (including the one disclosed as "derived" — the
official example already carries the subscription ID, so the disclosure is over-cautious, not a
divergence).

## 2. Methodology and scope

- **Per-unit review**: each of the 12 review units audited as its exact `base..head` delta by a
  dedicated agent against the dated spec (files read at the unit tip via `git show`; final state via
  the working tree, whose `Sources/` hash equals the unit-12 tip). Every reviewer sanity-checked its
  diffstat, treated prior documentation as claims (code + spec + executed evidence as ground truth),
  answered the stack-integrity questions (self-contained? fixes an earlier PR? belongs elsewhere?),
  and returned findings in the handoff's 8-field format.
- **Cross-cutting passes**: security/privacy composition (full-diff log and error-message sweeps,
  cache partition-key hygiene, handoff invariant checklist); concurrency/cancellation composition
  (`@unchecked Sendable` sweep, stream-buffer sweep, cancellation-chain matrix, test-double timing
  fidelity); architecture & public API (full a0ae212→9e44edf public-surface diff, Transport-protocol
  invariance, policy/evidence separation, naming, architecture judgment); documentation accuracy;
  conformance-repo integration review (both local commits); interop citation spot-check (all five
  pinned SDK snapshots fetched at their SHAs into disposable scratchpad clones — local checkouts and
  runner caches untouched).
- **Dynamic verification**: executed fresh in this audit (section 4).
- **Adversarial verification**: cross-corroboration between independent agents plus orchestrator
  code probes for the pivotal claims; single-source medium-or-higher findings put through a
  dedicated refute-first verification batch.
- **Explicitly not done**: Linux / minimum-Swift-toolchain matrix rerun (known deferral; recorded
  figures reproduced on macOS only); execution of other SDKs (interop verification is
  citation-level source reading at the pinned SHAs); any modification to tracked files, remotes, or
  the preserved working-tree documents.

## 3. Executive summary

**The stack is substantively ready for the planned serial upstream submission.** The audit found
one blocker-grade code defect and a short list of pre-submission text/restack corrections; all of
them have since been applied and re-verified (§0), so what follows is the audit as conducted,
with remediation status recorded per finding. Protocol
and wire behavior against the released `2026-07-28` tag is faithful (every deviation found is
deliberate, test-pinned, and ecosystem-aligned or stricter-than-spec); backward compatibility
through `2025-11-25` is preserved (compatibility defaults verified on all four construction/decode
paths; fresh legacy conformance runs clean); the security/privacy posture is clean (zero
stack-introduced logging/error leaks; cache partitioning verified exemplary; the handoff's full
invariant checklist closed with no gaps); and the fresh cross-SDK acceptance matrix passes at the
corrected tips with zero scored findings — closing the handoff's outstanding acceptance gate.

- **Blocker (now fixed): AUD-01** — `cancelRequest` issued immediately after `send` is
  silently lost on per-request connections (unit 04; small, well-bounded fix; no test covers the
  window today).
- **Must-fix PR text (now rewritten): AUD-02** — PR-03's body claims unit-05 behavior and tests as its own; a
  maintainer reviewing PR 03 in isolation would believe untested behavior exists.
- **Submission hygiene**: broken `MIGRATION.md` link that ships in every PR; a migration remedy
  that contradicts the SDK's own validation; several PR-body disclosure gaps; one stale SHA in a
  committed review record (all enumerated in sections 5 and 9).

Answers to the commissioning questions on stack structure:

1. **Related changes stay in the same PR** — verified per unit; every delta matches its stated
   responsibility, with the boundary exceptions listed below (all relocatable by restack before
   submission, none shipped as a separate "fix PR").
2. **No PR fixes an earlier PR** — true of the intended structure, but the audit found **four
   mid-stack cross-unit corrections** that violate it in spirit and should be restacked into their
   owning units (or explicitly disclosed) before submission: unit 03 fixes unit 01's
   `Discover.Result` decode default; unit 04's `e0ce4b1` completes unit 03's unrecognized-
   `resultType` rejection (a MUST — unit-03 tip is briefly non-conformant); unit 06 restores the
   HTTP version strictness that unit 03's `Version.supported` widening loosened (units 03–05 have a
   mid-stack regression window); unit 07 carries a 5-line unit-06 gap fix (metadata-bearing
   `initialize` handling) that its PR body does not disclose. The stack's own correction policy
   (fold into owning unit, restack successors) is the right remedy and has been exercised before.
3. **The integration story** — holds for users (README + MIGRATION.md + the 12 PR bodies give a
   coherent composition narrative) but is **thinner for upstream reviewers**: the stack README,
   IMPLEMENTATION.md (design constraints, fixture provenance, verification log), and all review
   records are aggregate-only and invisible in any PR; `MIGRATION.md:687` links IMPLEMENTATION.md
   and therefore breaks in every PR and in the shipped package; PR-01's body points at a
   provenance record its own delta does not contain. Fixes are one-line each (section 9).

### Per-unit verdicts

| Unit | Verdict | One-line rationale |
| --- | --- | --- |
| 01 wire-models | **PASS** | Types field-for-field vs schema.ts; fixtures byte-identical; three LOW doc gaps on real decode-behavior deltas |
| 02 oauth-issuer-validation | **PASS-WITH-FINDINGS** | All issuer/refresh/discovery invariants verified in code; findings LOW/INFO (legacy-token comparator edge, doc nits) |
| 03 discovery-negotiation | **PASS-WITH-FINDINGS** | Behavior sound at final state; PR body must be rewritten (AUD-02); probe-timeout UX + version-set asymmetry findings |
| 04 multi-round-trip | **FIX REQUIRED** | MRTR mechanics spec-faithful, but AUD-01 (lost cancellation) is blocker-grade and owned here |
| 05 http-client | **PASS-WITH-FINDINGS** | One-POST/SSE/cancellation/auth-serialization verified; fallback breadth is a deliberate, ecosystem-aligned spec deviation to document |
| 06 http-server | **PASS-WITH-FINDINGS** | Validation/isolation/cancellation verified; RFC empty-element MUST violation + two interop-calibration findings |
| 07 http-lifecycle-routing | **PASS** | All five precedence steps test-pinned; carries one undisclosed unit-06 hunk (disclose or move) |
| 08 tool-headers | **PASS-WITH-FINDINGS** | Sentinel/uniqueness/reachability enforcement correct; nested-`type` over-invalidation + refresh-trigger fragility |
| 09 subscriptions | **PASS-WITH-FINDINGS** | Ack-first/filter/ID invariants verified end-to-end; three MED operational findings (fan-out coupling, keep-alives, mixed-mode notify) |
| 10 response-caching | **PASS-WITH-FINDINGS** | Privacy partitioning exemplary; owns the composed invalidation-skip fix (AUD-04); reviewer's compat-regression claim refuted by executed evidence |
| 11 conformance | **PASS** | Zero `Sources/MCP` changes proven; adapter/fixture/runner verified; hidden diagnostics exactly as accepted |
| 12 defaults-release | **PASS-WITH-FINDINGS** | Zero bare `Version.latest` uses; defaults verified on all four paths; owns doc-gap fixes (A.7 remedy, broken link, decode-default silence) |

## 4. Dynamic verification — expected vs observed (all PASS)

Run 2026-08-15 (Node v26.7.0, Swift 6.4 / darwin arm64); logs preserved in the session scratchpad,
matrix reports under `../conformance/results/sdk-matrix-audit/`.

| Step | Expected (recorded) | Observed (fresh) |
| --- | --- | --- |
| `swift test` | 750 tests / 51 suites + 6 adapter | **750/51 + 6, 0 failures** (8.5 s) |
| Product builds | both conformance executables | ✅ |
| DocC `--warnings-as-errors` | pass, pre-existing `NetworkTransport` warning only | ✅ identical |
| `run-conformance.sh` (0.1.15) | 223 client + 47 server, clean | **223/0/0 + 47/0** |
| `run-conformance-2026-07-28.sh` | client 424 pass / 13 unscored fail / 0 warn; server 168 / 25 unscored Tasks | **exact match** |
| Matrix `swift-sdk@mcp-2026-conformance` | 18/18 · 30/30 · 32/32 · 37/37, zero scored findings | **exact; tested `26f9657`, checkout clean** |
| Matrix `swift-sdk` (aggregate) | same acceptance | **exact; tested `9e44edf`, checkout clean** |

The three previously-scored warnings (`sep-2575-client-retry-supported-version`,
`sep-2575-server-sends-prompts-list-changed-on-subscription`,
`sep-2575-server-sends-tools-list-changed-on-subscription`) are **absent as findings — passed
clean** in both fresh matrix runs. All remaining ⚠️ cells are driven solely by the known unscored
backlog (DPoP/DPoP-nonce, enterprise-managed authorization, WIF, JSON-Schema-preservation client
scenarios; Tasks-extension server scenarios). Report provenance verified per cell: uniform commit,
`checkoutDirty:false`, first cell fetched fresh (no `--path`), runs disjoint in time, judged by
report contents, never exit status. **The handoff's outstanding acceptance gate is closed.**

## 5. Verified findings register

Every finding below survived adversarial verification (independent cross-corroboration,
orchestrator code probes, or the dedicated refute-first batch). Line references are at `9e44edf`.
Fields per the handoff: ① severity + observable consequence · ② specification/RFC/interop evidence ·
③ provenance · ④ owning unit + smallest correct change boundary · ⑤ reproduction / regression test ·
⑥ compatibility + public-API impact · ⑦ security/privacy/cache/cancellation/concurrency impact ·
⑧ blocker vs follow-up.

### AUD-01 — `cancelRequest` immediately after `send` is silently lost (per-request lifecycle)

① **HIGH.** The documented cancellation API no-ops in a real window: `cancelRequest` gates both the
tombstone insert and the task-cancel closure on `logicalRequestAttempts[requestID] != nil`
(`Client.swift:1143-1147`), but that map is first populated inside `performLogicalRequest`'s loop
(`:1242`) — after the request Task's first actor hop and, with caching enabled, after further
awaits; the cancellation closure itself is registered synchronously at `send` (`:1090-1092`) and is
simply not invoked. In the window nothing is cancelled, no pending request exists to resume, and
the HTTP stream-cancel targets the logical ID while the attempt uses a fresh wire ID — total loss.
Consequence: MRTR elicitation prompts reach the user and side-effectful tools execute after the app
cancelled; `ctx.value` never throws `CancellationError`. ② Wire cancellation is advisory
(`basic/utilities/cancellation`), so this is an SDK API-contract defect, not a wire violation — it
defeats the tombstone mechanism built precisely for cancel-before-attempt (`:1237-1240`, `:1397`).
③ Introduced (unit 04, `4ce4948`); blast radius widened by unit 08 (`e5395ad` routes every
per-request send through `performLogicalRequest`). Verified independently by the unit reviewer and
an orchestrator code probe. ④ Unit 04; smallest fix: gate on
`logicalRequestCancellations[requestID] != nil` (synchronously registered) or insert the tombstone
unconditionally — the loop prechecks already honor it. Restack units 05–12 after amending. ⑤ Call
`send`, then `cancelRequest` from another task before the request Task's first actor turn; server
answers `input_required`; observe post-cancel prompt. The existing test
(`MultiRoundTripTests.swift:454`) waits for the handler to start and never exercises the window —
add a cancel-immediately-after-send case. ⑥ Behavior-only fix; no API change. ⑦ Cancellation
integrity; can execute side-effectful work believed cancelled. ⑧ **Blocker for the stack** (land
in unit 04 before submission).

### AUD-02 — PR-03 body claims unit-05 behavior and tests as its own

① **MED (stack integrity / reviewer-facing).** `03-discovery-negotiation.md:11/:37/:50-51` claim
HTTP 400/404/405 fallback classification, origin-keyed lifecycle retention, and tests thereof; at
tip `9ee677e` none exist — `classifyDiscoveryFailure`, `protocolLifecycleCache`, and all status
tests first appear in unit-05 commits (`2ffec09`/`0be6eda`/`22d90f5`); the tip's entire fallback
classifier is a one-line transport-type check. A maintainer approving PR 03 on this text believes
untested behavior exists. ② Claims-vs-delta (verified by grep at both tips). ③ Introduced
(aggregate PR-body docs). ④ PR-03 body; rewrite three passages to state that HTTP evidence,
status classification, and caching land in unit 05. ⑤ `git show 9ee677e:Sources/MCP/Client/Client.swift | grep -c classifyDiscoveryFailure` → 0. ⑥⑦ None (text). ⑧ **Must fix before submitting PR 03.**

### AUD-03 — Accept-header parsing rejects empty list elements (RFC 9110 MUST violation)

① **MED-HIGH.** `split` returns nil on any empty segment (`HTTPRequestValidation.swift:267,274`),
failing the whole header (`:94-98`) → `Accept: application/json, , text/event-stream` or a
trailing comma ⇒ 406 on every POST; `application/json;` (empty parameter) is likewise rejected.
Codified as expected behavior (`HTTPRequestValidationTests.swift:93,100`). ② RFC 9110 §5.6.1: "A
recipient MUST parse and ignore a reasonable number of empty list elements"; §5.6.6 grammar makes
the trailing parameter optional. ③ Introduced (unit 06, `bcfa141`). ④ Unit 06; skip empty list
elements/parameters instead of poisoning the parse. ⑤ POST with a trailing comma in Accept →
observe 406; regression: the two cited tests inverted. ⑥ Interop-only; conformance sends clean
headers so the suite can't catch it. ⑦ None. ⑧ Follow-up (recommended before submission of 06;
hard recipient-MUST, small fix).

### AUD-04 — Subscription-delivery failure paths skip cache invalidation and header-plan clearing

① **MED (composed).** `handleMessage` runs `guard await processSubscriptionMessage(message) else
{ return }` (`Client.swift:2572`) before `invalidateResponseCache(for:)` (`:2574`) and the
`clearToolHeaderSchemas` block (`:2576-2580`). The guard's false paths — unknown/stale subscription
id (`:2734-2742`, incl. post-failure races), pre-ack or out-of-filter (`:2744-2753`), buffer
overflow (`:2837-2842`), terminated — discard a genuinely received `listChanged`: cached lists stay
fresh for their full TTL and stale header plans produce `-32020`s. Bounded by: the app-visible
stream error on overflow, TTL expiry, and the `-32020` reload recovery (which heals both) — but a
UI that only reads the list never triggers recovery. ② `server/utilities/caching.mdx`
(listChanged invalidates). ③ Cache half introduced by unit 10 into a pre-existing lossy
composition (the header-clear skip predates it, units 08/09). ④ Unit 10; smallest fix: hoist both
calls above the guard (invalidating on an unverified notification is conservative — worst case an
extra refetch; not a privacy surface). ⑤ Two listeners, capacity 32, flood one until `.dropped`,
then observe stale `tools/list` served from cache. ⑥ None. ⑦ Cache-correctness only. ⑧ Priority
follow-up (fold into the stack if restacking anyway).

### AUD-05 — Fan-out couples listeners: one saturated subscriber cancels delivery to healthy waiters

① **MED.** `enqueueSubscriptionNotification` uses a throwing task group with `waitForAll`
(`Server.swift:1748-1820`): one listener's buffer-full throw (`:1797-1802`) cancels sibling
children; a sibling blocked in `pendingMessages` is resumed with `CancellationError`
(`:1811-1817,1920-1929`) and **misses the notification**; already-queued siblings deliver;
`Server.notify` throws one unattributed error after partial delivery (and a sibling resumed
normally but cancelled after queuing gets a spurious error despite delivering).
`MCP-2026-07-28-IMPLEMENTATION.md:271-272`'s "different subscriptions remain independent" is
inaccurate for this coupling; the backpressure test covers a single subscription only. ② Spec is
silent on backpressure (recorded gap) — this is SDK design review, not a violation. ③ Introduced
(unit 09). ④ Unit 09; per-subscription error isolation (don't cancel siblings; report per-ID) +
document partial-delivery semantics. ⑤ Capacity 1, two listeners, saturate A, block B in pending,
notify. ⑥ `notify` error semantics change slightly. ⑦ Delivery correctness under load. ⑧ Follow-up.

### AUD-06 — Listen streams die after ~60 s of quiet; dormancy has no per-subscription recovery

① **MED (operational).** The server emits no SSE keep-alive comments (no comment form exists in
`SSEEvent`, `HTTPServerTypes.swift:188-224`; no periodic writer in the transport), and the client
uses default `URLSessionConfiguration` (`HTTPClientTransport.swift:319`; 60 s inter-data timeout,
no listen-specific override) → a quiet listen stream times out, surfaces `.transportError` ⇒
`.disconnected` ⇒ dormant; the only re-listen path is a full reconnect
(`Client.swift:2636-2648,763`) or a new listen with a new ID. Degradation is signaled (the app
observes `.disconnected`) but silent in effect for apps that don't react. ②
`streamable-http.mdx:146-153` encourages keep-alive comments precisely against idle timeouts. ③
Introduced (unit 09; new-lifecycle-only). ④ Unit 09 (server keep-alives; consider an infinite
read timeout for listen POSTs client-side; document the `URLSessionConfiguration` mitigation). ⑤
Subscribe over HTTP, publish nothing for 61 s, observe `.disconnected`. ⑥ None. ⑦ Availability
of the subscription channel. ⑧ Follow-up (recommended before heavy production use).

### AUD-07 — Mixed-mode servers: one legacy `initialize` starves 2026 listeners of background notifications

① **MED.** `notify`'s early return (`Server.swift:672-678`) routes background notifications
(`currentHandlerContext == nil && isInitialized`) to the legacy broadcast, bypassing subscription
fan-out; `isInitialized` is server-global (`:338-344`) and set by any completed legacy initialize
in `.initializationAndPerRequestMetadata` mode. Verified reachable on dual-lifecycle transports
(stdio/custom): silent starvation of listen subscriptions. On the in-tree per-request HTTP
transport the legs cannot co-occur (initialize is rejected pre-dispatch), so the HTTP variant is
theoretical. ② Dual-era serving is spec-sanctioned (`versioning.mdx`); the starvation is an SDK
composition defect. ③ Introduced (unit 09 composition with pre-existing `isInitialized`). ④ Unit
09; in mixed mode, background `notify` should feed both the broadcast and the fan-out. ⑤
Dual-mode stdio server; legacy client initializes; 2026 client listens; `server.notify(...)` from
outside a handler → listener receives nothing. ⑥ None. ⑦ Delivery correctness. ⑧ Follow-up.

### AUD-08 — Parameterized Accept ranges never match (ecosystem-divergent strictness)

① **MED for third-party clients / LOW in-ecosystem.** `MediaRange.matches` requires the range's
parameters to be a subset of the expected (empty) set (`HTTPRequestValidation.swift:70-78,306-317`)
→ `Accept: application/json;charset=utf-8, text/event-stream` ⇒ 406. All five official SDK
clients send bare Accept headers (unaffected); TS/Go/Python servers accept the parameterized form
(TS by substring accident — open typescript-sdk#2480; Go/Python strip parameters), so heterogeneous
clients that work elsewhere hard-fail here. The ecosystem splits 3–2 on `*/*` (Swift accepts it).
② RFC 9110 §12.5.1 permits the strict reading; MCP spec only requires clients to list both types;
interop table verified at the pinned SDK SHAs. ③ Introduced (unit 06, deliberate, test-pinned).
④ Unit 06; either ignore non-`q` parameters (matching Go/Python) or keep strictness and fold the
question into the already-planned spec clarification (with `*/*`/q-values). ⑤ POST with
`charset` in Accept → 406 here, 200 on Go/TS/Python. ⑥ Third-party interop only. ⑦ None
(over-strict, no smuggling surface). ⑧ Follow-up.

### AUD-09 — Blanket JSON-RPC-code→HTTP-status mapping catches handler-level errors

① **MED (lower edge).** `httpStatusCode(forJSONRPCResponse:)` maps any response error `-32601`⇒404
and `-32602`⇒400 (`StreamableHTTPServerTransport.swift:365,384-405`) with no origin
discrimination; transport-level cases are already rejected pre-dispatch, so the `-32602`s that
reach `routeResponse` are almost exclusively handler-level (unknown tool/resource — the
conformance suite's own sep-2164 expects `-32602`), surfacing as HTTP 400 on valid POSTs. Sits
inside the spec's era-detection ambiguity for clients that key on status. ② The spec scopes 404 to
"does not implement the requested RPC method" (`streamable-http.mdx:271-273`) and enumerates 400
for the three modern validation errors (`:655-658`); no sentence prescribes 400 for a generic
application `-32602`. Mitigations: the full JSON-RPC body is preserved; era fallback applies only
to a first probe. The local conformance suite parses bodies regardless of status, so this passes
conformance today. ③ Introduced (unit 06, `fe9120e`). ④ Unit 06; tag validation-origin errors and
map only those (plus mandated codes) to non-200. ⑤ `tools/call` with a wrong tool name → observe
HTTP 400 + `-32602`. ⑥ Status-sensitive third-party clients surface transport errors instead of
JSON-RPC errors. ⑦ None. ⑧ Follow-up.

### AUD-10 — Discovery fallback breadth exceeds the spec letter (deliberate, ecosystem-aligned)

① **MED (deviation to document, not a code fix).** A correlated non-modern JSON-RPC error to the
`server/discover` probe under HTTP **200** is accepted as legacy evidence
(`Client.swift:1957`; the uncorrelated set is properly limited to 400/404/405 at
`HTTPClientTransport.swift:924`), and `-32601` is excluded from the recognized-modern set
(`:1934-1943`) — the spec's HTTP text sanctions body inspection "on 400" and lists method-not-found
among modern-error signals. ② `streamable-http.mdx:655-665,727-733`. **Interop verification: all
five official SDKs behave the same way** (TS test literally titled "…including 200-bodied errors";
Go test serves method-not-found with `http.StatusOK` expecting fallback; Python denylist; C# broad
protocol-exception catch — whose comment cites spec PR #2844; Rust legacy arm) — the deviation
matches ecosystem consensus against the spec letter, exactly the situation the prior
interoperability review's unfiled spec-clarification PR addresses. ③ Introduced deliberately
(units 03/05), test-pinned (`PerRequestHTTPClientTransportTests:1472,1567`). ④ Units 03/05 (docs)
+ the specification repo: file the prepared clarification PR before or alongside submission;
document the deviation in the PR bodies. ⑤ n/a (behavioral choice). ⑥ Helps real legacy servers
behind 200-returning frameworks; harms only misbehaving modern servers. ⑦ Negotiation-quality
only; the origin cache is per-connection-evicted on failed initialize. ⑧ Follow-up (file the spec
PR; add PR-body disclosure).

### AUD-11 — 2-second stdio probe timeout silently downgrades slow modern servers

① **MED.** Default `discoveryProbeTimeout` = 2 s (`Client.swift:199`); timeout →
`internalError` (`:1910-1916`) → classified initialization-based on non-HTTP transports
(`:1969-1975`) with **no log**; a dual-era server then accepts the fallback `initialize` and the
session silently runs 2025-11-25. Not sticky (the HTTP lifecycle cache doesn't apply to stdio;
re-probed per connection) — hypothesis of cache poisoning refuted. ② Spec sanctions
timeout-as-legacy in kind (`stdio.mdx` backward-compat bullet 3; `versioning.mdx` "or times out")
without prescribing a number; `npx`/container cold starts routinely exceed 2 s. ③ Introduced
(unit 03). ④ Unit 03; log a warning on timeout-driven fallback; reconsider the default (or start
the clock at first stdout byte). `0` disables. ⑤ MockTransport answering discover after 2.5 s;
assert lifecycle + a logged warning. ⑥ Config knob exists; no API change. ⑦ None. ⑧ Follow-up.

### AUD-12 — Version advertise/accept asymmetry on transport-restricted servers

① **MED.** `makeHandlerContext` accepts any version in `Version.perRequestMetadataSupported`
(`Server.swift:1395`) without intersecting `transportSupportedProtocolVersions`, while
`server/discover` results and `-32022` data are intersected (`:1441-1446,1612,1400`) — a server
whose transport disclaims 2026 still serves a 2026 request that reaches it. Reachable in-tree: the
pre-existing Stateful/Stateless transports advertise initialization-only sets yet perform no
body-metadata check, so a request with a valid legacy header but 2026 `_meta` passes. (The
package-only hook means third-party transports are consistent-by-default — the original
"custom Transport" leg was corrected in verification.) ② `versioning.mdx` (server MUST reject
versions it does not support; the advertised set is what clients are told to trust). ③ Introduced
(unit 03). ④ Unit 03; compute the effective per-request set once and use it for both the guard
and the advertisement. ⑤ Dual server on a Stateless transport; POST with legacy header + 2026
`_meta` → served instead of `-32022` naming legacy-only. ⑥ None. ⑦ Consistency between
advertisement and behavior. ⑧ Follow-up.

### AUD-13 — `x-mcp-header` planner over-invalidates tools with untyped nested `properties`

① **MED.** The plan builder requires explicit `"type":"object"` to descend (`HTTPHeaders.swift:117-122`);
a tool schema containing any `properties` subtree without it — **including a completely
unannotated sibling** — throws, and the whole tool is silently dropped from the client's validated
set (`HTTPClientTransport.swift:515-541`, warning logged) while server-side `updateTools` throws
wholesale (`StreamableHTTPServerTransport.swift:142-148`), leaving prior plans active. ② The spec
requires `type: "object"` only at the schema root (`schema.json:3641` — the root-leg hypothesis
was refuted; the code is spec-correct there); nested reachability is defined as "a chain
consisting solely of `properties` keys" (`streamable-http.mdx:388-395`) with no intermediate type
requirement; JSON Schema does not require `type` beside `properties`. ③ Introduced (unit 08,
deliberate, test-pinned `HTTPHeaderMetadataTests:99`). ④ Unit 08; descend on `properties`
presence, validate `type` only on annotated leaves; separately document `updateTools`'
throw-leaves-old-plans semantics and the unwired-`updateTools` hazard (empty plans silently skip
the server's MUST-validation). ⑤ Tool with `{"config":{"properties":{...}}}` (no type) + one
valid annotation elsewhere → tool vanishes from `tools/list` client-side. ⑥ Spec-valid tools
disappear silently. ⑦ None. ⑧ Follow-up.

### AUD-14 — Schema-refresh recovery is blocked in the fixable case and triggered by message-sniffing

① **MED-LOW.** `refreshToolHeadersIfNeeded`: (a) `guard !refreshedPlan.fields.isEmpty`
(`Client.swift:1471`) refuses the retry exactly when the tool *removed* its annotations — the
headerless retry that would succeed; (b) the trigger requires
`errorDescription.lowercased().contains("mcp-param-")` (`:1440`) — third-party `-32020` phrasings
never fire it. ② `HeaderMismatchError` has no structured data (`schema.mdx:294-299`), so message
matching is partly a spec limitation; the `refreshedPlan != previousPlan` guard (`:1472`) already
prevents futile loops, so the substring filter only loses recoveries. ③ Introduced (unit 08). ④
Unit 08; drop the substring filter for `tools/call` `-32020`s and allow the empty-plan retry. ⑤
Server drops a tool's annotations; client keeps sending stale headers and surfaces `-32020` without
refreshing. ⑥ Interop recovery quality. ⑦ None. ⑧ Follow-up (+ candidate spec issue: structured
data for HeaderMismatch).

### AUD-15 — Migration guide's `experimental` remedy contradicts the SDK's own validation

① **MED (doc).** `MIGRATION.md` A.7 (`:643-645`) tells users to migrate with
`mapValues(Value.string)`, but capability encoding enforces object values
(`Client.swift:471-480` → `Protocol20260728.swift:76-78`) — following the guide verbatim moves a
compile error to a runtime `EncodingError` at connect. The guide's own next bullet states the
object rule. ② schema.ts `{ [key: string]: JSONObject }` (both eras). ③ Introduced (unit 12
docs; the enforcement itself is unit 01's spec-faithful strictness). ④ Unit 12; correct the
bullet (e.g. `mapValues { .object(["value": .string($0)]) }`) and note the decode-side strictness
as an interop consequence for older peers. ⑤ Follow A.7 verbatim; connect throws. ⑥ Doc-driven
runtime failure. ⑦ None. ⑧ Must-fix text before submission (ships in PR 12).

### AUD-16 — Undocumented source break: `HTTPResponse.dataWithStatus`

① **MED (doc/API).** The public non-frozen enum `HTTPResponse` (existing at baseline with five
cases) gains `dataWithStatus` (`HTTPServerTypes.swift:95`) — its own doc comment tells HTTP
framework adapters to switch on it, and exhaustive adapter switches stop compiling on upgrade.
`IMPLEMENTATION.md:420` mislabels the case "additive"; migration A.7 omits it (as it omits the
`MCPError.remote` exhaustive-switch break and the `.serverError`→`.remote` reroute for data-bearing
unknown codes, and the three new `OAuthAuthorizationError` cases). ② Swift source-compat rules;
baseline verified at `a0ae212`. ③ Introduced (unit 06 code; aggregate docs). ④ Unit 12/A.7 +
PR-06 body: add bullets; recommend property-based bridging (`statusCode`/`headers`/`body`) as the
forward-compatible adapter pattern. ⑤ Any exhaustive third-party switch fails to compile. ⑥ The
break itself is small and legitimate; the omission is the defect. ⑦ None. ⑧ Must-fix text before
submission.

### Lower-severity findings (all verified; follow-ups unless noted)

| ID | Sev | Owning | Finding (→ smallest fix) |
| --- | --- | --- | --- |
| AUD-17 | LOW-MED | 03 | No negotiation-in-flight guard: concurrent `send` during `connectWithInfo` emits modern `_meta` to an unconfirmed server (→ `negotiating` state check) |
| AUD-18 | LOW-MED | 03→01/04/06 | Mid-stack cross-unit corrections to restack: `Discover` decode default (03→01); unrecognized-`resultType` MUST check (04's `e0ce4b1`→03; tip 03 briefly non-conformant); `Version.supported` widening vs HTTP validators (03..05 window, restored by 06); lifecycle-method gating landed in 09 though it is 03-scope policy |
| AUD-19 | LOW-MED | 01/06 | Double JSON re-encode number fidelity: integers in (Int64.max, UInt64.max] silently become Double on the wire; `-0.0`→`0` (pre-existing `Value` semantics composed by new plumbing → document or add Int64-overflow preservation) |
| AUD-20 | LOW-MED | 09×01 | stdio re-listen rejection with `-32000`/`-32001` decodes to transport conditions ⇒ silent dormancy instead of surfaced failure (→ exclude wire-decoded remote errors from disconnection classification); HTTP leg masked by transport guards (which also discard genuine rejection codes — fidelity note) |
| AUD-21 | LOW | 05 | 401/403 handled before correlated body parse ⇒ `-32020` refresh dead for non-conformant 403-mapping servers |
| AUD-22 | LOW | 05 | SSE parser dispatches an unterminated final event at EOF (WHATWG says drop) and throws on invalid UTF-8 (vs U+FFFD); `pendingRequestCancellations` persist to disconnect |
| AUD-23 | LOW | 05 | Drive-by re-order of pre-stack legacy auth retry semantics inside unit 05 (aligns legacy with new path; tested) → disclose in PR-05 body or split |
| AUD-24 | LOW | 06 | Origin: portless `Origin: http://localhost` rejected; `.localhost()` excludes https; rebinding rests on adapter-supplied Host (adapter passes it through; HTTP/1.1 guarantees it) → doc + relax localhost matching |
| AUD-25 | LOW | 06 | `httpRequestContext` original-ID fallback is dead in-tree but a latent public-API misattribution hazard under ID collision → drop or document routing-ID-only |
| AUD-26 | LOW-MED | 06 (pattern pre-exists) | Notification POSTs are 202'd then buffered unboundedly ahead of the serial loop (requests self-limit via suspended continuations) → bounded buffering |
| AUD-27 | LOW | 04 | `.manual` MRTR mode is unbounded (PR body says "enforce round limits" unqualified; handler's `round` argument is the escape hatch) → document or optional cap; requestState trust model absent from API doc comments (guide-only) |
| AUD-28 | LOW | 04/10/12 | Constructed-vs-decoded config divergence: `multiRoundTripMode`/`responseCacheMode` decode-absent to `.disabled` vs memberwise `.automatic(8)`/`.enabled(512)` — deliberate and test-pinned, but Server is self-consistent while Client is not, and no user-facing doc states it → document (or align; author's call) |
| AUD-29 | LOW | 08 | `=?base64?=` overlapping sentinel decodes to `""` instead of rejecting (no smuggling; still body-compared); deep `containsAnnotation` scan conflates schema/instance positions and recurses unbounded |
| AUD-30 | LOW | 09 | Typed re-decode of `SubscriptionsListen.Result` throws on absent `resultType` (generic layer defaults correctly; schema says treat as complete) — third-party graceful closures only |
| AUD-31 | LOW | 09 | Duplicate in-flight listen ID on stdio overwrites the subscription; displaced handler task leaks → reject duplicates |
| AUD-32 | LOW | 10 | Pagination same-scope check defeated by mid-pagination auth rotation (signal lost; no cross-context leak); `_meta {}` key residue (miss-only) |
| AUD-33 | LOW | 07/06 | Modern-only HTTP endpoints answer `initialize` without naming supported versions (spec SHOULD; the compliant Server message is dead code on the HTTP path); router re-parses bodies multiple times on an actor (stateless — could be nonisolated) and duplicates the 3-key metadata rule |
| AUD-34 | LOW | 02 | Legacy-token issuer fallback strips query/fragment (pre-existing comparator, now legacy-shape-only, one-generation exposure) → exact match; dead refresh token retried during the 60 s proactive window after 4xx; `cachedProtectedResourceMetadataURL` now write-only |
| AUD-35 | LOW | 11 | Fixture `--port` silently ignores malformed values; CI job 10-min budget headroom; adapter comma-collapses same-case duplicate headers (proxy-equivalent); fixture relies on default SIGTERM (`closeSubscriptionsGracefully` unreachable) — fixture-only |
| AUD-36 | INFO | 05/10 | Sticky `usesUntrackedAuthorization` permanently disables private-cache reads after any `requestModifier` Authorization touch — and the transport's own docc example uses `requestModifier` → document or reset on disconnect |
| AUD-37 | INFO | CC-1 | Cache partitions key on raw `"Bearer …"` strings in memory (never logged/persisted; list-scope keys have no TTL) → optional hardening: SHA-256 digest partition keys |
| AUD-38 | INFO | CC-3 | New public symbols lack `SeeAlso` dated-spec links; `StreamableHTTPServerTransport` is the least self-distinguishing of the three transport names; hook set should not fossilize as a hidden second protocol if external transports become a goal |

## 6. Re-verification of the restack corrections (all verified in code)

| Correction (owning unit) | Verdict |
| --- | --- |
| 01 ASCII extension identifiers | ✅ scalar-range enforcement + Unicode negative tests; grammar matches spec letter (empty-name/single-label edge cases are spec-permitted; hypothesis refuted) |
| 02 refresh-token issuer binding | ✅ binding checked after discovery, before transmit; stale token cleared *before* discovery so a failure can never leave it resendable; cross-issuer test pins it |
| 03/05 fallback classification | ✅ correlated non-modern errors (incl. under HTTP 200) select initialization; auth/transient/cancellation stay inconclusive; recognized modern errors never fall back — see AUD finding on the deliberate HTTP-200 breadth vs spec letter |
| 03 same-version advertised retry | ✅ one retry, fresh JSON-RPC id, same-version permitted, second rejection surfaced; ecosystem precedent verified at the pinned Python test and merged Go PR #989 |
| 03/05 origin-keyed lifecycle reuse | ✅ canonical origin only; stored value is the lifecycle enum only; failed cached-initialize evicts; HTTP-only by construction |
| 05 `enableStandaloneGetStream` | ✅ deprecated `streaming:` forwarder without default argument; GET stream gated to legacy lifecycle; modern selection clears session/GET state and never restarts it |
| 06 RFC 9110 media parser | ✅ q-values incl. `q=0`, wildcard precedence, case-insensitivity, OWS — with two strictness findings (empty list elements; parameterized ranges) recorded below |
| 11 custom-header schema from `tools/list` | ✅ the same `conformanceHeaderValidationTool` constant is the `ListTools` entry *and* the `updateTools` argument; adapter test proves enforcement |
| 09/11 list-change diagnostics | ✅ handler-only hidden tools (absent from `ListTools`, exactly what the scenario dispatches); `await server.notify(...)` through the real fan-out; no detached tasks; fresh matrix runs prove the three checks pass |

## 7. Deliberate deferrals — scope confirmation

Every deferral in the handoff was re-verified as accurately scoped; none is silently hiding a
regression: unscored backlog (Tasks, DPoP/nonce, enterprise auth, WIF, JSON-Schema preservation)
remains visible in artifacts and was never baselined away (`conformance-baseline.yml` is `client: []`
and is suppressed under `--requirements` anyway); `Server.notify` accepted-for-delivery wording is
accurate in code and docs; the successful alternate-version retry case remains untestable with a
single per-request revision (obligation recorded for the next revision's unit); the pre-existing
`StatelessHTTPServerTransport` collision/hang risks (#254/#255/#265) were **not** absorbed —
verified against the competing upstream PRs' scope (#264 vs #267, #260 vs #268); `NetworkTransport`
warning untouched; issue #222 correctly described as partial everywhere it is mentioned.

## 8. Pre-existing behavior observed (not caused by this stack; classify as separate upstream work)

Confirmed pre-existing at `a0ae212` and deliberately untouched, surfaced here because the audit's
composition passes swept the whole tree. Recommend filing as upstream issues independent of the
12-PR series:

1. **stdio EOF busy-spin + stranded requests** (HIGH): a finished receive stream makes the client
   loop spin at 100% CPU re-calling `receive()` on the same finished stream, and in-flight requests
   hang forever (`Client.swift:655-697`; `StdioTransport.swift:147-149`). Server-process death is
   the common stdio failure mode. (Also means subscription `.disconnected` events never fire on
   transport-level death.)
2. **`Server.stop()` never cancels in-flight handler tasks** (`Server.swift:477-499` vs `:323`).
3. **Server→client request wait is not cancellation-aware** — a cancelled handler blocked on
   sampling/elicitation/roots stays pinned until the client answers or `stop()`
   (`Server.swift:719-753`; the client side got deterministic-cancel treatment in this stack, the
   server side did not).
4. **Single-consumer `receive()` semantics unguarded/undocumented** across HTTP/stdio/InMemory
   transports + no double-connect guard in `Client.connectWithInfo` (recommended: document +
   active-consumer flag + connect guard).
5. **`InMemoryTokenStorage` is `@unchecked Sendable` with unsynchronized state**
   (`TokenStorage.swift:21-37`) — a race if one storage is shared across transports.
6. Legacy transports log session IDs / SSE event IDs at debug (known deferral, confirmed);
   `Client.swift:677-684` logs full payloads of *undecodable* inbound messages at warning
   (baseline verbatim).
7. Stale-session 400-vs-404 (`SessionValidator`, upstream #223 territory), absent-version-header
   fallback `2025-11-25` vs spec-SHOULD `2025-03-26` (mitigated by session-preferred lookup), and
   `WWW-Authenticate` quoted-pair unescaping (`\\` not unescaped) — all verbatim at baseline.
8. `swift-docc-plugin` pinned by `branch: "main"` — pre-existing upstream practice (`e3bf9aa`/
   `6132fd4`); per the owner's guidance, follow upstream general practice; at most an optional
   supply-chain note upstream.

## 9. Documentation accuracy

Spec-link discipline is clean (zero `/draft/` links anywhere; every dated link resolves at the tag,
including the unusual-looking `docs/2026-07-28/learn/versioning`). README.md is accurate: the
lifecycle section leads with the initialization-preserving default, every 2026 feature sits under
explicit opt-in, and all advertised API spellings exist. MIGRATION.md's ~25 verified examples
compile against the real API and its three security warnings are present. The audit handoff itself
is internally consistent (all SHAs/inventories verified; one note was overtaken by time — the
runner cache has now fetched `9e44edf`, courtesy of this audit's own runs).

Corrections needed (beyond AUD-02/15/16 above), all LOW:

1. `IMPLEMENTATION.md:119` — unit-01 row claims "…and this document"; no `Documentation/` file
   exists on branches 01–11 (the only hard wrong-location claim; `:129`'s unit-11
   platform-verification attribution is a softer instance). Reword to "aggregate-only review
   material".
2. PR-01 body `:7,:30` — points reviewers at a provenance record "alongside the tests" that its
   delta does not contain (the record is aggregate-only; the body's own tag+SHA pin at `:28-29`
   keeps verification possible). Point at the pin, or add a provenance note to unit 01.
3. `MIGRATION.md:687` — links `MCP-2026-07-28-IMPLEMENTATION.md`, broken in every upstream PR and
   in the shipped package (unit 12 carries only MIGRATION.md). Drop or inline.
4. `CONFORMANCE-FINDINGS.md:13` — presents pre-restack `30afa8d` as the "corrected review-stack
   tip" (actual `6f21292`; contradicts v2's table). The one genuinely stale SHA in the committed
   docs — every other historical SHA is correctly labeled. (`CODE-DESIGN-REVIEW.md`'s
   46/112/+21,573/−531 figure is byte-exact for its recorded moment — correctly historical; the
   final 44/114/+22,905/−534 appears only in the handoff.)
5. Stack `README.md:70-71` — the correction-unit list (01, 02, 03, 05, 06, 11) omits unit 09's
   conformance-round test correction. Extend or re-scope the sentence.
6. PR-06 body `:20` — "stateful transport remains unchanged" vs an actual 57-line delta (new
   public `originValidator:` overload + version-hook conformance) plus the version-set narrowing
   behavior change (2024-11-05/2026-07-28 headers now rejected on legacy transports —
   spec-defensible and tested, but observable). Disclose both.
7. Working tree: `SWIFT-CONFORMANCE-PLAN.md:32` carries stale morning-restack tips
   (`e697612`/`72e475f` → `26f9657`/`6f21292`); `CONFORMANCE-FIX-HANDOFF.md`'s "add the two tools
   to ListTools" step is superseded by the shipped hidden-handler mechanism (v2 findings pin it) —
   add a one-line supersession note.
8. PR-09 body under-discloses the lifecycle-method gates and the roots-capability wire
   normalization (both spec-correct and disclosed in IMPLEMENTATION.md, invisible upstream);
   PR-11 body doesn't name its ci.yml delta; PR-05 body omits the 3-line conformance-client rename
   hunk. Unverified-this-audit recorded claims (Linux 638 tests, Swift 6.0-image builds,
   static-Linux links) are all labeled as recorded history — reproduce before release if the
   source changes.

## 10. Conformance-repo integration findings (local branch `codex/swift-sdk-conformance-integration`)

Registration commit `b127936`: **sound and upstream-shaped** — entry fields verified against
`Package.swift` products; port 3000 consistent with all other entries; `127.0.0.1` (vs `localhost`)
is *justified* because the fixture binds IPv4-only (`main.swift:846`) — add a one-line comment so
upstream reviewers don't "normalize" it; `qualifyRepoName` extraction and the tier-check owner fix
are org-neutral and independently upstreamable; tests pin every field. Upstream path: treat as local
staging for conformance PR #432 (coordinate with @shoemoney; do not compete), then drop
`repo`/`defaultRef` + update the enumerated tests/README lines.

Matrix runner commit `0f2796f`: well-designed (sequential cells, result-file-driven verdicts,
atomic report writes, per-cell provenance, exit-code distrust) with the findings below.

> **Fixed 2026-08-15** in `04c8dc0` on `codex/swift-sdk-conformance-integration`: AUD-C1 and
> AUD-C2 are both closed, and the Swift entry carries the 127.0.0.1 rationale comment. Reuse and
> commit attribution now require a checkout the cell actually materialized, so a failed checkout
> neither poisons a later cell nor contributes a misleading commit — verified by running the
> matrix against a nonexistent ref: both cells fail honestly, neither receives `--path`, and the
> reported commit is `null` rather than the default branch's HEAD. The invalid
> `regression-swift-2025` report and the broken `290b39d` cache directory were deleted. The
> conformance suite passes (537 tests, including a new redaction case).

- **AUD-C1 (HIGH; blocker for upstreaming this commit, audit runs unaffected)**:
  `seenCheckout.add` runs unconditionally after every cell (`src/sdk-matrix.ts:834`), so after a
  failed checkout the next same-ref cell gets `--path` (which bypasses `ensureCheckout` entirely,
  `src/sdk-runner/index.ts:248-256`) and runs **whatever the directory contains** under the
  requested label. Proven on disk: `.sdk-under-test/coopsource__swift-sdk/290b39d` is a failed
  checkout parked on `main` (`290b39d` does not exist in the fork), and
  `results/sdk-matrix/regression-swift-2025/` attributes `main`@`a0ae212` server results to
  `swift-sdk@290b39d` — **that regression report's 290b39d rows are invalid evidence**. Blast
  radius includes transient fetch failures with a warm cache (silently certifies a stale checkout
  under the current label; undetectable for branch refs). Minimal fix: gate the add on cell success;
  recommended: hoist `ensureCheckout` into the matrix loop, always pass `--path`, fail the cell as
  infrastructure on checkout errors. This audit's acceptance runs were verified unaffected
  (first cells fetched fresh; uniform clean commits).
- **AUD-C2 (MED, security/privacy)**: wrapper redaction gaps — JSON key `authorization` not in
  `SENSITIVE_JSON_KEYS`; form-encoded token-endpoint bodies (`client_secret=…&refresh_token=…`),
  tokens in URLs, cookies, bare JWTs, and the `code` key all pass through; the 128 KiB flush
  comment claims an overlap the code does not implement. Raw per-scenario `checks.json` bypass the
  sink entirely (documented; keep treating full run directories as unpublishable without
  inspection).
- Confirmed by-design (documented, not defects): requirements runs exit 0 on scored SHOULD
  warnings (evidence must be read from reports); `--skip-build` can pair a fresh checkout with
  stale binaries (README-warned; recommend refusing when HEAD moved); failed builds are retried,
  not silently skipped; report writes are atomic.
- Swift-side scripts: 2026 runner pin/readiness/traps verified good; 2025 script nits
  (`sleep 3` readiness, no trap, unquoted `$BASELINE_ARG`, `--suite all` vs CI `core` divergence).
- **Seed findings resolved as non-bugs**: the CI "port mismatch" does not exist (fixture default
  port is 3001; ci.yml's no-arg launch + `localhost:3001` target are coherent; the KNOWN_SDKS 3000
  override is self-consistent; `HTTPApp`'s 3000 default is dead code in the binary). CI
  `main`-only triggers are a real but documented gap (stack README mandates retarget-then-CI;
  optional hardening: add `mcp-2026-*`/`submission/**` to `pull_request.branches`).

## 11. Interop citation spot-check (all pins resolve; local checkouts untouched)

| Claim | Verdict | Key evidence |
| --- | --- | --- |
| All five SDKs treat a correlated non-modern error to the discover probe as legacy evidence, incl. under HTTP 200 | **VERIFIED (5/5)** | TS `probeClassifier.ts:211-244` + test titled "…including 200-bodied errors"; Python `_probe.py:71-81` denylist; Go test serves `CodeMethodNotFound` with `http.StatusOK` expecting fallback; C# broad `McpProtocolException` catch (the "C# only falls back on 400" downstream claim is contradicted by code, as the prior review said); Rust `client.rs:1012-1022` |
| Bounded same-version advertised retry precedent | **VERIFIED** | Python test @ `52ad0a8:181-218` asserts identical-version retry exactly once; Go PR #989 (merged, `d9714c6`) has no inequality guard (structural); Rust `may_retry_current` corroborates |
| Accept-header handling across SDK servers | **VERIFIED** (review's table accurate) | TS raw substring (accepts parameterized by accident — open issue #2480; `*/*` ⇒ 406); Go/Python strip parameters + wildcards, no q; C# framework-typed; Rust raw contains. Ecosystem splits 3–2 on `*/*` |
| Compatibility-defaults precedent (TS v2 + Rust conservative; Go/C#/Python automatic) | **VERIFIED** | TS `DEFAULT_VERSION_NEGOTIATION_MODE = 'legacy'`; Rust `serve` hardcodes Initialize; Go/C#/Python default to probe-with-fallback |

Divergence finding recorded (unit 06 follow-up): the Swift server 406s
`Accept: application/json;charset=utf-8` where TS/Go/Python accept it — RFC-defensible strictness,
but ecosystem-divergent; supports the already-planned spec clarification rather than copying any
one SDK. In-ecosystem SDK-to-SDK traffic is unaffected (all five clients send bare Accept headers).

## 12. Refuted and downgraded candidates (appendix)

Recorded so the same hypotheses are not re-litigated:

- **Cache-field validation breaks pre-2026 servers** — REFUTED by orchestrator probe + executed
  evidence: `responseCachePolicy` lives inside `performLogicalRequest`, entered only on the
  per-request lifecycle branch (`Client.swift:~1081`); legacy connections never validate cache
  fields (hence 750/750 tests and 223 clean legacy conformance checks). Strictness applies only
  where the spec makes the fields a server MUST.
- **Era-cache poisoning by probe timeout** — REFUTED: the lifecycle cache is HTTP-only and the
  HTTP probe arm has no timeout; timeout downgrades are per-connection (AUD-11 is the residual).
- **`-32000`/`-32001` decode-as-transport ⇒ wrongful stdio fallback** — REFUTED as a defect:
  correlated non-modern and local failures classify identically and both spec-resolve to legacy on
  stdio; the residual is error-fidelity (AUD-20 note) and the decode arms are baseline-verbatim.
- **Router body-metadata precedence misroutes 2025 clients** — DOWNGRADED to accepted-by-design:
  triggers are exactly the three lifecycle keys (never progressToken/trace/vendor keys); the
  alternative protocolVersion-only trigger would violate the spec's missing-field rejection rule;
  consequence is a correct per-request `-32602` with no session damage.
- **Extension-identifier grammar too lax** (empty name, single-label prefix) — REFUTED: the spec's
  letter permits both; the mandatory-prefix rule is enforced.
- **Codable round-trip loses configuration** — REFUTED: custom `encode(to:)` preserves values;
  only absent-key decode diverges (AUD-28).
- **`type:"object"` required at schema root is over-strict** — REFUTED: `schema.json:3641`
  requires exactly that at the root (the nested leg is AUD-13).
- **WWW-Authenticate parser fragile** — REFUTED at severity: multi-challenge, quoted commas,
  escapes, token68, duplicates, coalesced headers all handled; sole cosmetic gap is `\\`
  unescaping (pre-existing), and unconditional well-known fallbacks make a stall impossible.
- **`issuerParameterRequired` under-enforced** — REFUTED: sourced from validated AS metadata; the
  hardcoded-false paths are deprecated source-compat overloads the SDK flow never calls.
- **Token storage cross-issuer bleed** — REFUTED within the documented one-authorizer contract;
  exact issuer binding blocks the bleed (the unsynchronized-storage race is a pre-existing note,
  section 8).
- **Early-cancel consequence on the legacy path / wrong-task `Task.isCancelled`** — mechanics
  confirmed but the headline consequence refuted: `cancelRequest` resumes with `CancellationError`
  before teardown, deterministically (AUD-01 is the per-request-lifecycle window, which is real).
- **202-strictness (204 ⇒ error)** — refuted as a defect: the spec's MUST-202 makes 204 server
  non-conformance; fixtures agree.
- **Hidden diagnostics leak into 2025 lists** — refuted: handler-only cases, absent from
  `ListTools`; frozen 2025 results byte-stable; fresh matrix confirms.
- **CI port mismatch (3000 vs 3001)** — resolved as no bug: the fixture defaults to 3001 and every
  consumer is self-consistent (the KNOWN_SDKS 3000 override included; `HTTPApp`'s 3000 default is
  dead code in the binary).
- **`swift-docc-plugin` branch pin** — pre-existing upstream practice; per the owner's direction,
  follow general practice (optional upstream note only).
- **CODE-DESIGN-REVIEW size figures stale** — downgraded: byte-exact for the recorded moment,
  correctly past-framed.

## 13. Submission-readiness disposition

**Gate A — COMPLETE (applied 2026-08-15; see §0).** The items below are recorded as originally
written; each was carried out and re-verified.

**Gate A as filed:**
1. Fix AUD-01 in unit 04 (+ the cancel-immediately-after-send regression test); restack 05–12 and
   re-verify with `git range-diff` per the stack's own discipline.
2. Restack the cross-unit hunks (AUD-18): resultType MUST check into 03; `Discover` decode default
   into 01; either move unit 07's initialize hunk into 06 or disclose it in PR-07's body; decide
   whether to scope the 03 version-widening with an initialization-scoped validator set in the
   same commit (removes the mid-stack window).
3. Rewrite PR-03's body (AUD-02); apply the PR-body disclosure list (05 legacy-auth reorder + rename
   hunk; 06 overloads + version narrowing + `dataWithStatus`; 09 gates + roots normalization; 11
   ci.yml; 12 A.7 additions incl. `MCPError.remote`/`OAuthAuthorizationError` breaks and the
   corrected `experimental` remedy — AUD-15/16); fix the broken MIGRATION link and the doc items in
   section 9.
4. Strongly recommended in the same pass (small, spec-grounded): AUD-03 (empty Accept elements)
   and AUD-04 (invalidation hoist).

**Gate B — coordination items (per the handoff's own list):** reconcile swift-sdk PR #269 before
submitting unit 11 and PR #271 before unit 05; pick one of #264/#267 and one of #260/#268 upstream
(never both); coordinate the conformance registration through PR #432 (@shoemoney) using the local
branch as staging; fix AUD-C1 before upstreaming the matrix-runner commit; file the two prepared
spec-clarification PRs (discovery fallback under success statuses — now with five-SDK evidence —
and Accept `*/*`/q-value semantics, extended with the parameterized-range question).

**Gate C — before release (not per-PR blockers):** the remaining MED follow-ups (AUD-05..14, 17,
19, 20, 26, 28); rerun the Linux + minimum-toolchain matrix (recorded figures were not re-executed
here); the pre-existing upstream issues in section 8 as separate filings; consider the CC-1 digest
hardening and the architecture extraction (Client.swift's five policy machines) before the next
protocol revision lands.

**Evidence status:** the handoff's final acceptance matrix requirement was **met** for the audited
code (section 4; fresh runs at `26f9657` and `9e44edf`, zero scored findings, provenance verified
per cell). The stale `results/sdk-matrix/latest.md` (from `584f8ff`) and the invalid
`regression-swift-2025/` 290b39d rows are superseded by `results/sdk-matrix-audit/`. The
remediated code was re-verified through the same frozen requirement sets against this working tree
(§0.3, `results/audit-postfix/`); re-running the fork-cloning matrix requires pushing the rewritten
branches, which is the owner's call.

---

*Audit artifacts: findings queue and dynamic logs in the session scratchpad; matrix reports under
`../conformance/results/sdk-matrix-audit/`; revert checkpoints (17 `audit-20260815/*` tags +
working-tree backups + MANIFEST) at `../audit-checkpoints-2026-08-15/`. Per-scenario conformance
artifacts are unredacted — inspect before sharing any result directory. This report is untracked
and not committed, per the working-tree preservation rules.*
