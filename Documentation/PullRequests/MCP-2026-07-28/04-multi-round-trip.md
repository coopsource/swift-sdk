# Add MCP multi-round-trip requests

## Summary

- add typed `input_required` results and retry parameters to the three supported methods
- process embedded roots, sampling, and elicitation requests concurrently with existing client handlers
- add one aggregate handler for manual processing
- preserve opaque request state, use fresh IDs, validate response maps, and bound automatic rounds
- honor a cancellation issued before a logical request records its first attempt

## Specification coverage

- `basic/patterns/mrtr`
- the multi-round-trip sections of `server/prompts`, `server/resources`, and `server/tools`
- the embedded input request types in `client/roots`, `client/sampling`, and `client/elicitation`

## Compatibility

Existing method handlers remain valid. The additive `MultiRoundTripMethod` marker identifies only
`prompts/get`, `resources/read`, and `tools/call`. Automatic, manual, and disabled client modes make the
new retry behavior selectable at runtime.

This review unit depends on per-request negotiation and is also a direct dependency of the later tool
header retry and response cache work.

## Review guide

Follow one logical request across multiple independent JSON-RPC attempts. Confirm that cancellation
stops embedded work and prevents a retry, response keys cannot cross logical requests, and the opaque
state is copied without interpretation.

## Testing

- concurrent embedded handlers completing out of order
- request-state-only retries and fresh attempt IDs
- missing capabilities, malformed requests, and response-map mismatch
- cancellation, round limits, and concurrent logical requests
- rejection of standalone roots, sampling, and elicitation requests at both client and server
  per-request boundaries
- `MultiRoundTripTests`: 14 tests passed on macOS
