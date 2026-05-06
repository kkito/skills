# Skills Library

A personal collection of custom skills for extending AI assistant capabilities.

## Overview

This repository contains custom skills that can be installed and used with AI assistants like Qwen Code. Each skill provides specialized functionality for specific tasks and workflows.

## Structure

```
skills/
├── <skill-name>/
│   ├── SKILL.md          # Skill definition file
│   ├── scripts/          # Optional: executable scripts
│   └── references/       # Optional: reference materials
└── ...
```

## Installation

```bash
npx skills add kkito/skills
```

> **注意:** 仅在自己机器上 macOS 15.7.2 上测试过。安装后 skills 目录下的技能即可在 AI 助手中使用。

## Available Skills

| Skill | Description |
|-------|-------------|
| `webfetch-cdp` | 通过 CDP (Chrome DevTools Protocol) 连接用户正在使用的 Chrome 浏览器，实现网页内容抓取 (webfetch) 和网页搜索 (websearch)。无需 API Key，利用浏览器登录态，支持 SPA/JS 渲染页面。输出结构化 YAML 快照，适合 LLM 处理。 |

## License

MIT
