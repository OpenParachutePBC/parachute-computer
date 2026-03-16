---
title: Event-Driven Callers
status: plan
priority: P1
date: 2026-03-16
labels: [daily, computer, app]
issue: 278
---

# Event-Driven Callers — Implementation Plan

## Overview

Extend the Caller system to support event-driven triggers alongside scheduled triggers. A Caller can fire in response to Note lifecycle events (`note.transcription_complete`, `note.created`) with optional metadata filters. Convert the hardcoded `_cleanup_transcription` pipeline into the first triggered Caller.

**Brainstorm**: [docs/brainstorms/2026-03-16-event-driven-callers-brainstorm.md](../brainstorms/2026-03-16-event-driven-callers-brainstorm.md)

---

## Architecture

### Current State

```
Transcription completes
  → _transcribe_and_cleanup() calls _cleanup_transcription() directly
  → Single SDK call (haiku) with CLEANUP_SYSTEM_PROMPT
  → Writes cleaned content back to Note
  → No visibility, not configurable, not disablable
```

Callers today are schedule-only: `discover_daily_agents()` queries all enabled Callers, `_schedule_from_list()` skips those with `schedule_enabled=false`, `run_daily_agent()` executes with day-scoped tools (`read_journal`, `write_output`, etc.).

### Target State

```
Transcription completes
  → Module fires event "note.transcription_complete" with entry context
  → CallerDispatcher queries Callers where trigger_event matches + filter matches
  → Each matching Caller is invoked with note-scoped tools (read_entry, update_entry_content)
  → Activity visible in Flutter UI on the Note
```

The Caller table gains two new columns. The execution path reuses the existing `run_daily_agent()` with a new `run_triggered_caller()` wrapper that injects note-scoped tools and the entry context.

---

## Phases

### Phase 1: Schema & Note-Scoped Tools

**Goal**: Add trigger columns to Caller schema, implement note-scoped tools, and create the triggered execution path.

#### 1a. Caller schema extension

**File**: `computer/modules/daily/module.py` — `_ensure_caller_schema()`

Add two new columns to the Caller table:

| Column | Type | Default | Purpose |
|--------|------|---------|---------|
| `trigger_event` | STRING | `""` | Event that fires this Caller (e.g., `"note.transcription_complete"`) |
| `trigger_filter` | STRING | `"{}"` | JSON object — metadata filter conditions |

Add them the same way existing columns are added (ALTER TABLE ADD COLUMN with DEFAULT). The migration is idempotent.

Update `_seed_builtin_callers()` to set trigger fields on the `transcription-cleanup` Caller:

```python
"trigger_event": "note.transcription_complete",
"trigger_filter": json.dumps({"entry_type": "voice"}),
```

**Note**: Existing Callers (user-created) will get empty strings, meaning they're schedule-only. No migration needed.

#### 1b. Note-scoped tool factory

**New file**: `computer/parachute/core/triggered_caller_tools.py`

Create a tool factory that produces note-scoped tools bound to a specific entry_id:

```python
def create_triggered_caller_tools(
    graph, entry_id: str, allowed_tools: list[str],
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
```

Tools:

| Tool | Schema | Behavior |
|------|--------|----------|
| `read_entry` | `{}` (no args — entry_id is bound) | Read the triggering Note's content, metadata, tags |
| `update_entry_content` | `{content: str}` | Replace the Note's content |
| `update_entry_tags` | `{tags: list[str]}` | Set the Note's tags |
| `update_entry_metadata` | `{key: str, value: str}` | Set a metadata field |

Each tool is pre-bound to the specific `entry_id` via closure. The Caller only gets tools listed in its `tools` config field. A cleanup Caller with `tools: ["read_entry", "update_entry_content"]` literally cannot modify tags or metadata.

Uses `create_sdk_mcp_server()` same as existing `create_daily_agent_tools()`.

#### 1c. Triggered execution path

**File**: `computer/parachute/core/daily_agent.py`

Add `run_triggered_caller()`:

```python
async def run_triggered_caller(
    vault_path: Path,
    agent_name: str,
    entry_id: str,
    event: str,
) -> dict[str, Any]:
```

This function:
1. Loads the Caller config from graph (same as `get_daily_agent_config()`)
2. Loads the entry from graph (content, metadata, type, date)
3. Builds a note-scoped prompt:
   ```
   A note has been {event description}. Use your tools to process it.
   Entry ID: {entry_id}
   Entry type: {entry_type}
   Date: {date}
   ```
4. Creates note-scoped tools via `create_triggered_caller_tools()`
5. Calls `_run_direct()` with `create_tools_fn` pointing to the note-scoped factory
6. Does NOT create a Card (triggered Callers transform Notes, not produce Cards)
7. Records the run on the Caller node (same `_record_caller_run()` pattern)

For the first iteration, triggered Callers always run in **direct mode** (no sandbox). The transcription-cleanup Caller currently runs via a simple SDK call — no need for Docker overhead. Sandbox support for triggered Callers can come later.

#### 1d. DailyAgentConfig extension

**File**: `computer/parachute/core/daily_agent.py` — `DailyAgentConfig`

Add fields:

```python
trigger_event: str = ""      # e.g., "note.transcription_complete"
trigger_filter: dict = {}    # e.g., {"entry_type": "voice"}
```

Update `from_row()` to parse these from graph data. `trigger_filter` is stored as JSON string, parsed to dict.

---

### Phase 2: Event Dispatch

**Goal**: Wire Note lifecycle events to discover and invoke matching triggered Callers.

#### 2a. CallerDispatcher

**New file**: `computer/parachute/core/caller_dispatch.py`

```python
class CallerDispatcher:
    """Discovers triggered Callers and invokes them when events fire."""

    async def dispatch(self, event: str, entry_id: str, entry_meta: dict) -> list[dict]:
        """Find Callers matching this event + filter, invoke them sequentially."""
```

Discovery query:
```cypher
MATCH (c:Caller)
WHERE c.enabled = 'true' AND c.trigger_event = $event
RETURN c
ORDER BY c.name
```

Filter matching: for each Caller, parse `trigger_filter` JSON and check against `entry_meta`:
- `{"entry_type": "voice"}` → entry must have `entry_type == "voice"`
- `{"tags": ["meeting"]}` → entry must have any of the listed tags
- `{}` → always matches (no filter)

Invoke matching Callers **sequentially** (not parallel) so earlier Callers' mutations are visible to later ones. Return a list of result dicts.

#### 2b. Wire into Daily module

**File**: `computer/modules/daily/module.py`

Replace the direct `_cleanup_transcription()` call in the transcription completion path with event dispatch:

**Before** (current, line ~1658):
```python
task = asyncio.create_task(
    _cleanup_transcription(graph, entry_id, content)
)
```

**After**:
```python
task = asyncio.create_task(
    self._dispatch_event("note.transcription_complete", entry_id)
)
```

Add `_dispatch_event()` method on `DailyModule`:
```python
async def _dispatch_event(self, event: str, entry_id: str):
    """Dispatch a Note event to matching triggered Callers."""
    dispatcher = CallerDispatcher(graph=self._get_graph(), vault_path=self.vault_path)
    entry = await self.get_entry(entry_id)
    if not entry:
        return
    entry_meta = {
        "entry_type": entry.get("entry_type", "text"),
        "tags": entry.get("tags", []),
        "date": entry.get("date", ""),
    }
    results = await dispatcher.dispatch(event, entry_id, entry_meta)
    for r in results:
        logger.info(f"Triggered caller '{r.get('agent')}' result: {r.get('status')}")
```

Also fire `"note.created"` at the end of `create_entry()`:
```python
# At end of create_entry(), after graph write + redo log
task = asyncio.create_task(self._dispatch_event("note.created", entry_id))
_background_tasks.add(task)
task.add_done_callback(lambda t: _background_tasks.discard(t))
```

#### 2c. Remove hardcoded cleanup

**File**: `computer/modules/daily/module.py`

- Remove the `_cleanup_transcription()` function
- Remove the `CLEANUP_SYSTEM_PROMPT` constant (it's already seeded into the Caller node)
- Remove the `query_streaming` import and direct SDK call
- Keep `_update_entry_transcription_status()` — the triggered Caller will use `update_entry_metadata` to set status

**Wait**: The transcription-cleanup Caller needs to manage `transcription_status` and `cleanup_status` metadata. Rather than requiring the LLM to call `update_entry_metadata` for status tracking, the `CallerDispatcher` should handle status bookkeeping:
- Before invoking: set `cleanup_status = "running"`
- After success: set `transcription_status = "complete"`, `cleanup_status = "completed"`
- After failure: set `cleanup_status = "failed"`

This keeps the Caller's job simple (just clean up text) while the dispatcher handles lifecycle.

---

### Phase 3: API & Flutter UI

**Goal**: Expose trigger configuration in the API and Flutter UI.

#### 3a. API updates

**File**: `computer/modules/daily/module.py` — Caller endpoints

Update the GET/POST/PUT Caller endpoints to include trigger fields:

- `GET /callers` and `GET /callers/{name}` — include `trigger_event` and `trigger_filter` in response
- `POST /callers` — accept `trigger_event` and `trigger_filter` in creation body
- `PUT /callers/{name}` — accept trigger fields in update body

Add a new endpoint for manual trigger testing:

```
POST /callers/{name}/trigger
Body: { "entry_id": "..." }
```

This invokes the Caller on a specific entry, regardless of filter. Useful for testing and one-off runs.

Also expose available events:

```
GET /callers/events
Response: [
  {"event": "note.created", "description": "Fires when a new note is saved"},
  {"event": "note.transcription_complete", "description": "Fires when voice transcription finishes"}
]
```

#### 3b. CallerEditScreen — trigger config

**File**: `app/lib/features/daily/journal/screens/caller_edit_screen.dart`

Add a "Trigger" section to the form, below the existing Schedule section:

- **Trigger event dropdown**: `None` (schedule-only), `note.created`, `note.transcription_complete`
- **Filter chips**: When a trigger event is selected, show filter options:
  - Entry type: voice, text, handwriting, image (multi-select chips)
  - Tags: text field for tag filter (comma-separated)
- **Note-scoped tools**: When trigger is set, show note-scoped tools (`read_entry`, `update_entry_content`, `update_entry_tags`, `update_entry_metadata`) instead of day-scoped tools

The UI should make clear that schedule and trigger are independent:
- A Caller can be schedule + trigger (rare but valid)
- A Caller can be schedule-only (current behavior)
- A Caller can be trigger-only (new behavior, e.g., cleanup)

#### 3c. Note-level Caller activity

**File**: `app/lib/features/daily/journal/widgets/` (new or existing)

Show Caller activity on individual Notes. When a triggered Caller has run on a Note:

- Small icon/badge on the Note card in the journal list
- Expandable section in Note detail showing what the Caller did
- Links to the Caller's session transcript

This mirrors the existing Bridge agent activity display in Chat. The data source is the Caller's session metadata (session_id, timestamps, status) which we can query from the API.

**New endpoint**:
```
GET /entries/{entry_id}/caller-activity
Response: [
  {
    "caller_name": "transcription-cleanup",
    "display_name": "Transcription Cleanup",
    "status": "completed",
    "ran_at": "2026-03-16T...",
    "session_id": "..."
  }
]
```

This requires a lightweight record of which Callers ran on which entries. The simplest approach: the `CallerDispatcher` writes a relationship in the graph:

```cypher
MERGE (c:Caller {name: $caller_name})-[r:RAN_ON]->(e:Note {entry_id: $entry_id})
SET r.status = $status, r.ran_at = $ran_at, r.session_id = $session_id
```

---

### Phase 4: Bug Fix & Polish

#### 4a. Fix spurious transcription-cleanup error

The user sees an error about the transcription-cleanup Caller failing to generate. Investigation shows:

- The `transcription-cleanup` Caller has `enabled: "true"` and `schedule_enabled: "false"`
- `discover_daily_agents()` queries `WHERE c.enabled = 'true'` — this returns ALL enabled Callers including non-scheduled ones
- `_schedule_from_list()` correctly skips `schedule_enabled=false` Callers
- BUT the Flutter app's polling/card-check may be looking at ALL enabled Callers and showing an error when no Card exists

**Fix**: The Flutter `callerDetailSheet` or card status check should distinguish between scheduled and triggered Callers. A triggered Caller with no Card is normal, not an error. Update the card status logic to only show "failed to generate" for Callers that have `schedule_enabled: true`.

#### 4b. Caller templates for triggered Callers

**File**: `computer/modules/daily/module.py` — `CALLER_TEMPLATES`

Add templates for common triggered Callers:

```python
{
    "name": "auto-tagger",
    "display_name": "Auto Tagger",
    "description": "Automatically tags new journal entries based on content",
    "trigger_event": "note.created",
    "trigger_filter": "{}",
    "tools": ["read_entry", "update_entry_tags"],
    ...
}
```

#### 4c. Update existing Caller template schema

Update `CallerTemplateDict` TypedDict and the `GET /callers/templates` response to include trigger fields.

---

## File Changes Summary

### New files
| File | Purpose |
|------|---------|
| `computer/parachute/core/triggered_caller_tools.py` | Note-scoped tool factory |
| `computer/parachute/core/caller_dispatch.py` | Event → Caller matching + invocation |

### Modified files (server)
| File | Changes |
|------|---------|
| `computer/modules/daily/module.py` | Schema migration (trigger columns), remove `_cleanup_transcription()` + `CLEANUP_SYSTEM_PROMPT`, add `_dispatch_event()`, update seed callers, update API endpoints, update templates |
| `computer/parachute/core/daily_agent.py` | Add `run_triggered_caller()`, extend `DailyAgentConfig` with trigger fields |
| `computer/parachute/core/daily_agent_tools.py` | No changes (day-scoped tools stay as-is) |
| `computer/parachute/core/hooks/events.py` | Add `DAILY_ENTRY_TRANSCRIPTION_COMPLETE` event |

### Modified files (Flutter)
| File | Changes |
|------|---------|
| `app/lib/features/daily/journal/screens/caller_edit_screen.dart` | Trigger event dropdown, filter UI, note-scoped tool selection |
| `app/lib/features/daily/journal/widgets/caller_detail_sheet.dart` | Distinguish scheduled vs triggered Callers in status display |
| `app/lib/core/services/computer_service.dart` | Add trigger fields to `DailyAgentInfo` model, add `callerActivity()` API call |

---

## Open Questions Resolved

1. **Concurrent triggers**: Both events fire their Callers, sequentially. `CallerDispatcher.dispatch()` runs Callers in name order within an event. Multiple events are dispatched independently as background tasks.

2. **Failure handling**: `CallerDispatcher` manages lifecycle status (`cleanup_status`). Failed Callers are logged but don't retry automatically. The UI shows the failure. Users can re-trigger manually via `POST /callers/{name}/trigger`.

3. **Caller chaining**: Deferred. Triggered Callers do NOT fire new events when they mutate a Note. This prevents loops. Future: opt-in chaining with depth limits.

---

## Implementation Order

1. **Phase 1a–1d** (schema + tools + execution path) — backend foundation
2. **Phase 2a–2b** (dispatcher + wiring) — event dispatch works
3. **Phase 2c** (remove hardcoded cleanup) — transcription-cleanup is now a Caller
4. **Phase 4a** (bug fix) — fix spurious error in Flutter
5. **Phase 3a** (API updates) — expose trigger config
6. **Phase 3b–3c** (Flutter UI) — configure + view activity
7. **Phase 4b–4c** (templates + polish) — templates for triggered Callers

Phases 1–2c can ship as one PR (backend). Phase 3–4 as a second PR (API + Flutter).

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Triggered Caller fails silently | Dispatcher writes RAN_ON relationship with status; Flutter shows it |
| Cleanup regression if Caller approach is slower | Keep `_cleanup_transcription()` behind a feature flag initially; remove once stable |
| Multiple Callers mutating same Note concurrently | Sequential execution within `dispatch()` |
| Infinite loops from chaining | No chaining in v1 — triggered Callers don't fire events |
| Direct-mode only limits isolation | Acceptable for v1 — cleanup is a simple text transform, not adversarial |
