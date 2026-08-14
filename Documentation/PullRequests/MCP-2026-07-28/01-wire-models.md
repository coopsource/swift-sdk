# Add MCP 2026-07-28 wire models

## Summary

- add the `2026-07-28` protocol vocabulary without enabling the new lifecycle
- add structured remote errors, result and cache models, capability extensions, and resource-link fields
- add fixtures copied from the tagged specification and record their provenance
- enforce the dated specification's ASCII grammar for extension identifiers

## Specification coverage

- `schema.ts`: `ClientCapabilities`, `ServerCapabilities`, `ToolResultContent`, `ResourceLink`,
  structured errors, result types, and cache/subscription vocabulary
- `basic/index#meta`
- `basic/versioning#extensions`

## Compatibility

This review unit does not change protocol selection or transport behavior. Existing APIs remain
available. The added trailing resource-link associated values have defaults, but exhaustive enum
patterns that spell every associated value may require a source update.

No dependency, platform, or Swift requirement is added. Both package manifests only exclude the
non-source fixture directory from the test target.

## Review guide

The authoritative source is specification tag `2026-07-28` at commit
`5f5440bb26a62e2cf3440b92da5a667efa03b267`. Review the model names and wire keys first, then compare
the fixture provenance recorded alongside the tests. Extension identifiers admit only the ASCII
letters, digits, and punctuation in the dated wire grammar; Swift's broader Unicode character
classes are intentionally not used.

## Testing

- existing initialization-based test suite
- official discovery, structured-error, and resource-link fixture decoding
- open capability and object-valued extension round trips, including rejection of scalar settings
- arbitrary and explicit-null sampling structured content
- ASCII boundary and Unicode-negative extension identifier cases
- `Protocol20260728Tests`: 12 tests passed on macOS
