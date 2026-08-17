# How the ecosystem implemented `2026-07-28`, and what it means for this SDK

Date: 2026-08-17 · Compared against `mcp-2026-07-28-rc1` (aggregate `b6cf7f9`)

Prompted by Cloudflare's [MCP v2 announcement](https://blog.cloudflare.com/mcp-v2/) and
[migration guide](https://developers.cloudflare.com/agents/model-context-protocol/guides/migrate-to-mcp-sdk-v2/),
then widened to the whole ecosystem: the TypeScript SDK at `2.0.0-alpha.0`, `cloudflare/agents`,
FastMCP v4, mcp-go, the Ruby/PHP/JVM SDKs, Google's MCP Toolbox, Microsoft's Azure MCP Server and
VS Code client, Gemini CLI, Block's goose, the gateway vendors (agentgateway, IBM ContextForge,
Docker, Kuadrant), and the Kotlin/Android and iOS implementations. Every claim about *our* code was
verified in this repository at the tag above.

## What to do about it

The design holds up. On five points we are ahead of the reference implementations, including two
spec MUSTs the TypeScript SDK appears to violate and one production outage class we are immune to by
construction. But the survey also surfaced **one defect in our code that another implementation has
already hit in production**, and it is the top of the list below.

| # | Change | Unit | Why |
| --- | --- | --- | --- |
| 1 | ~~Raise the discovery-probe budget past cold start, and log the downgrade~~ **(applied 2026-08-17)** | 03, 05 | Verified in our code; verified as a production failure elsewhere |
| 2 | SSE keepalive on listen streams + a client reconnect policy | 06, 09 | Most likely production failure we ship today |
| 3 | CORS/preflight built from the existing Origin allowlist | 06 | Browser-hosted clients are dead on arrival |
| 4 | Per-request/serverless recipe, and fix the README row that points serverless users at the legacy transport | 06/07, 12 | The README is actively misleading under this revision |
| 5 | A `requestState` sealing helper | 04 | The revision says MUST integrity-protect; four other SDKs ship a primitive, we ship prose |
| 6 | Escape hatch + logging for a non-conformant authorization server | 02 | Adopters currently hit an undiagnosable failure |
| 7 | `responseMode` override; clamp accepted `ttlMs` | 06, 10 | Deployability; a server can pin a cache entry indefinitely |

Item 1 is a genuine bug and worth fixing before submission. Items 2–4 are worth doing while those
units are open. The rest are follow-ups.

Beyond the units, the survey changes one strategic judgement: **the Tasks extension is not optional
for us.** See "The mobile case" below.

## Two framing corrections

**The Cloudflare documents describe Cloudflare's Workers wrapper, not the SDK.** `createMcpHandler`
exists twice with different options and different legacy strategies; `route`, `corsOptions`, and
`allowedHostnames` live only in `agents/mcp/server`. The SDK's own handler is deliberately
validation-free — no CORS, no Host/Origin checks, no token verification. So where we compare
unfavourably on CORS, the honest comparison is against a platform vendor's deployment layer, not
against the protocol SDK, which has none either.

Two claims in those documents are contradicted by the code they describe. The migration guide says
"listen streams reopen after failure"; the SDK says twice that it never re-listens and hands users a
hand-rolled retry loop instead. And the "thousands of requests per second, billions of tool calls"
figure has no published benchmark behind it — the conformance suite contains no load generation or
timing assertions at all.

**Statelessness was not designed for mobile.** Searching the specification and every SEP, the word
"mobile" appears three times, and only once as a design rationale. The stated motivation for SEP-2575
is uniformly load balancers, sticky sessions, and horizontal scaling. That matters to us because the
one place mobile *is* named is the escape hatch — see below.

## Who actually shipped

Three weeks in, adoption is bimodal, and the split is not by language but by whether the project owns
its protocol layer.

Shipped: FastMCP v4 (Python, 27.2k stars — larger than the official SDK), mcp-go, Google's MCP
Toolbox (same day), Microsoft's Azure MCP Server, Vercel's `mcp-handler` (one day after), Laravel,
Ruby, Quarkus, agentgateway (one day *before*), Kuadrant.

Not shipped: **every major client.** VS Code is pinned to `2025-11-25` with its tracking issue open
and unanswered. Gemini CLI is pinned to a `2025-11-25`-era SDK. goose upgraded to rmcp 3.0 nineteen
hours after release but still negotiates `2025-11-25`, because the Rust SDK deliberately kept
`LATEST = 2025-11-25`. JetBrains, Spring AI, and the Kotlin SDK have all their SEP issues open.

The lesson for our defaults: **servers moved first, clients have not moved at all.** Our unit 12
defaults to initialization-only and requires opt-in, which is exactly the posture the C# SDK, MCP
Toolbox, and goose each landed on independently. That default is right, and now has three
implementations' worth of corroboration.

For context on our own position: upstream `swift-sdk` last released 0.12.1 in May, its
[SEP-2575 issue](https://github.com/modelcontextprotocol/swift-sdk/issues/245) is open and unstarted,
and there is one other actively-maintained Swift implementation
([Cocoanetics/SwiftMCP](https://github.com/Cocoanetics/SwiftMCP), 160 stars), which is on
`2025-11-25` and whose source still references an RC-era error code the final spec renumbered.

## The bug the survey found

**A slow-starting stdio server was silently downgraded to the initialization era.** Fixed
2026-08-17 in units 03 and 05.

`Client.Configuration.discoveryProbeTimeout` defaulted to 2 seconds. On expiry the client throws
`MCPError.internalError("Server discovery timed out")`, which reaches `classifyDiscoveryFailure`
where it is not a `ProtocolLifecycleProbeError`, stdio is not an `HTTPProtocolNegotiationTransport`,
and a generic internal error is not a recognized modern error — so it falls through to
`.initializationBased` and the client retries with `initialize`.

[clio-agent#1186](https://github.com/iowarp/clio-agent/issues/1186) is the same failure in another
ecosystem: a `uv`-launched server takes ~22 seconds on its first-ever cold spawn, the client falls
back to `2025-11-25`, and a modern-only server refuses with `-32022`. It works on every subsequent
warm run, which is what makes it miserable to diagnose.

Two corrections to the first draft of this analysis, both established by reading the code rather than
inferring from the failure:

- **The verdict is not cached, and the downgrade is not sticky.** `protocolLifecycleCacheKey()` is
  implemented only on `HTTPClientTransport`, and `classifyDiscoveryFailure` returns `.inconclusive`
  for any `HTTPProtocolNegotiationTransport`. So the transport that falls back (stdio) never caches
  an era verdict, and the transport that caches (HTTP) never reaches the fallback on a timeout.
- **The fallback itself is deliberate and correct.** `timeoutCancellationPrecedesFallback` pins it
  explicitly. A pre-2026 server may ignore an unrecognized method rather than reporting `-32601`, in
  which case silence is the only signal it will ever give and fallback is the only way `.automatic`
  can connect to it at all. Classifying a timeout as `.inconclusive` — the first draft's proposed
  fix — would have regressed that interop case.

What was actually wrong was narrower: the **budget** was tuned for a warm process rather than a cold
interpreter start, and the downgrade was **silent**. Both are fixed:

- `discoveryProbeTimeout` now defaults to **15 seconds**, in the memberwise initializer and the
  decoder alike, with a doc comment stating that the budget must cover the peer's cold start because
  a server still loading an interpreter is indistinguishable from one that will never answer.
- The fallback now logs at warning level with the underlying error attached, so a downgrade is
  diagnosable instead of invisible.

The residual cost is stated rather than hidden: connecting to a legacy stdio server that silently
ignores unknown methods now waits the full budget before falling back. That is the right trade for a
client whose peers are increasingly modern, and the knob remains public for hosts that know their
peer is legacy.

## Where we are ahead

Verified in both codebases, and worth stating because two are spec MUSTs the reference
implementation misses:

1. **MRTR results are not cached.** SEP-2549 says results produced by retrying through MRTR MUST NOT
   be cached. In the TypeScript SDK the server-side cache-field fill gates only on
   `resultType === 'complete'` and the client writes unconditionally, so an MRTR-produced result is
   stamped and cached. We block it three ways: the store gate requires `round == 0`,
   `makeResponseCacheKey` returns nil when the parameters carry `inputResponses` or `requestState`,
   and the server refuses cache fields on an `input_required` result. No conformance scenario covers
   this — the suite marks client-side caching "not observable at the protocol level" — which is
   presumably why it went unnoticed.
2. **OAuth `state` is validated inside the SDK.** The TypeScript SDK states three times that this is
   the consumer's job, and every consumer reimplements it; it is the most-repeated footgun in that
   codebase. We compare it directly. For an SDK whose users are app developers rather than platform
   teams, owning it is right.
3. **We are structurally immune to the Ruby production outage.** Ruby SDK v1.1.0 advertised
   `2026-07-28` while emitting no `resultType`, and from 2026-08-12 every tool call from Claude
   connectors failed in production. Their fix then keyed the stamp on envelope presence, so a client
   that negotiated `2026-07-28` through the *legacy* handshake still got unstamped results — the
   lesson being that lifecycle and revision are separate axes. In our design they cannot drift:
   `Version.supported(for: .initializationBased)` subtracts the per-request-metadata versions, so
   `2026-07-28` is unreachable through `initialize` by construction.
4. **Unknown method answers `-32601`.** `server/discover` is now a backward-compatibility probe that
   pre-2026 servers receive whether they implement it or not. Java SDK 2.0.0 returned HTTP 500 for
   it; OpenAI's hosted client turned that into a 424 and the entire response failed, even for "hi"
   ([java-sdk#1072](https://github.com/modelcontextprotocol/java-sdk/issues/1072)). We throw
   `methodNotFound`, which is the difference between graceful client fallback and total outage.
5. **Cache partitioning is safe by construction.** The TypeScript SDK's `cachePartition` defaults to
   an empty string, making the private slot identical to the public one; it is safe only because
   each client allocates a fresh store, and sharing a store across principals leaks private resource
   bodies. We partition by the authorization context of the completed attempt and refuse private
   storage when identity is unavailable. Relatedly, our default `cacheScope` is `private` — matching
   Laravel, against Quarkus and Google's Toolbox, which both default to `public` and thereby let
   shared intermediaries cache across authorization contexts.

## Where we lag, and what to do

### Quiet subscription streams die, and never come back

Ruby ships a 15-second SSE keepalive and a 1000-stream cap; the TypeScript SDK ships
`keepAliveMs: 15000` and `maxSubscriptions: 1024`; Vercel added `maxSubscriptions` specifically
because listen streams reintroduce long-lived connections on serverless. We emit no keepalive, and
our client uses a default `URLSessionConfiguration` whose 60-second inter-data timeout then kills an
idle stream. The audit already recorded what follows: the subscription goes dormant, and only a full
reconnect revives it, because `reestablishSubscriptions()` has exactly one caller.

No client in the survey auto-reopens, so on that axis we are equal. But the *combination* on our side
means a Swift client that subscribes and then idles for a minute silently stops receiving
list-change notifications. On cellular or across app suspension, that is the normal case.

**Do:** emit keepalive comments from `StreamableHTTPServerTransport` (unit 06) and add an opt-in
reconnect policy with jittered backoff to `Client.Configuration` (unit 09). Do not copy the
TypeScript reconnect budget — 2 retries, 1.5× growth, no jitter anywhere — which is tuned for a
datacenter. A subscription cap is worth adding while unit 09 is open; every implementation that
shipped listen support added one, and ours is unbounded.

### Browser clients cannot talk to a Swift server

We have no CORS of any kind: non-POST returns 405, and no `Access-Control-*` header is ever emitted,
so even a permitted POST is blocked. Cloudflare's wrapper defaults to `origin: '*'`; the TypeScript
SDK ships Host and Origin validation middleware plus CORS on the OAuth discovery documents;
`danielealbano/android-remote-control-mcp` added CORS specifically so MCP Inspector could connect.

**Do:** add a `CORSValidator` to the validation pipeline answering `OPTIONS` with 204 and allow
headers derived from the `OriginValidator` allowlist already configured there (unit 06). We hold
exactly the data needed to answer a preflight and currently discard it.

One scoping note: browser-*hosted clients* are a smaller prize than they look, because the web went
elsewhere — [WebMCP](https://github.com/webmachinelearning/webmcp) is a separate W3C effort where the
page itself is the tool server. The real consumers here are inspector tooling and dashboards.

### The serverless story is asserted but not supported

Our `handleRequest(HTTPRequest) async -> HTTPResponse` is the right shape, but it parks on a
continuation only resolved by the `Server` receive loop, which `start(transport:)` spawns as an
unstructured task. There is no entry point that drives one dispatch inline, so an adopter on Lambda,
Cloud Run, or Vapor must keep a warm module-scope `Server` — which works, but is undocumented.

Worse, `README.md` recommends `StatelessHTTPServerTransport` for "serverless/edge functions." That
row predates this work, but under this revision it points adopters at the *initialization-era*
transport, the worst of the three for a cold-start-per-request environment.

**Do:** fix that README row (unit 12) and document the warm-server recipe. Optionally add
`Server.handle(_:on:)` driving a single dispatch without the receive loop (units 06/07) — the
per-request path has no cross-request state, so only the plumbing is missing.

### `requestState` sealing is prose on our side, a primitive on four others

The TypeScript SDK ships `createRequestStateCodec`, Python SDK v2 ships `RequestStateSecurity`
(encrypted and authenticated by default, bound to a TTL *and* the OAuth principal), FastMCP mirrors
it, and Ruby uses AES-256-GCM bound to TTL, method, target and arguments. Only ViteMCP declines, and
says so loudly.

The TypeScript details are worth copying: HMAC over a version prefix plus body so a token cannot be
transplanted across codec versions, a ≥32-byte key enforced at construction, key bytes snapshotted to
avoid a TOCTOU, binding stored as a domain-separated truncated tag rather than raw, MAC checked
before every other rejection reason, and fail-closed when a token minted with a binding meets an
instance configured without one.

One warning from Python's implementation that our documentation must carry: their default key is
`os.urandom(32)` **per process**, so a multi-instance deployment silently breaks on retry unless keys
are shared. If we ship a sealer with a per-process default, a two-replica Vapor deploy fails
intermittently and mysteriously.

**Do:** add `MultiRoundTripStateSealer` in unit 04. CryptoKit is already a dependency for PKCE.

### A broken authorization server hard-blocks adopters, undiagnosably

The TypeScript SDK ships `skipIssuerMetadataValidation`, scoped to exactly one check and explicitly
*not* the RFC 9207 callback `iss` check. We have no equivalent, and our discovery silently
`continue`s past a mismatch before throwing a generic discovery failure, so an adopter facing a
real-world trailing-slash issuer bug cannot tell why.

**Do:** log the mismatch unconditionally (unit 02) — pure win. For the escape hatch, prefer a
narrower shape than theirs: `trustedIssuerAliases`, naming the one broken server and the exact issuer
string accepted from it, rather than a blanket flag.

### Smaller items

`responseMode` — they expose `auto | sse | json` and warn at construction when you pick `json`. Our
validation pipeline hardcodes `sseRequired`, so a JSON-only client gets a 406 even from a server that
would never stream. The automatic policy is right; the missing override is a deployability gap behind
API gateways and buffering proxies.

TTL clamp — they cap accepted `ttlMs` at 24 hours so a server cannot pin an entry indefinitely. We
accept whatever the server sends.

## The mobile case

This is where the survey changed my view, and it is the most strategically important section.

**Nobody has made the mobile argument in public.** The specification's motivation is entirely
server-side scaling. The one place mobile is named as a design rationale is the Tasks extension:
"Mobile clients, intermittent networks, or environments where connections drop. Task IDs survive
disconnects." Meanwhile `Last-Event-ID` and SSE resumability are **removed**, and closing a stream is
now *defined* as cancellation — so on iOS every backgrounding, Wi-Fi-to-cellular handoff, and NAT
eviction is an involuntary disconnect that the protocol reads as intent to cancel, with no replay
path.

That has three consequences, unevenly weighted:

**Tasks is no longer an optional extension we deferred.** It is the only sanctioned durability
mechanism in the revision; its normative client requirement — persist task IDs durably so polling
resumes after a crash or restart — maps exactly onto iOS process death; and
[swift-sdk#247](https://github.com/modelcontextprotocol/swift-sdk/issues/247) is open and unstarted.
For a datacenter SDK, deferring Tasks is reasonable. For an Apple-platform SDK it removes the only
answer to the platform's defining constraint. I would not add it to the current stack — it is a
separate body of work — but it should be the next thing after these units land, and the migration
guide should say plainly that long-running tools need it.

**Client-side list caching stops being an optimization and becomes load-bearing.** With no resumption
and no "what changed while I was gone" mechanism, recovery from any subscription gap is a full list
re-fetch. On a metered radio that is exactly the cost SEP-2549's `ttlMs`/`cacheScope` exists to
avoid. Our unit 10 cache is therefore doing more work on mobile than its datacenter equivalent, which
strengthens the case for the TTL clamp and for persisting the cache across launches. One caveat
before anyone persists it: a server that omits `serverInfo` yields no stable identity to key on, so
the TypeScript SDK falls back to a per-connection surrogate and gets zero reuse across launches. If
we persist, we need a host-supplied stable identity and a defined policy on identity change.

**Three mechanisms lose state on suspension, and one we can fix better than anyone.** The PKCE
verifier, `state`, and validated issuer are locals inside `acquireTokenViaAuthorizationCode`, and
`TokenStorage` covers tokens only, so an app killed during `ASWebAuthenticationSession` restarts the
browser flow. The TypeScript SDK treats persisting discovery state as a MUST — but only because their
redirect is one-way and the process navigates away. `ASWebAuthenticationSession` is *awaitable*, so
we can own the whole round trip in one async call and avoid their sentinel/`finishAuth` design
entirely. That is a real advantage we have not taken. In-flight MRTR is the second (our retry loop
holds `attemptData`, `round`, and `requestState` as stack locals, so an interrupted interactive call
is un-checkpointable); subscriptions are the third.

Worth noting who else is here: **no vendor mobile app is an MCP client over the wire.** Claude and
ChatGPT both run the MCP client in their own cloud — the phone is a chat UI. Google's AI Edge Gallery
(Android, experimental) is the only real on-device client; the official Kotlin SDK has no
`androidTarget()` at all; and every third-party mobile client is on a pre-2026 revision. The mobile
MCP client niche is genuinely unoccupied, and the strongest argument for this revision on mobile —
that a process kill costs nothing when every request carries its own `_meta`, where before it forced
a full re-`initialize` — is sitting unused.

## Use cases we have not served

**Desktop and CLI hosts that spawn stdio servers.** Poorly served everywhere, and our nearest
constituency after apps. Our `StdioTransport` takes handles rather than spawning, so we own none of
this — defensible, but it means every macOS host rebuilds it. The prior art is unusually consistent,
and if we ever add a supervised-subprocess API these are the load-bearing details: recover the
login-shell `PATH` on macOS, because an app launched from Finder inherits a minimal `launchd`
environment (goose spawns `-l -i -c 'printenv PATH'`, detached to avoid `SIGTTIN`, using `printenv`
rather than `echo` because fish space-joins `$PATH`, cached once, never fatal); sanitize the child
environment rather than inheriting it (Gemini CLI's allowlist plus
`/TOKEN|SECRET|PASSWORD|KEY|AUTH|CREDENTIAL|PRIVATE/i` redaction, plus goose's 31-entry blocklist
whose macOS entries — `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH` — are the
ones that matter); shut down with a ladder (VS Code closes stdin, waits 10s, SIGTERMs the process
*tree*, waits 10s, SIGKILLs, and goes straight to forceful on a second stop); and distinguish
"process spawned" from "session ready," which VS Code conflates and pays for.

Three failure modes are already documented in the wild and worth designing against: duplicate
`initialize` on one stdio process (OpenAI's tunnel sends `server/discover`, then `initialize` twice);
byte caps applied on only one era, which left a legacy path collecting unboundedly and
memory-exhaustible; and unbounded stderr buffers captured but never read after startup.

**Multi-instance server deployments.** The TypeScript event bus is a pluggable interface precisely so
`notify` on node A reaches a listener on node B. Ours is in-process with no seam, so a Vapor service
scaled beyond one instance silently fails to fan out list-change notifications. This is the one
scaling gap I would call structural rather than cosmetic.

**Multi-tenant gateways.** The TypeScript factory builds a fresh server per request *and per
principal*, making tenant isolation the default; our long-lived actor with per-request
`HandlerContext` puts that on handler authors. Ship the primitives, not a gateway — but say so.

**High-RPS proxy fleets.** They added a zero-round-trip connect from a cached `DiscoverResult` so a
worker fleet does not re-probe per worker. Cheap to add, only matters at fleet scale.

## What not to copy

- **Their cache partition default** — an empty-string partition is safe only by accident of
  allocation.
- **Browser CORS heuristics.** In the browser shim a fetch `TypeError` is swallowed so discovery
  tries the next URL, and a failed preflight is read as a *legacy* signal. A native client has no
  preflight; adopting either would mask real `URLError`s and could silently fall back to a different
  authorization server during a cellular outage. Hard-code the non-browser semantics.
- **Reconnect budgets tuned for datacenters** — 2 retries, no jitter.
- **A blanket `skipIssuerMetadataValidation`.**
- **Defaulting to dual-era.** Cloudflare accepts both eras out of the box; we default to
  initialization-only with opt-in, as do the C# SDK, MCP Toolbox, and goose. An existing app should
  not change wire behavior by bumping a dependency. Keep ours; document the one-liner that gets their
  posture.
- **VS Code's missing per-call timeout** — still an open issue there.

## Conformance standing

Upstream `swift-sdk` is absent from the conformance runner's `KNOWN_SDKS`, and its absence is
asserted by a unit test. Upstream Swift CI still runs the old `v0.1.15` suite with the `core` subset.
Our unit 11 supersedes that locally and the local conformance branch registers Swift, but that
registration has no remote yet, and `tier-check --sdk swift-sdk` will not resolve until it lands.

One design note in our favour: other SDKs need per-revision `specOverrides` because each selects its
stateless lane differently — a process flag, a separate `/stateless` endpoint, an environment
variable. Our fixture serves both revisions at one endpoint, so our entry needs none.

Two practices worth adopting when the registration lands. The TypeScript SDK runs conformance as a
blocking CI job with a completely empty `2026-07-28` baseline, and exits non-zero when a *passing*
scenario is still listed as expected-to-fail — which forces baselines to burn down rather than rot.
And mcp-go pins the exact bytes a pre-2026 client receives in a golden file: no `resultType`, no
`ttlMs`, no `_meta`. That turns our backward-compatibility promise into an executable artifact, which
is the cheapest possible insurance for the dual-era work in units 03 and 07.

One caveat for anyone wiring this into an app target: the harness spawns a fresh process per client
scenario and needs a long-running listener for the server leg, so it cannot test a non-spawnable
host, and there is no stdio coverage at all. Its `command.split(' ')` is also not shell-safe, which
breaks on any path containing a space — DerivedData paths, notably.
