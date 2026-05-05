---
name: webfetch-cdp
description: >
  Fetches content from a specified URL and processes it using an AI model.
  Takes a URL and a prompt as input, fetches the URL content, and processes
  the content with the prompt. Returns the model's response about the content.
  Use this tool when you need to retrieve and analyze web content.
allowed-tools: Bash(webfetch-cdp.sh:*)
---

# WebFetch CDP - Playwright CLI Snapshot Extractor

Fetch web page content using playwright-cli's CDP (Chrome DevTools Protocol) snapshot capability. The snapshot outputs a structured YAML format containing page elements, hierarchy, and links - ideal for LLM processing.

## When to Use This Skill

- Need to access any webpage to get information
- The page requires JavaScript rendering (React, Vue, Angular SPAs)
- Content is dynamically loaded (lazy-load, async requests)
- Need structured page information (element types, hierarchy, links)
- User asks about content on a website

## Quick Start

### Basic Page Fetch

```bash
./skills/webfetch-cdp/webfetch-cdp.sh --url "https://example.com"
```

Expected output:

```yaml
- generic [ref=e2]:
  - heading "Example Domain" [level=1] [ref=e3]
  - paragraph [ref=e4]: This domain is for use in documentation examples...
```

### Wait for Dynamic Content

```bash
./skills/webfetch-cdp/webfetch-cdp.sh \
  --url "https://example.com/app" \
  --wait-selector "#data-table" \
  --wait-time 15000
```

### Custom Viewport

```bash
./skills/webfetch-cdp/webfetch-cdp.sh \
  --url "https://example.com" \
  --viewport "1920,1080"
```

## Script Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--url` | Yes | - | Target URL to fetch |
| `--wait-selector` | No | None | CSS selector to wait for before snapshot |
| `--wait-time` | No | 10000 | Max wait time in milliseconds |
| `--viewport` | No | None | Viewport size as "width,height" |
| `--no-close` | No | false | Don't close browser after fetch |

## Output Format

Outputs playwright-cli's snapshot YAML directly to stdout:

```yaml
- generic [ref=e2]:
  - heading "Example Domain" [level=1] [ref=e3]
  - paragraph [ref=e4]: This domain is for use in documentation examples...
  - link "Learn more" [ref=e6]:
    - /url: https://iana.org/domains/example
```

## Browser Reuse

The script automatically detects and reuses an open browser:

| Scenario | Behavior |
|----------|----------|
| No active browser | Opens new browser → navigates → fetches → closes |
| Browser already open | Reuses existing browser → navigates → fetches (keeps open) |

To explicitly keep the browser open, use `--no-close`.

## Error Handling

If a command fails, you'll see an error message on stderr. Common issues:

| Issue | Solution |
|-------|----------|
| Element not found | Add `--wait-selector` or increase `--wait-time` |
| Empty snapshot | Page might need more time to render; use `--wait-selector` |
| playwright-cli not found | Run `npm install -g playwright-cli` or use `npx playwright-cli` |
| Navigation failed | Check that the URL is accessible and valid |

## Dependencies

- `playwright-cli` - available globally or via npx

## Advanced: Direct playwright-cli Usage

For complex multi-step interactions, use playwright-cli directly:

```bash
# Open and navigate
playwright-cli open https://example.com
playwright-cli snapshot

# Interact with page
playwright-cli click e3
playwright-cli fill e5 "search query"
playwright-cli press Enter
playwright-cli snapshot

# Close when done
playwright-cli close
```
