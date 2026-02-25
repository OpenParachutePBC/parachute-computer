---
title: "Curator: Background Context Agent"
type: feat
date: 2026-02-24
issue: 125
---

# feat: Curator — Background Context Agent

## Overview

Replace `session_summarizer.py` with `curator.py` — a proper background agent
that uses Claude Haiku via the SDK with **per-chat-session continuity**, MCP
tools for writeback, and light UI visibility. The curator observes each chat
exchange and decides what to update: session title, summary, and activity log.

This is the curator pattern from the original `parachute-chat` repo, rebuilt
without the SQLite queue complexity, using fire-and-forget asyncio and a
scoped per-run MCP server.

## What Changes

### Server

| File | Action |
|------|--------|
| `computer/parachute/core/curator.py` | **New** — replaces `session_summarizer.py` |
| `computer/parachute/core/curator_mcp.py` | **New** — scoped MCP server for curator tools |
| `computer/parachute/core/session_summarizer.py` | **Deleted** — superseded by curator |
| `computer/parachute/core/orchestrator.py` | **Modified** — replace `summarize_session` call with `curator.observe()` |
| `computer/parachute/api/sessions.py` | **Modified** — include `curator_last_run` in session response |

### App

| File | Action |
|------|--------|
| `app/lib/features/chat/widgets/curator_chip.dart` | **New** — chip shown after curator runs |
| `app/lib/features/chat/providers/curator_providers.dart` | **New** — Riverpod provider |
| `app/lib/features/chat/screens/chat_screen.dart` | **Modified** — add chip to header |
| `app/lib/features/chat/models/curator_run.dart` | **New** — model for last run result |

### Tests

| File | Action |
|------|--------|
| `computer/tests/unit/test_curator.py` | **New** — unit tests for curator logic |
| `computer/tests/unit/test_session_summarizer.py` | **Deleted** — superseded |

---

## Technical Approach

### The Curator MCP Server (`curator_mcp.py`)

The core design challenge: the curator is a background asyncio task (not an
HTTP request), so it cannot use the existing `_session_context` mechanism that
`mcp_server.py` uses for per-request tool dispatch.

**Solution:** A lightweight stdio MCP server that accepts `--session-id` at
startup. Each curator run spawns its own scoped MCP server instance. The
`query_streaming()` call configures `mcp_servers` pointing to it:

```python
# In curator.py
mcp_servers = {
    "curator": {
        "command": sys.executable,
        "args": ["-m", "parachute.core.curator_mcp", "--session-id", session_id],
        "env": {"VAULT_PATH": str(vault_path)},
    }
}
```

The curator MCP server (`curator_mcp.py`) exposes three tools:

```python
# mcp__curator__update_title(title: str)
#   → database.update_session(session_id, SessionUpdate(title=title, metadata={...title_source: "ai"...}))
#   → Returns: {"status": "ok", "title": title}

# mcp__curator__update_summary(summary: str)
#   → database.update_session(session_id, SessionUpdate(summary=summary))
#   → Returns: {"status": "ok"}

# mcp__curator__log_activity(summary: str)
#   → append_activity_log(session_id, session_title, agent_type, exchange_number, summary)
#   → Returns: {"status": "ok"}
```

These tools write back to the database and activity log directly. The session
ID, vault path, and database path come from startup args / env vars.

### `CuratorService` (`curator.py`)

Replaces `session_summarizer.py`. Main entry point is `observe()` — same
fire-and-forget signature as `summarize_session()` to simplify orchestrator wiring.

```python
async def observe(
    session_id: str,
    message: str,
    result_text: str,
    tool_calls: list[str],
    exchange_number: int,
    session_title: Optional[str],
    title_source: Optional[str],
    database: object,
    vault_path: Path,
    claude_token: Optional[str],
) -> None:
    """Fire-and-forget curator run. Never raises."""
```

Internally:

1. **Cadence check** — same `_should_update()` logic: `{1, 3, 5}`, every 10th
2. **Load curator session** — `session.metadata.get("curator_session_id")` from
   the database. The curator session is **1:1 with the chat session** — it holds
   the full conversational context for exactly this chat, nothing else.
3. **Build prompt** — truncated exchange content, current title, exchange number,
   tool call names (see Prompt Design below)
4. **Call `query_streaming()`** with:
   - `model="claude-haiku-4-5-20251001"`
   - `use_claude_code_preset=False`
   - `system_prompt=CURATOR_SYSTEM_PROMPT`
   - `resume=curator_session_id` (the chat session's own curator session)
   - `mcp_servers={"curator": {...}}` (scoped MCP server)
   - `setting_sources=[]`
   - `tools=[]` (curator uses MCP tools, not CLI tools)
   - `permission_mode="bypassPermissions"` (curator tools auto-approved)
5. **Capture new session ID** — from `system` event on first run; save to
   `session.metadata["curator_session_id"]` via `database.update_session()`
6. **Capture tool calls** — from `assistant` events, record what curator decided
7. **Write `curator_last_run`** to session metadata for UI (title updated, logged, etc.)
8. **Catch all exceptions** — never raises, logs debug

### Prompt Design

The curator is told: "You are a background context agent observing a conversation.
After each exchange, use your tools to keep the session context current. You have
three tools: `update_title`, `update_summary`, `log_activity`. Use them as needed
— you don't have to use all of them. Be concise and factual."

Per-exchange prompt includes:
- Current session title (and whether it's user-set — if so, skip `update_title`)
- Exchange number
- User message (truncated 1000 chars)
- Tool calls used in this exchange (names only)
- Assistant response (truncated 2000 chars)

The curator's **per-chat-session continuity** means it accumulates the full
history of this conversation — it has seen every exchange it's observed,
knows what titles it already suggested, what it already logged, and can make
increasingly coherent decisions as the conversation evolves. This mirrors
exactly how the original `parachute-chat` curator worked.

### Cadence Control

Preserved from `session_summarizer.py` — no change:

```python
_CURATOR_EXCHANGES = {1, 3, 5}   # Always run on these
_CURATOR_INTERVAL  = 10           # After 5, run every 10th
```

### Session Metadata for UI

Two curator-related fields are written to `session.metadata` after each run:

```json
{
  "curator_session_id": "sdk-session-abc123",
  "curator_last_run": {
    "ts": "2026-02-24T15:47:00Z",
    "exchange_number": 3,
    "actions": ["update_title", "log_activity"],
    "new_title": "Python Async Patterns"
  }
}
```

- **`curator_session_id`** — persisted after the first curator run; used on
  every subsequent run to resume the same SDK session for this chat
- **`curator_last_run`** — updated after each run; read by the Flutter app on
  next `GET /api/chat/{session_id}` to show the curator chip

No push or polling required — the chip appears based on this field when the
app fetches the session (which it does after each stream completes).

### Orchestrator Change

Minimal: replace the `summarize_session` import and call:

```python
# orchestrator.py — before yield DoneEvent()
# OLD:
from parachute.core.session_summarizer import summarize_session
asyncio.create_task(summarize_session(...))

# NEW:
from parachute.core.curator import observe as curator_observe
asyncio.create_task(curator_observe(...))
```

Signature is identical — drop-in replacement.

---

## Flutter UI

### `CuratorChip` widget

Appears in the chat session header after the curator has run. Sourced from
`session.metadata["curator_last_run"]`.

```
[🤖 Updated title · Logged]  ← tappable chip
```

On tap → shows a lightweight `BottomSheet` or `Dialog` with last few runs:

```
Curator  ·  3:47 PM
  ✓ update_title → "Python Async Patterns"
  ✓ log_activity → "Exchange 3: Explored..."

Curator  ·  3:31 PM
  — no changes
```

**Manual trigger**: Small icon button (▶) in the app bar — calls
`POST /api/chat/{session_id}/curator/trigger` (new endpoint). Useful for
dev/testing and for users who want to force a run after editing context.

### Provider

```dart
// curator_providers.dart
final curatorLastRunProvider = Provider.autoDispose.family<CuratorRun?, String>(
  (ref, sessionId) {
    final session = ref.watch(chatSessionProvider(sessionId));
    return session.valueOrNull?.curatorLastRun;
  },
);
```

No separate API call needed — curator data comes from the session object already
fetched. The chip re-renders when the session refreshes (which happens after
each new stream completes).

### `CuratorRun` model

```dart
// curator_run.dart
class CuratorRun {
  final DateTime ts;
  final int exchangeNumber;
  final List<String> actions;  // ["update_title", "log_activity"]
  final String? newTitle;

  factory CuratorRun.fromJson(Map<String, dynamic> json) { ... }
  bool get hasChanges => actions.isNotEmpty;
}
```

---

## New Server Endpoint

```
POST /api/chat/{session_id}/curator/trigger
```

Manually triggers a curator run for testing/dev. Requires the current session
transcript to be readable. Returns `{"status": "queued"}` immediately (runs
fire-and-forget).

---

## Implementation Plan

### Phase 1: Server — `curator_mcp.py` + `curator.py`

1. Create `computer/parachute/core/curator_mcp.py`:
   - Stdio MCP server using `mcp` library (already a dependency)
   - Accepts `--session-id`, `--db-path`, `--vault-path` CLI args
   - Exposes: `update_title`, `update_summary`, `log_activity`
   - Each tool opens the database, executes, closes
   - Uses existing `append_activity_log()` from `activity_hook.py` for `log_activity`

2. Create `computer/parachute/core/curator.py`:
   - `_should_update(exchange_number)` — same cadence as session_summarizer
   - `observe(...)` — main entry, fire-and-forget
     - Reads `curator_session_id` from `session.metadata` (resume existing or start fresh)
     - On first run, captures new session ID from `system` event and writes it back
     - Writes `curator_last_run` to metadata after each run
   - `CURATOR_SYSTEM_PROMPT` — curator instructions + tool descriptions
   - No file-based session cache — session ID lives in `session.metadata["curator_session_id"]`

3. Write `computer/tests/unit/test_curator.py`:
   - Test `_should_update` cadence (same as existing tests, quick port)
   - Test `observe()` skips on non-cadence exchanges
   - Test `observe()` respects `title_source == "user"` (doesn't pass update_title to curator)
   - Test `observe()` never raises
   - Mock `query_streaming` to return mock tool call events

### Phase 2: Server — Wire into Orchestrator

4. Update `computer/parachute/core/orchestrator.py`:
   - Replace `from parachute.core.session_summarizer import summarize_session`
   - Replace `asyncio.create_task(summarize_session(...))` → `curator_observe(...)`

5. Update `computer/parachute/api/sessions.py`:
   - Include `curator_last_run` from `session.metadata` in `GET /api/chat/{session_id}` response
   - Add `POST /api/chat/{session_id}/curator/trigger` endpoint

6. Delete `computer/parachute/core/session_summarizer.py`
7. Delete `computer/tests/unit/test_session_summarizer.py`

8. Run tests: `pytest tests/unit/`

### Phase 3: Flutter — Curator Chip

9. Create `app/lib/features/chat/models/curator_run.dart`

10. Update session model to parse `curatorLastRun` from metadata:
    - Likely in `app/lib/features/chat/models/chat_session.dart`

11. Create `app/lib/features/chat/providers/curator_providers.dart`

12. Create `app/lib/features/chat/widgets/curator_chip.dart`:
    - Chip with 🤖 icon + action summary
    - Tappable → shows bottom sheet or dialog with run history
    - Manual trigger button

13. Add chip to `app/lib/features/chat/screens/chat_screen.dart` header area

---

## Acceptance Criteria

- [x] After an exchange on a cadence number, `observe()` fires as `asyncio.create_task()`
- [x] Curator session is **1:1 with the chat session** — `session.metadata["curator_session_id"]` is set after the first run and resumed on all subsequent runs
- [x] The curator session accumulates full context of that specific conversation across all cadence exchanges
- [x] Curator calls `mcp__curator__update_title` when title should change (not when `title_source == "user"`)
- [x] Curator calls `mcp__curator__update_summary` each cadence exchange
- [x] Curator calls `mcp__curator__log_activity` each cadence exchange
- [x] `session.metadata["curator_last_run"]` is written after each run
- [x] `observe()` never raises — all exceptions caught and logged
- [x] `GET /api/chat/{session_id}` includes `curatorLastRun` field
- [x] Flutter chip appears in chat header when `curatorLastRun` is present
- [x] Chip shows what the curator did (title updated, logged, etc.)
- [x] Manual trigger endpoint works (`POST /api/chat/{session_id}/curator/trigger`)
- [x] All unit tests pass; `ruff check` clean

---

## Dependencies & Risks

**MCP subprocess overhead**: Each curator run spawns the CLI subprocess (Claude
Haiku) AND a curator MCP server subprocess. Two processes per run. Acceptable
for fire-and-forget cadence runs, but worth monitoring.

**`mcp` library for `curator_mcp.py`**: Need to verify `mcp` (Model Context
Protocol Python SDK) is already a dependency, or add it. The existing
`mcp_server.py` likely already uses it.

**Daily session cache concurrent writes**: If two curator runs fire simultaneously
(unlikely with cadence, but possible), the cache file could race. Add simple
file-level locking or accept the benign race (second writer wins, losing one
session ID at most).

**Haiku model name**: Use `claude-haiku-4-5-20251001` (confirmed current as of
2026-02-24). Note in code for easy update.

---

## References

- Brainstorm: `docs/brainstorms/2026-02-24-curator-revival-background-context-agent-brainstorm.md`
- Archived original server: `OpenParachutePBC/parachute-chat`
- Archived original Flutter: `OpenParachutePBC/parachute-app` (`lib/features/chat/widgets/curator_session_viewer_sheet.dart`)
- Current session summarizer (to replace): `computer/parachute/core/session_summarizer.py`
- SDK wrapper: `computer/parachute/core/claude_sdk.py:142`
- Orchestrator trigger point: `computer/parachute/core/orchestrator.py:1304`
- Session API: `computer/parachute/api/sessions.py:118`
- Activity log format: `computer/parachute/hooks/activity_hook.py:211`
