# MCP 2026-07-28 Conformance Fix Handoff

Status: ready for implementation

Date: 2026-08-14

Target repository: `/Users/alan/projects/github/modelcontextprotocol/swift-sdk`

Target branch: `swift-sdk-mcp-update-07-28-26`

Tested implementation commit: `584f8ff96b0e2cf9deb2b125eb614392e032b511`

Conformance repository: `/Users/alan/projects/github/modelcontextprotocol/conformance`

Conformance commit used for the latest matrix: `0f2796f59204d32f903879a3c91fbc39a64c86d4`

## Objective

Fix the three remaining scored SHOULD warnings in the Swift SDK's MCP
2026-07-28 conformance result without regressing the frozen 2025-11-25
behavior.

This handoff is deliberately limited to the Swift repository. Implement the
Swift fixes and their focused Swift tests, run local Swift verification, then
stop. Do **not** run the cross-SDK conformance matrix. Alan will run that matrix
from the conformance repository after reviewing the Swift changes.

## Repository and safety constraints

- Work only on the existing `swift-sdk-mcp-update-07-28-26` branch. Do not
  switch branches, create an independent implementation branch, rewrite the
  existing stack, or reset the worktree.
- Preserve all existing modified and untracked files. At handoff time these
  included documentation, `lefthook.yml`, and
  `scripts/setup-conformance-development-repo.sh`; they are user-owned and are
  not cleanup targets.
- Do not modify the conformance repository as part of this task.
- Do not push, open issues or pull requests, comment, or otherwise write to any
  `modelcontextprotocol` remote repository.
- Do not hide the warnings in an expected-failures baseline and do not disable
  advertised capabilities merely to make checks skip.
- Do not implement the optional Tasks/authentication/JSON Schema backlog in
  this change. It is listed below only to distinguish it from the scored work.
- Keep the changes focused. In particular, the two server warnings are fixture
  integration omissions; the core subscription routing implementation already
  exists and should not be redesigned without evidence of a separate defect.

## Current conformance evidence

The cross-SDK matrix command was:

```sh
npm run sdk-matrix -- \
  --sdk swift-sdk \
  --sdk typescript-sdk \
  --requirements 2025-11-25,2026-07-28
```

It tested `coopsource/swift-sdk@584f8ff9` and produced these scored Swift
results:

| Requirements | Side | Clean scored scenarios | Scored failures | Scored warnings |
| --- | --- | ---: | ---: | ---: |
| 2025-11-25 | Client | 18/18 | 0 | 0 |
| 2025-11-25 | Server | 30/30 | 0 | 0 |
| 2026-07-28 | Client | 31/32 | 0 | 1 |
| 2026-07-28 | Server | 36/37 | 0 | 2 |

There are no scored MUST failures. The only scored findings are:

1. `sep-2575-client-retry-supported-version`
2. `sep-2575-server-sends-prompts-list-changed-on-subscription`
3. `sep-2575-server-sends-tools-list-changed-on-subscription`

The complete matrix report remains at:

```text
/Users/alan/projects/github/modelcontextprotocol/conformance/results/sdk-matrix/latest.md
```

The current requirements runner exits successfully when the only scored
findings are SHOULD warnings. Do not treat a zero process exit status by itself
as proof that these fixes worked; Alan will inspect the warning checks in the
matrix report.

## Fix 1: retry an advertised supported version exactly once

### Symptom

The 2026 client `request-metadata` scenario rejects the first request with an
HTTP 400 JSON-RPC `UnsupportedProtocolVersionError`:

```json
{
  "error": {
    "code": -32022,
    "message": "Unsupported protocol version",
    "data": {
      "supported": ["2026-07-28"],
      "requested": "2026-07-28"
    }
  }
}
```

The advertised mutually supported version intentionally equals the version
used by the first request. The conformance server expects one retry using that
advertised version. The Swift client makes no retry, leaving
`sep-2575-client-retry-supported-version` as a scored WARNING.

### Root cause

`Client.discoverConnection` already has a one-retry guard, but it additionally
suppresses the retry when the selected advertised version equals the initial
request:

```swift
if mayRetryVersion,
    let retryVersion = mutuallySupportedVersion(
        from: underlyingDiscoveryError(error)
    ),
    retryVersion != requestedVersion
{
    return try await discoverConnection(
        requestedVersion: retryVersion,
        mayRetryVersion: false
    )
}
```

Location:

```text
Sources/MCP/Client/Client.swift
```

At the tested commit the relevant condition is around lines 1817-1826.

### Required implementation

Allow the retry whenever all of these are true:

- this is the first attempt (`mayRetryVersion == true`);
- the error is the recognized unsupported-protocol-version error;
- its data decodes as `UnsupportedProtocolVersionData`;
- the server advertises a version supported by the per-request-metadata
  lifecycle.

Do not require the retry version to differ from the requested version. The
existing recursive call passes `mayRetryVersion: false`; retain that bound so a
second rejection cannot cause a loop.

The minimal expected production change is removal of the
`retryVersion != requestedVersion` predicate. Do not broaden retry behavior to
unrecognized errors, malformed error data, authentication failures, transport
failures, or cancellation.

### Required focused tests

Add focused cases to:

```text
Tests/MCPTests/ProtocolNegotiationTests.swift
```

Use the existing `MockTransport`, request decoding helpers, and asynchronous
`waitUntil` style in that suite. Cover the behavior as one cohesive negotiation
feature, with enough assertions to prove ordering and bounds:

1. **Same advertised version retries once and succeeds.**
   - Start a `.perRequestMetadataOnly` client connection.
   - Observe the first `server/discover` request.
   - Respond with `MCPError.remote` code
     `ProtocolErrorCode.unsupportedProtocolVersion` and encoded
     `UnsupportedProtocolVersionData` whose `supported` and `requested` values
     are both `Version.perRequestMetadataVersion`.
   - Observe a second `server/discover` request.
   - Verify its request ID is distinct and its wire protocol version remains
     `Version.perRequestMetadataVersion`.
   - Return a valid `Discover.Result` for the second request.
   - Verify connection succeeds with the per-request-metadata lifecycle and
     exactly two discovery requests were sent.

2. **A second rejection does not loop.**
   - Reject both discovery attempts with the same supported-version error.
   - Verify the client surfaces the second unsupported-version error.
   - Verify exactly two discovery requests were sent and no third attempt
     appears.

3. **Cancellation remains cancellation.**
   - Retain the existing cancellation behavior and add a focused assertion if
     necessary to show that cancellation while discovery is outstanding does
     not initiate a negotiation retry or initialization fallback.
   - The task must terminate with `CancellationError`, and any emitted
     cancellation notification must remain correlated to the outstanding
     request.

4. **Unrecognized failures remain non-retryable.**
   - Preserve the existing tests showing recognized non-negotiation errors do
     not trigger lifecycle fallback or a retry.

Avoid sleeps as the primary synchronization mechanism when the mock transport
can observe sends deterministically. Match the real boundary's request
ordering and cancellation behavior.

## Fixes 2 and 3: publish prompt/tool list-change events from the fixture

### Symptoms

The Swift conformance server advertises both capabilities:

```swift
prompts: .init(listChanged: true)
tools: .init(listChanged: true)
```

The 2026 server scenario then:

1. opens `subscriptions/listen` with a prompt-only or tool-only filter;
2. waits for the subscription acknowledgment;
3. calls `tools/call` with either `test_trigger_prompt_change` or
   `test_trigger_tool_change` on a separate request;
4. waits for the matching list-change notification on the open stream.

The Swift fixture does not currently list or handle either diagnostic tool.
Its default handler returns an `isError` tool result for an unknown tool, and
no notification reaches the subscription stream. The scored warnings are:

- `sep-2575-server-sends-prompts-list-changed-on-subscription`
- `sep-2575-server-sends-tools-list-changed-on-subscription`

The warning text says the list was mutated but no matching notification
arrived. The actionable issue is the missing diagnostic event publication.
The per-request server creates request-scoped handling state, so an actual
persistent list mutation is not required by this fixture; the change event is
what the conformance check observes.

### Existing core behavior that should be reused

`Server.notify` already recognizes these methods:

- `notifications/prompts/list_changed`
- `notifications/tools/list_changed`

For per-request-metadata mode it calls the subscription fan-out path, which:

- selects only subscriptions whose acknowledged filters permit the method;
- adds the original subscription request ID to notification metadata;
- queues and drains the message on the corresponding open stream;
- preserves acknowledgment-before-notification ordering.

Relevant locations:

```text
Sources/MCP/Server/Server.swift
Sources/MCP/Base/Subscriptions.swift
Tests/MCPTests/SubscriptionTests.swift
```

Do not replace this machinery with fixture-specific stream routing.

### Required fixture implementation

Modify:

```text
Sources/MCPConformance/Server/main.swift
```

> **Superseded (2026-08-15):** the shipped fixture keeps both diagnostics hidden — they are
> handled by `standardToolHandler` but deliberately absent from the `ListTools` result, which
> keeps the frozen 2025 tool list byte-identical. The conformance scenario only needs
> `tools/call` dispatch. Steps 2-5 below are accurate as shipped.

1. Add these two tools to the `ListTools` result with empty object input
   schemas:

   - `test_trigger_prompt_change`
   - `test_trigger_tool_change`

2. Add corresponding cases to `standardToolHandler`.

3. In the prompt trigger, await:

   ```swift
   try await server?.notify(
       PromptListChangedNotification.message(.init())
   )
   ```

4. In the tool trigger, await:

   ```swift
   try await server?.notify(
       ToolListChangedNotification.message(.init())
   )
   ```

5. After successful publication, return a normal, non-error `CallTool.Result`
   with a short diagnostic text such as `prompts_list_changed published` or
   `tools_list_changed published`.

Await notification publication before the handler returns. Do not use an
unstructured or detached task; the conformance test depends on deterministic
ordering and the publication error must not be silently lost.

The same server factory is used for initialization-based and
per-request-metadata paths. Adding the tools must not remove or rename any
existing 2025 fixture tool. Extra tools are compatible with the 2025 list
checks.

### Required focused tests

The executable's `main.swift` is not directly imported by the existing test
targets. Do not perform a large fixture refactor solely to unit-test two switch
cases. At minimum:

- build both conformance products to prove the fixture compiles;
- run `SubscriptionTests` to preserve the core fan-out contract;
- add or extend a focused `SubscriptionTests` case so both prompt and tool
  list-change notifications demonstrate:
  - acknowledgment is observed before notification;
  - the notification carries the correct subscription ID;
  - a prompt-only listener does not receive tool changes;
  - a tool-only listener does not receive prompt changes;
  - concurrent listeners receive only their selected notification type.

If a very small extraction makes the diagnostic handler directly testable
without expanding public API or destabilizing the executable, it is acceptable
but not required. The decisive end-to-end fixture verification will be Alan's
subsequent conformance matrix run.

## 2025 regression evidence and compatibility requirement

An exact before/after comparison was run with the same conformance commit and
the frozen `2025-11-25` requirements:

- baseline before the MCP 2026 work: `290b39d`;
- tested MCP 2026 implementation: `584f8ff`.

Results:

| Side | Baseline | Candidate | Changed normalized verdicts |
| --- | --- | --- | ---: |
| Client | 18/18 scored; 13 optional findings | 18/18 scored; the same 13 optional findings | 0 of 234 |
| Server | 30/30 scored; no optional findings | 30/30 scored; no optional findings | 0 of 84 |

The three fixes in this handoff must preserve that result. In particular:

- the discovery retry applies only to per-request-metadata negotiation and
  must not alter initialization-based version negotiation;
- adding diagnostic tools must not change existing tool semantics;
- do not change default protocol-mode compatibility behavior;
- do not remove 2025 methods, notifications, transports, or fixtures.

## Optional findings that are out of scope

The matrix also reports optional, unscored gaps. They do not block the three
scored fixes and must not be folded into this task:

- SEP-2663 Tasks support in the Swift server fixture;
- DPoP and DPoP nonce support in the client;
- enterprise-managed authorization;
- WIF JWT bearer authorization;
- a JSON Schema 2020-12 preservation handler in the conformance client.

Because the matrix treats optional findings as yellow, completing this handoff
may leave yellow cells even when all scored scenarios are clean. The expected
scored result after Alan reruns the matrix is:

| Requirements | Side | Expected clean scored scenarios | Expected scored warnings/failures |
| --- | --- | ---: | ---: |
| 2025-11-25 | Client | 18/18 | 0 |
| 2025-11-25 | Server | 30/30 | 0 |
| 2026-07-28 | Client | 32/32 | 0 |
| 2026-07-28 | Server | 37/37 | 0 |

## Local verification to complete before stopping

Run focused tests first, then the full local suite and product builds:

```sh
swift test --filter ProtocolNegotiationTests
swift test --filter SubscriptionTests
swift test
swift build --product mcp-everything-client
swift build --product mcp-everything-server
```

If the repository's current Swift Testing filter syntax selects no tests, use
the toolchain's supported test listing/filter spelling and record the exact
replacement command. Do not claim focused verification if zero tests ran.

Inspect the final diff and status without cleaning unrelated files:

```sh
git diff -- Sources/MCP/Client/Client.swift \
  Sources/MCPConformance/Server/main.swift \
  Tests/MCPTests/ProtocolNegotiationTests.swift \
  Tests/MCPTests/SubscriptionTests.swift
git status --short --branch
```

Do not run `npm run sdk-matrix`, `tier-check`, or any conformance command from
the conformance repository. Do not edit matrix results. Alan explicitly owns
that final verification step.

## Definition of done for the implementation agent

The agent is done when all of the following are true:

- the client retries an advertised mutually supported version exactly once,
  including when it equals the first requested version;
- successful continuation, second-rejection termination, cancellation, and
  no-loop behavior have focused Swift tests;
- both fixture diagnostic tools are listed and handled;
- prompt and tool triggers synchronously publish the corresponding
  list-change notification through `Server.notify`;
- subscription ID and filter behavior remain covered by focused Swift tests;
- focused tests, the full `swift test`, and both product builds pass;
- no unrelated user-owned changes were modified or removed;
- no remote repository was changed;
- the agent reports the changed files, exact test commands/results, remaining
  untracked/modified files, and the local commit SHA if it created a commit;
- the agent then stops and waits for Alan to run cross-SDK conformance testing.

## Copy-ready implementation prompt

```text
Work in /Users/alan/projects/github/modelcontextprotocol/swift-sdk on the
existing swift-sdk-mcp-update-07-28-26 branch.

Read Documentation/MCP-2026-07-28-CONFORMANCE-FIX-HANDOFF.md completely and
implement exactly the three scored MCP 2026-07-28 conformance fixes described
there:

1. Allow Client.discoverConnection to retry an advertised mutually supported
   protocol version exactly once even when it equals the initially requested
   version. Preserve cancellation, recognized-error handling, and the
   mayRetryVersion no-loop bound. Add focused tests for same-version retry and
   success, exactly one retry after a second rejection, cancellation, and no
   unintended fallback.

2. Add the test_trigger_prompt_change diagnostic tool to the Swift conformance
   server fixture and synchronously publish
   PromptListChangedNotification through Server.notify.

3. Add the test_trigger_tool_change diagnostic tool and synchronously publish
   ToolListChangedNotification through Server.notify.

Preserve subscription acknowledgement ordering, subscription IDs, and filter
behavior. Reuse the existing Server.notify subscription fan-out path. Do not
silence the checks by changing capabilities or baselines.

Preserve every existing modified and untracked file. Do not reset, clean,
switch branches, rewrite the review stack, or touch the conformance repository.
Do not make any remote GitHub changes. Keep Tasks, DPoP/nonce, enterprise auth,
WIF, and JSON Schema preservation out of scope.

Run the focused ProtocolNegotiationTests and SubscriptionTests, the full
swift test suite, and builds for mcp-everything-client and
mcp-everything-server. Confirm that the test filters actually execute tests.

When the Swift fixes and local verification are complete, report the changed
files, exact commands and results, git status, and commit SHA if one was
created. Then STOP and wait for Alan. Do not run the conformance cross-SDK
matrix; Alan will test the changes from
/Users/alan/projects/github/modelcontextprotocol/conformance.
```
