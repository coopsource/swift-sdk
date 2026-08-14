# Add MCP response caching

## Summary

- validate required cache fields for complete cacheable results
- add a bounded 512-entry LRU cache with injectable test time
- partition private entries by authorization context and allow public reuse
- add pagination-aware keys, scope consistency checks, notification invalidation, and per-call policy
- exclude multi-round-trip attempts and request-scoped logging from reuse

## Specification coverage

- `server/utilities/caching#cacheable-results`
- `server/utilities/caching#cache-key` and `#cacheable-model`
- `server/utilities/caching#cache-scope-field`
- `server/utilities/caching#interaction-with-notifications` and `#interaction-with-pagination`
- `server/utilities/caching#security-considerations`

## Compatibility

Caching is active only for selected 2026-07-28 cacheable methods and can be disabled at runtime. Existing
method overloads retain their behavior; additive overloads select reload or bypass behavior. Transports
that cannot expose a trustworthy authorization context do not store private responses.

This unit depends directly on multi-round-trip request tracking and on subscriptions for invalidation;
both dependencies should remain explicit if the stack is later rebased into a dependency graph.

## Review guide

Review cache keys and authorization partitions before eviction mechanics. Then trace list pagination,
inconsistent scopes, stale entries, tool/resource notifications, reload, bypass, reconnect, and
multi-round-trip retries.

## Testing

- freshness with a test clock and zero/negative TTL
- LRU eviction and invalid configuration
- exact-attempt private authorization, unavailable custom identity, and public reuse
- caller metadata and mutable capability context in cache keys
- conservative non-reusable defaults for unchanged 2026 handlers
- pagination scope mismatch and invalidation
- notification invalidation and MRTR exclusion
- 15 response-cache tests and 36 HTTP client tests passed on macOS; affected tests passed on Linux
