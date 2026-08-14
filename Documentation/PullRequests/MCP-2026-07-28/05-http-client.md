# Add per-request metadata HTTP client

## Summary

- add an isolated one-POST-per-message path to `HTTPClientTransport`
- accept direct JSON or request-scoped SSE responses on Apple and Linux
- add request cancellation, response ID and content-type validation, and lifecycle detection
- identify HTTP endpoints by canonical origin for client-owned lifecycle reuse
- expose `enableStandaloneGetStream` while retaining the deprecated explicit `streaming:` label
- serialize authorization preparation and challenge handling across concurrent requests

## Specification coverage

- `basic/transports/streamable-http#sending-messages-to-the-server`
- `basic/transports/streamable-http#receiving-messages-from-the-server`
- `basic/transports/streamable-http#cancellation`
- the Server-Sent Events processing rules linked by the transport specification

## Compatibility

The existing initialization-based EventSource, session ID, GET stream, replay, and DELETE behavior is
retained. The client selects the transport path through a package-scoped lifecycle update hook; the
public `Transport` requirement is unchanged.

`enableStandaloneGetStream` controls only the initialization-era standalone GET stream. Modern POST
responses can still select request-scoped SSE when that property is false. The old explicit
`streaming:` initializer forwards to the canonical spelling without retaining a default argument.

This branch is physically stacked after multi-round-trip support but its transport behavior logically
depends on discovery negotiation, with OAuth behavior supplied by the issuer-validation review unit.

## Review guide

Review direct JSON and SSE as separate completion paths. For each, check partial network chunks,
authentication challenges, cancellation before and after response headers, response correlation, and
cleanup of the URLSession task.

## Testing

- JSON and chunk-split SSE responses
- cancellation before headers and during streaming
- concurrent out-of-order responses
- serialized authorization, shared refresh, and exact retry limits
- leading UTF-8 BOM split across network chunks
- automatic lifecycle classification for correlated errors carried by HTTP 200/400/404/405,
  fallback for malformed or uncorrelated 400/404/405 responses, non-fallback 401/403/408/429/500,
  and initialization-safe transport defaults
- canonical and compatibility standalone GET configuration, automatic-fallback GET startup,
  modern state clearing, and request-scoped SSE independence
- 80 HTTP client and per-request client transport tests passed on macOS; focused streaming and
  cancellation tests passed on Linux
