---
title: "feat: Wire structured error and warning events to SSE streaming pipeline"
type: feat
date: 2026-02-17
issue: 49
modules: computer, app
priority: P2
deepened: 2026-02-17
---

# Server-Side Error Propagation to Clients

## Overview

Wire up the existing `TypedErrorEvent` infrastructure and add a new `WarningEvent` to the SSE streaming pipeline so clients receive structured, actionable feedback when things go wrong. Today, four error paths are caught server-side but never communicated to the client — the user experiences silent degradation with no explanation or recovery path.

The TypedError system already exists (`typed_errors.py`, `ErrorCode` enum, `parse_error()`, `TypedErrorEvent` in `events.py`, Flutter `TypedError` model, `ErrorRecoveryCard` widget). The gap is purely **wiring**.

## Review Findings (2026-02-17)

Deepened by 5 review agents: Flutter reviewer, Python reviewer, Performance oracle, Simplicity reviewer, Parachute conventions reviewer. Key changes incorporated below:

1. **Use `ContentType.warning`** — Warning text as `MessageContent.text()` gets overwritten by the next streaming text delta due to `lastIndexWhere` replace logic. Add a distinct content type.
2. **Add `TypedErrorEvent.from_typed_error()` factory** — Eliminates brittle 7-field copy-paste at 3 callsites.
3. **Add `aborted` to terminal checks** — Same class of bug as `typedError` missing from terminal checks.
4. **Add `typedError` to background stream filter** — `sendMessage` background filter (lines 1268-1274) only processes `done`, `error`, `aborted`.
5. **Move attachment warning yield after `UserMessageEvent`** — User should see their message before the warning.
6. **Cap attachment failure details at 5** — Matches MCP warning cap.
7. **Add `ERROR_DEFINITIONS` entries** — Without them, direct lookup raises `KeyError`.
8. **Drop warning accessors on `StreamEvent`** — Used once, inline `event.data[...]` instead.
9. **Use `_reattachStreamContent`** in reattach handler, not `accumulatedContent`.
10. **`CancelledError` handling unchanged** — Stays as `AbortedEvent`, explicitly noted.

## Problem Statement

| Gap | Location | Current Behavior | User Impact |
|-----|----------|-----------------|-------------|
| MCP loading failures | `orchestrator.py:519-522` | Logged, `resolved_mcps = None` | Tools vanish with no explanation |
| Attachment save failures | `orchestrator.py:457-459` | Logged, `[Failed to attach: file]` in message | No structured error for UI |
| SDK error events | `orchestrator.py:1115-1143, 1186-1202` | Plain `ErrorEvent(error=str)` | Raw error string, no recovery actions |
| Chat catch-all | `chat.py:98-100` | Raw `{'type': 'error', 'error': str(e)}` | Potentially exposes internals |

## Key Decisions

1. **Separate `WarningEvent`** (not severity field on `TypedErrorEvent`) — Warnings are non-fatal and must not stop the stream. Existing code treats `typedError` as terminal in multiple places (`chat_message_providers.dart:777`, `1506`). A separate event type naturally falls through as a no-op in all existing handlers, avoiding accidental stream-killing bugs.

2. **`WarningEvent` reuses `ErrorCode` enum** — Add two new codes (`ATTACHMENT_SAVE_FAILED`, `MCP_LOAD_FAILED`). Reuse existing `MCP_CONNECTION_FAILED` for MCP connection issues. Single namespace, no parallel enum.

3. **Aggregate multiple warnings** — Multiple attachment failures in one message yield one `WarningEvent` with a `details` list. Multiple MCP warnings yield one aggregated event.

4. **Warning display: inline content block** — Append a lightweight warning block to the message stream content (not toast/snackbar). This avoids callback plumbing from notifier to UI and ensures warnings are visible in scroll history.

5. **Fix latent `typedError` terminal bug** — `chat_service.dart:218-220` returns on `error` but not `typedError`. `background_stream_manager.dart:89-90` same issue. Fix both.

6. **Sandbox errors out of scope** — `sandbox.py` has its own error paths (lines 308, 340, 388, 394, 644). Converting those is a separate concern. File follow-up.

## Proposed Solution

### Phase 1: Server — WarningEvent Model + Fatal Error Wiring

**1a. Add `WarningEvent` to `events.py`**

```python
# computer/parachute/models/events.py

class WarningEvent(BaseModel):
    """Warning event — non-fatal issue, stream continues."""

    type: Literal["warning"] = "warning"
    code: ErrorCode = Field(description="Warning code for programmatic handling")
    title: str = Field(description="User-friendly warning title")
    message: str = Field(description="Detailed warning message")
    details: Optional[list[str]] = Field(
        default=None, description="List of specific issues (e.g., per-MCP failures)"
    )
    session_id: Optional[str] = Field(alias="sessionId", default=None)

    model_config = {"populate_by_name": True}
```

Add to `SSEEvent` union.

**1b. Add new `ErrorCode` values to `typed_errors.py`**

```python
# In ErrorCode enum:
ATTACHMENT_SAVE_FAILED = "attachment_save_failed"
MCP_LOAD_FAILED = "mcp_load_failed"
```

Add corresponding `ERROR_DEFINITIONS` entries with user-friendly titles/messages.

**1c. Add `TypedErrorEvent.from_typed_error()` factory**

Eliminates brittle 7-field copy at every callsite:

```python
# events.py — on TypedErrorEvent class
@classmethod
def from_typed_error(cls, error: "TypedError", session_id: str | None = None) -> "TypedErrorEvent":
    return cls(
        code=error.code, title=error.title, message=error.message,
        actions=error.actions, can_retry=error.can_retry,
        retry_delay_ms=error.retry_delay_ms, original_error=error.original_error,
        session_id=session_id,
    )
```

**1d. Wire fatal errors in `orchestrator.py`**

Replace `ErrorEvent` with `TypedErrorEvent` in two locations using the factory:

```python
# orchestrator.py:1136-1140 (SDK error event, non-session path)
# BEFORE:
yield ErrorEvent(error=error_msg, session_id=...).model_dump(by_alias=True)

# AFTER:
typed = parse_error(error_msg)
yield TypedErrorEvent.from_typed_error(
    typed, session_id=captured_session_id or session.id
).model_dump(by_alias=True)
```

Same pattern for the outer `except Exception` at line 1198-1202. Note: `CancelledError` handling stays as `AbortedEvent` — unchanged.

**1e. Wire fatal errors in `chat.py`**

```python
# chat.py:98-100
# BEFORE:
yield f"data: {json.dumps({'type': 'error', 'error': str(e)})}\n\n"

# AFTER:
typed = parse_error(e)
event = TypedErrorEvent.from_typed_error(typed)
yield f"data: {json.dumps(event.model_dump(by_alias=True))}\n\n"
```

### Phase 2: Server — Warning Event Wiring

**2a. MCP loading failures → WarningEvent**

```python
# orchestrator.py:519-522
except Exception as e:
    logger.error(f"Failed to load MCP servers (continuing without MCP): {e}")
    resolved_mcps = None
    # NEW: yield warning to client
    mcp_load_warning = WarningEvent(
        code=ErrorCode.MCP_LOAD_FAILED,
        title="MCP Tools Unavailable",
        message="MCP servers failed to load. Chat will continue without MCP tools.",
        details=[str(e)],
        session_id=session.id if session.id != "pending" else None,
    )
```

Store `mcp_load_warning` and yield it after `PromptMetadataEvent` (which is emitted at line ~642). Same for `mcp_warnings` from validation.

```python
# After PromptMetadataEvent yield (~line 642):
if mcp_load_warning:
    yield mcp_load_warning.model_dump(by_alias=True)
if mcp_warnings:
    yield WarningEvent(
        code=ErrorCode.MCP_CONNECTION_FAILED,
        title="MCP Configuration Issues",
        message=f"{len(mcp_warnings)} MCP server(s) skipped due to configuration issues.",
        details=mcp_warnings[:5],  # Cap detail list
        session_id=session.id if session.id != "pending" else None,
    ).model_dump(by_alias=True)
```

**2b. Attachment save failures → WarningEvent**

Collect failures during the attachment loop, yield one aggregated warning **after `UserMessageEvent`** (not immediately after the loop — user should see their message first):

```python
# orchestrator.py — attachment handling block
attachment_failures: list[str] = []

# Inside except block (line 457-459):
except Exception as e:
    logger.error(f"Failed to save attachment {file_name}: {e}")
    attachment_parts.append(f"[Failed to attach: {file_name}]")
    attachment_failures.append(f"{file_name}: {e}")

# Store warning, yield after UserMessageEvent (~line 469):
attachment_warning = None
if attachment_failures:
    attachment_warning = WarningEvent(
        code=ErrorCode.ATTACHMENT_SAVE_FAILED,
        title="Attachment Failed",
        message=f"Failed to save {len(attachment_failures)} attachment(s).",
        details=attachment_failures[:5],  # Cap at 5, matching MCP warning cap
        session_id=session.id if session.id != "pending" else None,
    )

# After UserMessageEvent yield:
if attachment_warning:
    yield attachment_warning.model_dump(by_alias=True)
```

### Phase 3: Flutter — Handle Warning + Fix Terminal Event Bugs

**3a. Fix latent terminal event bugs**

Add `typedError` AND `aborted` to all terminal checks (both are missing in some locations):

```dart
// chat_service.dart:218-220 — add typedError to terminal check
if (event.type == StreamEventType.error ||
    event.type == StreamEventType.typedError) {
  yield event;
  return;  // Stop consuming HTTP stream
}

// background_stream_manager.dart:89-90 — add typedError to terminal check
if (event.type == StreamEventType.done ||
    event.type == StreamEventType.error ||
    event.type == StreamEventType.typedError ||
    event.type == StreamEventType.aborted) {
  break;
}

// sendMessage background stream filter (lines 1268-1274) — add typedError
// Currently only processes done, error, aborted during background streaming.
// Add typedError so background typed errors actually terminate the loop.
```

**3b. Add `warning` StreamEventType, `ContentType.warning`, and parsing**

```dart
// stream_event.dart — enum
enum StreamEventType {
  // ... existing ...
  warning,  // Non-fatal issue, stream continues
  // ...
}

// stream_event.dart — parse switch
case 'warning':
  type = StreamEventType.warning;
  break;

// No dedicated warning accessors — inline event.data['title'] etc. at use site.
```

Add `ContentType.warning` to prevent the overwrite bug (the text accumulation logic uses `lastIndexWhere((c) => c.type == ContentType.text)` to replace the last text block — a warning stored as `ContentType.text` would be silently overwritten by the next text delta):

```dart
// In ContentType enum (message_content.dart or equivalent):
enum ContentType {
  text,
  toolUse,
  toolResult,
  warning,  // NEW — distinct from text to survive text-replacement logic
}

// MessageContent factory:
factory MessageContent.warning(String text) => MessageContent(
  type: ContentType.warning,
  data: {'text': text},
);
```

**3c. Handle warnings in `chat_message_providers.dart`**

In **both** `_handleStreamEvent` (reattach) and `sendMessage` switches. Note: reattach uses `_reattachStreamContent`, sendMessage uses `accumulatedContent`.

```dart
// In sendMessage switch:
case StreamEventType.warning:
  // Non-fatal — append inline warning as distinct content type
  final title = (event.data['title'] as String?) ?? 'Warning';
  final msg = (event.data['message'] as String?) ?? '';
  final details = (event.data['details'] as List<dynamic>?)?.cast<String>() ?? [];
  final warningText = details.isNotEmpty
      ? '$title: $msg\n${details.map((d) => '  - $d').join('\n')}'
      : '$title: $msg';
  accumulatedContent.add(MessageContent.warning(warningText));
  _updateAssistantMessage(accumulatedContent, isStreaming: true);
  break;

// In _handleStreamEvent switch (reattach path):
case StreamEventType.warning:
  final title = (event.data['title'] as String?) ?? 'Warning';
  final msg = (event.data['message'] as String?) ?? '';
  final details = (event.data['details'] as List<dynamic>?)?.cast<String>() ?? [];
  final warningText = details.isNotEmpty
      ? '$title: $msg\n${details.map((d) => '  - $d').join('\n')}'
      : '$title: $msg';
  _reattachStreamContent.add(MessageContent.warning(warningText));
  _updateAssistantMessage(_reattachStreamContent, isStreaming: true);
  break;
```

**3d. Render `ContentType.warning` in the message widget**

Add a simple blockquote-style rendering for warning content blocks in the message bubble widget. The `ContentType.warning` block renders as a muted warning banner inline in the message — no toast/snackbar plumbing needed.

Stream continues — `isStreaming` stays `true`, no state change.

## Acceptance Criteria

### Functional Requirements

- [x] MCP loading failure yields `WarningEvent` with code `mcp_load_failed`, stream continues
- [x] MCP validation warnings yield aggregated `WarningEvent` with details list
- [x] Attachment save failures yield aggregated `WarningEvent` with per-file details
- [x] SDK error events (`orchestrator.py:1136-1140`) yield `TypedErrorEvent` with recovery actions
- [x] Outer exception handler (`orchestrator.py:1198-1202`) yields `TypedErrorEvent`
- [x] Chat endpoint catch-all (`chat.py:98-100`) yields `TypedErrorEvent`
- [x] `WarningEvent` includes `code`, `title`, `message`, `details`, `sessionId`
- [x] New `ErrorCode` values: `ATTACHMENT_SAVE_FAILED`, `MCP_LOAD_FAILED`

### Client Requirements

- [x] Flutter parses `type: "warning"` as `StreamEventType.warning`
- [x] `ContentType.warning` added — distinct from `ContentType.text` to prevent overwrite bug
- [x] Warning events display as inline styled block in message stream
- [x] Warning events do NOT stop streaming
- [x] Warning handler in both `sendMessage` and `_handleStreamEvent` (reattach path)
- [x] `typedError` events stop streaming in `chat_service.dart` (latent bug fix)
- [x] `typedError` events break consumption loop in `BackgroundStreamManager` (latent bug fix)
- [x] `aborted` events break consumption loop in `BackgroundStreamManager` (consistency fix)
- [x] `typedError` added to background stream filter in `sendMessage` (lines 1268-1274)

### Non-Functional Requirements

- [x] No breaking change to `ErrorEvent` — plain `error` events still work for backward compat
- [x] `WarningEvent` is ignored by any consumer that doesn't explicitly handle it
- [x] Error messages from `parse_error()` — no raw exception strings reach clients
- [x] Aggregate warnings (max 5 details items) to prevent event flooding — both MCP and attachment warnings capped
- [x] `TypedErrorEvent.from_typed_error()` factory used at all callsites (no manual field copying)

## Files to Modify

### Server (computer/)

| File | Change |
|------|--------|
| `parachute/models/events.py` | Add `WarningEvent` model, add to `SSEEvent` union |
| `parachute/lib/typed_errors.py` | Add `ATTACHMENT_SAVE_FAILED`, `MCP_LOAD_FAILED` to `ErrorCode` + `ERROR_DEFINITIONS` |
| `parachute/core/orchestrator.py` | 4 changes: MCP warning yield, attachment warning yield, 2x `ErrorEvent` → `TypedErrorEvent` |
| `parachute/api/chat.py` | 1 change: catch-all → `TypedErrorEvent` |

### App (app/)

| File | Change |
|------|--------|
| `lib/features/chat/models/stream_event.dart` | Add `warning` enum + parse case (no dedicated accessors) |
| `lib/features/chat/models/message_content.dart` | Add `ContentType.warning` + `MessageContent.warning()` factory |
| `lib/features/chat/providers/chat_message_providers.dart` | Add `warning` case to both switch blocks; add `typedError` to background stream filter |
| `lib/features/chat/services/chat_service.dart` | Add `typedError` to terminal event check |
| `lib/features/chat/services/background_stream_manager.dart` | Add `typedError` + `aborted` to terminal event check |
| `lib/features/chat/widgets/` (message bubble) | Render `ContentType.warning` as inline styled block |

## Out of Scope

- Sandbox error conversion (`sandbox.py` error paths) — separate issue
- Chat validation errors (`chat.py` lines 42-54) — lower priority
- Warning display as toast/snackbar — start with inline, iterate later
- `DoneEvent` warning summary field — future enhancement
- Retry semantics for warnings (no "retry MCP load" endpoint exists)

## References

- Brainstorm: `docs/brainstorms/2026-02-16-server-error-propagation-brainstorm.md`
- Issue: #49
- Related todos: #007 (error event key inconsistency), #029 (unsanitized exceptions in bots.py)
- Flutter error plan: `docs/plans/2026-02-17-fix-flutter-error-surfacing-gaps-plan.md`
- Existing infrastructure: `computer/parachute/lib/typed_errors.py`, `computer/parachute/models/events.py`, `app/lib/features/chat/models/typed_error.dart`, `app/lib/features/chat/widgets/error_recovery_card.dart`
