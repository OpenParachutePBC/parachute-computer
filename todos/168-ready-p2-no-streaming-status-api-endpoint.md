---
status: ready
priority: p2
issue_id: 109
tags: [code-review, bug, chat, computer, agent-native]
dependencies: [155]
---

# No API endpoint for streaming tool/thinking activity — agents can't show progress

## Problem Statement

The tap-to-expand streaming thinking section gives human users live visibility into which tools and thinking steps are executing mid-stream. There is no equivalent for bot connectors (Telegram, Discord) or automated agents: no HTTP endpoint exposes the current streaming step, and no periodic SSE event surfaces a "currently running" label. A bot connector that joins mid-stream must reconstruct the full tool chain from individual `toolUse`/`toolResult`/`thinking` events accumulated from stream start — it cannot simply ask "what is Claude doing right now?"

The label logic is already implemented in `_streamingLabel()` in `collapsible_thinking_section.dart` (line 282). The server-side primitives are also already present. This is a purely additive gap.

## Findings

- **Source**: agent-native-reviewer (P2, confidence: 84)
- **Location**: `app/lib/features/chat/widgets/collapsible_thinking_section.dart:282` (label logic), no server route equivalent

## Proposed Solutions

### Solution A: `GET /chat/{session_id}/streaming-status` endpoint (Recommended)

Add a new route to the computer server returning the current streaming step for an active session:

```json
{
  "is_streaming": true,
  "current_step": "Bash",
  "current_step_summary": "Running git status",
  "tool_call_count": 3
}
```

The session manager already tracks active streams. The label logic can be lifted server-side from `_streamingLabel()`.
- **Pros**: Any HTTP client (bot connector, curl) can poll for progress; mirrors the human UI's information
- **Cons**: Requires server changes; adds one more endpoint to maintain
- **Effort**: Medium
- **Risk**: Low

### Solution B: Emit a periodic `status` SSE event during long-running tool calls

Emit a lightweight `{"type": "status", "label": "Bash", "summary": "..."}` SSE event every N seconds during active tool execution. Consumers that don't understand the event can ignore it; consumers that do can show live progress.
- **Pros**: No polling required; works for all stream consumers
- **Cons**: Changes the SSE event contract; bot connectors must be updated to forward these events
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/` (new route), `app/lib/features/chat/widgets/collapsible_thinking_section.dart` (label logic reference)

## Acceptance Criteria

- [ ] A bot connector or external HTTP client can determine what tool Claude is currently running during an active stream
- [ ] Does not require the consumer to have been on the stream since message start

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
