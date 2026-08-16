#!/bin/bash
set -euo pipefail

UPSTREAM_URL="https://github.com/modelcontextprotocol/conformance.git"
FORK_URL="https://github.com/coopsource/conformance.git"
INSTALL_DEPENDENCIES=true
VERIFY=true
CONFIGURE_FORK=true

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_SDK_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SWIFT_SDK_ROOT/.." && pwd)"
TARGET_DIRECTORY="$WORKSPACE_ROOT/conformance"

usage() {
  cat <<'EOF'
Usage: scripts/setup-conformance-development-repo.sh [options]

Clone and prepare the official MCP conformance repository as a peer of this
Swift SDK checkout. By default the resulting layout is:

  modelcontextprotocol/
    conformance/
    modelcontextprotocol/
    swift-sdk/

The official repository is configured as the fetch-only `origin` remote. A
separate contributor `fork` remote is configured for pushes. This script does
not create the GitHub fork itself.

Options:
  --target DIRECTORY  Override the destination directory.
  --fork-url URL      Override the contributor-fork URL.
  --no-fork           Do not configure a contributor-fork remote.
  --skip-install      Do not run npm ci.
  --skip-verify       Do not run npm run check and npm test.
  --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      if [[ $# -lt 2 ]]; then
        echo "--target requires a directory" >&2
        exit 1
      fi
      TARGET_DIRECTORY="$2"
      shift 2
      ;;
    --fork-url)
      if [[ $# -lt 2 ]]; then
        echo "--fork-url requires a URL" >&2
        exit 1
      fi
      FORK_URL="$2"
      shift 2
      ;;
    --no-fork)
      CONFIGURE_FORK=false
      shift
      ;;
    --skip-install)
      INSTALL_DEPENDENCIES=false
      shift
      ;;
    --skip-verify)
      VERIFY=false
      shift
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

if [[ -L "$TARGET_DIRECTORY" ]]; then
  echo "Refusing a symbolic-link destination: $TARGET_DIRECTORY" >&2
  exit 1
fi

for command_name in git npm node; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  fi
done

node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if [[ ! "$node_major" =~ ^[0-9]+$ ]] || ((node_major < 20)); then
  echo "Node.js 20 or newer is required; found $(node --version)." >&2
  exit 1
fi

if [[ -e "$TARGET_DIRECTORY" ]]; then
  if [[ ! -d "$TARGET_DIRECTORY/.git" ]]; then
    echo "Destination exists but is not a Git checkout: $TARGET_DIRECTORY" >&2
    exit 1
  fi

  existing_origin="$(git -C "$TARGET_DIRECTORY" remote get-url origin 2>/dev/null || true)"
  case "${existing_origin%.git}" in
    https://github.com/modelcontextprotocol/conformance|\
    git@github.com:modelcontextprotocol/conformance|\
    ssh://git@github.com/modelcontextprotocol/conformance)
      ;;
    *)
      echo "Existing checkout has an unexpected origin: ${existing_origin:-<missing>}" >&2
      exit 1
      ;;
  esac

  echo "Using existing conformance checkout: $TARGET_DIRECTORY"
else
  mkdir -p "$(dirname "$TARGET_DIRECTORY")"
  git clone "$UPSTREAM_URL" "$TARGET_DIRECTORY"
fi

# Keep the official repository available for fetching while preventing an
# accidental push. Git accepts the deliberately invalid push URL without
# changing origin's fetch URL.
git -C "$TARGET_DIRECTORY" remote set-url origin "$UPSTREAM_URL"
git -C "$TARGET_DIRECTORY" remote set-url --push origin DISABLED

if [[ "$CONFIGURE_FORK" == true ]]; then
  if git -C "$TARGET_DIRECTORY" remote get-url fork >/dev/null 2>&1; then
    existing_fork="$(git -C "$TARGET_DIRECTORY" remote get-url fork)"
    if [[ "${existing_fork%.git}" != "${FORK_URL%.git}" ]]; then
      echo "Existing fork remote does not match the requested URL:" >&2
      echo "  existing: $existing_fork" >&2
      echo "  requested: $FORK_URL" >&2
      exit 1
    fi
  else
    git -C "$TARGET_DIRECTORY" remote add fork "$FORK_URL"
  fi
  git -C "$TARGET_DIRECTORY" remote set-url --push fork "$FORK_URL"

  if ! git ls-remote "$FORK_URL" HEAD >/dev/null 2>&1; then
    echo "Warning: the contributor fork is not reachable yet: $FORK_URL" >&2
    echo "Create or grant access to that fork before pushing." >&2
  fi
fi

if [[ "$INSTALL_DEPENDENCIES" == true ]]; then
  if [[ ! -f "$TARGET_DIRECTORY/package-lock.json" ]]; then
    echo "The conformance checkout has no package-lock.json; refusing an unpinned install." >&2
    exit 1
  fi
  npm --prefix "$TARGET_DIRECTORY" ci
elif [[ "$VERIFY" == true && ! -d "$TARGET_DIRECTORY/node_modules" ]]; then
  echo "--skip-install requires existing node_modules or --skip-verify." >&2
  exit 1
fi

if [[ "$VERIFY" == true ]]; then
  npm --prefix "$TARGET_DIRECTORY" run check
  npm --prefix "$TARGET_DIRECTORY" test
fi

echo
echo "Conformance development checkout is ready:"
echo "  $TARGET_DIRECTORY"
echo
git -C "$TARGET_DIRECTORY" status --short --branch
git -C "$TARGET_DIRECTORY" remote -v
echo
echo "Next:"
echo "  cd '$TARGET_DIRECTORY'"
echo "  git switch -c codex/cross-sdk-interoperability"
