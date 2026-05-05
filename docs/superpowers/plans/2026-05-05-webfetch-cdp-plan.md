# webfetch-cdp Skill 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 创建一个利用 playwright-cli CDP snapshot 获取网页内容的全新 skill

**Architecture:** 单一脚本封装 playwright-cli 命令，自动检测浏览器状态（复用或新建），获取 snapshot YAML 输出给 LLM 处理

**Tech Stack:** Bash, playwright-cli

---

## 文件结构

| 文件 | 操作 | 说明 |
|------|------|------|
| `skills/webfetch-cdp/SKILL.md` | 创建 | 技能描述文档 |
| `skills/webfetch-cdp/webfetch-cdp.sh` | 创建 | 核心脚本 |
| `docs/superpowers/specs/2026-05-05-webfetch-cdp-design.md` | 已存在 | 设计文档 |

---

## Task 1: 创建 webfetch-cdp.sh 脚本

**Files:**
- Create: `skills/webfetch-cdp/webfetch-cdp.sh`

- [ ] **Step 1: 创建脚本骨架和参数解析**

```bash
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
```

- [ ] **Step 2: 添加 playwright-cli 检测和浏览器状态检查**

在参数解析后添加：

```bash
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
```

- [ ] **Step 3: 添加核心获取逻辑**

添加主函数：

```bash
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
```

- [ ] **Step 4: 添加执行和输出部分**

在脚本末尾添加：

```bash
# Run fetch
fetch_page
```

- [ ] **Step 5: 设置脚本可执行权限并提交**

```bash
chmod +x skills/webfetch-cdp/webfetch-cdp.sh
git add skills/webfetch-cdp/webfetch-cdp.sh
git commit -m "feat: add webfetch-cdp script with CDP snapshot support"
```

---

## Task 2: 创建 SKILL.md 文档

**Files:**
- Create: `skills/webfetch-cdp/SKILL.md`

- [ ] **Step 1: 创建完整的 SKILL.md**

```markdown
---
name: webfetch-cdp
description: >
  Fetch web page content using playwright-cli CDP snapshot for LLM processing.
  Use when the user needs to access a webpage, extract information from a website,
  or get content from JavaScript-rendered pages (SPAs, dynamic content).
  Triggers whenever web page access or information extraction from websites is needed.
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
```

- [ ] **Step 2: 提交 SKILL.md**

```bash
git add skills/webfetch-cdp/SKILL.md
git commit -m "docs: add webfetch-cdp skill documentation"
```

---

## Task 3: 测试验证

**Files:**
- Test: 手动测试脚本功能

- [ ] **Step 1: 测试基本功能**

```bash
./skills/webfetch-cdp/webfetch-cdp.sh --url "https://example.com"
```

Expected: 输出 YAML 格式的 snapshot 内容，包含页面结构信息。

- [ ] **Step 2: 测试浏览器复用**

```bash
# 第一次：打开新浏览器
./skills/webfetch-cdp/webfetch-cdp.sh --url "https://example.com" --no-close

# 第二次：复用已有浏览器
./skills/webfetch-cdp/webfetch-cdp.sh --url "https://iana.org"

# 清理：关闭浏览器
playwright-cli close
```

Expected: 第二次调用不打开新浏览器，直接使用已有的。

- [ ] **Step 3: 测试错误处理**

```bash
# 缺少 URL 参数
./skills/webfetch-cdp/webfetch-cdp.sh 2>&1

# 无效 URL
./skills/webfetch-cdp/webfetch-cdp.sh --url "not-a-url" 2>&1
```

Expected: 输出清晰的错误信息到 stderr，退出码非 0。
