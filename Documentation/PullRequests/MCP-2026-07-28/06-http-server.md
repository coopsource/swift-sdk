# Add per-request metadata HTTP server

## Summary

- add a framework-neutral `StreamableHTTPServerTransport` for the per-request-metadata lifecycle
- validate method, Origin, Accept, Content-Type, version, metadata, and request headers before dispatch
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
- 66 tests across the HTTP server transport suites and 8 media-validation tests passed on macOS;
  focused tests passed on Linux
