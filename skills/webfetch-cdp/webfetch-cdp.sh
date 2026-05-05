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
#

set -euo pipefail

# Default values
URL=""
WAIT_SELECTOR=""
WAIT_TIME=10000
VIEWPORT=""

# Parse arguments
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
    --help|-h)
      head -15 "$0"
      exit 0
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      # Positional argument: treat as URL if it looks like one
      if [[ "$1" == http://* || "$1" == https://* ]]; then
        URL="$1"
      else
        echo "Error: Invalid argument: $1 (expected URL starting with http:// or https://)" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate required arguments
if [[ -z "$URL" ]]; then
  echo "Error: URL is required" >&2
  echo "Usage: webfetch-cdp.sh <url> [options]" >&2
  exit 1
fi

# Find playwright-cli's bundled playwright module
find_playwright_module() {
  local cli_path
  cli_path=$(command -v playwright-cli 2>/dev/null) || {
    echo "Error: playwright-cli not found in PATH" >&2
    exit 1
  }

  # Read the symlink chain to find the actual npm package location
  local dir
  dir=$(cd "$(dirname "$cli_path")" && pwd)
  local node_modules="$dir/../lib/node_modules/@playwright/cli/node_modules"

  if [[ -d "$node_modules/playwright" ]]; then
    echo "$node_modules/playwright"
    return 0
  fi

  # Fallback: try global npm root
  local npm_root
  npm_root=$(npm root -g 2>/dev/null) || true
  if [[ -d "$npm_root/@playwright/cli/node_modules/playwright" ]]; then
    echo "$npm_root/@playwright/cli/node_modules/playwright"
    return 0
  fi

  echo "Error: Cannot find playwright module" >&2
  exit 1
}

PW_MODULE=$(find_playwright_module)

# Run the Node.js script
PW_MODULE="$PW_MODULE" URL="$URL" WAIT_SELECTOR="$WAIT_SELECTOR" WAIT_TIME="$WAIT_TIME" VIEWPORT="$VIEWPORT" \
  node "$(dirname "$0")/webfetch-cdp.mjs"
