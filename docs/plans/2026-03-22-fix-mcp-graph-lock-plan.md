---
title: "Route remaining MCP session tools through HTTP API"
type: fix
date: 2026-03-22
issue: 308
---

# Route remaining MCP session tools through HTTP API

## Problem

The direct MCP server (`mcp_server.py`) still uses `get_db()` for 6 session/tag tools, which opens a second Kuzu graph connection that conflicts with the server's lock. These tools fail silently whenever the server is running (which is always).

**Already fixed:** The 7 vault tools (search_memory, list_chats, etc.) were already migrated to HTTP loopback via `_brain_call()`. Only session/tag tools remain.

## Affected Tools

| Tool | Current | Needs |
|------|---------|-------|
| `get_session` | `get_db()` | HTTP endpoint |
| `search_by_tag` | `get_db()` | HTTP endpoint |
| `list_tags` | `get_db()` | HTTP endpoint |
| `add_session_tag` | `get_db()` | HTTP endpoint |
| `remove_session_tag` | `get_db()` | HTTP endpoint |
| `create_session` | `get_db()` | HTTP endpoint |

## Fix

### 1. Add HTTP endpoints to `api/sessions.py` (or `api/brain.py`)

```
GET  /api/sessions/{id}           → get_session
GET  /api/sessions/tags           → list_tags
GET  /api/sessions/tags/{tag}     → search_by_tag
POST /api/sessions/{id}/tags      → add_session_tag
DELETE /api/sessions/{id}/tags/{tag} → remove_session_tag
POST /api/sessions                → create_session
```

These endpoints call the existing `BrainChatStore` / `SessionManager` methods — no new business logic needed.

### 2. Update `mcp_server.py` tool handlers

Replace `get_db()` calls with `_brain_call()` to the new endpoints. Same pattern as the vault tools already use.

### 3. Remove `get_db()` from `mcp_server.py`

Once all tools use HTTP loopback, remove:
- `get_db()` function
- `_db` global
- Direct `BrainChatStore` / `SessionManager` imports
- `asyncio.get_event_loop().run_until_complete()` calls for DB init

## Acceptance Criteria

- [x] All 6 session/tag tools work when the server is running
- [x] `get_db()` removed from `mcp_server.py`
- [x] Existing vault tool routing via `_brain_call()` unchanged
- [x] `create_session` respects spawn limits and rate limiting via the endpoint
- [x] Trust level enforcement preserved (session context still checked)

## Context

- `_brain_call()` already exists and handles GET/POST with error handling (mcp_server.py:483-510)
- `BrainChatStore` has all the methods needed — endpoints just need to expose them
- Check `api/sessions.py` for existing session endpoints to avoid collisions
- `create_session` is the most complex — has spawn limits, rate limiting, and session hierarchy. Keep that logic server-side.
