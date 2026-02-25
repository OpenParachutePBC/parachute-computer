---
title: "MCP tools for session title and summary updates"
status: brainstorm
priority: P2
module: computer, chat
date: 2026-02-23
issue: 120
---

# MCP Tools for Session Metadata Updates

## Problem

The current `activity_hook.py` approach to updating session titles and summaries silently fails for most sessions. Here's why:

1. The hook runs as a subprocess on the `Stop` SDK event.
2. It calls `update_session_title()` / `update_session_summary()`, which use `get_database()` — the server process's singleton.
3. **Inside a Docker sandbox**, the hook subprocess has no access to the host DB file. `localhost:3333` inside the container points to the container's port, not the host. The write silently fails.

Most Parachute sessions operate sandboxed. So most sessions never get titled or summarized.

## Context

- MCP is **already the established cross-boundary channel** for sandboxed sessions. The `parachute` MCP server is spawned by the Claude Agent SDK with `PARACHUTE_SESSION_ID`, `PARACHUTE_VAULT_PATH`, etc. injected. It manages its own DB connection (not `get_database()`).
- The MCP server already has tools for reading sessions (`get_session`, `list_recent_sessions`, etc.) but no tools for **writing** session metadata.
- The `Session` model now has `title`, `summary`, and `metadata.title_source` fields (PR #119). `title_source` guards against overwriting user-set titles.
- The user's system prompt work is coming next — this feature feeds directly into it.

## What We're Building

Add `update_session_title` and `update_session_summary` MCP tools to `mcp_server.py`. Claude calls these tools explicitly as part of its session lifecycle — the same way it uses Brain tools or session-search tools. The MCP server writes to the DB, which works from any trust level including Docker sandboxed.

The system prompt (upcoming work) will instruct Claude when to call these tools: after the first substantive exchange to set a title, and periodically to refresh the summary.

## Approaches

### A — MCP tools only (replace hooks for metadata)

Add `update_session_title` and `update_session_summary` to `mcp_server.py`. Claude generates title/summary inline and calls these tools. Remove or no-op the corresponding code in `activity_hook.py`.

**Pros:**
- Clean, agent-native architecture — the AI is an active participant in its own metadata
- Works from any trust level including Docker sandbox
- No Haiku API call needed (Claude has full context, generates better titles)
- Simpler overall system — one code path

**Cons:**
- Requires system prompt guidance to work reliably — Claude won't call tools it doesn't know about
- Title/summary generation moves from background (free) to inline (uses main model tokens)

**Best for:** Long-term, if system prompt guidance can be relied on. This is the right architecture.

### B — MCP tools + keep activity_hook for non-sandboxed

Add MCP tools AND keep `activity_hook.py` doing the same work. Non-sandboxed sessions continue using the hook; sandboxed sessions use MCP tools.

**Pros:**
- Graceful transition — nothing breaks
- Hook still provides a backstop for sessions without system prompt guidance

**Cons:**
- Two code paths that can conflict (race conditions on who writes title/summary last)
- The hook's Haiku call + the AI's own title generation can diverge
- More complexity for maintenance

**Best for:** Short-term transition if you're not ready to deprecate the hook yet.

### C — HTTP endpoint for hooks to call

Keep `activity_hook.py` unchanged but add a `PUT /api/sessions/{id}` REST endpoint. The hook calls this endpoint instead of writing the DB directly.

**Pros:**
- Preserves the "background, automatic" nature
- No system prompt needed

**Cons:**
- Doesn't solve the sandbox problem — from inside Docker, `localhost:3333` is the container port, not host
- Requires network configuration (port mapping) per-deployment
- Adds a new API endpoint that duplicates MCP functionality

**Not recommended** — doesn't actually fix the core issue.

## Recommendation

**Approach A** — MCP tools, replacing the hook's metadata-update responsibility.

This is the agent-native approach: Claude is aware of and manages its own session metadata. The system prompt makes this reliable. Activity log (`Daily/.activity/`) still works via hook (it's just JSON logging, no DB write, so sandbox isn't an issue).

The existing hook code in `activity_hook.py` for title/summary writes can be left in place as a no-op fallback for the rare non-sandboxed case, but the MCP path becomes the primary.

## Key Decisions

1. **Two tools or one?** Leaning toward two (`update_session_title`, `update_session_summary`) — clearer intent, easier for Claude to know which to call and when. Mirrors the Brain tool pattern (separate create/update/delete per operation).

2. **session_id parameter?** Not needed — the MCP server already has `PARACHUTE_SESSION_ID` injected as env var. The tool operates on "the current session" implicitly.

3. **title_source guard?** Yes. `update_session_title` should check `metadata.title_source == "user"` and refuse to overwrite user-set titles. Same guard that exists in `activity_hook.py`.

4. **When does Claude call these?** System prompt will specify: call `update_session_title` after the first substantive exchange if no user-set title exists; call `update_session_summary` after meaningful exchanges. Exact cadence TBD in system prompt work.

5. **Activity hook fate?** The hook's Haiku-based title/summary generation becomes redundant. For now, keep the hook but remove or no-op its DB writes (it still generates the daily activity log). Formally deprecate in a follow-up.

## Open Questions

- Should `update_session_title` / `update_session_summary` be a single combined tool or two? (Leaning: two, for clarity)
- What's the right token budget for inline title/summary generation? Should we keep the Haiku call pattern or have the main model generate them?
- How do we handle the transition period where some sessions have system prompt guidance and some don't?
- Should there also be a `get_session_metadata` tool so Claude can read its own title/summary before deciding to update?

## References

- `computer/parachute/mcp_server.py` — MCP tool registration and dispatch pattern
- `computer/parachute/hooks/activity_hook.py` — existing title/summary logic, cadence gate, `title_source` guard
- `computer/parachute/lib/mcp_loader.py` — how session env vars are injected into MCP subprocess
- PR #119 — adds `summary` column and `update_session_summary` hook helper
