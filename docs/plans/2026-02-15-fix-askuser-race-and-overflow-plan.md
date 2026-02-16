---
title: "Fix AskUserQuestion Race Condition, Dead Card, and Title Bar Overflow"
type: fix
date: 2026-02-15
issue: "#36"
modules: [computer, app]
priority: P1
---

# Fix AskUserQuestion Race Condition, Dead Card, and Title Bar Overflow

## Overview

Three related reliability bugs in the Parachute app that undermine core UX. The AskUserQuestion flow has a race condition causing answer submissions to fail, the question card has no error/retry/dismiss states, and the chat title bar overflows on tablet screens.

## Problem Statement

1. **Race condition**: The orchestrator emits the `user_question` SSE event *before* the permission handler registers the Future. The app can POST an answer to `/chat/{id}/answer` and get a 404 because `pending_questions` doesn't have the entry yet.

2. **Dead card**: When answer submission fails, `UserQuestionCard` resets to its interactive state with no error message, no retry button, and no dismiss option. The user is stuck.

3. **Title overflow**: `_buildTitle()` uses `Row(mainAxisSize: MainAxisSize.min)` which prevents `Flexible` from constraining the title text, causing overflow on tablet-width screens.

## Proposed Solution

### Phase 1: Fix the Race Condition (server)

**Root cause**: Two independent request_id generators + SSE emits before handler registers.

**Fix**: Remove the `UserQuestionEvent` emission from the tool_use block detection in the orchestrator. Instead, emit it from the `on_user_question` callback, which fires *after* the handler has registered the Future.

**Files**:
- `computer/parachute/core/orchestrator.py`

**Changes**:

1. **Remove lines 948-960** (SSE emission from tool_use detection):

```python
# DELETE THIS BLOCK from orchestrator.py (lines 948-960):
# Special handling for AskUserQuestion - emit user_question event
if block.get("name") == "AskUserQuestion":
    questions = block.get("input", {}).get("questions", [])
    if questions and captured_session_id:
        tool_use_id = block.get("id", "")
        request_id = f"{captured_session_id}-q-{tool_use_id}"
        yield UserQuestionEvent(
            request_id=request_id,
            session_id=captured_session_id,
            questions=questions,
        ).model_dump(by_alias=True)
        logger.info(f"Emitted user_question event: {request_id}")
```

2. **Modify `on_user_question` callback** (lines 637-644) to store enough data for SSE emission. Currently stores `request_id` and `questions`. Also needs `session_id`:

```python
def on_user_question(request) -> None:
    nonlocal pending_user_question
    pending_user_question = {
        "request_id": request.id,        # Authoritative ID from handler
        "questions": request.questions,
        "session_id": captured_session_id,  # ADD THIS
    }
```

3. **Add SSE emission after the SDK event loop yields back** — this is the tricky part. The `on_user_question` callback fires inside the `can_use_tool` callback, which runs during `query_streaming()`. We can't yield from inside a callback.

**Solution**: Use a queue pattern. The callback stores the event, and the main event loop checks for it after each SDK event:

```python
# Before the async for loop:
pending_user_question_event: dict | None = None

def on_user_question(request) -> None:
    nonlocal pending_user_question_event
    pending_user_question_event = {
        "request_id": request.id,
        "questions": request.questions,
    }

# Inside the async for loop, after processing each event:
if pending_user_question_event and captured_session_id:
    yield UserQuestionEvent(
        request_id=pending_user_question_event["request_id"],
        session_id=captured_session_id,
        questions=pending_user_question_event["questions"],
    ).model_dump(by_alias=True)
    logger.info(f"Emitted user_question event: {pending_user_question_event['request_id']}")
    pending_user_question_event = None
```

**Why this works**: The `can_use_tool` callback blocks the SDK, so no new SDK events arrive until the question is answered. But the callback itself is synchronous — it sets `pending_user_question_event` and returns. The SDK then continues, and the next iteration of the `async for` loop sees the queued event and yields it.

**Wait — actually, the SDK blocks on `can_use_tool` (it's async, awaiting the Future).** So no more events come through the `async for` loop until the question is answered. The queue approach won't work because the loop is blocked.

**Revised approach**: Use `asyncio.Queue` to bridge the callback and the generator:

```python
import asyncio

user_question_queue: asyncio.Queue = asyncio.Queue()

def on_user_question(request) -> None:
    user_question_queue.put_nowait({
        "request_id": request.id,
        "questions": request.questions,
    })

# In the streaming loop, wrap query_streaming to also check the queue:
async for event in query_streaming(...):
    # Check for queued user questions first
    while not user_question_queue.empty():
        uq = user_question_queue.get_nowait()
        if captured_session_id:
            yield UserQuestionEvent(
                request_id=uq["request_id"],
                session_id=captured_session_id,
                questions=uq["questions"],
            ).model_dump(by_alias=True)

    # Process normal event...
```

**But wait** — if the SDK is blocked on `can_use_tool`, it won't yield any events to the `async for` loop, so we never check the queue. We need to interleave waiting on the SDK stream and the queue.

**Final approach (simplest)**: Emit the SSE event directly from the `on_user_question` callback by storing it and yielding it *before* the next SDK event. Since `_handle_ask_user_question` is `async` and blocks the SDK, we can use the fact that `on_user_question` is called synchronously *within* `_handle_ask_user_question`, which itself runs inside the `can_use_tool` callback, which is awaited by the SDK *before* it yields the next event.

The real issue is: **the `async for` loop in the orchestrator won't advance while `can_use_tool` is blocking**. So we need to emit the SSE event through a different channel.

**Correct solution**: The SSE stream is an async generator. The FastAPI endpoint iterates it. We need to yield from it even while the SDK is blocked. This requires **merging two async sources**: the SDK event stream and the user question notifications.

**Simplest correct fix**:

Instead of trying to yield from the generator, have the `on_user_question` callback write directly to the SSE response. But that's not how our SSE works — it yields dicts.

**Actually, let's re-examine the timing**:

1. SDK calls `can_use_tool("AskUserQuestion", input, context)`
2. Permission handler's `_handle_ask_user_question()` runs
3. At line 717: `self.pending_questions[request_id] = request` (Future registered)
4. At line 720-721: `self.on_user_question(request)` fires callback
5. At line 725: `await asyncio.wait_for(future, timeout=...)` blocks

The SDK is awaiting step 5. But the `async for` loop in the orchestrator is also blocked because `query_streaming()` hasn't yielded a new event.

**However**: The SSE endpoint in FastAPI uses `StreamingResponse` with our async generator. The HTTP connection stays open. The client receives events as they're yielded. When the generator is blocked (waiting for the next SDK event), no bytes go out.

We need the `UserQuestionEvent` bytes to go out to the client WHILE the SDK is blocked on `can_use_tool`. Since our generator can't yield during this time, we need a different approach.

**Working solution — use an intermediate async queue as the SSE source**:

```python
# In run_streaming(), instead of yielding directly:
event_queue: asyncio.Queue = asyncio.Queue()

# Wrap the SDK iteration in a task that puts events on the queue:
async def _process_sdk_events():
    async for event in query_streaming(...):
        await event_queue.put(process_event(event))
    await event_queue.put(None)  # Sentinel

# on_user_question puts events directly on the queue:
def on_user_question(request):
    event_queue.put_nowait(UserQuestionEvent(...).model_dump(by_alias=True))

# Generator yields from queue:
sdk_task = asyncio.create_task(_process_sdk_events())
while True:
    event = await event_queue.get()
    if event is None:
        break
    yield event
```

This decouples the SDK iteration from the SSE yield. The `on_user_question` callback fires (synchronously), puts the event on the queue, and the generator's `await event_queue.get()` picks it up immediately. Meanwhile, the SDK continues blocking on `can_use_tool`, but the SSE stream keeps flowing.

This is a moderate refactor of the streaming loop. The existing code yields directly from the `async for` loop. The new code uses a producer-consumer pattern with a queue.

### Phase 2: Fix the Dead Card (app)

**Files**:
- `app/lib/features/chat/widgets/user_question_card.dart`
- `app/lib/features/chat/screens/chat_screen.dart`
- `app/lib/features/chat/services/chat_session_service.dart`

**Changes to `user_question_card.dart`**:

1. Add error state and dismiss callback to widget interface:

```dart
class UserQuestionCard extends StatefulWidget {
  final List<Map<String, dynamic>> questions;
  final Future<bool> Function(Map<String, dynamic>) onAnswer;
  final VoidCallback? onDismiss;  // ADD: dismiss callback
  // ...
}
```

2. Add state variables:

```dart
String? _errorMessage;    // Error message on failure
bool _canRetry = true;    // Whether retry is possible
```

3. Update `_submitAnswers()` to handle failure:

```dart
final success = await widget.onAnswer(answers);
setState(() {
  _isSubmitting = false;
  if (success) {
    _isAnswered = true;
    _errorMessage = null;
  } else {
    _errorMessage = 'Failed to submit. Tap to retry.';
    _canRetry = true;
  }
});
```

4. Add dismiss button (always visible, top-right of card):

```dart
// In the header Row, after the Spacer:
IconButton(
  icon: Icon(Icons.close, size: 16),
  onPressed: widget.onDismiss,
  tooltip: 'Dismiss',
  padding: EdgeInsets.zero,
  constraints: BoxConstraints(minWidth: 28, minHeight: 28),
),
```

5. Show error message below options when `_errorMessage != null`:

```dart
if (_errorMessage != null)
  Padding(
    padding: EdgeInsets.only(top: Spacing.sm),
    child: Text(
      _errorMessage!,
      style: TextStyle(color: BrandColors.error, fontSize: 12),
    ),
  ),
```

**Changes to `chat_session_service.dart`**:

6. Add retry with backoff to `answerQuestion()`:

```dart
Future<bool> answerQuestion({...}) async {
  const retries = [Duration(milliseconds: 500), Duration(seconds: 1), Duration(seconds: 2)];

  for (var i = 0; i <= retries.length; i++) {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/answer'),
        headers: defaultHeaders,
        body: jsonEncode({'request_id': requestId, 'answers': answers}),
      ).timeout(const Duration(seconds: 30));  // Increase from 10s

      if (response.statusCode == 200) return true;
      if (response.statusCode == 404) {
        // No pending question — may be timing issue, retry
        if (i < retries.length) {
          await Future.delayed(retries[i]);
          continue;
        }
        return false;
      }
      return false;  // Other errors, don't retry
    } catch (e) {
      if (i < retries.length) {
        await Future.delayed(retries[i]);
        continue;
      }
      return false;
    }
  }
  return false;
}
```

**Changes to `chat_screen.dart`**:

7. Wire dismiss callback when building UserQuestionCard:

```dart
UserQuestionCard(
  questions: questions,
  onAnswer: (answers) => notifier.answerQuestion(answers),
  onDismiss: () => notifier.dismissPendingQuestion(),  // ADD
)
```

### Phase 3: Fix Title Bar Overflow (app)

**File**: `app/lib/features/chat/screens/chat_screen.dart`

**Change**: Remove `mainAxisSize: MainAxisSize.min` from the title Row (line 772-773):

```dart
// BEFORE (line 772):
Row(
  mainAxisSize: MainAxisSize.min,
  children: [

// AFTER:
Row(
  children: [
```

This lets the Row fill available width from its parent, and `Flexible` on the title text will properly constrain and ellipsize.

**Also fix `_appBarBadge`** (line 834) to handle long labels:

```dart
Widget _appBarBadge(String label, Color color) {
  return Container(
    constraints: BoxConstraints(maxWidth: 120),  // ADD: prevent badge overflow
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(...),
    child: Text(
      label,
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      overflow: TextOverflow.ellipsis,  // ADD
      maxLines: 1,                      // ADD
    ),
  );
}
```

### Phase 4: Test and Verify

**Manual testing checklist**:

- [ ] Send a message that triggers AskUserQuestion in Parachute Chat
- [ ] Verify question card appears
- [ ] Click an answer, verify it submits successfully
- [ ] Verify card shows "Answered" state after success
- [ ] Kill the server while a question is pending, verify error state appears on card
- [ ] Verify dismiss button works (card disappears, stream continues)
- [ ] Verify title bar on tablet-width window (no overflow with long title + badges)
- [ ] Verify title bar on narrow phone-width window
- [ ] Verify badges ellipsize when label is long

## Acceptance Criteria

- [x] AskUserQuestion answers submit reliably (no 404 errors from race condition)
- [x] Question card shows error message with retry option when submission fails
- [x] Question card has dismiss button that always works
- [x] No RenderFlex overflow on chat title bar at any screen size
- [ ] Server logs show matching request_ids between handler and SSE event
- [x] Retry logic handles transient 404s (handler not yet registered) gracefully

## Technical Considerations

### Architecture: Queue Pattern for SSE

The biggest change is refactoring the orchestrator's streaming loop from direct `async for` + `yield` to a producer-consumer queue pattern. This is necessary because `can_use_tool` blocks the SDK, preventing the generator from yielding while the question is pending.

**Risk**: The queue pattern changes how all SSE events flow, not just user questions. Careful to preserve event ordering and not drop events.

**Mitigation**: The `asyncio.Queue` is FIFO, so event order is preserved. The sentinel value (`None`) ensures clean shutdown. Existing event processing logic moves into the producer task unchanged.

### Alternative: Simpler Fix (Accept the Race, Fix on Client)

If the queue refactor feels too risky, a simpler approach:
- Keep the current dual emission (orchestrator + callback)
- Fix the client to retry on 404 with backoff (Phase 2 already does this)
- The retry handles the race — first attempt may 404, second succeeds after handler registers

**Tradeoff**: Doesn't fix the root cause, but is much simpler. The retry delay (500ms → 1s → 2s) would handle the race condition in practice since the handler registers within milliseconds of the SSE event.

### Existing Pattern: Finalize Before Yield

Commit `98be751` established the pattern: "finalize state BEFORE yielding events." The queue approach follows this spirit — the handler registers the Future, fires the callback, and only then does the SSE event reach the client.

## Dependencies & Risks

- **No schema changes** — SSE event format unchanged
- **No new dependencies** — uses stdlib `asyncio.Queue`
- **Risk**: Queue pattern changes event flow for ALL events, not just questions. Test thoroughly.
- **Risk**: `Flexible` behavior change in title Row could affect desktop layout. Test at multiple breakpoints.
- **Fallback**: If queue refactor is too risky, client-side retry alone handles the race in practice.

## References

- Brainstorm: `docs/brainstorms/2026-02-15-app-ui-stability-brainstorm.md`
- GitHub Issue: #36
- Race condition fix precedent: commit `98be751`
- Overflow audit precedent: commit `28d96db`
- `app/CLAUDE.md` overflow conventions (lines 121-131)
- `computer/parachute/core/orchestrator.py:637-660, 948-960`
- `computer/parachute/core/permission_handler.py:676-759`
- `app/lib/features/chat/widgets/user_question_card.dart`
- `app/lib/features/chat/widgets/error_recovery_card.dart` (error UI pattern)
- `app/lib/features/chat/screens/chat_screen.dart:747-832`
