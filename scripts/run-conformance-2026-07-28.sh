#!/bin/bash
set -euo pipefail

CONFORMANCE_PACKAGE="@modelcontextprotocol/conformance@0.2.0-alpha.11"
CLIENT_EXECUTABLE="mcp-everything-client"
SERVER_EXECUTABLE="mcp-everything-server"
REQUIREMENTS_VERSION="2026-07-28"
BASELINE_FILE="${BASELINE_FILE:-}"
RESULTS_DIRECTORY="${RESULTS_DIRECTORY:-.build/conformance-2026-07-28}"
MODE="${MODE:-both}"
SERVER_PID=""
SERVER_LOG=""

cleanup_server() {
  local exit_status="${1:-$?}"
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
  return "$exit_status"
}

trap 'cleanup_server $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --baseline)
      BASELINE_FILE="$2"
      shift 2
      ;;
    --results)
      RESULTS_DIRECTORY="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! "$MODE" =~ ^(client|server|both)$ ]]; then
  echo "Invalid mode: $MODE. Must be one of: client, server, both" >&2
  exit 1
fi

if [[ -n "$BASELINE_FILE" ]]; then
  if [[ ! -f "$BASELINE_FILE" ]]; then
    echo "Missing 2026-07-28 conformance baseline: $BASELINE_FILE" >&2
    exit 1
  fi
fi

swift build --product "$CLIENT_EXECUTABLE"
swift build --product "$SERVER_EXECUTABLE"

CLIENT_PATH="$(swift build --show-bin-path)/$CLIENT_EXECUTABLE"
SERVER_PATH="$(swift build --show-bin-path)/$SERVER_EXECUTABLE"
mkdir -p "$RESULTS_DIRECTORY"

if [[ "$MODE" == "client" || "$MODE" == "both" ]]; then
  CLIENT_ARGUMENTS=(
    client
    --command "$CLIENT_PATH"
    --requirements "$REQUIREMENTS_VERSION"
    --output-dir "$RESULTS_DIRECTORY/client"
  )
  if [[ -n "$BASELINE_FILE" ]]; then
    CLIENT_ARGUMENTS+=(--expected-failures "$BASELINE_FILE")
  fi
  npx --yes "$CONFORMANCE_PACKAGE" "${CLIENT_ARGUMENTS[@]}"
fi

if [[ "$MODE" == "server" || "$MODE" == "both" ]]; then
  SERVER_LOG="$RESULTS_DIRECTORY/server.log"
  "$SERVER_PATH" --port 3001 >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!

  ready=false
  for _ in {1..80}; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "The conformance server exited before it became ready" >&2
      cat "$SERVER_LOG" >&2
      wait "$SERVER_PID" 2>/dev/null || true
      exit 1
    fi
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --max-time 1 http://127.0.0.1:3001/mcp || true)"
    if [[ "$status" != "000" ]]; then
      ready=true
      break
    fi
    sleep 0.25
  done
  if [[ "$ready" != true ]]; then
    echo "The conformance server did not become ready within 20 seconds" >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "The conformance server exited after its readiness response" >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi

  SERVER_ARGUMENTS=(
    server
    --url http://127.0.0.1:3001/mcp
    --requirements "$REQUIREMENTS_VERSION"
    --output-dir "$RESULTS_DIRECTORY/server"
  )
  if [[ -n "$BASELINE_FILE" ]]; then
    SERVER_ARGUMENTS+=(--expected-failures "$BASELINE_FILE")
  fi
  npx --yes "$CONFORMANCE_PACKAGE" "${SERVER_ARGUMENTS[@]}"

  cleanup_server
fi
