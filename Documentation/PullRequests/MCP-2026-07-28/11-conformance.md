# Add MCP 2026-07-28 conformance coverage

## Summary

- add separately selectable client and server conformance adapters for `2026-07-28`
- test the NIO HTTP adapter's ordering, cancellation, write failure, and concurrent-request behavior
- pin the new runner to `@modelcontextprotocol/conformance@0.2.0-alpha.11`
- keep the initialization-based runner independently pinned to `v0.1.15`
- collect scenario results and logs without hiding unscored failures behind a baseline
- run the new suite in CI and upload its results and server log as artifacts
- add hidden prompt-change and tool-change diagnostics that publish through `Server.notify`

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

The list-change diagnostics are handler-only cases and do not alter `tools/list` or frozen 2025 tool
results. Each upgrades the weak server reference, awaits `Server.notify`, and returns success only
after the subscription publisher accepts the notification for delivery; no detached task, delay,
fixture mutation, or direct transport write is used.

The alpha.11 run passes every scored requirement. The server also passes all ten checks in the
released custom-header validation scenario. Remaining server failures are confined to the
unimplemented Tasks extension; client failures remain visible in the generated artifacts and are
reported separately from runner scoring.

## Testing

- 6 direct asynchronous NIO adapter tests on macOS and Linux
- 754 SDK tests in 51 suites before the default flip
- focused `ProtocolNegotiationTests`: 27 and `SubscriptionTests`: 15
- both conformance executable products build independently
- build both conformance executables as part of `swift test`
- `HTTPHandlerTests`: 6 adapter tests passed on macOS
