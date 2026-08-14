# Add MCP subscription streams

## Summary

- add `subscriptions/listen` models and client subscription APIs
- acknowledge each filter before delivering correlated notifications
- support concurrent filtered listeners and request-scoped logging
- reconnect explicit client registrations with the same subscription ID
- replace removed resource subscribe/unsubscribe behavior for 2026-07-28

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
- malformed, duplicated, and mismatched correlation metadata
- explicit reconnect, cancellation, abrupt closure, and graceful shutdown
- request-scoped logging thresholds
- bounded slow-listener failure and FIFO publisher backpressure
- cancellation and server shutdown while publishers are suspended
- 14 subscription tests, 35 HTTP client tests, and 20 streamable HTTP server tests passed on
  macOS; affected tests passed on Linux
