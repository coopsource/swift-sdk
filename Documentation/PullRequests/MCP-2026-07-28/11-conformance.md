# Add MCP 2026-07-28 conformance coverage

## Summary

- add separately selectable client and server conformance adapters for `2026-07-28`
- test the NIO HTTP adapter's ordering, cancellation, write failure, and concurrent-request behavior
- pin the new runner to `@modelcontextprotocol/conformance@0.2.0-alpha.11`
- keep the initialization-based runner independently pinned to `v0.1.15`
- collect scenario results and logs without hiding unscored failures behind a baseline

## Specification coverage

- `basic/transports/streamable-http#receiving-messages-from-the-server`
- `basic/transports/streamable-http#cancellation`
- `basic/patterns/cancellation#transport-specific-cancellation`
- all scored `2026-07-28` conformance requirements selected by `--requirements 2026-07-28`

## Compatibility

This review unit changes no `Sources/MCP` implementation and does not flip SDK defaults. Both
conformance executables select their lifecycle explicitly, so the earlier suite remains independent
of the default change in the following PR. A package-only support target exposes the existing NIO
adapter to tests without adding a library product or production dependency.

## Review guide

Review the adapter task lifetime first: channel closure, inbound error, and failed writes must cancel
request-scoped work, and all response writes must retain head/body/end order. Then review the runner's
immutable version pin, readiness probe, result preservation, cleanup, and optional baseline handling.

The alpha.11 run passes every scored requirement. The server also passes all ten checks in the
released custom-header validation scenario. Remaining server failures are confined to the
unimplemented Tasks extension; client failures remain visible in the generated artifacts and are
reported separately from runner scoring.

## Testing

- 6 direct asynchronous NIO adapter tests on macOS and Linux
- 715 SDK tests in 50 suites before the default flip
- 2026 client: 423 passing checks; 13 failures limited to five unscored scenarios
- 2026 server: 166 passing checks; 25 failures limited to nine Tasks-extension scenarios
- build both conformance executables as part of `swift test`
- `HTTPHandlerTests`: 6 adapter tests passed on macOS
