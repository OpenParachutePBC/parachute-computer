---
title: "feat: Hooks expansion — session summaries and context re-injection"
type: feat
date: 2026-02-23
issue: 61
---

# feat: Hooks expansion — session summaries and context re-injection

## Overview

Expand the hook system with two new capabilities: (1) persist AI-generated chat summaries to the session model so they're searchable and available as session previews, and (2) add a context re-injection hook that fires before context compaction to preserve critical context across long sessions.

The curator auto-titling work from this issue is **already done** — `activity_hook.py` generates titles via Haiku on the `Stop` SDK event and updates the session. This plan focuses on what's missing.

## Problem Statement / Motivation

**Chat summaries are generated but discarded.** `activity_hook.py` already calls Haiku after each exchange and parses `SUMMARY: <text>` from the response — but the summary is only written to the daily activity log JSONL (`vault/Daily/.activity/YYYY-MM-DD.jsonl`). It never reaches the session record. This means:
- Session list shows only titles, no preview text
- Search can't find sessions by content (only title)
- Brain module can't access session knowledge without parsing raw transcripts
- Resuming old sessions provides no quick context about what was discussed

**Context is lost across compaction.** Long sessions get compacted, erasing project context, conventions, and decisions from the visible window. The Claude Code `PreCompact` hook event lets us re-inject critical context before this happens, but no hook is configured.

## Proposed Solution

### 1. Persist summaries to the session model

Add a `summary` column to the `sessions` table and `summary` field to the `Session` model. Update `activity_hook.py` to write the generated summary to `db.update_session()` alongside the title update. Expose `summary` in API responses.

### 2. Add context re-injection hook

Create `computer/parachute/hooks/context_hook.py` — a `PreCompact` hook that reads `vault/.parachute/profile.md` (or a session-specific context file) and writes it back into the conversation as a system reminder before compaction discards it.

## Technical Considerations

**Migration pattern:** The codebase uses `ALTER TABLE sessions ADD COLUMN` migrations inside `database.py`'s `initialize_schema()`. The current schema version is v13 (workspace_id). This adds v14 (`summary TEXT`).

**`activity_hook.py` change is minimal:** The summary is already parsed into a variable (`summary` at line 331). We need one new call: `await update_session_summary(session_id, summary)` — mirroring the existing `update_session_title()` helper.

**`Session` model alignment:** `summary` follows the same pattern as `title` — `Optional[str]`, no alias needed (no camelCase), no default. It appears in `Session`, `SessionUpdate`, and `SessionCreate` (optional).

**API exposure:** `summary` should be included in the session list responses (`GET /api/chat`) so the Flutter app can use it as preview text without a separate fetch.

**`PreCompact` hook:** Fires before Claude compacts the context window. The hook receives `{session_id, transcript_path}` on stdin. Our implementation reads `vault/.parachute/profile.md` (user's persistent context) and outputs it as a block comment that gets injected before compaction. Uses the standard `type: "command"` hook pattern.

**No `PUT /api/sessions/{id}` needed for this issue.** User-rename support is a separate concern — the `title_source: "user"` guard already exists in `activity_hook.py` for when that endpoint is added.

## Acceptance Criteria

### Functional

- [x] `summary` column added to `sessions` table via v18 migration (existing DBs auto-migrated)
- [x] `summary: Optional[str]` field on `Session` model and `SessionUpdate` model
- [x] `db.update_session()` handles `summary` like it handles `title`
- [x] `activity_hook.py` persists the generated `SUMMARY:` text to `db.update_session()` after each qualifying exchange
- [x] `GET /api/chat` and `GET /api/chat/{id}` return `summary` in responses (via `_row_to_session`)
- [x] Context re-injection hook created at `computer/parachute/hooks/context_hook.py`
- [x] `PreCompact` hook registered in `.claude/settings.json`
- [x] Context hook reads `vault/.parachute/profile.md` (falls back gracefully if missing)

### Quality

- [x] Existing `activity_hook.py` tests continue to pass
- [x] New unit tests for `update_session_summary()` helper
- [x] New unit test for v18 migration (column exists after init)
- [x] No regressions in session API tests

## Implementation Plan

### Phase 1 — Session model + DB (data layer)

**`computer/parachute/db/database.py`**
- Add v14 migration in `initialize_schema()` (after v13 workspace_id block):
  ```python
  # Migration v14: Add summary column to sessions
  try:
      await self.connection.execute("SELECT summary FROM sessions LIMIT 1")
  except Exception:
      await self.connection.execute(
          "ALTER TABLE sessions ADD COLUMN summary TEXT"
      )
      logger.info("Added summary column to sessions (v14)")
  ```
- In `update_session()`: add `if update.summary is not None: updates.append("summary = ?"); params.append(update.summary)`
- In `_row_to_session()` (wherever rows are mapped to Session objects): include `summary=row["summary"]`

**`computer/parachute/models/session.py`**
- Add to `Session`:
  ```python
  summary: Optional[str] = Field(default=None, description="AI-generated session summary")
  ```
- Add to `SessionUpdate`:
  ```python
  summary: Optional[str] = None
  ```

### Phase 2 — Persist summaries from hook

**`computer/parachute/hooks/activity_hook.py`**
- Add `update_session_summary()` helper (mirror of `update_session_title()`):
  ```python
  async def update_session_summary(session_id: str, summary: str) -> None:
      """Persist AI-generated summary to session record."""
      if not summary:
          return
      try:
          db = DatabaseManager(vault_path / "Chat" / "sessions.db")
          await db.initialize_schema()
          await db.update_session(session_id, SessionUpdate(summary=summary))
      except Exception as e:
          logger.debug(f"Failed to update session summary: {e}")
  ```
- In `handle_stop_hook()`, after `append_activity_log()` (line ~131):
  ```python
  await update_session_summary(session_id, summary)
  ```
  (Only when `summary` is non-empty — already the case since `call_summarizer` returns `""` on failure)

### Phase 3 — Context re-injection hook

**`computer/parachute/hooks/context_hook.py`** (new file)
```python
#!/usr/bin/env python3
"""
Context Hook - re-injects profile context before compaction.

Triggered by Claude SDK's PreCompact hook. Reads vault/.parachute/profile.md
and outputs it so Claude can include it in the compacted context.

Usage: python -m parachute.hooks.context_hook
       (SDK passes hook input via stdin)
"""
import json
import sys
from pathlib import Path


def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        return

    vault_path = Path(hook_input.get("vault_path") or Path.home() / "Parachute")
    profile_path = vault_path / ".parachute" / "profile.md"

    if not profile_path.exists():
        return

    content = profile_path.read_text().strip()
    if not content:
        return

    # Output as a context reminder for Claude to include pre-compaction
    print(f"\n---\n## Persistent Context (re-injected before compaction)\n\n{content}\n---\n")


if __name__ == "__main__":
    main()
```

**`.claude/settings.json`** — add `PreCompact` hook:
```json
{
  "hooks": {
    "Stop": [...existing...],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "python -m parachute.hooks.context_hook"
          }
        ]
      }
    ]
  }
}
```

> Note: The vault path for the context hook needs to come from environment or be resolved from the session. Check how `activity_hook.py` resolves `vault_path` and use the same pattern.

### Phase 4 — Tests

**`computer/tests/unit/test_activity_hook.py`** (new or extend existing)
- `test_update_session_summary_persists_to_db`
- `test_update_session_summary_skips_empty_string`
- `test_handle_stop_hook_calls_update_session_summary`

**`computer/tests/unit/test_database.py`** (extend existing)
- `test_v14_migration_adds_summary_column`
- `test_update_session_summary_field`
- `test_get_session_returns_summary`

## Dependencies & Risks

- **`activity_hook.py` runs as a subprocess** — it must import `DatabaseManager` and resolve `vault_path` correctly. Check that `activity_hook.py` already does this for `update_session_title()` (it does — uses `_get_session()` which calls `db.get_session()`). The `vault_path` for the DB is resolved via `config.get_vault_path()` or similar.
- **Summarizer already parses `SUMMARY:`** — risk of empty summary on first exchange or on short messages. Already handled: `_should_update_title()` gates the call, and `call_summarizer` returns `""` on parse failure.
- **`PreCompact` hook availability** — verify this event is supported in the current Claude Code CLI version before registering it. If unavailable, fall back to `SessionStart` with a `compact` matcher. Document the fallback in code.
- **Flutter app changes not in scope** — the `summary` field will be available via API but showing it in the session list UI is tracked separately under #102.

## Success Metrics

- Summaries visible on `GET /api/chat` responses for all sessions after next exchange
- Zero regressions in existing hook and session tests
- Context hook fires (verify via `parachute logs`) on long-session compaction

## References

- `activity_hook.py`: `computer/parachute/hooks/activity_hook.py` — existing Stop hook, parse logic at line 331
- `update_session_title()`: `activity_hook.py:404` — pattern to follow for `update_session_summary()`
- `db.update_session()`: `computer/parachute/db/database.py:489` — where to add `summary` handling
- `Session` model: `computer/parachute/models/session.py:136`
- v13 migration (workspace_id): `computer/parachute/db/database.py:252` — pattern for v14
- `.claude/settings.json`: project root, current Stop hook configuration
- Issue brainstorm: GitHub issue #61 body (inline brainstorm with hook type analysis)
