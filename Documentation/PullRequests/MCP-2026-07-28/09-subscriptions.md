# Add MCP subscription streams

## Summary

- add `subscriptions/listen` models and client subscription APIs
- acknowledge each filter before delivering correlated notifications
- support concurrent filtered listeners and request-scoped logging
- cover prompt-only and tool-only publication through normal server notification routing
- reconnect explicit client registrations with the same subscription ID
- replace removed resource subscribe/unsubscribe behavior for 2026-07-28
- reject the methods and notifications the dated revision removes — `initialize`, `ping`,
  `logging/setLevel`, resource subscribe/unsubscribe, `notifications/initialized`, and
  roots list-changed — on a per-request connection
- normalize the deprecated roots capability in per-request metadata
- clear connection-scoped state for a change notification even when no subscriber can receive it

## Specification coverage

- `basic/patterns/subscriptions#acknowledgment`
- `basic/patterns/subscriptions#multiple-concurrent-subscriptions`
- `basic/patterns/subscriptions#cancellation`
- `basic/patterns/subscriptions#graceful-closure`
- `server/utilities/logging` request-scoped logging

## Compatibility

Initialization-based resource subscriptions, GET streams, logging level requests, and other earlier
revision behavior remain available when that lifecycle is selected. The new client registration survives
an explicit disconnect until the caller cancels it.

This unit depends on both HTTP paths and the lifecycle router. Response-cache invalidation is added by the
following review unit so the subscription diff remains focused on delivery semantics.

## Review guide

Treat acknowledgment, notification delivery, graceful response, abrupt disconnect, cancellation, and
reconnect as one ordered stream. Confirm filters are enforced by both sender and receiver and that every
delivered message carries the original client subscription ID rather than an internal routing ID.

## Testing

- acknowledgment-before-notification ordering
- concurrent listeners and filter isolation
- prompt and tool acknowledgments consumed before publication, with each notification carrying only
  its listener's request ID and no cross-filter delivery
- malformed, duplicated, and mismatched correlation metadata
- explicit reconnect, cancellation, abrupt closure, and graceful shutdown
- request-scoped logging thresholds
- bounded slow-listener failure and FIFO publisher backpressure
- cancellation and server shutdown while publishers are suspended
- 15 subscription tests, 36 HTTP client tests, and 20 streamable HTTP server tests passed on
  macOS; the full 736-test suite passed on the PR 09 branch
