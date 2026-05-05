---
name: webfetch-cdp
description: >
  Fetches content from a specified URL and processes it using an AI model.
  Takes a URL and a prompt as input, fetches the URL content, and processes
  the content with the prompt. Returns the model's response about the content.
  Use this tool when you need to retrieve and analyze web content.
  Also supports web search via search engine URLs (Google, Bing) — no API key needed,
  leverages Chrome login state for personalized results. Ideal for real-time web search
  and dynamic content that requires JavaScript rendering or authentication.
allowed-tools: Bash(webfetch-cdp.sh:*)
---

# WebFetch CDP - Playwright CDP Snapshot Extractor

Fetch web page content by connecting to the user's existing Chrome browser via CDP (Chrome DevTools Protocol). Outputs a structured YAML snapshot containing page elements, hierarchy, and links - ideal for LLM processing.

## Prerequisites

Chrome must have remote debugging enabled:

1. Open `chrome://inspect/#remote-debugging` in Chrome
2. Check **"Allow remote debugging for this browser instance"**
3. Restart Chrome if prompted

The script auto-discovers the debugging port (via `DevToolsActivePort` file or scanning ports 9222/9229/9333).

## When to Use This Skill

- Need to access any webpage to get information
- Page requires login state (user's Chrome is already logged in)
- Page requires JavaScript rendering (React, Vue, Angular SPAs)
- Content is dynamically loaded (lazy-load, async requests)
- Need structured page information (element types, hierarchy, links)
- User asks about content on a website

## Quick Start

### Basic Page Fetch

```bash
./skills/webfetch-cdp/webfetch-cdp.sh https://example.com
```

Or with `--url` flag:

```bash
./skills/webfetch-cdp/webfetch-cdp.sh --url "https://example.com"
```

Expected output:

```yaml
- heading "Example Domain" [level=1] [ref=e3]
- paragraph [ref=e4]: This domain is for use in documentation examples without needing permission. Avoid use in operations.
- paragraph [ref=e5]:
  - link "Learn more" [ref=e6] [cursor=pointer]:
    - text: Learn more
    - /url: https://www.iana.org/domains/example
```

### Wait for Dynamic Content

```bash
./skills/webfetch-cdp/webfetch-cdp.sh \
  https://example.com/app \
  --wait-selector "#data-table" \
  --wait-time 15000
```

### Custom Viewport

```bash
./skills/webfetch-cdp/webfetch-cdp.sh \
  https://example.com \
  --viewport "1920,1080"
```

### Web Search (Google/Bing)

Search the web without needing an API key — leverages your Chrome login state for personalized results:

```bash
# Google search
./skills/webfetch-cdp/webfetch-cdp.sh "https://www.google.com/search?q=天天跳绳"

# Bing search
./skills/webfetch-cdp/webfetch-cdp.sh "https://www.bing.com/search?q=天天跳绳"

# Search with longer wait time for dynamic content
./skills/webfetch-cdp/webfetch-cdp.sh \
  "https://www.google.com/search?q=天天跳绳" \
  --wait-time 10000
```

Expected output: structured YAML containing search results (titles, links, snippets):

```yaml
- link "天天跳绳" [ref=e142]:
  - /url: https://tiantiantiaosheng.com/dl/
  - heading "天天跳绳" [level=3]
- generic: 基于AI动作捕捉，与屏幕中元素体感互动得分，经典和创新的训练动作都在这...
- link "天天跳绳app-官方正版软件2026最新版本免费下载" [ref=e172]:
  - /url: https://sj.qq.com/appdetail/com.gkid.crazyrope
  - heading "天天跳绳app-官方正版软件2026最新版本免费下载" [level=3]
```

## Script Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `<url>` (positional) | No | - | Target URL (can also use `--url`) |
| `--url` | No | - | Target URL (alternative to positional) |
| `--wait-selector` | No | None | CSS selector to wait for before snapshot |
| `--wait-time` | No | 10000 | Max wait time in milliseconds |
| `--viewport` | No | None | Viewport size as "width,height" |

## Output Format

Outputs Playwright's aria snapshot as YAML to stdout:

```yaml
- generic [ref=e2]:
  - heading "Example Domain" [level=1] [ref=e3]
  - paragraph [ref=e4]: This domain is for use in documentation examples...
  - link "Learn more" [ref=e6]:
    - /url: https://iana.org/domains/example
```

The snapshot preserves page structure (element types, hierarchy, links) which is better for LLM understanding than plain text.

## Browser Reuse (CDP)

The script connects to the user's **existing Chrome browser** via CDP (Chrome DevTools Protocol):

| Behavior | Description |
|----------|-------------|
| Auto-discovery | Finds Chrome debugging port via `DevToolsActivePort` file or common ports (9222, 9229, 9333) |
| Reuses Chrome | Connects to the user's daily Chrome — **preserves all login states** |
| New tab only | Opens a new tab for the target URL, closes it after fetch — **never touches user's existing tabs** |
| Safe disconnect | Drops CDP connection on exit without closing the browser |

## Error Handling

| Issue | Solution |
|-------|----------|
| Chrome remote debugging not found | Open `chrome://inspect/#remote-debugging` and enable "Allow remote debugging" |
| Empty snapshot | Page might need more time; use `--wait-selector` |
| Navigation failed | Check that the URL is accessible and valid |
| playwright-cli not found | Install via `npm install -g @playwright/cli` |

## Dependencies

- `playwright-cli` (`@playwright/cli`) — provides the Playwright Node.js module
- Chrome with remote debugging enabled
- `curl` (macOS built-in)
