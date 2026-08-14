# Route HTTP requests by MCP lifecycle

## Summary

- add `LifecycleHTTPServerRouter` for one endpoint that supports both lifecycle mechanisms
- route per-request metadata to one stateless server transport
- retain the application's existing initialization and session factory for earlier revisions
- keep lifecycle-only modes available for A/B testing and staged rollout

## Specification coverage

- `basic/versioning#backward-compatibility-with-initialization-based-versions`
- `basic/transports/streamable-http`
- the version and lifecycle routing requirements in `basic/index#meta`

## Compatibility

The router does not own either server lifecycle and does not replace the stateful transport. Existing
HTTP applications can keep their session implementation and add the router at the framework adapter
boundary.

This unit requires both HTTP transport paths. It does not change protocol models or handler APIs.

## Review guide

Review routing precedence for body metadata, `initialize`, known version headers, old session headers,
and unrecognized versions. Malformed requests that show per-request intent must stay on the validation
path that returns a structured 2026 error.

## Testing

- per-request and initialization openings on one endpoint
- per-request metadata taking precedence over stale session headers
- malformed per-request-metadata openings and unknown versions
- lifecycle-only router modes
- `LifecycleHTTPServerRouterTests`: 9 tests passed on macOS; focused tests passed on Linux
