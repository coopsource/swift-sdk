# Swift SDK conformance and interoperability plan

Date: 2026-08-14

Status: Swift-side foundation complete; official runner integration and cross-SDK expansion remain

## Objective

Establish reproducible evidence that the Swift SDK conforms to the `2025-11-25` and `2026-07-28`
protocol revisions, integrate Swift with the official MCP conformance project, and then extend that
project with cross-SDK interoperability testing.

This is a separate workstream from submitting the 12 Swift protocol-support pull requests. It must
not add unrelated SDK fixes or delay review of those pull requests.

## Repository ownership

| Responsibility | Repository |
| --- | --- |
| Swift client/server implementation, conformance executables, adapter tests, and local pinned runs | `modelcontextprotocol/swift-sdk` |
| Official scenarios, frozen requirement sets, SDK checkout/build configuration, result schema, CI, and later pairwise execution | `modelcontextprotocol/conformance` |
| Normative protocol wording and the two deferred HTTP clarification proposals | `modelcontextprotocol/modelcontextprotocol` |

Do not put generic cross-SDK process management in the Swift SDK. Do not put executable test
infrastructure in the specification repository.

## Current state

### Swift SDK

The prepared Swift stack is on the contributor fork. Its conformance review unit is
`mcp-2026-conformance` at `7b97662`, followed by the defaults and release unit at `af3d4f0`
(tips as of the 2026-08-15 audit restack; earlier reports cite the pre-restack `e697612`/`72e475f`).

PR 11 currently provides:

- `mcp-everything-client` and `mcp-everything-server` SwiftPM products;
- client lifecycle selection from `MCP_CONFORMANCE_PROTOCOL_VERSION`;
- one HTTP server endpoint that routes both initialization-based and `2026-07-28` requests;
- a server `--port` option and fixed `/mcp` endpoint;
- deterministic readiness checks and process cleanup in the 2026 runner script;
- result and server-log preservation under `.build/conformance-2026-07-28`;
- six NIO adapter tests covering write order, disconnect cancellation, failed writes, and concurrent
  requests; and
- shared tool definitions for advertised tools and custom-header validation.

Verified baselines:

| Run | Result |
| --- | --- |
| Full Swift tests | 746 SDK tests in 51 suites and 6 adapter tests passed |
| `2025-11-25` pinned run | 223 client checks and 47 server checks passed with no unexpected failure |
| `2026-07-28` client requirements | 423 checks passed; 13 failures were unscored extension or added-after-release scenarios |
| `2026-07-28` server requirements | 166 checks passed; 25 failures were confined to the unscored Tasks extension |
| Documentation | DocC generation with warnings treated as errors passed |

The `2026-07-28` result is a conformance pass because every required check passed. Unscored
failures remain visible and must not be relabeled as passing behavior.

### Official conformance project

The pinned and current official revision is
[`c321dd32035556e6769d3724a8ee97d87c3faaac`](https://github.com/modelcontextprotocol/conformance/commit/c321dd32035556e6769d3724a8ee97d87c3faaac),
released as `0.2.0-alpha.11`.

The official project already provides:

- frozen `--requirements <revision>` sets;
- an `sdk` command that clones or opens an SDK, builds it, starts the selected side, and forwards
  scenario selection and result output;
- `KNOWN_SDKS` configuration with per-revision overrides;
- expected-failure evaluation distinct from required-test scoring; and
- server readiness, shutdown, and checkout caching.

Applicable required tests determine conformance scores. Pending, skipped, disputed, experimental,
and unclaimed legacy tests do not count toward the score.[^tiering]

### Active upstream overlap

- [conformance PR #432](https://github.com/modelcontextprotocol/conformance/pull/432), by
  `@shoemoney`, adds `swift-sdk` to `KNOWN_SDKS`. It is open at
  `f6de8bc1f27dbb4a9e251846b808e530772fe083`, with no review comments as of this plan. GitHub reports
  its current state as `unstable`. Coordinate with the contributor instead of opening a competing
  registration PR.
- [swift-sdk PR #269](https://github.com/modelcontextprotocol/swift-sdk/pull/269), also by
  `@shoemoney`, corrects the existing everything-server resource-template response. Keep that
  pre-existing fixture correction separate from the protocol-support stack.
- [conformance issue #250](https://github.com/modelcontextprotocol/conformance/issues/250) records
  the maintainer direction for one command that can test any official SDK at a pinned ref. The
  merged [PR #277](https://github.com/modelcontextprotocol/conformance/pull/277) established the
  current `sdk` command as the foundation for cross-SDK CI.

## Ground rules

1. Pin the Swift ref, conformance ref, specification revision, toolchain, and operating system for
   every recorded result.
2. Run client and server legs independently. One passing side never implies the other passed.
3. Run each protocol revision at its own wire lifecycle. `2025-11-25` uses initialization;
   `2026-07-28` uses per-request metadata.
4. Use frozen requirement sets for release claims. Use the current full suite separately to expose
   post-release and extension gaps.
5. Preserve failing unscored scenarios in artifacts. Do not add an expected-failure entry merely to
   improve the displayed result.
6. Distinguish an SDK failure, a conformance-project defect, an invalid test fixture, and a protocol
   ambiguity before changing code.
7. Match real process, streaming, cancellation, ordering, and concurrency behavior. Do not replace
   HTTP or stdio boundaries with buffered function-call substitutes.
8. Keep fixes in the review unit or repository that owns the failing boundary.

## Phases

### Phase C0: create the conformance development checkout

From the Swift SDK checkout:

```bash
scripts/setup-conformance-development-repo.sh
```

This creates the peer checkout at
`/Users/alan/projects/github/modelcontextprotocol/conformance`, configures the official `origin` as
fetch-only, configures `coopsource/conformance` as `fork`, installs dependencies, and runs the
conformance project's checks and tests.

Before editing:

```bash
cd /Users/alan/projects/github/modelcontextprotocol/conformance
git status --short --branch
git remote -v
git rev-parse HEAD
npm start -- sdk --help
```

Read `AGENTS.md`, `README.md`, `SDK_INTEGRATION.md`, `src/runner/DESIGN.md`,
`src/sdk-runner/`, issue #250, merged PR #277, and active PR #432 completely.

Exit gate:

- clean conformance checkout at the recorded official revision;
- `npm run check` and `npm test` pass; and
- official `origin` cannot be pushed accidentally.

### Phase C1: freeze the Swift executable contract

Review the Swift executables as public test-process boundaries rather than example applications.
Record and test these contracts:

#### Client

- accepts the server URL as its positional argument;
- requires `MCP_CONFORMANCE_SCENARIO`;
- selects the lifecycle from `MCP_CONFORMANCE_PROTOCOL_VERSION`;
- reads scenario context and credentials only from documented conformance environment variables;
- writes diagnostics to standard error without corrupting protocol traffic; and
- exits nonzero for invalid arguments or an unsupported scenario.

#### Server

- accepts `--port <number>` and rejects malformed or missing values rather than silently using an
  unintended port;
- binds only to loopback by default;
- serves `/mcp`;
- routes both supported lifecycle eras without sharing request-scoped state incorrectly;
- becomes ready only after both server paths are installed; and
- terminates cleanly on the signals used by the official runner.

Review whether explicit lifecycle selection is still necessary on the server. Prefer the existing
dual-era endpoint if it behaves deterministically under both frozen requirement sets; add a mode
only if an official run demonstrates a real need.

Add focused process-contract tests for any behavior not already covered. Keep this work in Swift
PR 11 while that unit has not entered upstream review.

Exit gate:

- both products build on macOS and Linux;
- adapter and process-contract tests pass repeatedly;
- cancellation and shutdown leave no server process or occupied port; and
- no production dependency or public SDK product is added solely for conformance testing.

### Phase C2: reproduce the pinned Swift baselines

Run from the Swift SDK branch that contains PR 11:

```bash
swift test --filter HTTPHandlerTests
scripts/run-conformance.sh
scripts/run-conformance-2026-07-28.sh
```

Then run:

```bash
swift test
swift package generate-documentation --target MCP --warnings-as-errors
```

Archive:

- the Swift and conformance SHAs;
- `swift --version`, `node --version`, and the operating-system version;
- client and server result directories;
- server logs;
- required, unscored, skipped, and warning counts; and
- exit status for each independent leg.

Do not treat historical check counts as assertions if the checked-out code differs. The gates are
the frozen required checks and the absence of new failures relative to the matching pinned refs.

### Phase C3: validate through the official `sdk` command

First inspect PR #432 and contact `@shoemoney`. Offer the prepared Swift conformance branch and its
dual-era behavior; do not duplicate the PR.

Suggested message:

> We have a restacked Swift `mcp-2026-conformance` branch that adds explicit 2026 lifecycle
> selection, a dual-era server endpoint, custom-header wiring, deterministic readiness, and adapter
> cancellation/order tests. Both `2025-11-25` and `2026-07-28` required runs pass. Would you like to
> update #432 against this branch as the Swift PR series lands? I can provide exact commands and
> retain your contribution as the Swift registration change.

Fetch the active PR for local review without changing its remote branch:

```bash
cd /Users/alan/projects/github/modelcontextprotocol/conformance
git fetch origin pull/432/head:refs/remotes/origin/pr/432
git diff --stat origin/main...origin/pr/432
git diff origin/main...origin/pr/432 -- src/sdk-runner
```

Use a separate conformance worktree or local review branch if changes are needed. Do not force-push
the contributor's branch without explicit coordination.

Once the Swift entry is present locally, run the fork branch through the official command:

```bash
npm start -- sdk coopsource/swift-sdk@mcp-2026-conformance \
  --mode client --requirements 2025-11-25 \
  -o results/swift-sdk/2025-11-25/client

npm start -- sdk coopsource/swift-sdk@mcp-2026-conformance \
  --mode server --requirements 2025-11-25 \
  -o results/swift-sdk/2025-11-25/server

npm start -- sdk coopsource/swift-sdk@mcp-2026-conformance \
  --mode client --requirements 2026-07-28 \
  -o results/swift-sdk/2026-07-28/client

npm start -- sdk coopsource/swift-sdk@mcp-2026-conformance \
  --mode server --requirements 2026-07-28 \
  -o results/swift-sdk/2026-07-28/server
```

The `--requirements` path deliberately ignores automatically configured expected-failure baselines
when deciding conformance. It runs the frozen scenarios at the requested wire revision.

Also run the current full suite for visibility, but report it separately from release conformance:

```bash
npm start -- sdk coopsource/swift-sdk@mcp-2026-conformance \
  --mode client --suite all -o results/swift-sdk/current/client

npm start -- sdk coopsource/swift-sdk@mcp-2026-conformance \
  --mode server --suite all -o results/swift-sdk/current/server
```

Exit gate:

- all four frozen-requirement legs pass;
- the official command builds and manages Swift without manual process cleanup;
- full-suite differences are classified without hiding them; and
- PR #432 contains or references the final commands and evidence.

### Phase C4: platform and repeatability matrix

Required lanes:

| Platform | Purpose |
| --- | --- |
| Native macOS, supported Swift toolchain | Foundation and URLSession behavior, SwiftPM executable paths, complete client/server requirements |
| Linux, supported Swift toolchain | FoundationNetworking, NIO behavior, process shutdown, complete non-platform-excluded requirements |
| Minimum supported Swift compiler | Package and MCP target build; run executable tests supported by that compiler |

Run each lifecycle and role at least twice during stabilization to expose occupied-port, incomplete
shutdown, cache reuse, and ordering defects. Use unique result directories. A retry may confirm an
environmental failure, but it must not overwrite or erase the first result.

Exit gate:

- no order-dependent result across repeated runs;
- platform exclusions are explicit and justified;
- the same Git revisions reproduce equivalent required-test verdicts; and
- CI uploads machine-readable results and server logs on success and failure.

### Phase C5: security, privacy, and execution safety

Treat checked-out SDK refs and their build scripts as untrusted code.

- Pin external SDK refs to immutable SHAs for release and scheduled runs.
- Do not expose repository, package-registry, signing, or deployment secrets to builds of
  contributor-controlled refs.
- Use least-privilege CI tokens and read-only source checkouts where possible.
- Run HTTP tests on loopback with ephemeral ports or isolated workers. Do not expose test servers
  to the LAN.
- Use isolated temporary directories or containers for Linux SDK builds; do not share writable
  dependency caches across untrusted refs without a reviewed cache key.
- Never publish access tokens, refresh tokens, authorization codes, client secrets, private keys,
  cookies, or complete authorization headers in logs or result artifacts.
- Treat scenario context, mirrored MCP headers, request bodies, session IDs, and event IDs as
  potentially sensitive. Redact before publication.
- Bound process lifetime, output size, network access, and retained artifacts.
- Verify that cleanup terminates process groups and descendants, not only the initial shell.

Exit gate:

- a documented CI threat model covers fork PRs, scheduled main-branch runs, dependency installation,
  network access, secrets, caches, and artifacts; and
- one negative test proves a terminated or failed SDK process cannot remain alive or leak sensitive
  output into the published report.

### Phase C6: upstream integration

The smallest useful upstream change is Swift registration in `KNOWN_SDKS`. PR #432 already owns
that change. Help it land rather than replacing it.

Before the PR is ready:

- resolve its current unstable checks;
- update its evidence after the relevant Swift review units land or point it at an agreed immutable
  Swift ref for review;
- confirm whether `.build/debug` is reliable on all supported hosted architectures or use
  `swift build --show-bin-path` through a small wrapper;
- run both frozen requirement revisions, not only `--suite core` and the default server suite;
- keep the full-suite gaps visible without using them to misstate the frozen requirement result;
  and
- preserve attribution for the contributor's registration work.

Do not absorb swift-sdk PR #269 into the protocol series. Land, rebase over, or record it as an
external prerequisite according to its upstream disposition.

### Phase C7: cross-SDK interoperability expansion

Begin only after Swift runs reliably through the official `sdk` command.

Open a conformance design issue before implementation. Reference issue #250, PR #277, PR #432, and
the existing SDK Working Group responsibility for conformance integration.[^sdk-working-group]

The first proposal should be a Swift-centered star:

- Swift client against pinned TypeScript, Python, Go, C#, and Rust servers; and
- each pinned client against the Swift server.

Keep these result classes separate:

1. normative conformance results produced by official scenarios;
2. immutable observations from direct SDK-to-SDK exchanges; and
3. reviewed deviations with an issue or specification reference.

Two implementations agreeing is not proof of conformance. A pairwise failure is not automatically
proof that either SDK violates the specification. Reduce every mismatch to an official scenario or
a smallest wire trace before assigning ownership.

After the star is stable:

- add current/current pairwise scheduled runs;
- add legacy/current combinations on a slower schedule;
- shard by client, server, protocol revision, and transport;
- generate Markdown and JSON from the same immutable result records; and
- add Java, Ruby, PHP, and Kotlin only after their executable contracts are reviewed.

Generic pairwise orchestration, reports, and CI remain in the conformance repository. The Swift SDK
keeps only its executables, local smoke scripts, Swift-specific tests, and links to official results.

## Failure classification

For every failure, record one category before proposing a change:

| Category | Required evidence | Owner |
| --- | --- | --- |
| Swift implementation defect | Smallest failing Swift test plus official scenario or normative citation | Owning Swift review unit or later focused Swift PR |
| Swift executable defect | Process/adapter reproduction independent of production API semantics | Swift conformance review unit |
| Conformance-project defect | Reference implementation or wire-schema evidence showing the test sent or expected invalid behavior | Conformance PR/issue |
| Specification ambiguity | Two plausible readings plus cross-SDK observations and smallest wire example | Specification issue or isolated clarification PR |
| Unsupported extension | Extension identifier and explicit Swift support decision | Separate extension work, not core conformance |
| Environment failure | Toolchain, OS, port, network, or dependency evidence; successful controlled rerun | CI or development environment |

Never fix an older unrelated Swift defect merely because the expanded suite exposes it. File or
link a separate issue and keep the protocol-support review focused.

## Deliverables

- Swift process-contract tests and any minimal executable corrections in PR 11.
- Four frozen-requirement result sets for Swift: two roles by two revisions.
- Separate current full-suite result sets.
- macOS and Linux evidence with immutable revisions and toolchain versions.
- A coordinated update or review contribution to conformance PR #432.
- A security and execution-safety note for CI.
- An upstream design issue for direct pairwise interoperability.
- Generated Swift-centered star results only after that design is accepted.

## First executable slice for the next agent

1. Preserve the current Swift worktree. It presently has untracked setup work; do not stage an
   unrelated `lefthook.yml` without establishing its owner and purpose.
2. Run `scripts/setup-conformance-development-repo.sh` and record the resulting conformance SHA and
   baseline `npm` checks.
3. Read the files and upstream items listed in Phase C0.
4. Fetch PR #432 read-only and compare its Swift command assumptions with the prepared PR 11 branch.
5. Post or prepare the coordination message for `@shoemoney`; do not open a duplicate PR.
6. Run the four `sdk --requirements` commands in Phase C3 against
   `coopsource/swift-sdk@mcp-2026-conformance`.
7. Classify every difference using the table above. Do not edit production Swift during this slice.
8. Write a short results report with exact commands, SHAs, counts, logs, and the next smallest
   code change, if any.

Stop the first slice after the reproduction and classification report. Obtain agreement on any
change that would alter PR ownership or expand the official conformance command before implementing
it.

## Sources

[^tiering]: [MCP SDK tiers: conformance testing](https://modelcontextprotocol.io/community/sdk-tiers#conformance-testing).

[^sdk-working-group]: [SDK Working Group scope](https://modelcontextprotocol.io/community/working-groups/sdk#in-scope).

- [Official conformance repository at the pinned revision](https://github.com/modelcontextprotocol/conformance/tree/c321dd32035556e6769d3724a8ee97d87c3faaac)
- [Official SDK runner documentation](https://github.com/modelcontextprotocol/conformance/blob/c321dd32035556e6769d3724a8ee97d87c3faaac/README.md#running-against-an-sdk-at-a-specific-ref)
- [`KNOWN_SDKS` at the pinned revision](https://github.com/modelcontextprotocol/conformance/blob/c321dd32035556e6769d3724a8ee97d87c3faaac/src/sdk-runner/known-sdks.ts)
- [Conformance tests required for observable Standards Track behavior](https://modelcontextprotocol.io/community/sep-guidelines#conformance-test-requirement)
