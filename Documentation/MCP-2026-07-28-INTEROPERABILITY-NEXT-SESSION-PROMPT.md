# Prompt used for the interoperability implementation session (historical)

This prompt records how the completed Phase 7 session began. Do not use it to resume the current
stack: its commit, worktree, and dependency-lockfile instructions describe the pre-restack state.
See `MCP-2026-07-28-FOLLOW-UP-PLAN.md` for the final disposition.

Copy the text below into a new Codex session whose workspace is
`/Users/alan/projects/github/modelcontextprotocol/swift-sdk`.

---

Continue the MCP 2026-07-28 interoperability work in the Swift SDK. The research and design review
are complete; implement Phase 7 fully, verify it, commit it in logically separable review units,
and push the completed aggregate branch to my `fork` remote. Never push to `origin`.

Start in `/Users/alan/projects/github/modelcontextprotocol/swift-sdk` on branch
`swift-sdk-mcp-update-07-28-26`. At handoff, HEAD was
`8e8f00854070c4cedf86e8702ce195d28e44c0f0`, tracking
`fork/swift-sdk-mcp-update-07-28-26`. First run `pwd`, `git status --short --branch`,
`git remote -v`, and `git log -5 --oneline`. Preserve all existing worktree changes. In particular,
the modified follow-up plan and untracked interoperability report/handoff/prompt are intentional.
`Package.resolved` was deliberately committed at `8e8f008`; leave it alone unless your own package
resolution changes it for a justified reason.

Read these documents completely before editing:

1. `/Users/alan/projects/github/modelcontextprotocol/swift-sdk/Documentation/MCP-2026-07-28-INTEROPERABILITY-HANDOFF.md`
2. `/Users/alan/projects/github/modelcontextprotocol/swift-sdk/Documentation/MCP-2026-07-28-INTEROPERABILITY-REVIEW.md`
3. `/Users/alan/projects/github/modelcontextprotocol/swift-sdk/Documentation/MCP-2026-07-28-FOLLOW-UP-PLAN.md`
4. `/Users/alan/projects/github/modelcontextprotocol/swift-sdk/Documentation/MCP-2026-07-28-IMPLEMENTATION.md`
5. `/Users/alan/projects/github/modelcontextprotocol/swift-sdk/Documentation/MCP-2026-07-28-MIGRATION.md`
6. `/Users/alan/projects/github/modelcontextprotocol/swift-sdk/Documentation/PullRequests/MCP-2026-07-28/README.md` and review-unit notes 03, 05, 06, 11, and 12
7. `/Users/alan/projects/avp/graph/docs/research/mcp-swift-sdk-suggestions-index-20260813.md`

Treat the local dated specification at
`/Users/alan/projects/github/modelcontextprotocol/modelcontextprotocol` revision
`b25c0874bf0ba699a58e21ef06f659d839659de3` as authoritative, followed by the HTTP RFCs, the
official conformance runner, and official SDKs. The review document records exact pinned revisions
for TypeScript, Python, Go, C#, Rust, and conformance. Do not redo that survey unless an unresolved
implementation question actually requires it.

Implement these settled changes:

1. Fix automatic `server/discover` fallback. A valid, correlated JSON-RPC error to the mandatory
   discovery probe that is not recognized modern evidence must classify as initialization-era
   evidence even when carried by HTTP 200, as well as supported compatibility statuses such as
   400/404/405. `.perRequestMetadataOnly` must not fall back. Preserve no-fallback behavior for
   recognized modern errors, auth failures, 408/429/5xx, network failures, and cancellation. Treat
   malformed JSON and mismatched or uncorrelated bodies on 400/404/405 as legacy evidence. Preserve
   the existing bare-405 fallback and the
   unsupported-version retry. Centralize this as a discovery-outcome decision, not a status-only
   collection of special cases. Include an end-to-end initialization-era control after fallback.

2. Rename the canonical HTTP-client option from `streaming` to
   `enableStandaloneGetStream`, expose it as a public read-only property, and keep the already
   shipped explicit `streaming: Bool` initializer as a deprecated forwarding overload without a
   default. Update internal call sites. Test initialization mode, automatic fallback, modern state
   clearing, compatibility-overload behavior, and that request-scoped POST SSE remains independent.
   Do not throw or warn merely because modern negotiation correctly disables session state and the
   standalone GET stream.

3. Replace case-sensitive and prefix-based `Accept`/`Content-Type` checks with a shared HTTP-aware
   media-range parser. Cover case-insensitive type/subtype, parameters, whitespace, suffix
   rejection, exact/type/global wildcards, `q=0`, precedence, duplicates, and malformed syntax.
   Be conservative with invalid input and do not paste the downstream patch verbatim.

4. Add a compiling handler-emitted progress example to the migration guide before the
   invalidation/subscription section. Base it on the conformance server and request-scoped SSE
   tests. Await all progress work before the handler returns; do not recommend detached or unjoined
   work.

Use the exact source landmarks, acceptance criteria, and test inventory in the handoff. Keep the
changes associated with their original review units: discovery semantics in PR 03, HTTP plumbing
and standalone GET API in PR 05, media validation in PR 06, and progress docs in PR 12. Work on the
aggregate branch first and make small, cherry-pickable commits. Do not modify the source review
branches until the aggregate passes. If a unit is already under upstream review, use a focused
follow-up rather than rewriting reviewed history. Never force-push reviewed work blindly.

Run focused tests while iterating, then run all of:

```bash
swift test
swift package generate-documentation --target MCP --warnings-as-errors
scripts/run-conformance.sh
scripts/run-conformance-2026-07-28.sh
```

Record exact results and any known unscored failures in the follow-up plan. Mark Phase 7 checkboxes
only when their work is actually complete. Commit the existing report/plan/handoff documentation
separately from implementation where practical. Push the finished aggregate branch to `fork` and
confirm its upstream tracking state. Do not push any branch or tag to `origin`.

The two possible specification clarifications—HTTP 200 discovery fallback and effective Accept
quality/wildcard semantics—must remain isolated from Swift commits. The review contains the minimum
reproducers and tradeoffs. You may prepare draft wording, but do not push the specification peer
without a separately confirmed destination.

Stop after Phase 7 is implemented, verified, documented, committed, and pushed. Do not let the
full Phase 8 cross-SDK matrix delay the Graph application trial. In your final response, list the
commits, exact verification results, the `fork` branch pushed, any review-branch propagation still
needed, and any spec clarification intentionally deferred.

---
