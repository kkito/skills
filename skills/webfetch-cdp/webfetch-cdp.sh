#!/usr/bin/env bash
#
# webfetch-cdp - Fetch web page content using playwright-cli CDP snapshot
#
# Usage:
#   webfetch-cdp.sh --url <url> [options]
#
# Options:
#   --url <url>           Target URL to fetch (required)
#   --wait-selector <sel> CSS selector to wait for (optional)
#   --wait-time <ms>      Max wait time in ms (default: 10000)
#   --viewport <W,H>      Viewport size, e.g. "1920,1080" (optional)
#   --no-close            Don't close browser after fetch (optional)
#

set -euo pipefail

# Default values
URL=""
WAIT_SELECTOR=""
WAIT_TIME=10000
VIEWPORT=""
NO_CLOSE=false

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
    --no-close)
      NO_CLOSE=true
      shift
      ;;
    --help|-h)
      head -15 "$0"
      exit 0
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$URL" ]]; then
  echo "Error: --url is required" >&2
  exit 1
fi

# Determine playwright-cli command
PLAYWRIGHT_CLI="playwright-cli"
if ! command -v "$PLAYWRIGHT_CLI" &>/dev/null; then
  PLAYWRIGHT_CLI="npx playwright-cli"
  if ! command -v npx &>/dev/null; then
    echo "Error: playwright-cli or npx not found in PATH" >&2
    exit 1
  fi
fi

# Check if browser is already open
has_active_browser() {
  local output
  output=$($PLAYWRIGHT_CLI list 2>/dev/null || true)
  # If output contains active session info, browser is open
  if [[ -n "$output" ]] && echo "$output" | grep -qi "active\|session\|page\|url"; then
    return 0
  fi
  return 1
}

# Track if we opened a new browser (to decide whether to close)
BROWSER_WAS_OPEN=false

# Main fetch function
fetch_page() {
  local temp_dir
  temp_dir=$(mktemp -d)
  local snapshot_file="$temp_dir/snapshot.yml"

  # Navigate: open new browser or goto existing
  if has_active_browser; then
    BROWSER_WAS_OPEN=true
    $PLAYWRIGHT_CLI goto "$URL" || {
      echo "Error: Failed to navigate to $URL" >&2
      rm -rf "$temp_dir"
      exit 1
    }
  else
    $PLAYWRIGHT_CLI open "$URL" || {
      echo "Error: Failed to open $URL" >&2
      rm -rf "$temp_dir"
      exit 1
    }
  fi

  # Set viewport if specified
  if [[ -n "$VIEWPORT" ]]; then
    local width height
    width=$(echo "$VIEWPORT" | cut -d',' -f1)
    height=$(echo "$VIEWPORT" | cut -d',' -f2)
    $PLAYWRIGHT_CLI resize "$width" "$height" 2>/dev/null || true
  fi

  # Wait for selector if specified
  if [[ -n "$WAIT_SELECTOR" ]]; then
    $PLAYWRIGHT_CLI eval "(async () => {
      try {
        await page.waitForSelector('$WAIT_SELECTOR', { timeout: $WAIT_TIME });
        return 'found';
      } catch (e) {
        return 'timeout: ' + e.message;
      }
    })()" 2>/dev/null || true
  fi

  # Take snapshot
  $PLAYWRIGHT_CLI snapshot --filename="$snapshot_file" 2>/dev/null || {
    echo "Error: Failed to take snapshot" >&2
    # Close browser if we opened it
    if [[ "$BROWSER_WAS_OPEN" != "true" && "$NO_CLOSE" != "true" ]]; then
      $PLAYWRIGHT_CLI close 2>/dev/null || true
    fi
    rm -rf "$temp_dir"
    exit 1
  }

  # Output snapshot content
  if [[ -f "$snapshot_file" ]]; then
    cat "$snapshot_file"
  else
    echo "Error: Snapshot file was not created" >&2
    if [[ "$BROWSER_WAS_OPEN" != "true" && "$NO_CLOSE" != "true" ]]; then
      $PLAYWRIGHT_CLI close 2>/dev/null || true
    fi
    rm -rf "$temp_dir"
    exit 1
  fi

  # Close browser if we opened it and --no-close is not set
  if [[ "$BROWSER_WAS_OPEN" != "true" && "$NO_CLOSE" != "true" ]]; then
    $PLAYWRIGHT_CLI close 2>/dev/null || true
  fi

  # Cleanup temp dir
  rm -rf "$temp_dir"
}

# Run fetch
fetch_page
