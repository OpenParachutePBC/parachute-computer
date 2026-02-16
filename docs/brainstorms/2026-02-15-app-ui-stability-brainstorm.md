# App UI Stability: AskUserQuestion Failures & Overflow Errors

**Status**: Brainstorm complete, ready for planning
**Priority**: P1 (Core UX reliability)
**Modules**: app, computer

---

## What We're Building

Fix three reliability issues in the Flutter app:
1. **AskUserQuestion answer submission fails** — the question card renders but submitting an answer returns 404 or silently fails
2. **Failed question card stays stuck** — no dismiss, no error state, no retry — dead card blocks the UI
3. **RenderFlex overflow errors** — layout overflow on multiple screens, confirmed on title bar at tablet sizes

These are foundational UX bugs that undermine trust in the app.

---

## Why This Approach

### Problem 1: AskUserQuestion Race Condition

The AskUserQuestion flow has a **dual request_id generation** problem and a **timing race**.

**The flow today:**

```
SDK emits tool_use block for AskUserQuestion
    |
    ├── Orchestrator (SSE stream) sees the block
    |   └── Generates request_id = f"{captured_session_id}-q-{tool_use_id}"
    |   └── Yields UserQuestionEvent to the app
    |
    └── SDK calls can_use_tool("AskUserQuestion", ...)
        └── PermissionHandler._handle_ask_user_question()
        └── Generates request_id = f"{self.session.id}-q-{tool_use_id}"
        └── Creates Future, stores in pending_questions[request_id]
```

**Two bugs here:**

1. **ID mismatch**: `captured_session_id` (orchestrator) and `self.session.id` (permission handler) can differ during the "pending" → real session ID transition. The orchestrator updates `captured_session_id` on the first SDK event, but `permission_handler.session` gets updated later (orchestrator line 883). If AskUserQuestion fires before session finalization, the IDs won't match.

2. **Timing race**: The SSE event (step 1) can reach the app *before* the permission handler has registered the Future (step 2). User clicks answer → POST to `/answer` → handler says "no pending question" → 404.

**Evidence**: The `question_timeout_seconds` is 300s (generous), but the app's HTTP POST has a 10-second timeout. If the POST fails, the card silently stays — no retry, no error feedback to the user.

### Problem 2: Dead Card After Failure

When `_submitAnswers()` fails (line 178 returns false), the card resets to its initial interactive state — `_isSubmitting = false`, `_isAnswered = false`. No error message, no dismiss button. The user sees a card that looks clickable but the server-side Future may have already timed out or the pending question was already cleaned up. There is no way to dismiss the card except sending a new message.

**Code path** (`user_question_card.dart` lines 178-185):
```dart
final success = await widget.onAnswer(answers);
setState(() {
  _isSubmitting = false;
  if (success) {
    _isAnswered = true;
  }
  // On failure: nothing happens — card just sits there
});
```

### Problem 3: Title Bar Overflow

**Confirmed location**: `chat_screen.dart` `_buildTitle()` method (line 747).

The title bar is a `Column` with:
1. A `Row(mainAxisSize: MainAxisSize.min)` containing icon + title text + dropdown arrow (line 772)
2. A `SingleChildScrollView` with badges row (line 801)

**The bug**: The title `Row` uses `mainAxisSize: MainAxisSize.min` which tells it to size to its content rather than respect parent constraints. The `Flexible` wrapper on the Text widget (line 781) only constrains the text if the Row itself is bounded — but `MainAxisSize.min` means the Row doesn't fill available space, so if content exceeds available width, it overflows.

**When it appears on mobile AppBar** (line 388): `AppBar.title` provides constraints, but the `Row(mainAxisSize: MainAxisSize.min)` fights against them. On tablet-width screens, the AppBar has less space due to action buttons (settings, more menu), and long session titles push the Row past its bounds.

**The embedded toolbar** (line 488) wraps `_buildTitle` in `Expanded`, which helps, but the inner Row still has the same `MainAxisSize.min` issue — it just has more space to work with on desktop.

**Additional overflow suspects** (need hands-on audit):
- Badge rows in various places
- Tool result content rendering
- Long file paths or error messages in message bubbles

---

## Key Decisions

### 1. Single Source of Truth for request_id

**Decision**: The permission handler should be the sole generator of request_ids. The orchestrator should read the ID from the handler callback instead of computing its own.

**Current** (two generators):
```python
# Orchestrator (line 954)
request_id = f"{captured_session_id}-q-{tool_use_id}"

# Permission handler (line 698)
request_id = f"{self.session.id}-q-{tool_use_id}"
```

**Proposed**: The `on_user_question` callback already passes the `UserQuestionRequest` which contains `.id` — the orchestrator should use that instead of recomputing:

```python
# on_user_question callback stores the request with its authoritative ID
# Orchestrator reads pending_user_question["request_id"] which came from handler
```

### 2. Ensure Handler Registers Before SSE Emits

**Decision**: The `UserQuestionEvent` SSE emission should only happen *after* the permission handler has registered the pending question.

**Current flow** (race-prone):
1. Orchestrator sees `tool_use` block → emits SSE immediately
2. SDK calls `can_use_tool` → handler registers Future (may happen after step 1)

**Proposed flow**:
1. Orchestrator sees `tool_use` block for AskUserQuestion → does NOT emit SSE yet
2. SDK calls `can_use_tool` → handler registers Future → fires `on_user_question` callback
3. Callback signals orchestrator → NOW emit the SSE event

This eliminates the race entirely. The `on_user_question` callback mechanism is already in place (orchestrator line 637-643), it just needs to be the trigger for SSE emission rather than the tool_use block detection.

### 3. Card Must Have Error & Dismiss States

**Decision**: The UserQuestionCard needs three additional states beyond "interactive" and "answered":

- **Error with retry**: "Failed to submit — tap to retry" after answer POST fails
- **Dismiss**: X button always visible so user can dismiss a stuck card
- **Timed out**: Auto-dismiss or show "Question expired" when server timeout fires

**Implementation in `user_question_card.dart`**:
- Add `_hasError` bool state, shown when `onAnswer` returns false
- Add dismiss callback (`onDismiss`) to the widget interface
- Show error message + retry button on failure
- Provider calls `dismissPendingQuestion()` (already exists at line 1649) on dismiss

### 4. Answer Submission Resilience

**Decision**: Add retry logic on the app side.

- Retry the POST up to 3 times with short backoff (500ms, 1s, 2s)
- Increase HTTP timeout from 10s to 30s
- After all retries exhausted, show error state on card (not silent failure)

### 5. Fix Title Bar Overflow

**Decision**: Change the title Row from `MainAxisSize.min` to default (`MainAxisSize.max`).

**Current** (line 772):
```dart
Row(
  mainAxisSize: MainAxisSize.min,  // Sizes to content, can overflow
  children: [icon, Flexible(title), dropdown],
)
```

**Fix**:
```dart
Row(
  // Remove mainAxisSize: MainAxisSize.min
  // Default MainAxisSize.max respects parent constraints
  children: [icon, Flexible(title), dropdown],
)
```

This lets `Flexible` on the title text actually work — the Row fills available space, and the text truncates with ellipsis as intended.

---

## Architecture

### Files to Modify

**Server (computer/):**
- `computer/parachute/core/orchestrator.py` — Remove UserQuestionEvent emission from tool_use block detection (lines 948-960); instead emit from `on_user_question` callback using handler's authoritative request_id

**App (app/):**
- `app/lib/features/chat/widgets/user_question_card.dart` — Add error state, dismiss button, retry UI
- `app/lib/features/chat/services/chat_session_service.dart` — Add retry logic with backoff, increase timeout
- `app/lib/features/chat/screens/chat_screen.dart` — Fix title bar `Row` constraints (line 772); wire dismiss callback to `UserQuestionCard`; audit other overflow-prone layouts
- `app/lib/features/chat/providers/chat_message_providers.dart` — Wire dismiss through to `dismissPendingQuestion()`

### No Schema Changes Required

The SSE event format stays the same. The fix is about *when* and *where* the event is generated, not what it contains.

---

## Open Questions

### 1. Should we deduplicate the user_question SSE event?
Currently the orchestrator emits it from the tool_use block AND the handler fires the callback. We should have only one emission path. **Recommendation**: Yes, single path through the callback.

### 2. Should the card auto-dismiss on timeout?
If the server-side Future times out (5 min), the card stays visible in the app with no feedback. **Recommendation**: Emit a `user_question_timeout` SSE event so the app can dismiss the card and show "Question expired".

### 3. Full overflow audit scope
The title bar is confirmed. Are there other screens? **Recommendation**: Fix the title bar first, then do a targeted audit of other screens at tablet and phone sizes. Common suspects: session list items, settings panels, message bubbles with long content.

---

## Success Criteria

- AskUserQuestion card reliably submits answers on first attempt
- No 404 errors on `/answer` endpoint due to ID mismatches
- Failed submissions show clear error with retry option
- Users can always dismiss a stuck question card
- No RenderFlex overflow on chat title bar at tablet/phone sizes
- Server logs show matching request_ids between SSE events and pending questions

---

## Related Issues
- #29: Desktop/Telegram Integration Fixes (overlapping app reliability)
- #23: Bot Management Overhaul (bot sessions also use AskUserQuestion flow)
