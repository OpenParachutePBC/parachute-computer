---
title: "fix: sandbox message parity — structured content on reload"
type: fix
date: 2026-03-10
issue: 217
---

# Sandbox Message Parity — Structured Content on Reload

Fix message persistence so sandbox and direct chat sessions display identical content on reload — including thinking blocks, tool calls, and tool results. Also fix the silent exchange drop when no text events arrive.

## Problem Statement

Four related bugs cause content loss in chat sessions:

1. **Sandbox transcripts store only text** — `write_sandbox_transcript()` writes a flat string, discarding thinking/tool_use/tool_result blocks
2. **Exchanges silently dropped** — transcript writing gated on `had_text`; tool-only responses vanish
3. **Loading strips structured content** — `_extract_message_content()` filters to text-only, affecting both paths
4. **No structured accumulation** — orchestrator tracks a flat `response_text` string, not content blocks

## Acceptance Criteria

- [x] Reopening a sandbox chat shows thinking blocks, tool calls, and tool results from prior messages
- [x] Reopening a direct chat shows the same (fix loading side)
- [x] Tool-only responses (no text) are persisted and visible on reload
- [x] Old transcripts (plain text format) still load correctly (backward compatible)
- [x] Flutter `CollapsibleThinkingSection` renders on reload identically to during streaming

## Implementation

### Phase 1: Accumulate structured content in orchestrator (Python)

**File: `computer/parachute/core/orchestrator.py`**

In `_process_sandbox_event()`:
- Add `content_blocks: list[dict]` to `ctx.sbx` (alongside existing `response_text`)
- On `"thinking"` events: append `{"type": "thinking", "text": content}`
- On `"tool_use"` events: append `{"type": "tool_use", ...tool_call_data}`
- On `"tool_result"` events: append `{"type": "tool_result", "toolUseId": ..., "content": ..., "isError": ...}`
- On `"text"` events: append or update last text block `{"type": "text", "text": content}`
- Change the `had_text` flag to `had_content` — set True on ANY content event, not just text

In `_run_sandboxed()`:
- Initialize `sbx["content_blocks"] = []` and `sbx["had_content"] = False`
- Pass `content_blocks` to transcript writer instead of `response_text`

### Phase 2: Fix transcript writing (Python)

**File: `computer/parachute/core/session_manager.py`**

Update `write_sandbox_transcript()`:
- Change signature: replace `assistant_response: str` with `content_blocks: list[dict]`
- Write assistant event with full content blocks: `{"content": content_blocks}`
- Remove the `had_text` gate in orchestrator — write transcript whenever "done" arrives and `had_content` is True (or even unconditionally, since the user message should always persist)
- Keep writing a "result" event with the text-only content for SDK resume compatibility

### Phase 3: Fix message loading (Python)

**File: `computer/parachute/core/session_manager.py`**

Replace `_extract_message_content()` with `_extract_message_blocks()`:
- Returns `list[dict]` instead of `Optional[str]`
- Preserves all block types: text, thinking, tool_use, tool_result
- For string content (old transcripts, user messages): wraps in `[{"type": "text", "text": content}]`

Update `_load_sdk_messages()`:
- Use `_extract_message_blocks()` instead of `_extract_message_content()`
- Messages now have `content: list[dict]` instead of `content: str`
- Skip "result" events when a preceding "assistant" event already captured the content (avoid duplication)

**Backward compatibility**: The new `_extract_message_blocks()` detects format by checking `isinstance(content, str)` vs `isinstance(content, list)`. Old transcripts with plain strings get wrapped in a text block. No migration needed.

### Phase 4: Update Flutter parser (Dart)

**File: `app/lib/features/chat/models/chat_message.dart`**

Update `ChatMessage.fromJson()` content block parsing to handle all types:
- `type == "text"` → `MessageContent.text(...)` (already works)
- `type == "tool_use"` → `MessageContent.toolUse(ToolCall.fromJson(...))` (already works)
- `type == "thinking"` → `MessageContent.thinking(text)` (add this case)
- `type == "tool_result"` → `MessageContent.toolUse(...)` with result data, or a new content type if needed for display

The `CollapsibleThinkingSection` widget already handles both `ContentType.thinking` and `ContentType.toolUse` — no widget changes needed if the content blocks parse correctly.

### Phase 5: Handle tool_result in Flutter (Dart)

Tool results need to pair with their tool_use blocks for the UI to show checkmarks/results. During streaming this happens via `StreamEventType.toolResult` matching by `toolUseId`. On reload, the content blocks arrive pre-ordered.

**Option A (simpler):** Don't create separate `tool_result` content blocks in the message. Instead, when loading, merge tool_result data into the preceding tool_use block (matching by `toolUseId`). The `ToolCall` model already has `result` and `isError` fields.

**Option B:** Create a new `ContentType.toolResult` and handle it in `CollapsibleThinkingSection`.

**Recommend Option A** — it matches the streaming behavior where tool results update the existing tool_use entry.

## Files to Modify

| File | Change |
|------|--------|
| `computer/parachute/core/orchestrator.py` | Accumulate `content_blocks` in `_process_sandbox_event()`, remove `had_text` gate |
| `computer/parachute/core/session_manager.py` | Update `write_sandbox_transcript()` signature, replace `_extract_message_content()` with `_extract_message_blocks()`, fix `_load_sdk_messages()` dedup |
| `app/lib/features/chat/models/chat_message.dart` | Add `thinking` and `tool_result` handling in `fromJson()` |

## Technical Considerations

- **SDK transcript format**: Direct sessions use SDK-written JSONL which already has structured content. The loading fix (Phase 3) benefits both paths automatically.
- **Content block size**: Tool inputs/outputs can be large. For now, store everything — the transcript is already append-only and per-session. Truncation can be added later if file sizes become a problem.
- **No model changes needed**: `SessionWithMessages.messages` is already `list[dict[str, Any]]` — the dict values just become richer.
- **Brain graph**: Exchange storage in the brain graph is out of scope — it stores summary text and that's fine for search. The JSONL transcript is the source of truth for full message content.

## Testing

- Unit test: `_extract_message_blocks()` handles old string format, new block format, and mixed content
- Unit test: `write_sandbox_transcript()` with content_blocks produces valid JSONL that `_load_sdk_messages()` can round-trip
- Manual: Send a sandbox chat with tool calls → reload → verify thinking/tools appear
- Manual: Send a direct chat with tool calls → reload → verify same
- Manual: Open an old session (pre-fix) → verify it still loads (backward compat)
