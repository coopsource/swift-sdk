# Add MCP request header validation

## Summary

- generate the standard `Mcp-Method`, `Mcp-Name`, and schema-derived `Mcp-Param-*` headers
- derive only statically reachable, protocol-supported JSON Schema properties
- validate exact encoding on the server and return structured `HeaderMismatch` errors
- refresh a changed tool schema and retry one constrained tool call with a fresh request ID

## Specification coverage

- `basic/transports/streamable-http#request-headers`
- `basic/transports/streamable-http#case-sensitivity`
- `server/tools` `x-mcp-header` schema annotations and `HeaderMismatch` recovery
- RFC 9110 field-name and optional-whitespace rules referenced by the specification

## Compatibility

Header generation is confined to the per-request HTTP path. Invalid `x-mcp-header` annotations remove
only the affected tool from the transport's validated tool definitions. Earlier HTTP behavior and the
public `Transport` protocol remain unchanged.

This unit depends directly on the HTTP client and multi-round-trip logical-attempt machinery, even though
the latter dependency is transitive in the current linear stack.

## Review guide

Compare every supported scalar and null case against the tagged specification fixtures. Pay particular
attention to safe integers, numeric comparison, Base64 sentinels, case-insensitive header names,
case-sensitive values, optional whitespace, and schema reachability through nested objects.

## Testing

- standard and schema-derived exact encodings
- absent, null, unsafe numeric, and unsupported schema values
- server mismatch responses and request ID preservation
- optional-whitespace normalization with case-sensitive values
- client-scoped learned schemas across independent connections and authorization contexts
- one stale-schema refresh and no retry for unrelated mismatches
- 11 header-schema tests, 33 HTTP client tests, and 19 streamable HTTP server tests passed on
  macOS; focused tests passed on Linux
