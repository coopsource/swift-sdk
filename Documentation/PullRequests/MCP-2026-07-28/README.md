# MCP 2026-07-28 pull request materials

This directory contains an editable pull request body for each review branch in the
MCP 2026-07-28 stack. The files live on the aggregate branch so preparing the reviews
does not add bookkeeping-only commits to the feature branches.

Specification section names in the bodies refer to tag `2026-07-28`, commit
`5f5440bb26a62e2cf3440b92da5a667efa03b267`. See the
[versioning section](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning) and
the fixture paths in `Documentation/MCP-2026-07-28-IMPLEMENTATION.md`.

The pull requests are stacked in this order:

| Order | Head branch | Base branch | Body |
|---:|---|---|---|
| 1 | `mcp-2026-wire-models` | `main` | `01-wire-models.md` |
| 2 | `mcp-2026-oauth-issuer-validation` | `mcp-2026-wire-models` | `02-oauth-issuer-validation.md` |
| 3 | `mcp-2026-discovery-negotiation` | `mcp-2026-oauth-issuer-validation` | `03-discovery-negotiation.md` |
| 4 | `mcp-2026-multi-round-trip` | `mcp-2026-discovery-negotiation` | `04-multi-round-trip.md` |
| 5 | `mcp-2026-http-client` | `mcp-2026-multi-round-trip` | `05-http-client.md` |
| 6 | `mcp-2026-http-server` | `mcp-2026-http-client` | `06-http-server.md` |
| 7 | `mcp-2026-http-lifecycle-routing` | `mcp-2026-http-server` | `07-http-lifecycle-routing.md` |
| 8 | `mcp-2026-tool-headers` | `mcp-2026-http-lifecycle-routing` | `08-tool-headers.md` |
| 9 | `mcp-2026-subscriptions` | `mcp-2026-tool-headers` | `09-subscriptions.md` |
| 10 | `mcp-2026-response-caching` | `mcp-2026-subscriptions` | `10-response-caching.md` |
| 11 | `mcp-2026-conformance` | `mcp-2026-response-caching` | `11-conformance.md` |
| 12 | `mcp-2026-defaults-release` | `mcp-2026-conformance` | `12-defaults-release.md` |

## Contributor fork workflow

Do not push these branches to the official `modelcontextprotocol/swift-sdk` remote.
Fork that repository under a personal GitHub account, then add the fork as a separate
remote while leaving `origin` pointed at the official repository:

```sh
git remote add fork git@github.com:YOUR_USERNAME/swift-sdk.git
git remote -v
```

HTTPS may be used instead:

```sh
git remote add fork https://github.com/YOUR_USERNAME/swift-sdk.git
```

The branch-push helper previews by default and refuses an official-repository URL:

```sh
scripts/push-mcp-2026-review-branches.sh --remote fork
scripts/push-mcp-2026-review-branches.sh --remote fork --push
```

The 12 feature branches form a review stack, but predecessor branch names exist only in
the contributor fork. The least surprising upstream workflow is therefore serial:

1. Push the full stack to the contributor fork for safekeeping and review.
2. Submit only `mcp-2026-wire-models` to the official repository's `main` branch.
3. After it merges, fetch (without changing local `main`) and create a separate
   `submission/...` branch containing the next review delta on `origin/main`.
4. Push that submission branch to the contributor fork and submit it to official `main`,
   then repeat for the remaining review units.

This avoids presenting cumulative changes as independent upstream pull requests. It also
works whether the maintainer merges, squashes, or rebases an earlier pull request. The source
review branches are snapshots, not permanent authorities: when review finds a defect, put the
correction in its owning unit and restack every successor before submission. Do not add a later
"fix" review unit for code that has not entered upstream review. A PR body with a `PR-BLOCKER`
comment cannot be submitted by the helper.

The source stack was regenerated after the aggregate review on 2026-08-14 and again after the
third-party audit on 2026-08-15. Corrections now live in units 01, 02, 03, 04, 05, 06, 09, 10,
and 11, and the final documentation in unit 12 describes the resulting behavior. Each branch builds on its documented predecessor, so the delta for each review remains
focused and the complete tree is preserved at every step.

For example, after the wire-model PR merges, prepare the OAuth submission without changing
either source review branch:

```sh
git fetch origin main
git branch submission/mcp-2026-oauth-issuer-validation \
  mcp-2026-oauth-issuer-validation
git rebase --onto origin/main \
  mcp-2026-wire-models \
  submission/mcp-2026-oauth-issuer-validation
git switch swift-sdk-mcp-update-07-28-26
scripts/push-mcp-2026-review-branches.sh \
  --remote fork \
  --only submission/mcp-2026-oauth-issuer-validation \
  --push
```

The rebase selects only the commits in
`mcp-2026-wire-models..mcp-2026-oauth-issuer-validation`. Resolve conflicts in favor of the
merged upstream behavior and the documented OAuth delta. Before submission, the PR helper
verifies that the resulting tree still matches the source review branch. If the maintainer
changed the predecessor while merging, that exact-tree check intentionally stops; review
and update the feature and its PR body instead of bypassing the check.

## Pull request helper

`scripts/create-mcp-2026-pull-requests.sh` previews the current stacked mapping without
making network changes. It never pushes branches. To create draft pull requests inside the
contributor fork for reviewing the feature deltas, run:

```sh
scripts/create-mcp-2026-pull-requests.sh \
  --submit \
  --repo YOUR_USERNAME/swift-sdk
```

These fork-local pull requests are optional; they preserve the stacked feature deltas but
are not submissions to the official repository.

For the first official pull request, install and authenticate the GitHub CLI, then use:

```sh
gh auth login
scripts/create-mcp-2026-pull-requests.sh \
  --submit \
  --repo modelcontextprotocol/swift-sdk \
  --head-owner YOUR_USERNAME \
  --base-main \
  --only mcp-2026-wire-models
```

After each predecessor merges, fetch official `main` and restack the next unit. The same
command submits it after replacing the `--only` value and adding its submission branch:

```sh
scripts/create-mcp-2026-pull-requests.sh \
  --submit \
  --repo modelcontextprotocol/swift-sdk \
  --head-owner YOUR_USERNAME \
  --base-main \
  --only mcp-2026-oauth-issuer-validation \
  --submission-head submission/mcp-2026-oauth-issuer-validation
```

`--base-main` validates against `origin/main`; it refuses the submission if that ref does
not match the documented predecessor or is not an ancestor of the selected submission
head. `--submission-head` also verifies that the submission produces the same source tree.
The script refuses any official-repository submission unless `--repo`, `--head-owner`,
`--base-main`, and `--only` make the destination and single review unit explicit.

The script creates drafts by default. Pass `--ready` with `--submit` only when the selected
pull request is ready for normal review. The Markdown body remains editable before and after
submission.

The repository workflow currently filters pull-request runs to a `main` base. GitHub therefore
may not run that workflow while a review unit targets its predecessor branch. The local results
are recorded in each body, but every PR must receive the repository's normal CI run after its
predecessor merges and it is retargeted to `main`, before it is merged.

The base branches recorded in the table describe the source review deltas. They do not
authorize pushing any branch to the official repository.
