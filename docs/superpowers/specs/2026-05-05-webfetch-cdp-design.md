---
name: webfetch-cdp-skill-design
date: 2026-05-05
status: draft
---

# webfetch-cdp Skill 设计文档

## 概述

创建一个全新的 skill `webfetch-cdp`，利用 playwright-cli 的 CDP 能力获取网页内容，通过 snapshot YAML 格式输出给 LLM 处理。

**核心定位：** 当需要访问网页、从网页获取信息时触发。

---

## 文件结构

```
skills/webfetch-cdp/
├── SKILL.md          # 技能描述 + 使用文档
└── webfetch-cdp.sh   # 核心脚本
```

---

## 脚本接口

### 输入参数

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `--url` | 是 | - | 目标 URL |
| `--wait-selector` | 否 | - | CSS 选择器，等待动态内容加载 |
| `--wait-time` | 否 | 10000 | 最大等待时间（毫秒） |
| `--viewport` | 否 | - | 视口大小，格式 `宽,高` 如 `1920,1080` |
| `--no-close` | 否 | false | 不关闭浏览器（用于保持会话） |

### 输出

直接将 playwright-cli 的 snapshot YAML 内容输出到 stdout。

**输出示例：**
```yaml
- generic [ref=e2]:
  - heading "Example Domain" [level=1] [ref=e3]
  - paragraph [ref=e4]: This domain is for use in documentation examples without needing permission.
  - paragraph [ref=e5]:
    - link "Learn more" [ref=e6]:
      - /url: https://iana.org/domains/example
```

---

## 核心流程

```
1. 检查是否有活跃浏览器
     ↓
   playwright-cli list
     ↓
2. 判断浏览器状态
     ├── 有活跃浏览器 → goto <url>
     └── 无活跃浏览器 → open <url>
     ↓
3. (可选) 调整视口 --viewport
     ↓
4. (可选) 等待动态内容
     await page.waitForSelector(selector, { timeout })
     ↓
5. 获取 snapshot
     snapshot --filename=<临时文件>
     ↓
6. 读取 YAML 内容 → stdout
     ↓
7. (可选) 关闭浏览器
     如果 --no-close 未设置 且 本次是新打开的浏览器 → close
     ↓
8. 清理临时文件
```

---

## 浏览器复用策略

### 判断逻辑

```bash
# 检查是否有活跃浏览器
playwright-cli list

# 输出为空或无活跃会话 → 需要 open
# 输出有活跃会话 → 只需要 goto
```

### 行为

| 场景 | 行为 |
|------|------|
| 无活跃浏览器 | `open <url>` → 获取 → `close` |
| 有活跃浏览器 | `goto <url>` → 获取（不关闭） |
| 有活跃浏览器 + `--no-close` | 同上，明确不关闭 |

### 重要原则

- **不强制管理 session**：复用默认会话，让用户通过原生 playwright-cli 命令管理多会话场景
- **自动清理**：脚本自己打开的浏览器，获取完成后自动关闭
- **不干扰外部会话**：如果是复用已有浏览器，不执行 close

---

## SKILL.md 设计

### 触发条件

当需要访问网页、从网页获取信息时触发。包括但不限于：

- 查看网页页面内容
- 获取特定信息（价格、新闻、文档等）
- 需要 JavaScript 渲染的 SPA 应用
- 动态加载内容（滚动加载、异步请求）
- 需要登录后访问的内容（配合已有浏览器会话）

### allowed-tools

```
Bash(webfetch-cdp.sh:*)
```

### 使用示例

**基本获取：**
```bash
webfetch-cdp.sh --url "https://example.com"
```

**等待动态内容：**
```bash
webfetch-cdp.sh --url "https://example.com/app" --wait-selector "#data-table" --wait-time 15000
```

**自定义视口：**
```bash
webfetch-cdp.sh --url "https://example.com" --viewport "1920,1080"
```

**保持浏览器打开：**
```bash
webfetch-cdp.sh --url "https://example.com/login" --no-close
```

---

## 与现有 webfetch 的区别

| 特性 | webfetch.sh | webfetch-cdp.sh |
|------|-------------|-----------------|
| 输出格式 | JSON（含 content, js_result 等字段） | snapshot YAML 原始输出 |
| 内容处理 | 提取 body.innerText 纯文本 | 保留页面结构（元素类型、层级、链接） |
| 适用场景 | 通用网页内容提取 | 需要结构化信息的场景 |

---

## 依赖

- `playwright-cli` - 全局安装或通过 npx 可用
