---
title: "feat: generate session title/summary from server streaming event loop"
type: feat
date: 2026-02-23
issue: 122
---

# feat: Session Title/Summary via Server Event Loop

## Overview

Move automatic session title and summary generation from a Stop hook (`activity_hook.py`) into the server's streaming event loop. The server already processes every session's events — triggering summarization there works uniformly for direct and sandboxed sessions, with no hook registration, no Python path portability problems, and no settings.json complexity.

## Problem Statement

The current Stop hook approach has two structural problems:

1. **Hook portability**: The hook command embeds a host-specific Python path. Sandboxed sessions run inside Docker where that path doesn't exist — hooks silently fail and titles/summaries are never generated for sandboxed sessions.
2. **Hook registration**: The vault's `.claude/settings.json` must be created, maintained, and kept in sync with the installed Python path — operational complexity that grows over time.

## Solution

The orchestrator's `run_streaming()` already yields every event including the `result` event (session complete). A fire-and-forget `asyncio.create_task()` launched just before `yield DoneEvent()` runs summarization as a background task. By this point all data needed is already in memory — no JSONL transcript parsing required.

## Technical Approach

### What Already Exists (Keep)

- `PATCH /api/chat/{session_id}/metadata` endpoint (`api/sessions.py:249`) — the write path, enforces `title_source == "user"` guard
- `update_session_title` / `update_session_summary` MCP tools — for agent-native use (Claude calling them explicitly)
- `call_summarizer()` in `activity_hook.py:295` — the Claude SDK call that generates title/summary text; reuse this logic
- `_should_update_title()` in `activity_hook.py:158` — exchange cadence logic ({1, 3, 5} then every 10th); reuse
- `get_daily_summarizer_session()` / `save_daily_summarizer_session()` — per-day summarizer session continuity; reuse
- Activity logging in `handle_stop_hook()` — unrelated to title/summary, stays in the hook

### New Module: `parachute/core/session_summarizer.py`

Extract the title/summary logic from `activity_hook.py` into a proper server-side module. This avoids the orchestrator importing from `parachute/hooks/` (which is a subprocess utility, not a library), and makes the logic testable in isolation.

**Contents:**
- `SUMMARIZER_SYSTEM_PROMPT` — moved from `activity_hook.py:41`
- `_should_update_title(exchange_number: int) -> bool` — moved from `activity_hook.py:158`
- `get_exchange_number(session: Session) -> int` — computes exchange number from `session.message_count`
- `build_summarizer_prompt(session, message, result_text, tool_calls, exchange_number) -> str` — builds the prompt
- `call_summarizer(session, prompt, settings) -> tuple[str | None, str | None]` — runs the Claude SDK query, returns `(title, summary)`
- `summarize_session(session_id, message, result_text, tool_calls, database, settings) -> None` — the top-level async function called from the orchestrator; handles exchange gating, summarization, and writing

### Orchestrator Change (`orchestrator.py`)

Insert a single fire-and-forget task just before `yield DoneEvent()` at line 1299:

```python
# computer/parachute/core/orchestrator.py (near line 1299)
# Kick off title/summary generation as a background task
if captured_session_id and session:
    from parachute.core.session_summarizer import summarize_session
    asyncio.create_task(
        summarize_session(
            session_id=captured_session_id,
            message=message,
            result_text=result_text,
            tool_calls=tool_calls or [],
            database=self.database,
            settings=self.settings,
        )
    )

yield DoneEvent(...).model_dump(by_alias=True)
```

**Exchange number computation:** `session.message_count` counts prior messages. Each exchange = 2 messages (user + assistant). Exchange number = `(session.message_count // 2) + 1`.

**Write path:** `summarize_session()` writes directly via `self.database.update_session()` — no HTTP roundtrip. Must replicate the `title_source != "user"` guard (same logic as the PATCH endpoint).

### activity_hook.py Changes

Remove from `handle_stop_hook()`:
- Steps 3 (`_should_update_title` check), 5 (`call_summarizer`), and 7 (`update_session_metadata` for title/summary)
- The `_should_update_title`, `SUMMARIZER_SYSTEM_PROMPT` constants (moved to `session_summarizer.py`)
- The `_get_session()` fetch (no longer needed for title/summary; still needed for activity logging if `agent_type` is used)

Keep in `handle_stop_hook()`:
- Step 2: `read_last_exchange()` (for activity logging)
- Step 6: `append_activity_log()` (Daily/.activity/ JSONL files)
- The `get_daily_summarizer_session` / `save_daily_summarizer_session` functions move to `session_summarizer.py`

## Implementation Plan

### Phase 1: Extract to `session_summarizer.py`

1. Create `computer/parachute/core/session_summarizer.py`
2. Move from `activity_hook.py`:
   - `SUMMARIZER_SYSTEM_PROMPT`
   - `_should_update_title()` and the `_TITLE_UPDATE_EXCHANGES` / `_TITLE_UPDATE_INTERVAL` constants
   - `get_daily_summarizer_session()` / `save_daily_summarizer_session()`
   - Summarizer prompt building logic (currently inline in `call_summarizer()`)
3. Implement `summarize_session()` as the top-level entry point:
   - Computes exchange number
   - Gates on `_should_update_title()`
   - Fetches session from DB for `title` and `metadata.title_source`
   - Calls the Claude SDK summarizer
   - Writes result via `database.update_session()` (with `title_source` guard)
   - Handles all exceptions — fire-and-forget, never raises

### Phase 2: Wire into Orchestrator

1. Import `summarize_session` in `orchestrator.py`
2. Add `asyncio.create_task(summarize_session(...))` just before `yield DoneEvent()`
3. Pass `message`, `result_text`, `tool_calls`, `captured_session_id`, `session`, `self.database`, `self.settings`

### Phase 3: Trim `activity_hook.py`

1. Remove title/summary steps from `handle_stop_hook()`
2. Remove constants/helpers that moved to `session_summarizer.py`
3. Keep activity logging intact
4. Update the docstring/comment to reflect narrowed scope (activity logging only)

### Phase 4: Tests

1. `tests/unit/test_session_summarizer.py` — unit tests for:
   - `_should_update_title()` cadence (exchanges {1, 3, 5}, every 10th)
   - `summarize_session()` skips when exchange not in cadence
   - `summarize_session()` respects `title_source == "user"` guard
   - `summarize_session()` writes title + summary when appropriate
   - Exception handling (never raises)
2. Update `tests/unit/test_activity_hook.py` — remove tests for moved functions

## Acceptance Criteria

- [ ] New chat session: after the 1st AI response, title is generated automatically (within a few seconds, background)
- [ ] Title is never overwritten when `title_source == "user"` (user-renamed sessions stay renamed)
- [ ] Works for both direct and sandboxed sessions (orchestrator handles both)
- [ ] `activity_hook.py` still writes Daily/.activity/ JSONL logs (activity logging unaffected)
- [ ] No Stop hook configuration needed in vault `.claude/settings.json`
- [ ] `call_summarizer()` failure is caught silently (never breaks the streaming response)
- [ ] Exchange cadence preserved: fires at 1, 3, 5, then every 10th

## Files Touched

| File | Change |
|------|--------|
| `computer/parachute/core/session_summarizer.py` | **New** — extracted title/summary logic |
| `computer/parachute/core/orchestrator.py` | Add `asyncio.create_task(summarize_session(...))` before `yield DoneEvent()` |
| `computer/parachute/hooks/activity_hook.py` | Remove title/summary steps, keep activity logging |
| `computer/tests/unit/test_session_summarizer.py` | **New** — unit tests |
| `computer/tests/unit/test_activity_hook.py` | Remove tests for moved functions |

## References

- `orchestrator.py:1231` — where `result` event is received
- `orchestrator.py:1299` — `yield DoneEvent(...)` — insertion point for background task
- `activity_hook.py:73` — `handle_stop_hook()` — source of logic to move/remove
- `activity_hook.py:158` — `_should_update_title()` — exchange cadence
- `activity_hook.py:295` — `call_summarizer()` — Claude SDK query to reuse
- `api/sessions.py:249` — `PATCH /chat/{session_id}/metadata` — write path (or bypass via `database.update_session()`)
- Issue #121 — PR that added the REST endpoint and MCP tools
- Issue #119 — PR that added the `summary` column
