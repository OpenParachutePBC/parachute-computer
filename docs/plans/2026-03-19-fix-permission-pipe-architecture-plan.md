---
title: "Permission Pipe Architecture Cleanup"
type: fix
date: 2026-03-19
issue: 295
---

# Permission Pipe Architecture Cleanup

Fix intermittent "Stream closed" errors on file edits by removing the unnecessary permission pipe from DIRECT trust sessions, and suppress unwanted Claude Code tools (AskUserQuestion, PlanMode).

## Problem Statement

All sessions currently use `permission_mode="default"` with a `can_use_tool` callback, which routes every tool invocation through a stdin/stdout pipe between the orchestrator and the CLI subprocess. For DIRECT trust sessions, the `PermissionHandler` auto-approves everything — the pipe round-trip adds latency and fragility for zero security benefit. When the pipe breaks (cause TBD), write operations fail with "Stream closed" while reads survive (reads may be auto-approved by the CLI without the pipe round-trip).

## Proposed Solution

Switch DIRECT trust sessions to `permission_mode="bypassPermissions"` (already used by `daily_agent.py`) and suppress unwanted tools via system prompt instructions + graceful event-stream handling.

### Phase 1: Bypass permissions for DIRECT trust

**File: `computer/parachute/core/orchestrator.py`** — `_run_trusted()` method (~line 930)

Currently:
```python
sdk_can_use_tool = permission_handler.create_sdk_callback()
async for event in query_streaming(
    ...,
    permission_mode="default",
    can_use_tool=sdk_can_use_tool,
    ...
):
```

Change to:
```python
# DIRECT trust: bypass permission pipe entirely
# SANDBOXED sessions don't reach _run_trusted (they use _run_sandboxed)
async for event in query_streaming(
    ...,
    permission_mode="bypassPermissions",
    can_use_tool=None,
    ...
):
```

**What this does:**
- Eliminates the permission pipe for all DIRECT trust sessions
- The CLI auto-approves all tool calls without pipe round-trips
- Fixes the "Stream closed" bug for the common case
- No `PermissionHandler` needed for DIRECT sessions

**What to verify:**
- The `AsyncIterable`/`done_event` stdin pattern must still work (it's needed for multi-turn tool execution, not just permissions)
- `query_streaming()` already handles `can_use_tool=None` — it just doesn't add it to options

**Simplification opportunity:** Since `_run_trusted` is only called for DIRECT trust (sandboxed goes through `_run_sandboxed`), the permission handler creation in Phase 3 of `run_streaming()` can be skipped for DIRECT sessions. Remove or conditionalize the `PermissionHandler` setup at ~line 542.

### Phase 2: Suppress unwanted tools via system prompt

**File: `computer/parachute/core/orchestrator.py`** — system prompt assembly

Add to the system prompt for DIRECT trust sessions:
```
Do not use the AskUserQuestion tool — communicate questions directly in your response text.
Do not use EnterPlanMode or ExitPlanMode — respond directly without entering plan mode.
```

This is ~99% effective. The model rarely ignores direct system prompt instructions about tool usage.

**Where to add:** In the system prompt assembly section of `run_streaming()`, after the module prompt is composed. This should be a small append, not a separate mechanism.

### Phase 3: Graceful AskUserQuestion fallback

Even with system prompt suppression, handle the edge case where the model tries AskUserQuestion anyway.

**File: `computer/parachute/core/orchestrator.py`** — event stream processing

Currently the orchestrator detects `AskUserQuestion` tool_use blocks and stashes the tool_use_id for the permission handler. With no permission handler, this code needs updating:

- When an `AskUserQuestion` tool_use block is detected in the event stream, log a warning
- The tool will execute (since permissions are bypassed) but the response will be empty/default
- Consider: auto-respond with a generic "Please ask in your response text" message if the SDK supports injecting tool results

**Minimal approach:** Just remove the AskUserQuestion detection/stashing code from the event processing loop. If the model uses it despite the prompt, it'll get an empty response and adapt. This is acceptable for DIRECT trust.

### Phase 4: Clean up PermissionHandler for DIRECT trust

**File: `computer/parachute/core/permission_handler.py`**

No changes needed to the handler itself — it's simply not instantiated for DIRECT sessions anymore.

**File: `computer/parachute/core/orchestrator.py`**

- Conditionalize permission handler creation: only create for sessions that will use `_run_sandboxed`
- Remove or guard the `pending_permissions` dict updates for DIRECT sessions
- Clean up the AskUserQuestion SSE event emission (only relevant when permission handler exists)

**File: `computer/parachute/api/chat.py`**

- The `/chat/{session_id}/answer` endpoint (for AskUserQuestion responses) can remain — it's only called when a question event is emitted, which won't happen for DIRECT sessions

## Acceptance Criteria

- [x] DIRECT trust sessions use `permission_mode="bypassPermissions"` with no `can_use_tool` callback
- [x] File edit operations no longer fail with "Stream closed" for DIRECT trust sessions
- [x] AskUserQuestion and PlanMode are suppressed via system prompt instructions
- [x] AskUserQuestion detection in event stream is gracefully handled (no crash if model uses it anyway)
- [x] `PermissionHandler` is not instantiated for DIRECT trust sessions
- [x] SANDBOXED sessions continue to work as before (no changes to `_run_sandboxed`)
- [x] Daily agent continues to work (already uses `bypassPermissions`)
- [x] `AsyncIterable`/`done_event` stdin pattern still works with `bypassPermissions`

## Technical Considerations

- **`bypassPermissions` is proven**: `daily_agent.py` already uses it successfully. This isn't a new pattern.
- **stdin must stay open**: The `AsyncIterable` wrapping is needed regardless of permission mode — it keeps stdin open for multi-turn tool execution. Verify this still works when `can_use_tool=None`.
- **No pipe = no pipe failures**: The fix is structural — we're removing the failure mode, not adding retry logic.
- **SANDBOXED sessions unaffected**: They use `_run_sandboxed()` which has its own execution model (Docker). The permission pipe issue doesn't apply.
- **AskUserQuestion in Flutter app**: The app has UI for answering questions (`POST /chat/{sessionId}/question-response`). This UI simply won't be triggered for DIRECT sessions. No app changes needed.

## Dependencies & Risks

- **Low risk**: `bypassPermissions` is a proven mode already in use
- **Edge case**: If the model uses AskUserQuestion despite system prompt suppression, the behavior should be graceful (empty response, not crash)
- **Future consideration**: When custom system prompt work (#297) lands, the tool suppression instructions become part of the standard prompt rather than an ad-hoc append

## References

- Brainstorm: `docs/brainstorms/2026-03-19-permission-pipe-architecture-brainstorm.md`
- Companion issue: #297 (Custom System Prompt)
- Existing `bypassPermissions` usage: `computer/modules/daily/daily_agent.py` (~line 642)
- SDK types: `PermissionMode = Literal["default", "acceptEdits", "plan", "bypassPermissions"]`
