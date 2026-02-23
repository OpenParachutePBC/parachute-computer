---
title: "feat: Chat UI Redesign — Prettier Interface + Bug Fixes"
type: feat
date: 2026-02-22
issue: 106
---

# feat: Chat UI Redesign — Prettier Interface + Bug Fixes

## Overview

Three-phase improvement to the Chat UI: fix transcript parsing bugs causing tools/skills to render incorrectly on reload, redesign the thinking/tool activity display to match Claude.ai's two-phase streaming pattern (current step only → collapsed summary), and polish message bubbles throughout.

---

## Phase 1: Bug Fixes

### 1A. Transcript Tool Classification Fix

**File:** `app/lib/features/chat/models/session_transcript.dart`

**Problem:** In `toMessages()`, some tool_use blocks — especially skill invocations and possibly agent Tasks — fall through and don't produce a `ContentType.toolUse` block. On reload, they render as raw text messages.

**Implementation:**

1. Add debug logging to `toMessages()` that prints `[transcript] tool_use name=X` for every tool_use block encountered. Run a session with skills and compare live vs. reloaded.

2. The conversion path for tool_use blocks is at lines 185–212. Audit:
   - Does `name="Skill"` produce a ToolCall? (note case sensitivity)
   - Does `name` starting with `mcp__` (plugin tools) produce a ToolCall?
   - Does `name="Task"` (agent spawning) produce a ToolCall?
   - Are there any early-return conditions that silently skip a tool_use block?

3. Ensure the only special case that bypasses generic ToolCall creation is `AskUserQuestion` (lines 188–205). Every other `tool_use` block must produce a `ContentType.toolUse` content item.

4. Also audit: if a skill tool_use has no corresponding `tool_result` event in the transcript (result never written), confirm `_findToolResult()` returns null gracefully and the ToolCall still renders without a result.

**Acceptance:** After a session with skill invocations, reload — they should appear as tool chips in `CollapsibleThinkingSection`, not as text bubbles.

---

### 1B. Mid-Stream Message Ordering Fix

**File:** `app/lib/features/chat/providers/chat_message_providers.dart`

**Problem:** When the user submits a message while the assistant is mid-stream, the new user message appears in the list immediately (optimistic add) while the assistant's response for the previous message continues streaming. This creates a visually jarring interleaving: `[User A] [Streaming Assistant...] [User B]`.

**Root cause:** The user message is added to state eagerly, but the still-streaming assistant message continues to be updated below it. The queue (`_sendQueuedMessages`, lines 1582–1587) correctly defers the actual API send until `done`, but the UI state update happens immediately.

**Implementation:**

1. When `sendMessage()` is called while `state.isStreaming == true`, instead of immediately adding the user message to `state.messages`, add it to an in-memory `_pendingUserMessages` queue alongside the existing deferred send queue.

2. On the `done` event (lines 1533–1589), after finalizing the assistant message, flush `_pendingUserMessages` into `state.messages` before calling `_sendQueuedMessages()`. This way all pending user messages appear at once after the current response completes.

3. Add a visual indicator on the input field when a message is queued: disable the send button and show "Waiting for response..." or similar. (Small UX improvement, prevents double-queuing confusion.)

4. Apply the session-ID guard pattern from institutional learnings: before flushing pending messages, confirm `state.sessionId == expectedSessionId`.

**Files also touched:**
- `app/lib/features/chat/screens/chat_screen.dart` — disable input / show queued state
- `app/lib/features/chat/widgets/chat_input_bar.dart` — accept `isQueued` prop

**Acceptance:** Submitting while streaming → user message does not appear until current streaming response completes. Then user message appears, and new streaming starts immediately.

---

### 1C. System Content Hiding

**File:** `app/lib/features/chat/screens/chat_screen.dart`

**Problem:** Compact summaries and some session markers surface as visible message bubbles on session reload.

**Implementation:**

1. In the `ListView.builder` item builder, skip rendering for `message.isCompactSummary == true` messages entirely (return `const SizedBox.shrink()`). They are already wrapped in `CollapsibleCompactSummary` elsewhere; the issue is they're also being rendered directly.

2. Audit the condition at lines that filter the messages list passed to `ListView.builder`. Confirm `isCompactSummary` messages are excluded **before** indexing into the list — don't just return an empty widget, actually filter them from the list to avoid empty gaps in scroll calculations.

3. Session resume markers: only show `_buildResumeMarker()` when `sessionResumeInfo?.method == 'fresh_start'` or explicit user action. Suppress on transparent SDK resume.

**Acceptance:** Reloading a session with compact summaries shows no raw summary text messages in the chat list.

---

## Phase 2: Two-Phase Streaming Renderer

**Primary file:** `app/lib/features/chat/widgets/collapsible_thinking_section.dart`
**Secondary:** `app/lib/features/chat/widgets/message_bubble.dart`

### Current Behavior
`CollapsibleThinkingSection` receives all thinking+tool items for a message. `initiallyExpanded` is `true` during streaming, `false` after. The whole list renders whenever expanded. There is no concept of "show only the current step."

### Target Behavior

| State | Display |
|-------|---------|
| `isStreaming=true`, items accumulating | Single row: pulsing dot + current step label |
| `isStreaming=false`, collapsed | Single row: "Thinking · 3 tools" with `▶` expand |
| `isStreaming=false`, expanded | Full ordered list of all steps (existing) |

### Implementation

**Step 1: Add `isStreaming` parameter**

```dart
// collapsible_thinking_section.dart
class CollapsibleThinkingSection extends StatefulWidget {
  final List<MessageContent> items;
  final bool isDark;
  final bool isStreaming;          // NEW — replaces initiallyExpanded driving streaming UI
  final bool initiallyExpanded;   // keep for non-streaming default state

  const CollapsibleThinkingSection({
    required this.items,
    required this.isDark,
    this.isStreaming = false,      // NEW
    this.initiallyExpanded = false,
  });
}
```

In `message_bubble.dart` where `CollapsibleThinkingSection` is constructed (currently passes `initiallyExpanded: widget.message.isStreaming`), also pass `isStreaming: widget.message.isStreaming`.

**Step 2: Streaming single-step view**

When `isStreaming == true`, render only the last item in `items` (the current step):

```dart
// In _CollapsibleThinkingSectionState.build():
if (widget.isStreaming) {
  return _buildStreamingCurrentStep(context);
}
// else: existing collapsed/expanded logic
```

`_buildStreamingCurrentStep()`:
- Shows `_PulsingDot()` + current step label derived from last item:
  - `ContentType.thinking` → "Thinking..."
  - `ContentType.toolUse` where name is bash/shell → "Running command..."
  - `ContentType.toolUse` where name contains "search"/"grep" → "Searching..."
  - `ContentType.toolUse` where name is "read" → "Reading file..."
  - `ContentType.toolUse` where name is "write"/"edit" → "Editing file..."
  - `ContentType.toolUse` where name is "Skill" → "Running skill..."
  - `ContentType.toolUse` where name is "Task" → "Spawning agent..."
  - `ContentType.toolUse` otherwise → "Using tool: [name]..."
- Subtle left border in theme accent color
- Padded to match message bubble content area

**Step 3: `_PulsingDot` widget**

```dart
// New private widget in collapsible_thinking_section.dart
class _PulsingDot extends StatefulWidget { ... }

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.25, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: Container(
      width: 7, height: 7,
      decoration: BoxDecoration(
        color: // theme accent color (turquoise),
        shape: BoxShape.circle,
      ),
    ),
  );
}
```

**Step 4: Polished collapsed summary row**

When `isStreaming == false` and `!_sectionExpanded`, the collapsed row currently shows text like "5 tools · 2 thoughts". Polish:

- Consistent icon: `Icons.auto_awesome` or `Icons.hub` (subtle, not distracting)
- Typography: `labelMedium` weight, muted foreground color (not primary)
- Counts computed from items: `thinkingCount` = items where `type == thinking`, `toolCount` = items where `type == toolUse`
- Format: `"[icon] Thought [N]× · [N] tool[s]"` or `"[icon] [N] tools"` if no thinking
- Tap to expand: same existing toggle, just better styled
- `▶ / ▼` chevron on right side

**Acceptance:**
- During streaming: only pulsing dot + current step label visible
- After streaming: collapsed row with counts
- Tap expands to full list
- Looks correct on both light and dark themes

---

## Phase 3: Visual Polish

### 3A. Message Bubble Polish
**File:** `app/lib/features/chat/widgets/message_bubble.dart`

- **Padding:** Increase content padding from current to `EdgeInsets.symmetric(horizontal: 16, vertical: 12)` for assistant bubbles; user bubbles `horizontal: 14, vertical: 10`
- **Text:** Ensure `bodyMedium` is used for all message text (not `bodySmall`)
- **Assistant bubble background:** Slightly elevated surface color (one level above `surface`) for better contrast vs. background
- **User bubble:** Keep current teal, but add subtle shadow `BoxShadow(blurRadius: 4, offset: Offset(0, 2), color: Colors.black12)`
- **Streaming indicator:** Replace simple `CircularProgressIndicator` with the new `_PulsingDot` (reuse from Phase 2) + "Thinking..." text in muted style

### 3B. Tool Chip Polish (Expanded View)
**File:** `app/lib/features/chat/widgets/collapsible_thinking_section.dart`

In the expanded list, each tool item is shown as a chip with name + summary. Polish:
- Add a thin left border in a muted accent color for each tool row
- Tool name: `labelSmall` bold, icon color matched to success (turquoise) / error (red)
- Summary text: `bodySmall`, muted, no bold
- Thinking block: italic `bodySmall` with `Icons.psychology_outlined` icon, extra indent
- Reduce gap between tool items from current spacing

### 3C. Collapsed Summary Row
Already addressed in Phase 2 Step 4 above.

---

## Acceptance Criteria

- [x] Reloading a session with skill invocations shows tool chips, not raw text bubbles
- [x] Submitting a message mid-stream: new user message does not appear until current response completes
- [x] No compact summary or internal session messages visible in chat list on reload
- [x] During streaming: `CollapsibleThinkingSection` shows only the current step with pulsing dot
- [x] After streaming: single collapsed row with "N tools · N thoughts" format
- [x] Expanding the collapsed row shows all steps in order
- [x] Visual polish applied: better padding, typography, and tool chip styling
- [x] No regressions: existing tool expansion, user question cards, compact summaries, segment loading all still work

---

## Files Changed

| File | Change |
|------|--------|
| `app/lib/features/chat/models/session_transcript.dart` | Tool classification audit + fix in `toMessages()` |
| `app/lib/features/chat/providers/chat_message_providers.dart` | Mid-stream ordering fix: defer user message add until `done` |
| `app/lib/features/chat/screens/chat_screen.dart` | Filter `isCompactSummary` from list; suppress transparent resume markers; queued-send UI state |
| `app/lib/features/chat/widgets/collapsible_thinking_section.dart` | Two-phase renderer: `_PulsingDot`, streaming single-step view, polished collapsed row |
| `app/lib/features/chat/widgets/message_bubble.dart` | Pass `isStreaming` to section; visual polish; replace streaming indicator |
| `app/lib/features/chat/widgets/chat_input_bar.dart` | Accept `isQueued` prop for mid-stream queue state |

---

## Dependencies & Risks

- **Flutter animation controller lifecycle**: `_PulsingDot` must properly dispose its `AnimationController` to avoid leaks. Use `SingleTickerProviderStateMixin` and dispose in `dispose()`.
- **Throttle + ordering interaction**: Phase 1B (deferred user message) must flush pending user messages atomically before `_sendQueuedMessages()` fires — otherwise the queued API send races with the state update.
- **isCompactSummary filtering**: Filter from the messages list before indexing, not via empty widget returns, to avoid scroll position jumps.
- **Tool name matching**: Audit should include MCP plugin tool names (`mcp__plugin_X__toolname`) which are already handled in the display layer but may not be in transcript parsing.

## References

- Brainstorm: `docs/brainstorms/2026-02-22-chat-ui-redesign-brainstorm.md`
- Stream lifecycle cleanup patterns: `docs/plans/2026-02-17-fix-chat-stream-lifecycle-cleanup-plan.md`
- Mid-stream reattachment: `docs/plans/2026-02-19-fix-mid-stream-session-content-frozen-plan.md`
- AskUserQuestion race: `docs/plans/2026-02-15-fix-askuser-race-and-overflow-plan.md`
- Current thinking section: `app/lib/features/chat/widgets/collapsible_thinking_section.dart`
- Transcript conversion: `app/lib/features/chat/models/session_transcript.dart:75`
- Message providers: `app/lib/features/chat/providers/chat_message_providers.dart:1731`
