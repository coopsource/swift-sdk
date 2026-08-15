# Add per-request metadata HTTP server

## Summary

- add a framework-neutral `StreamableHTTPServerTransport` for the per-request-metadata lifecycle
- validate method, Origin, Accept, Content-Type, version, metadata, and request headers before dispatch
- honor a cancellation that arrives before a request registers its handler task, from either the
  `notifications/cancelled` message or a request-scoped transport reporting a disconnect
- parse media types, parameters, wildcards, precedence, and quality values for HTTP validation
- return direct JSON until a related notification requires request-scoped SSE
- isolate reused client request IDs and propagate stream cancellation to server work

## Specification coverage

- `basic/transports/streamable-http#message-flow`
- `basic/transports/streamable-http#security-warning`
- `basic/transports/streamable-http#cancellation`
- `basic/index#meta` request requirements and JSON-RPC invalid-parameter errors

## Compatibility

The existing stateful and stateless HTTP server transports keep their initialization-based request
handling. They gain a required-label `originValidator:` initializer overload and report their
binding's protocol versions to `Server`, and `HTTPResponse` gains a `dataWithStatus` case for
JSON-RPC bodies returned with a non-200 status; an adapter that switches exhaustively over
`HTTPResponse` needs that case, which Appendix A.7 of the migration guide records. The new
transport is a separate public type because session state and request-scoped stateless behavior cannot be
combined safely behind the old transport's public surface.

## Review guide

Trace the generated routing ID from HTTP input through `Server.HandlerContext` and back to the original
client ID. Check every waiter completion path, especially cancellation before dispatch, stream closure,
server shutdown, unknown methods, and malformed requests.

## Testing

- direct JSON, request-scoped notifications, and SSE completion
- concurrent clients reusing an ID and completing out of order
- cancellation before work and after streaming begins
- missing or malformed required request metadata, version-header disagreement, and JSON-RPC
  invalid-parameter mapping
- validation failures and exact HTTP status/error body preservation
- case-insensitive media types, exact suffix rejection, valid parameters, `q=0`, wildcard
  precedence, duplicate ranges, and malformed `Accept` and `Content-Type` syntax
- 66 tests across the HTTP server transport suites, 9 media-validation tests, and 7 cancellation
  tests passed on macOS; focused tests passed on Linux
- a cancellation delivered while a request is parked before handler registration leaves the handler
  unrun; the test fails against the previous ordering


## Related upstream pull requests

- **[#270](https://github.com/modelcontextprotocol/swift-sdk/pull/270) — early request cancellation
  race.** The ordering defect it identifies is real, and this unit now fixes it: a cancellation that
  arrives before a request registers its handler task is recorded against the same pre-dispatch
  ledger the transport path uses, instead of being dropped. #270 bundles that fix with a
  duplicate-request-id rejection that regresses multi-client traffic (see #254), which this unit does
  not adopt. [triage §#270](https://github.com/coopsource/swift-sdk/blob/swift-sdk-mcp-update-07-28-26/Documentation/MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md#pr-270) and
  [the finding](https://github.com/coopsource/swift-sdk/blob/swift-sdk-mcp-update-07-28-26/Documentation/MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md#cancellation-gap).
- **[#264](https://github.com/modelcontextprotocol/swift-sdk/pull/264) /
  [#267](https://github.com/modelcontextprotocol/swift-sdk/pull/267) — colliding stateless request
  ids.** #264 independently arrives at the same routing-id isolation this unit's transport uses;
  #267 instead rejects colliding ids, which punishes a conformant second client. Recommendation and
  the defects to fix in #264 first: [triage §#264 vs #267](https://github.com/coopsource/swift-sdk/blob/swift-sdk-mcp-update-07-28-26/Documentation/MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md#collision).
- **[#260](https://github.com/modelcontextprotocol/swift-sdk/pull/260) /
  [#268](https://github.com/modelcontextprotocol/swift-sdk/pull/268) — cancelled exchange hangs.**
  Legacy-transport only; both apply cleanly alongside this unit. The equivalent case here is handled
  by treating a client disconnect as cancellation. [triage §#260 vs #268](https://github.com/coopsource/swift-sdk/blob/swift-sdk-mcp-update-07-28-26/Documentation/MCP-2026-07-28-UPSTREAM-PR-TRIAGE.md#cancelled-exchange).
