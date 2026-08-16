# Draft upstream comments

Status: **drafts for review — nothing has been posted.** Each block below is ready to paste as a
comment on the named pull request or issue. They are written to be useful to the author and the
maintainer without presuming a decision that is not ours to make, and they disclose that the MCP
2026-07-28 series is in flight so the overlap is not a surprise later.

Order matters a little: #264 and #260 are the two that unblock decisions, so post those first if
you only post some. Every claim in them was verified against the code — see
[`MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md`](MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md) for the evidence
behind each one.

---

## 1. On [#264](https://github.com/modelcontextprotocol/swift-sdk/pull/264) — isolate stateless HTTP request exchanges

> I reviewed this closely while preparing a 2026-07-28 protocol series for this SDK, and I think the
> approach here is the right one. The new per-request Streamable HTTP transport that revision needs
> arrives at the same design independently: rewrite the inbound JSON-RPC id to a transport-private
> routing id, keep the client's id alongside it, and restore it on the way out. Two implementations
> converging on that is a good sign it is the shape the problem wants.
>
> Three things I would want changed before it lands, one of them blocking:
>
> **1. `JSONSerialization` mutates numbers in both directions.** `routingRequest` and
> `restoringResponseID` re-serialize the whole message, and that round trip is not value-preserving:
>
> ```
> in:  {"temp":1.0,"ratio":0.1,"big":9007199254740993}
> out: {"big":9007199254740993,"ratio":0.10000000000000001,"temp":1}
> ```
>
> That rewrites tool arguments before the handler sees them and results before the client sees them,
> for every request, not just colliding ones. Going through the SDK's own `Value` with
> `JSONDecoder`/`JSONEncoder` avoids it — that is what the 2026 transport does for the same rewrite.
> Worth a test asserting `{"ratio": 0.1}` survives both directions unchanged.
>
> **2. The raw-id fallback in `httpRequestContext(for:)` leaves #265 partly open.** When a wire id
> maps to more than one exchange it returns the most recently registered one, which is the original
> confused-deputy read narrowed to direct API callers rather than removed. `routedRequestID` already
> does the right thing by failing closed on ambiguity; applying that rule to both would let the PR
> claim #265 outright.
>
> **3. `originalRequestID` resolves from `responseWaiters`, which is populated after the
> continuation yield.** It works today only because no `await` intervenes between the yield and the
> registration. Resolving it from a map registered alongside `httpRequestContexts` — which is
> populated before the yield — would make that robust to future edits.
>
> Minor: the `excluding:` parameter on `makeExchangeID` looks vestigial, and the `400` branch in
> `routingRequest` appears unreachable because `handlePost` has already classified the id.
>
> One heads-up on sequencing. I have a 2026-07-28 series in progress that adds a separate
> per-request transport and touches `StatelessHTTPServerTransport` only to pin its protocol-version
> set, so the overlap with this PR is one line on the actor declaration. The one place to be careful
> is `HandlerContext.id`: in that series it is deliberately the *routing* id (the client's id is a
> separate `requestID` field), because `id` is what closes a request-scoped SSE stream and keys
> subscriptions. This PR gives `id` the client's id instead. Whichever lands second, that field
> should not be resolved by simply taking the other side's line.

---

## 2. On [#267](https://github.com/modelcontextprotocol/swift-sdk/pull/267) — reject colliding in-flight ids

> Thanks for tackling #254/#265 — the underlying defect is real and worth fixing. I want to push
> back on the remedy though, because I think rejection is the wrong direction for this transport.
>
> JSON-RPC id uniqueness is scoped to the sender, not globally. 2025-11-25 `basic/index.mdx` says an
> id "MUST NOT have been previously used by the requestor within the same session", and 2026-07-28
> sharpens it to "any other request the sender has issued and not yet received a response for". This
> transport is explicitly multi-client, so a second client using `id: 1` is fully conformant and has
> no way to know the first client exists. Returning 409 makes it pay for another client's behavior.
>
> There is also an availability consequence. `httpRequestContexts[requestID]` is only removed when
> the waiter resumes, and there is no deadline (that is #255, still open), so a client that
> disconnects mid-call leaves the entry in place. From then on every client POSTing that id gets 409
> until the transport is torn down. Since most clients start their id sequence at 1 and `initialize`
> is typically id 0 or 1, one hung tool call can lock out initialization for everyone.
>
> Two smaller things: the 409 body carries `"id": null` even though the id was read successfully,
> which `index.mdx` reserves for the case where the id could not be read; and because
> `extractID` stringifies integers, a legitimately distinct `1` is rejected while `"1"` is in flight
> — the exact conflation #254 calls out.
>
> [#264](https://github.com/modelcontextprotocol/swift-sdk/pull/264) takes the isolation approach
> instead — private routing ids with the client's id restored on the way out — which is also the
> design the 2026-07-28 Streamable HTTP transport needs, so the two transports would converge rather
> than diverge. My suggestion would be to close this in favor of that one. If an interim guard is
> wanted while #264 is revised, a logged warning would get the diagnostic value without the lockout.

---

## 3. On [#260](https://github.com/modelcontextprotocol/swift-sdk/pull/260) — complete a cancelled request's HTTP exchange

> I traced both this and #268 against the specification and the transport, and this is the one I
> would merge.
>
> The specification collision is real and both PRs resolve it the same defensible way: the transport
> section says a request POST **MUST** be answered with JSON or SSE, cancellation says the receiver
> **SHOULD NOT** respond, and because this transport pins `Accept: application/json` the
> close-the-stream escape hatch does not exist. A JSON error is the only completion available, and
> the sender is told to ignore late responses anyway.
>
> What sets this PR apart is the testing. Blocking the handler on a stream fed from inside a real
> `CallTool` handler makes the "waiter is registered" precondition an observable fact rather than a
> sleep; `raceAgainstTimeout` turns a hang into a bounded failure; and asserting the error code, the
> content type, integer-id round-tripping, and the ignore paths covers the things that would
> silently regress. Verifying that the handler actually observed `CancellationError` is the part
> #268 cannot show, because it never instantiates a `Server`.
>
> Three suggestions:
>
> 1. **The client-visible message is doubled.** `MCPError.serverError`'s description prepends
>    `"Server error: "`, so the wire string is `"Server error: Request cancelled"`. `.remote(code:
>    message:data:)` encodes the message verbatim if you want the cleaner text. Either way, pinning
>    it with `==` rather than `.contains` would catch this class of drift.
> 2. **Promote `-32002`.** Clients need to recognize it to tell cancellation from a generic server
>    error, so a named constant beats a `private static let`.
> 3. **Say that the waiter deadline is deferred.** #255 also asks for one; stating that it is out of
>    scope with a follow-up issue keeps the PR from looking like it closes more than it does.
>
> For context, I have a 2026-07-28 series in progress. It does not touch this code path — under that
> revision the HTTP cancellation signal is the client disconnect, which a new per-request transport
> handles — and I confirmed this PR applies cleanly on top of that series. So there is no
> sequencing constraint from my side, other than that #264, if it lands, changes how waiters are
> keyed and this would want a rebase after it.

---

## 4. On [#273](https://github.com/modelcontextprotocol/swift-sdk/pull/273) — exact raw JSON request handling

> The defect motivating this is real and I think it is worth more attention than the rest of the PR:
> `Value.init(from:)` coerces any decoded string that parses as a data URL into `.data`, and
> `encode(to:)` regenerates a canonical spelling from the bytes. So `"data:,hello"` round-trips as
> `"data:text/plain;base64,aGVsbG8="` — measured, not hypothetical. That is silent and lossy, and it
> affects every path that carries a string through `Value`, not only inbound server requests.
>
> Would you consider splitting that fix out on its own? It is a small change in `Value.swift`, it
> benefits clients and servers equally, and it can land immediately. As written, this PR leaves the
> coercion in place — the raw path covers inbound requests, while handlers still return typed
> results that encode through `Value` on the way out, so the outbound half of the round trip is
> unchanged.
>
> On the larger feature, two observations offered in good faith:
>
> - **It is not additive for non-users.** `requestRoute(in:)` runs on every inbound message and
>   rebuilds its raw-aware method list per call; batch detection now routes every batch through
>   `RawJSONValue.batchElementRanges` with a `validateSyntax()` pass per element regardless of
>   whether any raw-aware handler is registered. Gating the new path so that a server with zero raw
>   handlers takes byte-for-byte the old route would make the "these limits do not affect legacy
>   handlers" claim true of the parser as well as the limits.
> - **`.invalid(.random, …)` for unrecoverable ids.** JSON-RPC 2.0 wants `id: null` when the id
>   cannot be determined. Feeding `[1,2,3]` currently produces three error responses with three
>   random ids.
>
> The parser itself reads carefully — surrogate-pair validation, bounded routing capture, overflow
> checks before allocation, cancellation threaded through decode — and the adversarial tests are the
> right ones. My concern is scope and placement, not craft.
>
> Sequencing note: I have a 2026-07-28 series in progress whose multi-round-trip handler subclasses
> `RequestHandlerBox`, so this PR's signature change would force an update there (and vice versa).
> Landing that series first is the cheaper order, since this PR would then rebase onto a stable
> `handleRequest` rather than the other way round.

---

## 5. On [#271](https://github.com/modelcontextprotocol/swift-sdk/pull/271) — Windows build guards (and [#261](https://github.com/modelcontextprotocol/swift-sdk/issues/261))

> Confirming this diagnosis independently: the manifest conditions `EventSource` on Apple platforms
> only, so on Windows `#if !os(Linux)` is true and the import refers to a module that was never
> linked. Switching to `canImport(EventSource)` and `canImport(FoundationNetworking)` is the right
> fix, and splitting those two axes is correct rather than fussy — `URLSession.AsyncBytes` is a
> Darwin-Foundation capability independent of EventSource.
>
> One thing that might be worth adding to the case for it. I have a 2026-07-28 series in progress
> that adds a per-request POST path to `HTTPClientTransport`, and that path is platform-agnostic: a
> delegate-based `dataTask` plus its own SSE parser, no EventSource. It introduces no new
> platform-guard sites, so this PR still maps one-to-one onto it. The upshot is that with this fix
> applied, Windows would get working request-scoped SSE under the new revision rather than only
> graceful degradation of the legacy standalone GET stream.
>
> Whichever of us lands first, the other rebases one hunk — the series renames `streaming` to
> `enableStandaloneGetStream` on a context line inside one of the guards. Happy to take that on my
> side.
>
> Separately: there is no Windows job in CI, so nothing will keep this fixed once it is. Might be
> worth a follow-up adding `windows-latest` to the build matrix, even build-only.

---

## 6. On [#269](https://github.com/modelcontextprotocol/swift-sdk/pull/269) — don't return a resource template from `resources/list`

> Confirming the defect: `test://template/{id}` is served from `resources/list` as a `Resource`,
> whose `uri` is `format: uri` in the schema, and the braces make it fail that format check — which
> is why the conformance suite's `wire-schema-valid` check flags it. Templates belong in
> `resources/templates/list` as `ResourceTemplate` with a `uriTemplate`.
>
> Heads-up that a 2026-07-28 conformance series I have in progress fixes the same thing slightly
> differently: it keeps a concrete `test://template/example` resource in `resources/list` (so the
> read path stays exercised), adds the missing `resources/templates/list` handler, and gives that
> handler the `ttlMs`/`cacheScope` hints the 2026-07-28 caching scenario requires. If that lands,
> this can close as covered; if this lands first, the fixture change is a one-hunk conflict I will
> resolve on my side. Either order is fine — flagging it so it is not a surprise.
