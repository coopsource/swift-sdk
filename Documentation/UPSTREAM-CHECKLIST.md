# Upstream checklist — the one place to look (2026-08-15)

When you have time for upstream work, start here. Everything is staged in the **coopsource org**;
nothing needs re-deriving. Verified 2026-08-15: the 12-unit stack is linear (01 → 12), every unit
is based on upstream `main` (`a0ae212`), local == `coopsource/swift-sdk` on every branch, and the
aggregate's `Sources/`, `Tests/`, and manifests are byte-identical to unit 12's (the aggregate
adds documentation and scripts only).

## 1. The 12 swift-sdk PRs — ready to file, one per spec area

| Unit | Branch on `coopsource/swift-sdk` | Spec area |
|---|---|---|
| 01 | `mcp-2026-wire-models` | 2026-07-28 wire models |
| 02 | `mcp-2026-oauth-issuer-validation` | OAuth issuer binding (RFC 9207) |
| 03 | `mcp-2026-discovery-negotiation` | `server/discover`, per-request protocol negotiation |
| 04 | `mcp-2026-multi-round-trip` | Multi-round-trip requests |
| 05 | `mcp-2026-http-client` | Per-request-metadata HTTP client |
| 06 | `mcp-2026-http-server` | Per-request-metadata HTTP server transports |
| 07 | `mcp-2026-http-lifecycle-routing` | `LifecycleHTTPServerRouter` |
| 08 | `mcp-2026-tool-headers` | Schema-derived `x-mcp-header` |
| 09 | `mcp-2026-subscriptions` | `subscriptions/listen` |
| 10 | `mcp-2026-response-caching` | `ttlMs` / `cacheScope` response caching |
| 11 | `mcp-2026-conformance` | Conformance coverage |
| 12 | `mcp-2026-defaults-release` | Release defaults |

- PR bodies: `Documentation/PullRequests/MCP-2026-07-28/01-…12-*.md` (on the aggregate branch).
- Tooling: `scripts/create-mcp-2026-pull-requests.sh` — **previews by default**, creates drafts
  only with `--submit`, non-draft with `--ready`. `scripts/push-mcp-2026-review-branches.sh`
  re-pushes the stack.
- The aggregate `swift-sdk-mcp-update-07-28-26` is the integration branch GraphApp pins
  (`b6cf7f9`); it is not itself a PR.

## 2. Conflicting upstream PRs — triage done, do not re-litigate

- `MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md` (aggregate branch) — which upstream PRs overlap which
  units, and the recommended posture for each.
- `UPSTREAM-COMMENTS-DRAFT.md` (this branch) — drafted comments awaiting your review; file as
  comments on the overlapping PRs when ready.
- Conformance registration coordinates through upstream **PR #432** (per the audit §0.5).

## 3. Still to file (fixes / issues / docs)

- `UPSTREAM-ISSUE-value-data-url-coercion.md` (this branch) — `Value` silently coerces strings
  that look like data URLs. Draft ready.
- Two prepared specification clarifications — see the triage document for both.
- GraphApp report #4 (docs contribution): the handler-emitted progress example for the migration
  guide — `graph` repo, `docs/research/swift-sdk-migration-guide-progress-contribution-20260813.md`
  (its §2 snippet is marked UNCOMPILED; compile before submitting).

## 4. Do NOT re-file — already fixed at `b6cf7f9`

GraphApp's three measured reports (`graph` repo,
`docs/research/mcp-swift-sdk-suggestions-index-20260813.md` has the full status block):

1. `.automatic` HTTP-200 fallback hazard — fixed in `classifyDiscoveryFailure`.
2. Silent streaming discard — fixed by `enableStandaloneGetStream` rename.
3. Accept-header case sensitivity — fixed by `HTTPMediaValueParser`.

**Caution before citing them in PR conversation:** provenance is unrecorded. The third-party audit
report cites none of them, yet all three are fixed in code — consistent with the reports having
been applied, but not proof. If an upstream reviewer asks "where did this fix come from", check
with the owner rather than asserting either origin.

## 5. Conformance repo — staged 2026-08-15

- Fork created: `coopsource/conformance` (fork of `modelcontextprotocol/conformance`).
- Branch pushed: `codex/swift-sdk-conformance-integration` @ `04c8dc0`, based on upstream `main`
  (`c321dd3` = `0.2.0-alpha.11`). Three commits: register the Swift SDK, add the SDK conformance
  matrix runner, fix matrix-cell attribution. This discharges the audit §0.5 note ("that branch
  still needs a fork or patch export").
- One coherent PR when filed; coordinate with upstream PR #432 (item 2 above).
- GraphApp side-note: its D112 "conformance harness out of alpha" prerequisite is discharged by an
  upstream **npm release** past `0.2.0-alpha.11`, not by anything in these repos.

## 6. Safety net

`~/projects/avp/swift-sdk-archive/20260815/` — full-ref bundles for both repos (restore-verified),
the pre-restack history, all `audit-20260815/*` tags, and byte-identical copies of the files that
were uncommitted that day. The only route back to pre-restack SHAs; nothing on any remote reaches
them.
