# Add MCP per-request protocol negotiation

## Summary

- add client and server runtime protocol modes
- add `server/discover`, required per-request metadata, `resultType`, and structured protocol errors
- probe and fall back for automatic clients while retaining explicit lifecycle-only modes
- retry one mutually supported advertised version, including the originally requested version
- classify a correlated non-modern discovery error as initialization-era evidence without
  broadening fallback to ordinary failed operations
- reject a `resultType` the client does not recognize, and reject `initialize` on a request that
  carries per-request metadata
- keep the initialization-era Streamable HTTP transports on their own protocol-version set as the
  supported set grows
- expose `Client.ConnectionInfo` and extend `Server.HandlerContext` with request lifecycle data

## Specification coverage

- `basic/versioning#protocol-version-negotiation`
- `basic/versioning#backward-compatibility-with-initialization-based-versions`
- `basic/index#meta` and `basic/index#resulttype`
- `server/discover`
- `basic/patterns/cancellation#transport-specific-cancellation`

## Scope

This pull request establishes the lifecycle policy and its stdio-style probe. The HTTP evidence
that feeds the policy — correlated status classification, request-scoped SSE, and the client-local
per-origin lifecycle cache — arrives with the HTTP client transport in PR 05, and the per-request
HTTP server binding arrives in PR 06. On this branch an automatic client over HTTP surfaces a
discovery failure rather than classifying it by status.

## Compatibility

The public `Transport` actor and raw `Data` boundary are unchanged. `connect(transport:)` remains as a
compatibility wrapper, while `connectWithInfo(transport:)` exposes the selected lifecycle. Serialized
configuration without a protocol mode decodes as initialization-only.

New programmatic configurations default to initialization-only; applications explicitly opt in after
both lifecycles are complete.

Adding `2026-07-28` to `Version.supported` would otherwise widen what the existing Streamable HTTP
server transports accept in an `MCP-Protocol-Version` header, so this change also introduces
`Version.streamableHTTPSupported(for:)` and pins the stateful and stateless transports to the
initialization-based Streamable HTTP revisions. `2024-11-05` remains excluded from that binding
because it uses the deprecated HTTP+SSE transport.

## Review guide

Concentrate on the fallback classification table: a discovery result or recognized 2026 error keeps the
new lifecycle; only a conclusive earlier-server response may start initialization. A correlated error to
the mandatory probe is conclusive when it is not recognized modern evidence; auth, transient, network,
and cancellation failures remain inconclusive. Check that version and capability state is attached
to each handler without changing handler signatures. The client owns lifecycle policy; transports
provide identity and response evidence without making that policy decision.

An advertised-version retry is limited to one correlated structured `-32022` response to the
idempotent discovery request. It does not apply to authentication, transient transport, malformed
data, or cancellation failures, and a second rejection is surfaced without fallback or another
retry.

`resultType` handling follows `basic/index#resulttype`: an absent value is treated as `complete`,
`complete` and `input_required` are recognized, and any other value is invalid. `input_required`
becomes actionable in PR 04; here it is simply recognized rather than rejected.

## Testing

- per-request-only, initialization-only, and combined servers
- every supported initialization-based revision and both incompatible lifecycle-only combinations
- malformed and missing metadata and unsupported versions
- authentication, transient, and cancellation failures that must not fall back, plus every
  recognized protocol error that must not fall back
- stdio-style discovery cancellation with and without an SDK timeout
- absent, unrecognized, and malformed `resultType` plus `-32022` with no common revision
- `initialize` carrying per-request metadata is rejected without starting initialization
- same-version advertised retry with a fresh JSON-RPC ID, unchanged metadata, and no initialization;
  a distinguishable second rejection proves the one-retry bound
- the Streamable HTTP version partition excludes the deprecated HTTP+SSE revision
- strict dual-lifecycle notification ordering, serialized configuration compatibility, and
  `ConnectionInfo`
- `VersioningTests`: 13 tests and `ProtocolNegotiationTests`: 23 tests passed on macOS


## Related upstream pull requests

- **[#257](https://github.com/modelcontextprotocol/swift-sdk/pull/257) — make `initialize`
  idempotent.** Directly opposed to this unit: #257 deletes the already-initialized guard, while
  this unit hardens `initialize` as a one-shot, era-selecting operation and rejects it outright on a
  request that carries per-request metadata. Under `2026-07-28` an `initialize` selects the legacy
  era for the session, so making it repeatable would let a client change era mid-session. Analysis
  and the alternative this unit suggests (idempotency at the stateless transport, per issue #219):
  [triage §#257](https://github.com/coopsource/swift-sdk/blob/swift-sdk-mcp-update-07-28-26/Documentation/MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md#pr-257).
- **[#264](https://github.com/modelcontextprotocol/swift-sdk/pull/264) /
  [#267](https://github.com/modelcontextprotocol/swift-sdk/pull/267)** both modify
  `StatelessHTTPServerTransport`, which this unit also touches to pin the initialization-era
  Streamable HTTP version set. Textual overlap only, on the actor declaration:
  [triage §#264 vs #267](https://github.com/coopsource/swift-sdk/blob/swift-sdk-mcp-update-07-28-26/Documentation/MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md#collision).
