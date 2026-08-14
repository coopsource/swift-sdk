# MCP Conformance Findings for the 2026-07-28 Swift Update

## Scope

This report records the conformance results for the modified Swift SDK client
and server fixtures. It separates frozen-revision requirements from optional
extension and post-release coverage so the registration decision is based on
the scored requirements.

- Conformance commit: `c321dd32035556e6769d3724a8ee97d87c3faaac`
- Swift SDK commit: `584f8ff96b0e2cf9deb2b125eb614392e032b511`
- Swift branch: `swift-sdk-mcp-update-07-28-26`
- Repository: `coopsource/swift-sdk`
- Test date: 2026-08-14

No Swift implementation code was changed as part of this findings handoff.
The three scored warnings below are intentionally visible and are not added to
`conformance-baseline.yml`.

## Environment

- macOS 27.0 (build 26A5406e), Apple silicon
- Xcode 27.0 (build 27A5237l)
- Apple Swift 6.4 (`swiftlang-6.4.0.30.4`, target
  `arm64-apple-macosx27.0.0`)
- Node.js 26.7.0
- npm 11.19.0

The conformance registration documents Swift 6.1 or newer as the minimum
prerequisite; this run used Swift 6.4.

## Commands

The fixtures were built once and then reused:

```sh
swift build --product mcp-everything-client
swift build --product mcp-everything-server
```

The server fixture was launched with:

```sh
.build/debug/mcp-everything-server --port 3000
```

The conformance runner was invoked from the Swift checkout for each frozen
revision and each side:

```sh
node /Users/alan/projects/github/modelcontextprotocol/conformance/dist/index.js \
  client --command .build/debug/mcp-everything-client \
  --requirements 2025-11-25

node /Users/alan/projects/github/modelcontextprotocol/conformance/dist/index.js \
  server --url http://127.0.0.1:3000/mcp \
  --requirements 2025-11-25

node /Users/alan/projects/github/modelcontextprotocol/conformance/dist/index.js \
  client --command .build/debug/mcp-everything-client \
  --requirements 2026-07-28

node /Users/alan/projects/github/modelcontextprotocol/conformance/dist/index.js \
  server --url http://127.0.0.1:3000/mcp \
  --requirements 2026-07-28
```

The repository helper script was also exercised for the 2026-07-28 run:

```sh
scripts/run-conformance-2026-07-28.sh
```

## Results

| Revision | Side | Passing checks | Scored MUST failures | Scored SHOULD warnings | Unscored failures |
| --- | --- | ---: | ---: | ---: | ---: |
| 2025-11-25 | Client | 272 | 0 | 0 | 13 |
| 2025-11-25 | Server | 84 | 0 | 0 | 0 |
| 2026-07-28 | Client | 423 | 0 | 1 | 13 |
| 2026-07-28 | Server | 166 | 0 | 2 | 25 |

For 2025-11-25, every scored client and server check passes. For 2026-07-28,
there are no scored MUST failures. The remaining scored results are three
SHOULD-level warnings. Optional extension and post-release failures are
unscored and do not block registering the Swift SDK.

Important runner behavior: a requirements command currently exits successfully
when its only scored problems are SHOULD warnings. Swift verification must
inspect the warning checks in the output; a zero exit status alone does not
prove that all scored SHOULD requirements pass.

## Prioritized Scored Follow-up

### 1. Client supported-version retry

Check: `sep-2575-client-retry-supported-version`

When the first initialize attempt is rejected with the supported-version error,
retry once using an advertised supported version even if that version equals
the version requested on the first attempt. The current client suppresses the
retry when the advertised value equals the original request.

Tests should prove all of the following together:

- exactly one retry occurs;
- initialization continues successfully after that retry;
- cancellation is respected;
- a second rejection cannot create a retry loop.

### 2. Prompt list-change notification after subscription

Check: `sep-2575-server-sends-prompts-list-changed-on-subscription`

Update the Swift conformance server fixture so its prompt-change diagnostic
acknowledges the trigger and then emits the filtered prompt list-change
notification. Preserve the subscription ID and the requested filter in the
notification path.

### 3. Tool list-change notification after subscription

Check: `sep-2575-server-sends-tools-list-changed-on-subscription`

Apply the equivalent fixture behavior for tool-list changes: acknowledge the
diagnostic trigger, emit the filtered notification, and preserve the
subscription ID and filter semantics.

## Optional, Unscored Backlog

The following gaps are useful future coverage but are not part of the scored
registration result:

- SEP-2663 Tasks support in the server fixture;
- DPoP and DPoP nonce support in the client;
- enterprise-managed authorization;
- WIF JWT bearer authorization;
- a JSON Schema 2020-12 preservation handler in the Swift conformance client.

These items should remain separate from the three scored SHOULD warnings when
reporting Swift conformance status.

## Recommended Handoff Sequence

The existing follow-up and Swift conformance plans describe a larger program
that includes platform repeatability and eventual cross-SDK interoperability.
The evidence from this run supports the following narrower sequence:

1. Keep the Swift implementation stack and the conformance registration as
   separate review units. The registration needs no per-revision override: the
   same Swift server command and `/mcp` endpoint passed both frozen lifecycle
   revisions.
2. Treat the local conformance branch as a `coopsource`-owned candidate. The
   planning documents record an overlapping conformance PR #432; do not open a
   competing upstream change without first resolving ownership. No upstream
   inspection or coordination was performed during this run.
3. Land or hand off the registration before adding generic cross-SDK
   orchestration or CI. Interoperability design is a later, separate workstream
   and should not expand this registration branch.
4. Repeat the four frozen legs on Linux and with the minimum supported Swift
   6.1 toolchain before making the registration a broad CI dependency. Use
   those results to decide whether `.build/debug` is portable enough or a
   `swift build --show-bin-path` wrapper is warranted; do not change the tested
   command based on speculation alone.
5. Address the three scored SHOULD warnings in the priority order above, with
   focused timing, ordering, cancellation, subscription-ID, and filter tests.
   Keep Tasks and authorization extensions in separate follow-ups.

The combined tier command correctly attributed the temporary run to
`coopsource/swift-sdk@swift-sdk-mcp-update-07-28-26` and scored 67/67 required
server scenarios and 50/50 required client scenarios. Its repository-health
result was Tier 3 because the contributor fork lacks the official repository's
release and label signals. That governance score describes the temporary fork;
it must not be presented as the official Swift SDK's tier.
