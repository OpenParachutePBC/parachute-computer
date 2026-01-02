# Parachute Base - Development Guide

## Project Overview

Parachute Base is the backend server for the Parachute ecosystem. It provides AI agent execution, session management, and per-module RAG search. Any Parachute module (Chat, Daily, Build) can call Base for AI functionality.

## Architecture

```
┌─────────────────┐     ┌─────────────────┐
│ Parachute Chat  │     │ Parachute Daily │
└────────┬────────┘     └────────┬────────┘
         │                       │
         └───────────┬───────────┘
                     ▼ HTTP/SSE (port 3333)
         ┌───────────────────────┐
         │   Express Server      │
         └───────────┬───────────┘
                     │
          ┌──────────┴──────────┐
          ▼                     ▼
   ┌──────────────┐      ┌──────────────┐
   │ Session Mgr  │      │ Orchestrator │
   │ (markdown)   │      │ (Claude SDK) │
   └──────────────┘      └──────────────┘
```

## Key Files

| File | Purpose |
|------|---------|
| `server.js` | Express API server (8 endpoints) |
| `lib/orchestrator.js` | Agent execution via Claude SDK |
| `lib/session-manager-v2.js` | Session persistence as markdown |
| `lib/module-indexer.js` | Per-module RAG indexing |
| `lib/module-search.js` | Semantic + keyword search |
| `lib/chat-scanner.js` | Chat module content scanner |
| `lib/default-prompt.js` | Built-in system prompt |
| `lib/logger.js` | Structured logging |

## Commands

```bash
npm start                           # Start server
npm run dev                         # Start with auto-reload
npm test                            # Run unit tests
VAULT_PATH=/path/to/vault npm start # Custom vault
```

## API Endpoints (8 total)

### Core Chat
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check |
| `/api/chat` | POST | Run agent (streaming SSE) |
| `/api/chat` | GET | List sessions |
| `/api/chat/:id` | GET | Get session with messages |
| `/api/chat/:id` | DELETE | Delete session |

### Module Resources
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/modules/:mod/prompt` | GET | Get module's system prompt |
| `/api/modules/:mod/prompt` | PUT | Update module's CLAUDE.md |
| `/api/modules/:mod/search` | GET | Search module content |
| `/api/modules/:mod/index` | POST | Rebuild module index |

## POST /api/chat (Main Endpoint)

Streaming agent execution via SSE:

```javascript
// Request
POST /api/chat
{
  "message": "Hello!",
  "sessionId": "optional-uuid",      // Omit for new session
  "module": "chat",                  // chat, daily, build
  "systemPrompt": "...",             // Optional override
  "initialContext": "...",           // First message context
  "priorConversation": "...",        // For continuations
  "continuedFrom": "session-id"      // Link to original
}

// SSE Events
data: {"type": "session", "sessionId": "...", "title": "..."}
data: {"type": "model", "model": "claude-opus-4-5-20250514"}
data: {"type": "text", "content": "Hello! How can I..."}
data: {"type": "thinking", "content": "Let me think about..."}
data: {"type": "tool_use", "name": "Read", "input": {...}}
data: {"type": "tool_result", "id": "...", "content": "..."}
data: {"type": "done", "sessionId": "...", "title": "...", "model": "..."}
data: {"type": "aborted", "message": "Stream stopped by user"}
data: {"type": "session_unavailable", "reason": "...", "hasMarkdownHistory": true}
```

## Module System

Each module has its own:
- Session folder: `{Module}/sessions/`
- RAG index: `{Module}/index.db`
- System prompt: `{Module}/CLAUDE.md` (optional, falls back to default)

**Supported modules**: `chat`, `daily`, `build`

## Session Storage

Sessions use **lightweight pointer architecture**—markdown files contain only frontmatter metadata, with SDK JSONL files as the source of truth for messages.

Stored in `{Module}/sessions/*.md`:

```markdown
---
sdk_session_id: "abc-123-def"
title: "Project Discussion"
created_at: "2025-12-20T10:30:00Z"
last_accessed: "2025-12-20T11:00:00Z"
archived: false
message_count: 12
source: "parachute"
---
```

For imported Claude Code sessions, includes `working_directory` and `model` fields.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_PATH` | `./sample-vault` | Path to vault folder |
| `PORT` | `3333` | Server port |
| `HOST` | `0.0.0.0` | Bind address |
| `LOG_LEVEL` | `INFO` | DEBUG, INFO, WARN, ERROR |

## Authentication

Uses **Claude Agent SDK authentication** via `claude login`. No API keys needed.

```bash
npm install -g @anthropic-ai/claude-code
claude login
```

---

**Last Updated**: January 2, 2026
