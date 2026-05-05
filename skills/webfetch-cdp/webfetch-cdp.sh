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

# Sanitize --wait-selector to prevent command injection via JS interpolation
if [[ -n "$WAIT_SELECTOR" ]]; then
  if [[ "$WAIT_SELECTOR" == *["';()"]* ]]; then
    echo "Error: --wait-selector contains invalid characters" >&2
    exit 1
  fi
fi

# Validate --wait-time is a number
if ! [[ "$WAIT_TIME" =~ ^[0-9]+$ ]]; then
  echo "Error: --wait-time must be a number" >&2
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
  # If output contains "status: open", a browser session is active
  if echo "$output" | grep -qi "status: open"; then
    return 0
  fi
  return 1
}

# Track if we opened a new browser (to decide whether to close)
BROWSER_WAS_OPEN=false

# Temp directory for trap-based cleanup (set in fetch_page)
TEMP_DIR=""

# Trap-based cleanup: removes temp dir and closes browser if we opened it
cleanup() {
  local exit_code=$?
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
  if [[ "${BROWSER_WAS_OPEN:-false}" != "true" && "${NO_CLOSE:-false}" != "true" ]]; then
    $PLAYWRIGHT_CLI close 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

# Main fetch function
fetch_page() {
  local temp_dir
  temp_dir=$(mktemp -d) || {
    echo "Error: Failed to create temporary directory" >&2
    exit 1
  }
  local snapshot_file="$temp_dir/snapshot.yml"

  # Register temp dir for trap-based cleanup
  TEMP_DIR="$temp_dir"

  # Navigate: open new browser or goto existing
  if has_active_browser; then
    BROWSER_WAS_OPEN=true
    $PLAYWRIGHT_CLI goto "$URL" || {
      echo "Error: Failed to navigate to $URL" >&2
      return 1
    }
  else
    $PLAYWRIGHT_CLI open "$URL" || {
      echo "Error: Failed to open $URL" >&2
      return 1
    }
  fi

  # Check if navigation resulted in an error page (e.g., DNS resolution failure)
  local page_url
  page_url=$($PLAYWRIGHT_CLI eval "window.location.href" 2>/dev/null | grep -o 'chrome-error://' || true)
  if [[ -n "$page_url" ]]; then
    echo "Error: Failed to load $URL - page could not be reached" >&2
    return 1
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
    return 1
  }

  # Output snapshot content
  if [[ -f "$snapshot_file" ]]; then
    cat "$snapshot_file"
  else
    echo "Error: Snapshot file was not created" >&2
    return 1
  fi
}

# Run fetch
fetch_page
