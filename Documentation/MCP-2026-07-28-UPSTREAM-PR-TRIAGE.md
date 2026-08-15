# Upstream pull-request triage

Date: 2026-08-15 · Reviewed against the unit tips listed in
[`PullRequests/MCP-2026-07-28/README.md`](PullRequests/MCP-2026-07-28/README.md)

Nine open pull requests on `modelcontextprotocol/swift-sdk` overlap the MCP 2026-07-28 series. This
records what each one does, whether it is right, how mature it is, and what to do about it.

Sections carry stable anchors (`#collision`, `#cancelled-exchange`, `#pr-257`, `#pr-269`,
`#pr-270`, `#pr-271`, `#pr-273`, `#cancellation-gap`, `#value-data-url`) so pull-request
descriptions can link to a specific decision.

## Context that frames every recommendation

- **Upstream is dormant.** No pull request has merged since **2026-04-29**; the last five merges are
  all from March–April. There are **32 open pull requests**, the oldest from 2025-04-04.
- **No CI has ever run on any of them.** `statusCheckRollup` is empty for all nine. The repository
  has a real matrix (macOS + Linux, conformance, DocC, static Linux), but Actions are gated behind
  maintainer approval for outside contributors and nobody has granted it. Every "tests pass" claim
  in these PRs is self-attested.
- **No maintainer has reviewed or commented on any of the nine.** All are `REVIEW_REQUIRED` /
  `BLOCKED`.
- All nine are authored by outside contributors, none of whom has landed a change in this
  repository before.

The practical consequence: **do not sequence our series behind any of them.** Treat them as
information about the code, and as relationships to disclose in our pull-request bodies.

## Measured conflict map

Every PR applies cleanly to upstream `main`; none is stale. Conflicts against our stack were
measured by applying each diff, not estimated.

| PR | vs `main` | vs our stack | Cause |
| --- | --- | --- | --- |
| #257 | clean | conflict | we replaced the exact lines it deletes |
| #260 | clean | **clean** | — |
| #264 | clean | conflict | shared actor-declaration line + `Server.swift` dispatch |
| #267 | clean | conflict | adjacent to our actor-declaration edit |
| #268 | clean | **clean** | — |
| #269 | clean | conflict | same fixture block, different fix |
| #270 | clean | conflict | we rewrote every region it touches |
| #271 | clean | conflict | one hunk, `streaming` → `enableStandaloneGetStream` rename |
| #273 | clean | conflict | handler-box hierarchy, `withMethodHandler` anchor, `handleBatch` |

## The two competing pairs

<a id="collision"></a>
### #264 vs #267 — colliding stateless request IDs (#254, #265): back **#264**, close **#267**

Both address concurrent clients whose JSON-RPC ids collide on the stateless HTTP transport.

**#264 (jstar0) — isolation.** Rewrites the inbound id to a transport-private UUID and restores the
client's id on the way out. This is *the same design as our unit-06 `StreamableHTTPServerTransport`*
(`makeRoutingID`, `replacingMessageID`, `activeRequests[...].originalID`), independently arrived at.
It fixes both issues, its tests use a real both-in-flight barrier rather than sleeps, and it deletes
two `Task.sleep` waits from existing tests.

Blocking defects to request before merge:

1. `routingRequest`/`restoringResponseID` round-trip through `JSONSerialization`, which mutates
   numbers in both directions — reproduced locally: `{"temp":1.0,"ratio":0.1}` becomes
   `{"ratio":0.10000000000000001,"temp":1}`. This corrupts tool arguments before the handler sees
   them and results before the client sees them. Our transport avoids it by going through `Value` +
   `JSONEncoder`; ask for the same.
2. `httpRequestContext(for:)` keeps a raw-id fallback returning the most recent match, so #265 stays
   open for direct API callers. Its sibling `routedRequestID` correctly fails closed; apply that rule
   to both.
3. `originalRequestID` resolves from a map populated *after* the continuation yield; correct today
   only because no `await` intervenes.
4. `HandlerContext.id` must stay the routing id. We deliberately split `id` (package, routing) from
   `requestID` (public, client's id), and `context.id` routes request-scoped SSE and keys
   subscriptions. Taking #264's single-field semantics naively would break both.

**#267 (jpurnell) — rejection.** Returns HTTP 409 when a wire id is already in flight. This is not a
fix; it is an availability regression:

- Id uniqueness is scoped to the *sender* — 2025-11-25 `basic/index.mdx` ("previously used by the
  requestor"), sharpened in 2026-07-28 ("any other request the sender has issued"). A second client
  using id `1` is fully conformant and cannot know the first exists.
- One stuck request locks that id for **every** client until transport teardown, because the context
  entry is only removed when the waiter resumes and there is no deadline. Since most clients start at
  id 1, a single hung call can lock out `initialize`.
- It does not fix the `"1"` vs `1` conflation that issue #254 explicitly calls out.
- Its error body carries `"id": null` even though the id was read successfully, contrary to
  `index.mdx` ("MUST include the same ID … except … where the ID could not be read").

Close it with thanks. If an interim guard is wanted while #264 is revised, the only defensible form
is a logged warning, never a 409.

**On backporting the 2026 design to the legacy transport: #264 already is that backport.** Once our
series lands, the right end state is one shared `replacingMessageID` and a single
`OriginalRequestIDProviding` protocol across both transports.

<a id="cancelled-exchange"></a>
### #260 vs #268 — cancelled exchange hangs (#255): back **#260**, keep **#268** as fallback

The specification genuinely collides here: the transport says a request POST **MUST** be answered
with JSON or SSE, while cancellation says the receiver **SHOULD NOT** respond. Because this
transport pins `Accept: application/json` (no SSE), the close-the-stream escape hatch does not
exist, so answering with a JSON error is the only completion available. Both PRs resolve it the same
way and both are correct on every path traced (cancel before dispatch, mid-handler, after response;
no double-resume, no leak). Note this bug class is legacy-only: under 2026-07-28 the cancellation
signal on HTTP is the stream close, which our unit-06 transport already handles.

The difference is rigor.

| | #260 (ianegordon) | #268 (jpurnell) |
| --- | --- | --- |
| Tests | 5, real `Server`, deterministic handshake, asserts code/content-type/integer-id/ignore paths | 1, no `Server`, `sleep` + poll, asserts only that an error exists |
| Encode failure | resumes with an error → 500 | `?? Data()` → **HTTP 200 with an empty body** |
| Activity | opened 2026-07-20, active through 2026-08-09 | opened 2026-07-29, no activity since |
| External validation | **yes** — an affected user pinned the commit, ran their own hang-reproduction suite, confirmed the fix | none |

#268's one advantage: its error message is `"Request cancelled"` where #260's renders as
`"Server error: Request cancelled"`, because `MCPError.serverError`'s description prepends a prefix.
Ask #260 to use `.remote(code:message:data:)` (which encodes the message verbatim) and to pin the
string with `==` rather than `.contains`. Also ask for `-32002` to become a named constant, and for
the deferred waiter deadline to be stated explicitly.

Sequencing: land #264 first, then ask #260 to rebase — #260 resumes waiters by raw id and will need
to resolve the active exchange once ids are isolated.

## The remaining five

<a id="pr-257"></a>
### #257 — make `initialize` idempotent

**Oppose as written.** It deletes the already-initialized
guard. The body claims the specification requires this; it does not — 2025-11-25 `lifecycle.mdx` is
silent on repeated `initialize`, and the transport document treats re-initialization as *starting a
new session*. Under 2026-07-28 it is worse: `initialize` selects the legacy era for the session, so
making it freely repeatable lets a client flip era mid-session. It also misattributes issue #144,
whose real cause is per-connection state ownership, and it "fixes" that by letting one client
silently overwrite another's negotiated version and capabilities. Redirect to what issue #219
actually asked for: idempotency at the stateless transport, not in `Server`.

<a id="pr-270"></a>
### #270 — early request cancellation race

**Back the core idea; request changes.** The race is real, and
**our stack still has it** (see below). But the PR bundles four unrelated changes, and one of them —
rejecting duplicate outstanding request ids — is the same policy as #267 and regresses `main` for the
same reason. It also reindents every line it touches to 2 spaces in a 4-space file. Ask for the
ordering fix alone.

<a id="pr-273"></a>
### #273 — raw JSON request handling

**Request changes; strictly last.** The motivating bug is real and
worth more than the rest of the PR: `Value` silently coerces any string that looks like a data URL
into `.data`, so `"data:,A brief note"` does not survive a round trip. That is a handful of lines in
`Value.swift` and affects every code path. The proposed remedy instead adds a 1,341-line hand-written
JSON parser on the inbound hot path for everyone, with six new public types, for an opt-in ergonomics
feature with no specification basis. Ask for the `Value` fix as its own small PR. If the parser lands
at all it must come after our series — it changes `RequestHandlerBox`'s signature, which our
multi-round-trip handler subclasses.

<a id="pr-269"></a>
### #269 — conformance fixture returns a template from `resources/list`

**Real bug; our unit 11 already fixes it more completely** (a valid concrete `test://template/example` resource, a real
`resources/templates/list` handler, and 2026-07-28 caching hints, which #269 lacks). Credit it in the
unit 11 body and let the maintainer close it as covered.

<a id="pr-271"></a>
### #271 — Windows build guards

**Correct, minimal, orthogonal; leave it upstream.** It replaces
`#if !os(Linux)` with `canImport(EventSource)` / `canImport(FoundationNetworking)`, which is exactly
right: the Package manifest conditions EventSource on Apple platforms, so `!os(Linux)` is true on
Windows and the import fails. Our unit 05 has the same five guard sites, no new ones, so the fix maps
one-to-one. Worth noting in our PR body: our per-request POST path is platform-agnostic
(delegate-based, with our own SSE parser), so once #271 lands, Windows gains *working*
request-scoped SSE rather than mere graceful degradation. Windows has no CI here, so nothing will
keep it fixed.

<a id="our-code"></a>
## Two findings about our own code

<a id="cancellation-gap"></a>
**1. The stdio cancellation ordering gap — found here, now fixed in unit 06.** `handleRequest` runs
on its own task so the receive loop keeps reading, and notifications are handled inline on that
loop. A `notifications/cancelled` could therefore be processed before the request it names had
registered a handler task, and the built-in handler dropped it because `removePendingRequest` found
nothing. The pre-dispatch ledger unit 06 already had was written only by the transport
(stream-close) path, so it did not cover this.

This is the server-side mirror of the client-side lost-cancellation defect the audit found
(AUD-01). The new lifecycle makes it matter more: on stdio under 2026-07-28 the notification is the
*only* cancellation mechanism, because there is no stream to close
(`basic/patterns/cancellation.mdx`).

Fixed in unit 06, which owns that ledger: the server records a request as dispatching before its
task is scheduled, a cancellation arriving in the window is recorded against the same ledger both
mechanisms now share, and the existing pre-dispatch guard consumes it. A regression test parks a
request inside the handler-context lookup, cancels it, and asserts the handler never runs; it fails
against the previous code. This overlaps #270 — see [#270](#pr-270).

<a id="value-data-url"></a>
**2. `Value`'s data-URL coercion is a live round-trip bug** (`Value.swift`, identical on `main`): any
decoded string matching a data URL becomes `.data` and re-encodes differently. Worth filing upstream
independently of #273.

## Recommended actions

1. Submit the 12 units on their own schedule. Nothing here justifies waiting.
2. Disclose the overlaps in the affected bodies: unit 11 → #269 (superseded), unit 05 → #271/#261
   (left to its author), and — if the ordering fix lands with us — #270.
3. Decide the placement of the stdio cancellation fix above.
4. Optionally comment upstream, where an independent confirmation is the cheapest thing that moves
   any of this: back #264's approach over #267's, support #260, and ask #273 to split out the `Value`
   fix. Every one of these has sat with zero engagement.
