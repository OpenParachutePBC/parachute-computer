---
date: 2026-02-22
topic: chat-ui-redesign
status: brainstorm
priority: P1
labels: brainstorm, chat, app
issue: "#106"
---

# Chat UI Redesign: Prettier Interface + Bug Fixes

## What We're Building

A comprehensive overhaul of the Chat UI — fixing transcript parsing bugs that cause tools and skills to render incorrectly on reload, and redesigning how thinking/tool activity is displayed during and after streaming.

The current UI shows an ever-growing list of thinking and tool steps as the assistant works. Claude.ai does this better: during active streaming it shows just the current step with subtle animation, then collapses everything into a single expandable row when the response is complete. We want that pattern.

## Problems Being Solved

### Bug: Tools and Skills Show as Text on Reload

When a session is resumed from transcript (`session_transcript.dart` → `toMessages()`), some tool_use blocks — especially skill invocations — fall through as plain text instead of being converted to ToolUse content blocks. This means:
- On initial load (live stream): tool appears correctly in `CollapsibleThinkingSection`
- On reload: same tool appears as an ugly raw text message in the bubble

Root cause: `toMessages()` likely has incomplete skill-name matching or misses certain tool call patterns when converting SDK transcript events.

### Bug: Messages Out of Order

Intermittent reordering of messages during streaming or reload. Likely a state update race condition in `ChatMessagesNotifier` or stream event accumulation.

### Bug: System/Internal Content Leaking Into Chat

Compact summaries, session markers, and other "behind the scenes" SDK artifacts sometimes surface as visible messages when a session is reloaded. These should always be hidden unless explicitly expanded.

### UX: Ever-Growing Tool/Thinking List

`CollapsibleThinkingSection` renders all thinking and tool steps in a vertical list that grows unboundedly during long responses. This is visually noisy. Claude.ai shows one step at a time during streaming, then collapses everything on completion.

### UX: Visual Polish

Message bubbles, tool chips, thinking sections, and overall layout need refinement — better typography, spacing, color contrast, and information density.

## Chosen Approach: Streaming-Aware Two-Phase Renderer

The key insight is that thinking/tools have two phases with different optimal displays:

1. **Streaming phase** (`message.isStreaming == true`): Show only the _current_ step with a subtle animated indicator. Don't accumulate a list.
2. **Completed phase** (`isStreaming == false`): Collapse all thinking/tools into a single expandable summary row.

This maps cleanly onto the existing `ChatMessage.isStreaming` flag.

### What Changes

**`CollapsibleThinkingSection` redesign:**
- Streaming: Animated single-step view ("Searching for X..." / "Thinking..." / "Running bash...")
- Completed: Single collapsed row — e.g. "↓ Thinking + 3 tool calls" with expand affordance
- Expanded: Ordered list of all steps (existing behavior)

**`session_transcript.dart` fix:**
- Audit `toMessages()` tool_use classification for all tool names including `skill`, `Task`, and other special cases
- Ensure result: same visual rendering whether live or from transcript

**Stream ordering fix:**
- Audit `ChatMessagesNotifier` for race conditions in event accumulation
- Ensure `addMessage` and `updateLastMessage` operate atomically relative to stream events

**System content hiding:**
- `isCompactSummary` messages: never show in list (skip in ListView builder)
- Session resume markers: only show if user explicitly triggered a new session (not on transparent resume)

**Visual polish:**
- Message bubble: improve padding, radius, and text styles
- Tool chips: more informative summaries, better icons, cleaner expand/collapse
- Thinking text: style as clearly secondary/internal content

## Key Decisions

- **Two-phase renderer over a single unified view**: Streaming and completed states are fundamentally different — optimizing each separately is cleaner than trying to animate a list.
- **Fix transcript parsing before visual work**: The bug where reload and live-stream render differently means users can't trust what they see. Fix this first within the same effort.
- **Don't rebuild the message model**: The `ChatMessage` / `MessageContent` model is sound. Changes are in rendering and transcript parsing only.
- **`isStreaming` flag is the source of truth**: Drives phase switching in the renderer. No new state needed.

## Scope

Changes touch:
- `app/lib/features/chat/widgets/collapsible_thinking_section.dart` — two-phase renderer
- `app/lib/features/chat/models/session_transcript.dart` — tool classification fix
- `app/lib/features/chat/widgets/message_bubble.dart` — visual polish
- `app/lib/features/chat/screens/chat_screen.dart` — hide system content in list
- `app/lib/features/chat/providers/chat_message_providers.dart` — ordering fix (if needed)

## Design Details (Resolved)

- **Collapsed summary row**: Current "5 tools · 2 thoughts" format is good, just needs visual polish
- **Streaming indicator**: Pulsing animation — a breathing/pulsing dot or shimmer effect on the current step label
- **Tool results**: Inline expansion (existing behavior) — confirmed correct
- **Ordering bug repro**: Most reliably triggered by submitting a new message while the assistant is mid-stream. Root cause is likely a race condition in `ChatMessagesNotifier` — the new user message state update interleaves with ongoing assistant message accumulation events.

## Next Steps

→ `/para-plan #NN` for implementation details
