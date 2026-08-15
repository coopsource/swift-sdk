# Finalize MCP 2026-07-28 release defaults

## Summary

- keep new clients and servers initialization-only until applications explicitly opt in
- make `Version.latest` identify `2026-07-28`
- keep initialization requests and session transports on `Version.latestInitializationVersion`
- retain initialization-only decoding for stored configurations that omit `protocolMode`
- document the established `connect(transport:)` identity placeholder while preserving omitted
  identity as `nil` through `connectWithInfo(transport:)`
- add a weather-service migration guide with minimal and full client and server examples
- show handler-emitted progress whose work completes within the handler lifetime
- document public API behavior and protocol constraints using the repository's existing DocC style,
  and update affected specification links

## Specification coverage

- `basic/versioning#protocol-version-negotiation`
- `basic/versioning#backward-compatibility-with-initialization-based-versions`

The migration guide also links the applicable discovery, multi-round-trip, subscription, caching,
Streamable HTTP, tool, elicitation, and OAuth sections at the point where each behavior is
introduced.

## Compatibility

Newly constructed and decoded configurations both remain initialization-only, and callers select an
explicit mode for A/B testing or staged rollout. Initialization-specific APIs never derive their wire
version from `Version.latest` after the flip.

Existing tests that specifically cover initialization-only methods now say so at construction time.
This keeps their meaning stable rather than changing those tests to exercise a lifecycle in which the
methods are not defined. No dependency, platform requirement, or minimum Swift requirement is added.
The compatibility `connect(transport:)` result remains non-optional as established by the SDK. When
a per-request server omits its optional identity, its documented `unknown` / `0.0.0` values are
placeholders rather than peer-reported identity; `connectWithInfo(transport:)` preserves `nil`.

## Review guide

Review this PR independently from conformance plumbing. Confirm every use of
`latestInitializationVersion` is at an initialization or established-session boundary, then review the
default-to-default initialization path and the explicitly configured automatic and combined paths.
Review the public API comments as a documentation-only
commit, then review the migration guide as a separate commit. The guide follows the README's
weather-service examples and identifies source-compatibility, security, lifecycle, cache,
subscription, HTTP, and OAuth risks introduced by the earlier feature PRs.
Its progress example reuses the caller's token, awaits every notification, and returns only after
progress work finishes so a modern request-scoped SSE response remains open for the full sequence.

## Testing

- complete programmatic and serialized configuration-default assertions
- migration client, server, multi-round-trip, cache, subscription, and tool-header examples
  type-check with compiler warnings treated as errors
- DocC generation with `--warnings-as-errors`
- 750 SDK tests in 51 suites plus 6 adapter tests in 1 suite on macOS after aggregate-review
  corrections
- 638 tests available in the official Swift 6.1.3 Linux image
- MCP target build with the official Swift 6.0.3 Linux image
- static Linux server link without a new warning attributable to this work
- every scored alpha.11 `2026-07-28` conformance requirement
- alpha.11 local report: 424 client and 168 server checks passed, with zero scored warnings or
  failures; 13 client and 25 server failures remain explicitly unscored
- initialization-based `v0.1.15`: 223 client checks and 47 server checks with no unexpected failure
