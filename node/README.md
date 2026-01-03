# Parachute Agent

AI agent backend for Parachute - define agents in markdown, chat with your knowledge graph.

## Overview

Parachute Agent is a simple backend that:
- **Reads agent definitions from markdown files** - No config files, just edit markdown
- **Chats via Claude Agent SDK** - Direct integration, no subprocess complexity
- **Persists sessions as markdown** - Human-readable, syncs across devices
- **Works with any markdown folder** - Obsidian vault, plain files, whatever

## Quick Start

```bash
npm install

# Point to your markdown folder
VAULT_PATH=/path/to/your/vault npm start

# Server runs on http://localhost:3333
```

## Agent Definitions

Create agents in an `agents/` folder as markdown files:

```markdown
---
name: Daily Reflection
description: Process daily journal entries
model: claude-sonnet-4-20250514
system_prompt: |
  You are a thoughtful reflection partner.
  Help the user process their daily notes.
---

# Daily Reflection Agent

Additional context for the agent goes here.
```

## API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/agents` | GET | List all agents |
| `/api/chat` | POST | Send message to agent |
| `/api/chat/sessions` | GET | List chat sessions |
| `/api/chat/session` | DELETE | Clear a session |

### Chat Request

```bash
curl -X POST http://localhost:3333/api/chat \
  -H "Content-Type: application/json" \
  -d '{"agentPath": "agents/daily-reflection.md", "message": "Hello!"}'
```

## Architecture

```
┌─────────────────┐     ┌─────────────────┐
│ Parachute App   │     │ Obsidian Plugin │
└────────┬────────┘     └────────┬────────┘
         │                       │
         └───────────┬───────────┘
                     ▼
         ┌───────────────────────┐
         │   Parachute Agent     │
         │   (this backend)      │
         │                       │
         │  - Load agent .md     │
         │  - Chat via Claude SDK│
         │  - Session persistence│
         └───────────────────────┘
                     │
                     ▼
              Claude Agent SDK
```

## Project Structure

```
agent/                     # You are here (within parachute monorepo)
├── server.js              # Express API
├── lib/
│   ├── orchestrator.js    # Agent execution via Claude SDK
│   ├── session-manager.js # Session persistence (markdown)
│   ├── agent-loader.js    # Load agent definitions
│   └── ...
├── obsidian-plugin/       # Optional Obsidian integration
└── sample-vault/          # Example agents
```

## Obsidian Plugin

An optional Obsidian plugin is included for in-editor agent interaction.

```bash
cd obsidian-plugin
npm install && npm run build
```

Copy to your vault's `.obsidian/plugins/parachute-agent/` folder.

## Authentication

This project uses **Claude Agent SDK authentication** via `claude login`. No API keys needed!

```bash
# One-time setup
npm install -g @anthropic-ai/claude-code
claude login
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_PATH` | `./sample-vault` | Path to markdown folder |
| `PORT` | `3333` | Server port |

## Part of Parachute

This is the agent backend within the [Parachute monorepo](../README.md) — an open-source "second brain" powered by AI.

- **[agent/](.)** - Agent backend (you are here)
- **[app/](../app/)** - Flutter mobile/desktop app
- **[Root README](../README.md)** - Monorepo overview and quick start

---

**Last Updated:** December 22, 2025
