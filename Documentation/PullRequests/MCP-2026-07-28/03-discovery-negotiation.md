# Add MCP per-request protocol negotiation

## Summary

- add client and server runtime protocol modes
- add `server/discover`, required per-request metadata, `resultType`, and structured protocol errors
- probe and fall back for automatic clients while retaining explicit lifecycle-only modes
- classify correlated non-modern discovery errors as initialization-era evidence without
  broadening fallback to ordinary failed operations
- retain automatically selected initialization lifecycles by transport identity
- expose `Client.ConnectionInfo` and extend `Server.HandlerContext` with request lifecycle data

## Specification coverage

- `basic/versioning#protocol-version-negotiation`
- `basic/versioning#backward-compatibility-with-initialization-based-versions`
- `basic/index#meta` and `basic/index#resulttype`
- `server/discover`
- `basic/patterns/cancellation#transport-specific-cancellation`

## Compatibility

The public `Transport` actor and raw `Data` boundary are unchanged. `connect(transport:)` remains as a
compatibility wrapper, while `connectWithInfo(transport:)` exposes the selected lifecycle. Serialized
configuration without a protocol mode decodes as initialization-only.

New programmatic configurations default to initialization-only; applications explicitly opt in after
both lifecycles are complete.

## Review guide

Concentrate on the fallback classification table: a discovery result or recognized 2026 error keeps the
new lifecycle; only a conclusive earlier-server response may start initialization. A correlated error to
the mandatory probe is conclusive when it is not recognized modern evidence, including an HTTP 200 body;
auth, transient, network, and cancellation failures remain inconclusive. Malformed or uncorrelated
bodies on HTTP 400/404/405 select initialization. Check that version and capability state is attached
to each handler without changing handler signatures. The client owns lifecycle policy and cached
selection; transports provide identity and response evidence without making that policy decision.

## Testing

- per-request-only, initialization-only, and combined servers
- every supported initialization-based revision and both incompatible lifecycle-only combinations
- malformed and missing metadata and unsupported versions
- HTTP 400/404/405 compatibility responses, authentication and transient failures, and every
  recognized protocol error that must not fall back
- stdio-style discovery cancellation with and without an SDK timeout
- absent, malformed, and unsupported `resultType` plus `-32022` with no common revision
- strict dual-lifecycle notification ordering, serialized configuration compatibility, and
  `ConnectionInfo`
- `VersioningTests`: 12 tests and `ProtocolNegotiationTests`: 19 tests passed on macOS
