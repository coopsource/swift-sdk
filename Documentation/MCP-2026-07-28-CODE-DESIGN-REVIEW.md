# MCP 2026-07-28 aggregate code and design review

Date: 2026-08-14

## Scope and baseline

This review covers the complete `swift-sdk-mcp-update-07-28-26` aggregate rather than only its
latest commits. The comparison baseline is the official Swift SDK `main` and release `0.12.1` at
`a0ae212`. At the start of review, the aggregate contained 46 commits across 112 files with 21,573
insertions and 531 deletions.

The review used the released MCP `2026-07-28` specification as the protocol authority and compared
the implementation with current official SDK behavior where useful. It concentrated on wire
correctness, lifecycle interoperability, OAuth issuer boundaries, HTTP behavior, request isolation,
cache privacy, maintainability, and the proposed 12-unit upstream series.

## Outcome

The aggregate review found three submission blockers and five important correctness or process
problems. Every code-level finding was corrected in its owning review unit, all successors were
restacked, and the complete series was smoke-tested at each boundary. There is no follow-up "fix"
unit: each proposed review presents its final behavior the first time a maintainer sees it.

| Finding | Owner | Resolution |
| --- | --- | --- |
| Refresh token could be sent after discovery selected a different authorization server | PR 02 | Retain the stored token through discovery and require its recorded issuer to match before refresh. A two-issuer regression proves the second token endpoint never receives the first issuer's refresh token. |
| Malformed or uncorrelated HTTP 400/404/405 discovery responses did not fall back | PR 03 and PR 05 | The HTTP transport now classifies an unrecognized compatibility response as initialization-era evidence. Client policy remains separate from HTTP parsing. |
| An advertised supported version equal to the first discovery request was not retried | PR 03 and PR 05 | The client now performs the same bounded advertised-version retry used for any mutually supported version. HTTP coverage proves a correlated structured error reaches that policy. |
| The conformance server advertised a custom-header tool without installing its schema on the transport | PR 11 | The executable and transport share one tool definition. An adapter regression and the pinned server scenario verify HTTP 400 and `-32020` behavior. |
| `Accept` media parameters were parsed and discarded | PR 06 | Media parameters now participate in matching and specificity. Parameters after `q` remain media parameters under RFC 9110 rather than obsolete accept extensions. |
| Extension identifiers accepted Unicode letters and digits outside the wire grammar | PR 01 | Identifier validation now uses explicit ASCII predicates with Unicode negative tests. |
| HTTP lifecycle selection was discarded on every reconnect | PR 03 and PR 05 | Automatically selected initialization lifecycles are cached by canonical HTTP origin. A failed cached assumption is removed so a later connection can probe again. |
| The conformance fixture lacked prompt and tool list-change diagnostics | PR 09 and PR 11 | Focused listener tests prove acknowledgment ordering and filter isolation; hidden diagnostic calls await `Server.notify` before returning success. |
| Aggregate follow-ups and PR bodies were ahead of source review branches | Submission workflow | Corrections were moved into their owning units and every successor was restacked. The helper still rejects an explicit `PR-BLOCKER` marker if a future review discovers another propagation gap. |
| Readiness text treated runner scoring as complete specification coverage | PR 11 and PR 12 | Documentation now reports scored status and actual requirement coverage separately. The previously failing custom-header scenario passes all ten checks. |

### Change boundary

No unrelated defect in the released SDK was corrected as part of this review. Every behavioral
change is either in code added by this protocol revision or is the minimum change to an existing
path required to make the new behavior safe:

- the OAuth challenge and proactive-refresh paths now apply the issuer binding introduced by the
  new authorization support;
- automatic lifecycle negotiation now implements the dated HTTP fallback and origin-cache rules;
- advertised-version negotiation now performs the specification's one bounded discovery retry;
- media, extension-identifier, and mirrored-header validation enforce new wire requirements; and
- the conformance executable now configures the new mirrored-header feature that it advertises and
  publishes subscribed prompt and tool changes through normal server routing.

The broader source diff also removes branch-added protocol-history comments that did not match the
repository's DocC style. That is documentation-only. The older stateless request-ID collision,
legacy cancellation work, session/event-ID logging, repeated initialization, raw JSON dispatch,
Windows transport guards, and the existing `NetworkTransport` compiler warning were not changed.
They remain separate upstream issues or pull requests.

## Correctness details

### OAuth issuer binding

Before this review, the `401` path extracted only the refresh-token string and cleared the stored
token before rediscovery. A challenge can legitimately change authorization servers at the same
protected-resource metadata URL. The old refresh token could therefore be sent to the newly
selected token endpoint.

The authorizer now compares the stored token's exact `authorizationServerIssuer` with the selected
issuer before refresh. Legacy stored records fall back to the existing authorization-server URL
comparison. Proactive refresh uses the same check. A mismatch clears the token and continues with a
fresh grant for the selected issuer.

This implements the requirement that credentials and tokens remain separate per authorization
server.[^authorization-server-discovery]

### Lifecycle fallback and origin reuse

The dated HTTP binding says that an empty body or any body that is not a recognized modern JSON-RPC
error on a compatibility response selects initialization. The prior implementation handled only an
empty body. Plain text, malformed JSON, a missing response ID, or a mismatched response ID on HTTP
400/404/405 now follows the specification.[^streamable-http]

Authorization failures, HTTP 408/429/5xx, network failures, and cancellation remain inconclusive.
Recognized `HeaderMismatch`, `MissingRequiredClientCapability`, and
`UnsupportedProtocolVersionError` responses remain modern evidence.

The client also retains an automatically selected initialization lifecycle by HTTP origin. A new
transport to the same origin initializes directly instead of issuing another modern-era probe. If
that cached initialization attempt fails, the entry is removed; the next connection probes again.
The cache is client-local and contains only the lifecycle, not capabilities, server identity,
credentials, paths, queries, or fragments.[^versioning]

### HTTP media values

The parser keeps media parameters, treats them as part of representation matching, and includes the
parameter count in precedence among otherwise equally specific ranges. It processes `q` as weight
regardless of its order, as RFC 9110 recommends. It rejects whitespace around `=` because that is
not part of the parameter grammar.[^rfc-9110-accept]

`Content-Type` continues to accept parameters on an `application/json` request because the request
body representation carries those parameters. For `Accept`, a parameterized-only JSON range does
not authorize an unparameterized JSON response; a separate unparameterized range does.

### Advertised-version retry

A correlated `UnsupportedProtocolVersionError` can advertise a version that is mutually supported
but equal to the version in the first discovery request. That is internally inconsistent server
behavior, but the versioning rules still direct clients to retry an advertised supported version.
The client now does so at most once, using a fresh JSON-RPC ID and the same version metadata.

The retry applies only to idempotent `server/discover`. Authentication failures, transient transport
failures, malformed or uncorrelated responses, and cancellation do not enter this path. A second
structured rejection is surfaced without initialization fallback or a third request.

### Custom request headers

The conformance executable now uses the same `Tool` value for `tools/list` and transport header
validation. Missing, malformed, or mismatched `Mcp-Param-*` fields are rejected before method
dispatch with HTTP 400 and JSON-RPC error code `-32020`.[^streamable-http]

The migration guide also states the privacy boundary: Base64 is syntax-safe encoding, not
confidentiality. Mirrored values can be visible to proxies, gateways, access logs, and tracing
systems. Tool authors should not annotate credentials, tokens, personal content, or unrestricted
user input.

### Conformance subscription diagnostics

The prompt-change and tool-change diagnostics remain hidden handler cases rather than entries in
`tools/list`, preserving the public fixture and frozen 2025 results. Each case upgrades the weak
server reference, awaits the corresponding `Server.notify` publication, and returns success only
after publication completes. They introduce no persistent mutation, detached work, delay, or direct
transport write.

### Extension identifiers

Swift `Character.isLetter` and `isNumber` are Unicode-aware. The protocol name grammar is explicitly
ASCII. The validator now permits only ASCII letters and digits plus the punctuation allowed in each
segment. Tests reject Unicode in both the prefix and name.

## Security, privacy, and authorization analysis

This analysis is Phase 8 of the overall follow-up plan and is a release gate for the affected review
units.

### Assets and trust boundaries

- OAuth client secrets, private-key assertions, authorization codes, access tokens, and refresh
  tokens cross resource-server and authorization-server boundaries.
- Protected-resource metadata, authorization-server metadata, redirects, and endpoint overrides
  cross network trust boundaries and can influence subsequent credential transmission.
- `Mcp-Method`, `Mcp-Name`, and `Mcp-Param-*` values cross application, proxy, gateway, logging, and
  routing boundaries.
- HTTP request contexts, response streams, progress, cancellation, and JSON-RPC IDs cross
  concurrent-request boundaries.
- Private cached results cross time and retry boundaries and must remain partitioned by the identity
  that completed the successful attempt.

### Controls verified

- OAuth discovery requires HTTPS except for the deliberate loopback allowance, validates resource
  identity and authorization-server metadata issuer equality, and rejects private-network endpoint
  misuse through the configured URL policy.
- Authorization redirect handling validates redirect URI, state, and RFC 9207 issuer information.
- Configured and dynamically registered credentials remain issuer-bound. Client ID Metadata
  Documents are portable only when the authorization server advertises support.
- Stored refresh tokens are never sent after a change in selected issuer.
- HTTP standard and schema-derived headers are validated against the request body before dispatch.
- The per-request transport replaces external JSON-RPC IDs with private routing IDs and retains the
  original ID only for application-visible context and the response envelope.
- Request-scoped streams and cancellation remove their HTTP context and routing state on completion
  or disconnect.
- Private cache entries use the authorization context from the completed attempt, including an
  authentication retry. Public cache entries are separated from private partitions. Reconnect and
  connection-generation changes invalidate connection-scoped cache state.
- Logs inspected in the changed authorization and per-request HTTP paths do not emit bearer tokens,
  refresh tokens, client secrets, authorization codes, or request bodies.
- Advertised-version retry is limited to one correlated, structured rejection of an idempotent
  discovery request and cannot retry authentication, transport, malformed-data, or cancellation
  failures.
- Conformance list-change diagnostics are localhost-only, retain no state or credentials, and use
  ordinary subscription filtering and correlation.

### Remaining upstream risks

The older `StatelessHTTPServerTransport` still keys waiters and request contexts by the external
JSON-RPC ID. Concurrent clients can collide. This predates the new transport and is already covered
by official issues and competing fixes. It should be resolved through the active upstream work
rather than expanded inside this series. Session IDs and SSE event IDs are also logged by existing
legacy transport code; deployments should treat debug logs as sensitive until that older behavior
is reviewed separately.

## Official Swift SDK issue and PR coordination

GitHub status was rechecked on 2026-08-14. Every issue and pull request listed in this section was
open at that time.

Direct implementation references:

- [#245](https://github.com/modelcontextprotocol/swift-sdk/issues/245), SEP-2575, is the umbrella for
  the stateless lifecycle work.
- [#228](https://github.com/modelcontextprotocol/swift-sdk/issues/228), reported by
  `@caomengxuan666`, maps directly to request-header unit 08.
- OAuth unit 02 covers [#241](https://github.com/modelcontextprotocol/swift-sdk/issues/241),
  [#240](https://github.com/modelcontextprotocol/swift-sdk/issues/240),
  [#239](https://github.com/modelcontextprotocol/swift-sdk/issues/239),
  [#236](https://github.com/modelcontextprotocol/swift-sdk/issues/236),
  [#242](https://github.com/modelcontextprotocol/swift-sdk/issues/242),
  [#186](https://github.com/modelcontextprotocol/swift-sdk/issues/186), and
  [#185](https://github.com/modelcontextprotocol/swift-sdk/issues/185).
- MRTR unit 04 covers [#238](https://github.com/modelcontextprotocol/swift-sdk/issues/238),
  [#244](https://github.com/modelcontextprotocol/swift-sdk/issues/244), and
  [#237](https://github.com/modelcontextprotocol/swift-sdk/issues/237).
- Cache unit 10 covers [#243](https://github.com/modelcontextprotocol/swift-sdk/issues/243).
- Wire unit 01 relates to [#234](https://github.com/modelcontextprotocol/swift-sdk/issues/234) and
  [#233](https://github.com/modelcontextprotocol/swift-sdk/issues/233).

[Issue #222](https://github.com/modelcontextprotocol/swift-sdk/issues/222), reported by `@wcarson`,
is only partially covered. The branch sends the commonly required refresh-token grant declaration,
but it does not expose arbitrary dynamic-registration metadata. It should not be described as
closed without agreement on that public configuration.

Active overlaps to reconcile before submission:

| Upstream PR | Contributor | Relationship |
| --- | --- | --- |
| [#264](https://github.com/modelcontextprotocol/swift-sdk/pull/264) | `@jstar0` | Transparent isolation for colliding stateless HTTP request IDs; closest to the new transport's private routing IDs. |
| [#267](https://github.com/modelcontextprotocol/swift-sdk/pull/267) | `@jpurnell` | Rejects duplicate in-flight IDs with HTTP 409. Select one collision strategy rather than combining both. |
| [#260](https://github.com/modelcontextprotocol/swift-sdk/pull/260), [#268](https://github.com/modelcontextprotocol/swift-sdk/pull/268) | `@ianegordon`, `@jpurnell` | Complete cancelled HTTP exchanges; rebase on the selected collision solution. |
| [#270](https://github.com/modelcontextprotocol/swift-sdk/pull/270) | `@dariuscorvus` | Early-cancellation and duplicate-request handling in `Server.swift`. |
| [#271](https://github.com/modelcontextprotocol/swift-sdk/pull/271) | `@lionheart-jhanke` | Windows guards in `HTTPClientTransport`; land or rebase before unit 05. |
| [#269](https://github.com/modelcontextprotocol/swift-sdk/pull/269) | `@shoemoney` | Conformance resource-template correction; land or rebase before unit 11. |
| [#273](https://github.com/modelcontextprotocol/swift-sdk/pull/273) | `@steipete` | Raw JSON dispatch overlap in `Server.swift`; coordinate rather than folding unrelated behavior into this series. |
| [#257](https://github.com/modelcontextprotocol/swift-sdk/pull/257) | `@VictorPuga` | Repeated initialization; keep separate from lifecycle discovery policy. |

PRs #264 and #267 both address [#254](https://github.com/modelcontextprotocol/swift-sdk/issues/254)
and [#265](https://github.com/modelcontextprotocol/swift-sdk/issues/265). PRs #260 and #268 both
address [#255](https://github.com/modelcontextprotocol/swift-sdk/issues/255). Those are competing
solutions, not four independent changes to combine.

Useful outreach is to `@jstar0`, `@vectory-eric`, `@ianegordon`, `@jpurnell`, and
`@dariuscorvus`, offering the new transport's private routing and cancellation tests as reference
code and retaining attribution for any incorporated work. No outreach was sent as part of this
review.

## Upstream review-unit order

The regenerated source branches are ready in this order. Active upstream overlaps should be
rechecked immediately before each corresponding submission:

1. Wire models, including ASCII extension identifier validation.
2. OAuth issuer validation, including refresh-token binding.
3. Discovery and negotiation, owning lifecycle policy, the bounded advertised-version retry, and
   the origin cache.
4. Multi-round-trip requests.
5. HTTP client, owning HTTP response evidence, the origin cache key, and transport-boundary retry
   coverage.
6. HTTP server, including RFC 9110 media matching.
7. HTTP lifecycle router.
8. Tool request headers.
9. Subscriptions, including prompt/tool filter-isolation coverage.
10. Response caching.
11. Conformance, including the shared custom-header tool configuration and hidden list-change
    diagnostics.
12. Defaults and concise migration/release documentation.

Transport code should report evidence; client code should select the protocol era. Header-schema
mechanics should remain separate from the conformance application that configures them.

## Documentation disposition

The handoff, next-session prompt, research record, and detailed implementation record are contributor
working records. They should remain in the fork or issue tracker rather than being included in the
upstream SDK PRs. Upstream-facing material should be limited to focused PR descriptions, the README,
a concise migration guide, release notes, and any short coverage matrix maintainers request.

The aggregate review removed the proposed `Since: MCP 2026-07-28` DocC convention. Protocol revision
history belongs in migration and release material; public symbols now use the repository's existing
behavior-focused DocC style.

## Verification

- `swift test --filter OAuthAuthorizerTests`: 21 tests passed, including the two-issuer refresh
  boundary regression.
- `swift test --filter 'HTTPRequestValidationTests|Protocol20260728Tests|PerRequestHTTPClientTransportTests'`:
  56 tests passed.
- `swift test --filter HTTPHandlerTests`: 6 adapter tests passed.
- Pinned initialization-based run: 223 client checks and 47 server checks passed with no failure or
  warning.
- Pinned 2026 run: 424 client and 168 server checks passed with no scored failure or warning. The 13
  client and 25 server failures are explicitly unscored Tasks, authorization-extension, or
  post-release JSON Schema coverage.
- Full `swift test`: 750 SDK tests in 51 suites and 6 adapter tests in 1 suite passed.
- `swift package generate-documentation --target MCP --warnings-as-errors` succeeded. Compilation
  still reports the pre-existing `NetworkTransport` implicit-capture warning; this branch does not
  change that unrelated implementation.

[^authorization-server-discovery]: [MCP 2026-07-28: Authorization Server Discovery](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery)
[^streamable-http]: [MCP 2026-07-28: Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
[^versioning]: [MCP 2026-07-28: Versioning and Compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
[^rfc-9110-accept]: [RFC 9110 section 12.5.1: Accept](https://www.rfc-editor.org/rfc/rfc9110.html#section-12.5.1)
