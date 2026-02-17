# Server-Side Error Propagation to Clients

**Status**: Brainstorm complete, ready for planning
**Priority**: P2 (Reliability & observability)
**Modules**: computer

---

## What We're Building

Wire up structured error events to the SSE streaming pipeline so clients know when non-fatal failures happen during a session. Today, multiple error paths are caught and logged server-side but never communicated to the client. The user experiences silent degradation -- tools disappear without explanation, attachments fail without feedback, and SDK errors arrive as generic strings.

The infrastructure for this largely already exists (`TypedErrorEvent`, `typed_errors.py`, `ErrorCode` enum, `parse_error()`) but is not connected to the streaming pipeline.

### Specific Gaps

1. **MCP loading failures silently swallowed** (`orchestrator.py` ~line 503-506) -- MCP server loading fails entirely, execution continues with `resolved_mcps = None`. The `PromptMetadataEvent` reports `availableMcps: []` which is a partial signal, but a user who configured MCP servers gets no explanation for why their tools vanished.

2. **Attachment save failures not propagated** (`orchestrator.py` ~lines 418-447) -- When an attachment fails to decode/save, the error is logged and a `[Failed to attach: filename]` text is appended to the message. The client never receives a structured error event, so the UI can't display an attachment-specific failure state.

3. **Bare exception catch-all in SDK wrapper** (`claude_sdk.py` ~lines 207-210) -- The general `except Exception` handler converts all non-`ClaudeSDKError` exceptions to `{"type": "error", "error": str(e)}` with no error categorization. The `ClaudeSDKError` handler (lines 204-206) is slightly better but still doesn't use the `TypedError` system.

4. **Generic exception in chat streaming** (`chat.py` ~lines 96-98) -- The outer exception handler in `event_generator` converts any unhandled exception to `str(e)`. No error categorization, no recovery actions, no session context.

---

## Why This Approach

### The TypedError System Already Exists

The `typed_errors.py` module has a complete error classification system:
- `ErrorCode` enum with 15 codes (auth, billing, rate limit, MCP, session, etc.)
- `RecoveryAction` model with keyboard shortcuts and action types
- `parse_error()` function that pattern-matches error strings to codes
- `TypedErrorEvent` in `events.py` ready to be yielded in the SSE stream

The gap is purely in **wiring** -- the orchestrator and SDK wrapper need to yield `TypedErrorEvent` instead of plain `ErrorEvent` in the right places, and new non-fatal warning events need to be added for degraded-but-functional states.

### Non-Fatal vs Fatal Distinction

Not all errors should stop the stream. MCP loading failure is a **degraded state** -- the session should continue, but the client needs to know tools are unavailable. Attachment save failure is a **partial failure** -- the message should still send, but the client should show which attachments failed.

This calls for a **warning event** in addition to error events. The existing `TypedErrorEvent` can serve this purpose with severity-level semantics, or a lightweight `WarningEvent` can handle it.

---

## Key Decisions

1. **Use `TypedErrorEvent` for fatal errors in the streaming pipeline** -- Replace plain `ErrorEvent` yields in the orchestrator's exception handlers with `TypedErrorEvent` yields that include error codes, recovery actions, and original error context. Use `parse_error()` for classification.

2. **Add a `WarningEvent` for non-fatal degraded states** -- New event type for situations where the stream continues but the client should display a notice. MCP loading failures, attachment save failures, and MCP validation warnings would use this. The client can display these as toast notifications or inline warnings without interrupting the chat.

3. **Improve SDK wrapper error categorization** -- The bare `except Exception` in `claude_sdk.py` should attempt to classify the error (is it a network issue? auth issue? SDK bug?) before yielding the error event. The `parse_error()` function already handles this pattern matching.

4. **Keep `chat.py` outer handler as safety net** -- The outer exception handler in the chat endpoint should remain as a last-resort catch-all, but should use `parse_error()` to yield a `TypedErrorEvent` instead of a bare string.

---

## Open Questions

1. **WarningEvent vs severity field on TypedErrorEvent?** -- Should we add a new `WarningEvent` model, or add a `severity: "warning" | "error"` field to `TypedErrorEvent`? A new event type is simpler for clients to handle (different event type = different handler), but a severity field keeps the event taxonomy smaller.

2. **Client-side handling** -- How should the Flutter app display warning events? Toast notifications? Inline banners in the chat? A status bar indicator? This is more of an app-side design question but affects what data we put in the warning event.

3. **MCP partial failures** -- When some MCP servers load but others fail, should the warning list each failed server, or just say "N of M MCP servers failed to load"? Detailed per-server info is more useful for debugging but noisier for the user.

4. **Retry semantics for warnings** -- Should warning events include recovery actions? For MCP failures, a "Retry" action could trigger a session restart with MCP reload. For attachment failures, a "Retry upload" action could re-attempt the save. This adds complexity but makes warnings actionable.
