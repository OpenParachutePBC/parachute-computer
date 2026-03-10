# Sandbox Message Parity — Structured Content on Reload

**Status:** Brainstorm
**Priority:** P1
**Labels:** computer, app, chat
**Issue:** #217

---

## What We're Building

Full parity between sandbox and direct chat sessions for message persistence and display. Today, sandbox sessions lose thinking blocks, tool calls, and sometimes entire messages when you reload a chat. Direct sessions have the same content-stripping problem on reload, but sandbox has additional issues around transcript writing that can cause whole exchanges to vanish.

**The goal:** When you reopen any chat — sandbox or direct — you see the same thinking blocks, tool calls, and tool results that you saw during streaming. No content loss, no silent drops.

## Why This Matters

Sandbox is the default mode for chat. If messages disappear or lose their structure on reload, users lose trust in the system. Tool calls and thinking blocks aren't decoration — they're how you understand what the agent did and why. Losing them makes past conversations opaque and makes it hard to pick up where you left off.

## Problems Found (Audit)

### Problem 1: Sandbox transcripts only store plain text

`write_sandbox_transcript()` in `session_manager.py` constructs the assistant message as a single text block:

```python
{"content": [{"type": "text", "text": assistant_response}]}
```

Where `assistant_response` is the accumulated `response_text` string — just the text events. Thinking, tool_use, and tool_result events stream to the client during the session but are never captured for storage. On reload, you get a flat text blob.

### Problem 2: Entire exchanges silently dropped

Transcript writing is gated on `had_text` (orchestrator.py line 1275). If the agent responds with only tool calls before producing any text, or if the container errors mid-stream, `had_text` stays `False` and **nothing is written** — not even the user's message. The entire exchange vanishes silently.

### Problem 3: Message loading strips structured content (both paths)

`_extract_message_content()` in `session_manager.py` filters to only `type == "text"` blocks when loading from JSONL. This affects both sandbox AND direct sessions on reload. Even if the JSONL contains full structured content (as direct session transcripts do), it's stripped to plain text at load time.

### Problem 4: No structured event accumulation during streaming

The orchestrator tracks `response_text` (a flat string) for sandbox sessions and `current_text` (also a flat string) for direct sessions. Neither path accumulates the structured content block array (thinking, tool_use, tool_result, text) that the SDK provides. The events fly through to the client in real-time and are lost.

## Key Decisions

### 1. Accumulate structured content blocks, not just text

During streaming (both paths), maintain a `content_blocks: list[dict]` alongside the text accumulator. Each thinking, tool_use, tool_result, and text event appends a block. This array is what gets written to the transcript.

### 2. Fix `write_sandbox_transcript()` to write structured content

Instead of constructing a synthetic single-text-block message, write the accumulated content blocks array. The JSONL format already supports this — direct session transcripts from the SDK use structured content.

### 3. Remove the `had_text` gate on transcript writing

Write the transcript whenever a "done" event arrives, regardless of whether text was produced. A response that's all tool calls is still a valid exchange that should persist. The user's message should never be silently dropped.

### 4. Fix `_load_sdk_messages()` to return structured content

Replace `_extract_message_content()` (which returns a plain string) with a method that returns the full content block array. Messages in the API response go from `{content: "string"}` to `{content: [{type: "text", ...}, {type: "thinking", ...}, {type: "tool_use", ...}]}`.

### 5. Update Flutter message parser to handle all block types

`ChatMessage.fromJson()` already handles `tool_use` blocks. Add handling for `thinking` and `tool_result` blocks so they render in `CollapsibleThinkingSection` on reload, exactly as they do during streaming.

## Scope

### In scope
- Structured content accumulation in both sandbox and direct streaming paths
- Transcript writing with full content blocks
- Message loading with structured content preservation
- API contract change for message format
- Flutter parser updates for thinking + tool_result blocks
- Removing the `had_text` gate on transcript writing

### Out of scope (future)
- Brain graph exchange storage with structured content (currently stores summary text)
- Per-project tool permission fine-tuning
- Retroactive fix for existing transcripts (old sessions will still show text-only)

## Open Questions

1. **Backward compatibility**: When loading old transcripts that have plain text content, the parser needs to handle both formats gracefully. Should we version the transcript format or just detect the shape?
2. **Content block size**: Tool inputs/outputs can be large. Should we truncate tool_result content in the transcript, or store everything? The brain graph already truncates exchanges — should transcripts follow the same limits?
3. **Direct session transcripts**: The SDK writes its own JSONL for direct sessions. These already have structured content. Do we just fix the loading side (Problem 3) for direct sessions, or also write our own structured transcripts to ensure consistency?
