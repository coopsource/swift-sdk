#!/bin/bash
set -euo pipefail

REMOTE=""
PUSH=false
FORCE_WITH_LEASE=false
INCLUDE_AGGREGATE=true
ONLY_BRANCH=""
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/push-mcp-2026-review-branches.sh --remote REMOTE [options]

Preview the MCP 2026-07-28 branches that would be pushed to a contributor fork.
No network changes are made unless --push is supplied. The script refuses to push
to the official modelcontextprotocol/swift-sdk repository.

Options:
  --remote REMOTE      Contributor-fork remote to inspect or push.
  --push               Push the listed branches.
  --force-with-lease   Update previously pushed branches after restacking.
                       Requires --push.
  --review-only        Do not include the aggregate implementation branch.
  --only BRANCH        Push only the named local branch, including a submission branch.
  --help               Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      if [[ $# -lt 2 ]]; then
        echo "--remote requires a remote name" >&2
        exit 1
      fi
      REMOTE="$2"
      shift 2
      ;;
    --push)
      PUSH=true
      shift
      ;;
    --force-with-lease)
      FORCE_WITH_LEASE=true
      shift
      ;;
    --review-only)
      INCLUDE_AGGREGATE=false
      shift
      ;;
    --only)
      if [[ $# -lt 2 ]]; then
        echo "--only requires a local branch" >&2
        exit 1
      fi
      ONLY_BRANCH="$2"
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

if [[ -z "$REMOTE" ]]; then
  echo "--remote is required" >&2
  exit 1
fi
if [[ "$FORCE_WITH_LEASE" == true && "$PUSH" == false ]]; then
  echo "--force-with-lease requires --push" >&2
  exit 1
fi

if ! remote_url="$(git -C "$REPOSITORY_ROOT" remote get-url --push "$REMOTE" 2>/dev/null)"; then
  echo "Unknown or unconfigured remote: $REMOTE" >&2
  exit 1
fi

remote_identity="${remote_url%.git}"
remote_identity="${remote_identity%/}"
case "$remote_identity" in
  https://github.com/modelcontextprotocol/swift-sdk|\
  git@github.com:modelcontextprotocol/swift-sdk|\
  ssh://git@github.com/modelcontextprotocol/swift-sdk)
    echo "Refusing to push to the official repository: $remote_url" >&2
    exit 1
    ;;
esac

BRANCHES=(
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
if [[ -n "$ONLY_BRANCH" ]]; then
  BRANCHES=("$ONLY_BRANCH")
elif [[ "$INCLUDE_AGGREGATE" == true ]]; then
  BRANCHES+=("swift-sdk-mcp-update-07-28-26")
fi

for branch in "${BRANCHES[@]}"; do
  if ! git -C "$REPOSITORY_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "Missing local branch: $branch" >&2
    exit 1
  fi
done

echo "Contributor fork remote: $REMOTE ($remote_url)"
echo "Branches:"
for branch in "${BRANCHES[@]}"; do
  printf '  %s\n' "$branch"
done

if [[ "$PUSH" == false ]]; then
  echo
  echo "Preview only. Pass --push after confirming this is your contributor fork."
  exit 0
fi

for branch in "${BRANCHES[@]}"; do
  if [[ "$FORCE_WITH_LEASE" == true ]]; then
    git -C "$REPOSITORY_ROOT" push \
      --force-with-lease \
      --set-upstream \
      "$REMOTE" \
      "$branch:$branch"
  else
    git -C "$REPOSITORY_ROOT" push \
      --set-upstream \
      "$REMOTE" \
      "$branch:$branch"
  fi
done
