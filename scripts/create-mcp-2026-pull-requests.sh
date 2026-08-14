#!/bin/bash
set -euo pipefail

SUBMIT=false
DRAFT=true
REPOSITORY=""
ONLY_BRANCH=""
HEAD_OWNER=""
SUBMISSION_HEAD=""
BASE_MAIN=false
UPSTREAM_REMOTE="origin"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
BODY_DIRECTORY="$REPOSITORY_ROOT/Documentation/PullRequests/MCP-2026-07-28"

usage() {
  cat <<'EOF'
Usage: scripts/create-mcp-2026-pull-requests.sh [options]

Preview the stacked MCP 2026-07-28 pull requests. No pull requests are created unless
--submit is supplied.

Options:
  --submit           Create pull requests with the GitHub CLI.
  --ready            Create non-draft pull requests. Requires --submit.
  --repo OWNER/REPO  Pass an explicit repository to gh.
  --only BRANCH      Preview or create only the named head branch.
  --head-owner OWNER Qualify the pull request head as OWNER:BRANCH.
  --submission-head BRANCH
                     Submit BRANCH while using --only to select its review body.
  --base-main        Target main instead of the documented stacked base. Requires --only.
  --upstream-remote REMOTE
                     Validate --base-main against REMOTE/main. Default: origin.
  --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --submit)
      SUBMIT=true
      shift
      ;;
    --ready)
      DRAFT=false
      shift
      ;;
    --repo)
      if [[ $# -lt 2 ]]; then
        echo "--repo requires OWNER/REPO" >&2
        exit 1
      fi
      REPOSITORY="$2"
      shift 2
      ;;
    --only)
      if [[ $# -lt 2 ]]; then
        echo "--only requires a head branch" >&2
        exit 1
      fi
      ONLY_BRANCH="$2"
      shift 2
      ;;
    --head-owner)
      if [[ $# -lt 2 ]]; then
        echo "--head-owner requires a GitHub owner" >&2
        exit 1
      fi
      HEAD_OWNER="$2"
      shift 2
      ;;
    --submission-head)
      if [[ $# -lt 2 ]]; then
        echo "--submission-head requires a local branch" >&2
        exit 1
      fi
      SUBMISSION_HEAD="$2"
      shift 2
      ;;
    --base-main)
      BASE_MAIN=true
      shift
      ;;
    --upstream-remote)
      if [[ $# -lt 2 ]]; then
        echo "--upstream-remote requires a remote name" >&2
        exit 1
      fi
      UPSTREAM_REMOTE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$DRAFT" == false && "$SUBMIT" == false ]]; then
  echo "--ready requires --submit" >&2
  exit 1
fi
if [[ "$BASE_MAIN" == true && -z "$ONLY_BRANCH" ]]; then
  echo "--base-main requires --only so one review unit is submitted at a time" >&2
  exit 1
fi
if [[ -n "$SUBMISSION_HEAD" && ( -z "$ONLY_BRANCH" || "$BASE_MAIN" == false ) ]]; then
  echo "--submission-head requires --only and --base-main" >&2
  exit 1
fi
if [[ "$SUBMIT" == true && -z "$REPOSITORY" ]]; then
  echo "--submit requires --repo so the destination is explicit" >&2
  exit 1
fi
if [[ "$SUBMIT" == true && "$REPOSITORY" == "modelcontextprotocol/swift-sdk" ]]; then
  if [[ -z "$HEAD_OWNER" || "$BASE_MAIN" == false || -z "$ONLY_BRANCH" ]]; then
    echo "Submitting to modelcontextprotocol/swift-sdk requires --head-owner, --base-main, and --only" >&2
    exit 1
  fi
fi

HEAD_BRANCHES=(
  "mcp-2026-wire-models"
  "mcp-2026-oauth-issuer-validation"
  "mcp-2026-discovery-negotiation"
  "mcp-2026-multi-round-trip"
  "mcp-2026-http-client"
  "mcp-2026-http-server"
  "mcp-2026-http-lifecycle-routing"
  "mcp-2026-tool-headers"
  "mcp-2026-subscriptions"
  "mcp-2026-response-caching"
  "mcp-2026-conformance"
  "mcp-2026-defaults-release"
)

BASE_BRANCHES=(
  "main"
  "mcp-2026-wire-models"
  "mcp-2026-oauth-issuer-validation"
  "mcp-2026-discovery-negotiation"
  "mcp-2026-multi-round-trip"
  "mcp-2026-http-client"
  "mcp-2026-http-server"
  "mcp-2026-http-lifecycle-routing"
  "mcp-2026-tool-headers"
  "mcp-2026-subscriptions"
  "mcp-2026-response-caching"
  "mcp-2026-conformance"
)

BODY_FILES=(
  "01-wire-models.md"
  "02-oauth-issuer-validation.md"
  "03-discovery-negotiation.md"
  "04-multi-round-trip.md"
  "05-http-client.md"
  "06-http-server.md"
  "07-http-lifecycle-routing.md"
  "08-tool-headers.md"
  "09-subscriptions.md"
  "10-response-caching.md"
  "11-conformance.md"
  "12-defaults-release.md"
)

TITLES=(
  "Add MCP 2026-07-28 wire models"
  "Enforce MCP OAuth issuer binding"
  "Add MCP per-request protocol negotiation"
  "Add MCP multi-round-trip requests"
  "Add per-request metadata HTTP client"
  "Add per-request metadata HTTP server"
  "Route HTTP requests by MCP lifecycle"
  "Add MCP request header validation"
  "Add MCP subscription streams"
  "Add MCP response caching"
  "Add MCP 2026-07-28 conformance coverage"
  "Enable MCP 2026-07-28 defaults"
)

matched_branch=false
for index in "${!HEAD_BRANCHES[@]}"; do
  head_branch="${HEAD_BRANCHES[$index]}"
  submission_head="$head_branch"
  base_branch="${BASE_BRANCHES[$index]}"
  validation_base="$base_branch"
  body_file="$BODY_DIRECTORY/${BODY_FILES[$index]}"

  if [[ -n "$ONLY_BRANCH" && "$head_branch" != "$ONLY_BRANCH" ]]; then
    continue
  fi
  matched_branch=true

  if [[ -n "$SUBMISSION_HEAD" ]]; then
    submission_head="$SUBMISSION_HEAD"
  fi

  if ! git -C "$REPOSITORY_ROOT" show-ref --verify --quiet "refs/heads/$head_branch"; then
    echo "Missing local branch: $head_branch" >&2
    exit 1
  fi
  if ! git -C "$REPOSITORY_ROOT" show-ref --verify --quiet "refs/heads/$submission_head"; then
    echo "Missing local submission branch: $submission_head" >&2
    exit 1
  fi
  if [[ "$BASE_MAIN" == true ]]; then
    validation_base="refs/remotes/$UPSTREAM_REMOTE/main"
    if ! git -C "$REPOSITORY_ROOT" rev-parse --verify --quiet "$validation_base^{commit}" >/dev/null; then
      echo "Missing $validation_base; fetch the upstream main branch first" >&2
      exit 1
    fi
    if [[ "$base_branch" != "main" ]] &&
      ! git -C "$REPOSITORY_ROOT" diff --quiet "$validation_base" "$base_branch"; then
      echo "$validation_base does not yet match the documented predecessor $base_branch" >&2
      echo "Wait for the predecessor to merge, then restack $head_branch on $validation_base" >&2
      exit 1
    fi
  elif ! git -C "$REPOSITORY_ROOT" show-ref --verify --quiet "refs/heads/$base_branch"; then
    echo "Missing local base branch: $base_branch" >&2
    exit 1
  fi
  if [[ ! -f "$body_file" ]]; then
    echo "Missing pull request body: $body_file" >&2
    exit 1
  fi
  if ! git -C "$REPOSITORY_ROOT" merge-base --is-ancestor "$validation_base" "$submission_head"; then
    echo "Local branch $submission_head does not contain its submission base $validation_base" >&2
    exit 1
  fi
  if git -C "$REPOSITORY_ROOT" diff --quiet "$validation_base..$submission_head"; then
    echo "Local branch $submission_head has no review delta from $validation_base" >&2
    exit 1
  fi
  if [[ "$submission_head" != "$head_branch" ]] &&
    ! git -C "$REPOSITORY_ROOT" diff --quiet "$head_branch" "$submission_head"; then
    echo "Submission branch $submission_head does not produce the same tree as $head_branch" >&2
    exit 1
  fi
done

if [[ "$matched_branch" == false ]]; then
  echo "Unknown head branch: $ONLY_BRANCH" >&2
  exit 1
fi

blocker_files=("$BODY_DIRECTORY"/[0-9][0-9]-*.md)
if [[ -n "$ONLY_BRANCH" ]]; then
  for index in "${!HEAD_BRANCHES[@]}"; do
    if [[ "${HEAD_BRANCHES[$index]}" == "$ONLY_BRANCH" ]]; then
      blocker_files=("$BODY_DIRECTORY/${BODY_FILES[$index]}")
      break
    fi
  done
fi

if grep -n "<!-- PR-BLOCKER:" "${blocker_files[@]}"; then
  echo >&2
  echo "Resolve and remove every PR-BLOCKER comment before submission." >&2
  if [[ "$SUBMIT" == true ]]; then
    exit 1
  fi
fi

echo "MCP 2026-07-28 stacked pull requests:"
for index in "${!HEAD_BRANCHES[@]}"; do
  if [[ -n "$ONLY_BRANCH" && "${HEAD_BRANCHES[$index]}" != "$ONLY_BRANCH" ]]; then
    continue
  fi
  display_base="${BASE_BRANCHES[$index]}"
  display_head="${HEAD_BRANCHES[$index]}"
  if [[ -n "$SUBMISSION_HEAD" ]]; then
    display_head="$SUBMISSION_HEAD"
  fi
  if [[ "$BASE_MAIN" == true ]]; then
    display_base="main"
  fi
  printf '%2d. %-42s -> %-42s %s\n' \
    "$((index + 1))" \
    "$display_head" \
    "$display_base" \
    "${BODY_FILES[$index]}"
done

if [[ "$SUBMIT" == false ]]; then
  echo
  echo "Preview only. Review the Markdown files and pass --submit to create draft pull requests."
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required for --submit." >&2
  exit 1
fi

for index in "${!HEAD_BRANCHES[@]}"; do
  if [[ -n "$ONLY_BRANCH" && "${HEAD_BRANCHES[$index]}" != "$ONLY_BRANCH" ]]; then
    continue
  fi
  head_argument="${HEAD_BRANCHES[$index]}"
  if [[ -n "$SUBMISSION_HEAD" ]]; then
    head_argument="$SUBMISSION_HEAD"
  fi
  base_argument="${BASE_BRANCHES[$index]}"
  if [[ -n "$HEAD_OWNER" ]]; then
    head_argument="$HEAD_OWNER:$head_argument"
  fi
  if [[ "$BASE_MAIN" == true ]]; then
    base_argument="main"
  fi
  if [[ "$DRAFT" == true ]]; then
    gh pr create \
      --repo "$REPOSITORY" \
      --head "$head_argument" \
      --base "$base_argument" \
      --title "${TITLES[$index]}" \
      --body-file "$BODY_DIRECTORY/${BODY_FILES[$index]}" \
      --draft
  else
    gh pr create \
      --repo "$REPOSITORY" \
      --head "$head_argument" \
      --base "$base_argument" \
      --title "${TITLES[$index]}" \
      --body-file "$BODY_DIRECTORY/${BODY_FILES[$index]}"
  fi
done
