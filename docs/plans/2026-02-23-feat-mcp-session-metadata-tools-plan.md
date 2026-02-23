---
title: "feat: MCP tools for session title and summary updates"
type: feat
date: 2026-02-23
issue: 120
---

# feat: MCP tools for session title and summary updates

## Overview

Add `update_session_title` and `update_session_summary` MCP tools to `mcp_server.py`. Claude calls these tools to manage its own session metadata — the agent-native pattern. The MCP server uses its own DB connection that works from any trust level, including Docker sandboxed sessions, fixing the silent failure that currently affects most Parachute sessions.

As a companion change, remove the DB write calls from `activity_hook.py` (title/summary). The hook's daily activity log write is unchanged and continues working from all contexts.

## Problem Statement

`activity_hook.py` calls `update_session_title()` / `update_session_summary()`, which use `get_database()` — the server process singleton. Hook subprocesses in Docker sandboxes have no access to the host DB file. The writes silently fail. Most Parachute sessions never get a title or summary.

MCP is already the established cross-boundary channel. The `parachute` MCP server subprocess gets `PARACHUTE_SESSION_ID` and `PARACHUTE_VAULT_PATH` injected and maintains its own DB connection. It's the right place for this.

## Proposed Solution

Two new MCP tools in `mcp_server.py`:

- **`update_session_title`** — writes title + sets `metadata.title_source = "ai"`. Refuses silently if `title_source == "user"` (respects user renames).
- **`update_session_summary`** — writes summary. No guard needed.

Both tools derive `session_id` from the ambient `SessionContext` (already loaded from env vars at startup). No parameter needed from Claude — the tool always operates on the current session.

Remove `await update_session_title(...)` and `await update_session_summary(...)` calls from `handle_stop_hook()` in `activity_hook.py`. The helpers can be removed too.

System prompt work (upcoming, separate issue) will instruct Claude when to call these tools.

## Technical Considerations

**`SessionContext` is already available.** `mcp_server.py` loads it at startup via `SessionContext.from_env()`. Tool handlers already have access to `session_id` through this context.

**MCP uses its own `get_db()`, not `get_database()`.** The module-level `get_db()` in `mcp_server.py` opens a direct connection to `$PARACHUTE_VAULT_PATH/Chat/sessions.db`. No server process singleton involved.

**`title_source` guard lives in the MCP tool**, not the activity_hook. Pattern: read session → check `session.metadata.get("title_source") == "user"` → if so, return a "protected" message without writing.

**`SessionUpdate` already has `summary` and `title` fields** (from PR #119). The DB layer handles them correctly.

**Tool input schema** — both tools take a single required string param. No `session_id` (implicit from context). Claude's descriptions must be clear enough for the system prompt to guide correct usage.

**No `get_session_metadata` tool needed** — `get_session` already exists and returns the full session including `title`, `summary`, and `metadata`. Claude can call that first if it needs to check before updating.

## Acceptance Criteria

### Functional

- [ ] `update_session_title` tool registered in `TOOLS` list in `mcp_server.py`
- [ ] `update_session_summary` tool registered in `TOOLS` list in `mcp_server.py`
- [ ] Both tools dispatch through `handle_tool_call()` to dedicated handler functions
- [ ] `update_session_title` respects `title_source == "user"` guard — returns a "title protected by user" message without writing
- [ ] `update_session_title` sets `metadata.title_source = "ai"` on write
- [ ] Both tools derive `session_id` from ambient `SessionContext` (no parameter from caller)
- [ ] Both tools return a clear success or error JSON string
- [ ] Both tools return an error if `SessionContext.session_id` is None (no session context available)
- [ ] `handle_stop_hook()` in `activity_hook.py` no longer calls `update_session_title()` or `update_session_summary()`
- [ ] Daily activity log write in `activity_hook.py` is unchanged

### Quality

- [ ] Unit tests for `update_session_title` handler (success, title_source guard, missing session context)
- [ ] Unit tests for `update_session_summary` handler (success, missing session context)
- [ ] Existing activity_hook tests continue to pass
- [ ] No regressions in MCP server tests

## Implementation Plan

### Phase 1 — MCP tool handlers

**`computer/parachute/mcp_server.py`**

Add two handler functions after the existing session tag handlers:

```python
async def _handle_update_session_title(title: str) -> dict[str, Any]:
    """Update the current session's title. Respects user-set title protection."""
    ctx = _get_session_context()  # module-level SessionContext
    if not ctx.session_id:
        return {"error": "No session context available"}

    db = await get_db()
    session = await db.get_session(ctx.session_id)
    if session is None:
        return {"error": f"Session not found: {ctx.session_id}"}

    # Respect user-set title
    title_source = (session.metadata or {}).get("title_source")
    if title_source == "user":
        return {"status": "protected", "message": "Title set by user — not overwritten"}

    metadata = dict(session.metadata or {})
    metadata["title_source"] = "ai"
    from parachute.models.session import SessionUpdate
    await db.update_session(ctx.session_id, SessionUpdate(title=title, metadata=metadata))
    return {"status": "ok", "title": title}


async def _handle_update_session_summary(summary: str) -> dict[str, Any]:
    """Update the current session's summary."""
    ctx = _get_session_context()
    if not ctx.session_id:
        return {"error": "No session context available"}

    db = await get_db()
    from parachute.models.session import SessionUpdate
    await db.update_session(ctx.session_id, SessionUpdate(summary=summary))
    return {"status": "ok"}
```

Add to `TOOLS` list (after `remove_session_tag`):

```python
Tool(
    name="update_session_title",
    description=(
        "Update the title of the current session. "
        "Call this after the first substantive exchange to give the session a descriptive name. "
        "Will not overwrite a title the user has manually set."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": "Short, descriptive title (5-10 words) summarizing the session topic",
            }
        },
        "required": ["title"],
    },
),
Tool(
    name="update_session_summary",
    description=(
        "Update the summary of the current session. "
        "Call this periodically to keep a current description of what has been discussed. "
        "The summary is used as a preview in session lists and for future context."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "summary": {
                "type": "string",
                "description": "1-2 sentence summary of the session's key topics and outcomes so far",
            }
        },
        "required": ["summary"],
    },
),
```

Add dispatch in `handle_tool_call()`:

```python
elif name == "update_session_title":
    result = await _handle_update_session_title(title=arguments["title"])
elif name == "update_session_summary":
    result = await _handle_update_session_summary(summary=arguments["summary"])
```

### Phase 2 — Remove hook DB writes

**`computer/parachute/hooks/activity_hook.py`**

In `handle_stop_hook()`, remove:
```python
# Remove these two calls:
await update_session_title(session_id, new_title, title_source="ai")
# ... and:
await update_session_summary(session_id, summary)
```

Also remove the `update_session_title()` and `update_session_summary()` helper functions (lines ~412–442) — they are no longer called from anywhere.

> Note: The `_should_update_title()`, `call_summarizer()`, and `append_activity_log()` functions remain. The daily activity log still uses `title` and `summary` in its JSONL entries — those values come from the in-memory parse, not the DB, so they still work correctly.

### Phase 3 — Tests

**`computer/tests/unit/test_mcp_session_metadata.py`** (new file)

```python
class TestUpdateSessionTitleTool:
    async def test_success(self, test_database, monkeypatch): ...
    async def test_respects_user_title_source(self, test_database, monkeypatch): ...
    async def test_sets_ai_title_source(self, test_database, monkeypatch): ...
    async def test_no_session_context(self, monkeypatch): ...
    async def test_session_not_found(self, monkeypatch): ...

class TestUpdateSessionSummaryTool:
    async def test_success(self, test_database, monkeypatch): ...
    async def test_no_session_context(self, monkeypatch): ...
```

Tests use `monkeypatch` to set `PARACHUTE_SESSION_ID` env var and inject `test_database` as the MCP's db connection.

## Dependencies & Risks

- **PR #119 must be merged first** — `SessionUpdate.summary` and the `summary` column are added there. This plan depends on them.
- **System prompt not in scope** — tools will be registered but Claude won't call them until the system prompt work (separate issue) instructs it. This is fine — tools are silent until called.
- **`_get_session_context()` accessor** — check whether the module-level `SessionContext` is already exposed via a function or just directly as `_session_context`. Use whichever pattern is cleaner; initialize it lazily if needed.
- **Concurrent writes** — during the transition period, if a non-sandboxed session somehow still calls both the hook and the MCP tool, there's a benign last-write-wins race. Low risk since hook writes are being removed.

## References

- `computer/parachute/mcp_server.py:109` — `get_db()`, `SessionContext.from_env()`, `TOOLS` list, `handle_tool_call()`
- `computer/parachute/hooks/activity_hook.py:412` — `update_session_title()` / `update_session_summary()` to be removed
- `computer/parachute/models/session.py` — `Session`, `SessionUpdate` with `title`, `summary`, `metadata`
- Issue #119 (PR) — adds `summary` column and `SessionUpdate.summary`
- Brainstorm: `docs/brainstorms/2026-02-23-mcp-session-metadata-tools-brainstorm.md`
