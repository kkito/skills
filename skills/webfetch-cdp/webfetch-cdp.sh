#!/usr/bin/env bash
#
# webfetch-cdp - Fetch web page content using Playwright CDP snapshot
#
# Usage:
#   webfetch-cdp.sh <url> [options]
#   webfetch-cdp.sh --url <url> [options]
#
# Options:
#   <url>                 Target URL (positional or --url)
#   --wait-selector <sel> CSS selector to wait for (optional)
#   --wait-time <ms>      Max wait time in ms (default: 10000)
#   --viewport <W,H>      Viewport size, e.g. "1920,1080" (optional)
#   --stop                Stop the background daemon
#   --restart             Restart the background daemon
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="/tmp/webfetch-cdp.pid"
HTTP_PORT="${WEBFETCH_CDP_PORT:-8668}"
DAEMON_LOG="/tmp/webfetch-cdp.log"

# --- Daemon management ---

is_daemon_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

start_daemon() {
  local pw_module
  pw_module=$(find_playwright_module)

  # Start the daemon in background
  PW_MODULE="$pw_module" HTTP_PORT="$HTTP_PORT" node "$SCRIPT_DIR/webfetch-cdp.mjs" \
    2>>"$DAEMON_LOG" &

  local pid=$!
  echo "$pid" > "$PID_FILE"

  # Wait for HTTP server to appear (up to 10 seconds)
  local retries=0
  while ! curl -s "http://127.0.0.1:${HTTP_PORT}" >/dev/null 2>&1 && [[ $retries -lt 100 ]]; do
    sleep 0.1
    retries=$((retries + 1))
  done

  if ! curl -s "http://127.0.0.1:${HTTP_PORT}" >/dev/null 2>&1; then
    echo "Error: Failed to start daemon. Log:" >&2
    tail -10 "$DAEMON_LOG" >&2
    exit 1
  fi
}

stop_daemon() {
  if is_daemon_running; then
    local pid
    pid=$(cat "$PID_FILE")
    # Try graceful shutdown via HTTP
    curl -s -X POST "http://127.0.0.1:${HTTP_PORT}/exit" >/dev/null 2>&1 || true
    sleep 0.2
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}

# --- Find playwright module ---

find_playwright_module() {
  local cli_path
  cli_path=$(command -v playwright-cli 2>/dev/null) || {
    echo "Error: playwright-cli not found in PATH" >&2
    exit 1
  }

  local dir
  dir=$(cd "$(dirname "$cli_path")" && pwd)
  local node_modules="$dir/../lib/node_modules/@playwright/cli/node_modules"

  if [[ -d "$node_modules/playwright" ]]; then
    echo "$node_modules/playwright"
    return 0
  fi

  local npm_root
  npm_root=$(npm root -g 2>/dev/null) || true
  if [[ -d "$npm_root/@playwright/cli/node_modules/playwright" ]]; then
    echo "$npm_root/@playwright/cli/node_modules/playwright"
    return 0
  fi

  echo "Error: Cannot find playwright module" >&2
  exit 1
}

# --- Parse arguments ---

URL=""
WAIT_SELECTOR=""
WAIT_TIME=10000
VIEWPORT=""
ACTION="fetch"  # fetch | stop | restart

while [[ $# -gt 0 ]]; do
  case $1 in
    --url)
      URL="$2"
      shift 2
      ;;
    --wait-selector)
      WAIT_SELECTOR="$2"
      shift 2
      ;;
    --wait-time)
      WAIT_TIME="$2"
      shift 2
      ;;
    --viewport)
      VIEWPORT="$2"
      shift 2
      ;;
    --stop)
      ACTION="stop"
      shift
      ;;
    --restart)
      ACTION="restart"
      shift
      ;;
    --help|-h)
      head -15 "$0"
      exit 0
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ "$1" == http://* || "$1" == https://* ]]; then
        URL="$1"
      else
        echo "Error: Invalid argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# --- Execute ---

case "$ACTION" in
  stop)
    stop_daemon
    echo "Daemon stopped."
    exit 0
    ;;
  restart)
    stop_daemon
    sleep 0.5
    start_daemon
    echo "Daemon restarted."
    exit 0
    ;;
esac

if [[ -z "$URL" ]]; then
  echo "Error: URL is required" >&2
  exit 1
fi

# Ensure daemon is running
if ! is_daemon_running || ! curl -s "http://127.0.0.1:${HTTP_PORT}" >/dev/null 2>&1; then
  start_daemon
fi

# Build JSON request and send via HTTP
JSON="{\"url\":\"${URL}\",\"waitSelector\":\"${WAIT_SELECTOR:-}\",\"waitTime\":${WAIT_TIME},\"viewport\":\"${VIEWPORT:-}\"}"

curl -s -X POST "http://127.0.0.1:${HTTP_PORT}/fetch" \
  -H "Content-Type: application/json" \
  -d "$JSON"
