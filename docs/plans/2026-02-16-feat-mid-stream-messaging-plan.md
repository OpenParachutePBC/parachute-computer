---
title: "feat: Mid-stream messaging — send messages while Claude is responding"
type: feat
date: 2026-02-16
issue: "#56"
priority: P1
modules: app, computer
---

# Mid-Stream Messaging

Allow users to send messages while Claude is actively streaming a response. The Claude Agent SDK supports this via `stream_input()` accepting an `AsyncIterable` — our `done_event` pattern already keeps stdin open. This is primarily a wiring task across server and app.

## Overview

**Current behavior**: Input disabled during streaming (`chat_screen.dart:736`), provider early-returns (`chat_message_providers.dart:1026`), SDK iterable yields one message then blocks (`claude_sdk.py:57-65`).

**Target behavior**: Input stays enabled. When the user sends while streaming, the message is injected into the active SDK stream via an `asyncio.Queue`. Claude receives it as additional context mid-response.

**Scope for v1**:
- Text-only injection (no attachments)
- App (Flutter) only — bot connectors excluded (they use per-chat locks)
- Non-sandboxed sessions only (Docker sessions have no stdin access)
- Abort behavior unchanged
- No per-message acknowledgment tracking

---

## Phase 1: Server — Message Queue Infrastructure

### 1.1 Modify `_string_to_async_iterable` to accept a message queue

**File**: `computer/parachute/core/claude_sdk.py:48-65`

Add `message_queue: Optional[asyncio.Queue]` parameter. When provided, loop on the queue with a 0.5s timeout between `done_event` checks. **Drain remaining queue items before exiting** to avoid silently dropping messages sent in the last moment.

```python
async def _string_to_async_iterable(
    s: str,
    done_event: Optional[asyncio.Event] = None,
    message_queue: Optional[asyncio.Queue] = None,
) -> AsyncGenerator[dict[str, Any], None]:
    yield {"type": "user", "message": {"role": "user", "content": s}}

    if done_event is None:
        return

    while not done_event.is_set():
        if message_queue is None:
            await done_event.wait()
            break
        try:
            msg = await asyncio.wait_for(message_queue.get(), timeout=0.5)
            yield {"type": "user", "message": {"role": "user", "content": msg}}
        except asyncio.TimeoutError:
            continue

    # Drain any messages queued right as done_event fired
    if message_queue is not None:
        while not message_queue.empty():
            try:
                msg = message_queue.get_nowait()
                yield {"type": "user", "message": {"role": "user", "content": msg}}
            except asyncio.QueueEmpty:
                break
```

### 1.2 Pass queue through `query_streaming`

**File**: `computer/parachute/core/claude_sdk.py:160-214`

Add `message_queue` parameter to `query_streaming()`. Pass it to `_string_to_async_iterable` when creating the effective prompt.

### 1.3 Track queues in Orchestrator

**File**: `computer/parachute/core/orchestrator.py`

- Add `self.active_stream_queues: dict[str, asyncio.Queue] = {}` alongside `active_streams` (~line 197)
- In `run_streaming()`, create a bounded queue: `message_queue = asyncio.Queue(maxsize=20)`
- Register in `active_stream_queues` when session ID is known (same lifecycle as `active_streams`)
- Pass `message_queue` to `query_streaming()`
- Clean up in `finally` block alongside `active_streams`
- Handle the "pending" → real session ID re-key for queues (same pattern as `active_streams` at line 974-977)

### 1.4 Add inject method to Orchestrator

**File**: `computer/parachute/core/orchestrator.py`

```python
async def inject_message(self, session_id: str, message: str) -> bool:
    """Inject a user message into an active stream. Returns True if queued."""
    queue = self.active_stream_queues.get(session_id)
    if queue is None:
        return False
    try:
        queue.put_nowait(message)
        return True
    except asyncio.QueueFull:
        return False
```

### 1.5 Emit SSE event for injected messages

**File**: `computer/parachute/core/orchestrator.py`

When a message is injected, yield a `UserMessageEvent` on the SSE stream so that:
- Background stream reattach sees it
- Multi-tab scenarios stay in sync
- The session transcript reflects the injection

This requires the inject path to signal the streaming generator. Use a secondary queue or callback that the SSE generator checks.

**Simpler v1 approach**: The SDK will emit the injected user message as an event in the stream (since it goes through `stream_input`). The orchestrator already yields all SDK events to the SSE stream. Verify this works — if the SDK emits a `user` event for injected messages, no extra work is needed.

### 1.6 Update message count tracking

**File**: `computer/parachute/core/orchestrator.py:~1131`

Currently hardcoded `increment_message_count(final_session_id, 2)`. Track inject count during the stream and increment by `1 + inject_count + 1` (initial user + injected users + assistant).

---

## Phase 2: Server — API Endpoint

### 2.1 Add inject endpoint

**File**: `computer/parachute/api/chat.py` (after line 260, after the `/answer` endpoint)

```python
class InjectMessageRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=32000)

@router.post("/chat/{session_id}/inject")
async def inject_message(
    request: Request,
    session_id: str,
    body: InjectMessageRequest,
) -> dict[str, Any]:
    orchestrator = request.app.state.orchestrator
    success = await orchestrator.inject_message(session_id, body.message)
    if not success:
        raise HTTPException(
            status_code=404,
            detail="No active stream for this session",
        )
    return {"success": True}
```

**Auth**: Uses the same middleware as other `/api/chat` endpoints — no extra work needed (the router already has auth applied).

**Validation**: `min_length=1` prevents empty messages. `max_length=32000` matches the existing chat message limits.

---

## Phase 3: App — Chat Service

### 3.1 Add `injectMessage` to chat service

**File**: `app/lib/features/chat/services/chat_session_service.dart`

Add after the existing `answerQuestion` method (~line 369):

```dart
/// Inject a message into an active stream.
/// Returns true if queued, false if no active stream or error.
Future<bool> injectMessage(String sessionId, String message) async {
  try {
    final response = await client.post(
      Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/inject'),
      headers: defaultHeaders,
      body: jsonEncode({'message': message}),
    ).timeout(const Duration(seconds: 5));
    return response.statusCode == 200;
  } catch (e) {
    debugPrint('[ChatService] Error injecting message: $e');
    return false;
  }
}
```

---

## Phase 4: App — State Management

### 4.1 Add `_injectMessage` to ChatMessagesNotifier

**File**: `app/lib/features/chat/providers/chat_message_providers.dart`

Replace the early return at line 1026 with inject routing:

```dart
Future<void> sendMessage({required String message, ...}) async {
  if (state.isStreaming) {
    await _injectMessage(message);
    return;
  }
  // ... existing send logic unchanged
}
```

**Critical design decision — message list ordering**:

When a user injects a message mid-stream, insert it AFTER the current streaming assistant message. The assistant continues updating as `messages.last` because the SDK merges injected input into the same response turn. The message list becomes:

```
[user1, assistant(streaming)]  →  inject  →  [user1, assistant(streaming), user_inject]
```

But now `messages.last` is a user message, so `_performMessageUpdate` will fail. **Fix**: Change `_performMessageUpdate` to find the last assistant message by role instead of assuming `messages.last`:

```dart
void _performMessageUpdate(List<MessageContent> content, {required bool isStreaming}) {
  final messages = List<ChatMessage>.from(state.messages);
  // Find last assistant message (may not be messages.last if user injected)
  final lastAssistantIndex = messages.lastIndexWhere(
    (m) => m.role == MessageRole.assistant,
  );
  if (lastAssistantIndex == -1) return;

  messages[lastAssistantIndex] = messages[lastAssistantIndex].copyWith(
    content: List.from(content),
    isStreaming: isStreaming,
  );
  state = state.copyWith(messages: messages);
}
```

Also update `_updateOrAddAssistantMessage` (the reattach variant at line 781) with the same pattern.

**The `_injectMessage` method**:

```dart
Future<void> _injectMessage(String message) async {
  final sessionId = state.sessionId;
  if (sessionId == null) return;

  // Optimistic UI: add user message to list
  final userMessage = ChatMessage(
    id: const Uuid().v4(),
    role: MessageRole.user,
    content: [MessageContent.text(message)],
    timestamp: DateTime.now(),
  );
  state = state.copyWith(
    messages: [...state.messages, userMessage],
  );

  // POST to inject endpoint
  final chatService = _ref.read(chatSessionServiceProvider);
  final success = await chatService.injectMessage(sessionId, message);

  if (!success) {
    // Fallback: stream likely ended, send as new turn
    // Remove the optimistic message first
    final msgs = List<ChatMessage>.from(state.messages);
    msgs.removeWhere((m) => m.id == userMessage.id);
    state = state.copyWith(messages: msgs, isStreaming: false);
    // Re-send as normal message (new turn)
    await sendMessage(message: message);
  }
}
```

**Key**: The fallback on 404 automatically re-sends as a new turn. The user never loses their message.

### 4.2 Handle "pending" session ID

If `state.sessionId` is null (new session, first message still processing), `_injectMessage` returns early. The user must wait for the session ID event before they can inject. This is a narrow window (~1-2 seconds) and acceptable for v1.

---

## Phase 5: App — UI Changes

### 5.1 Enable input during streaming

**File**: `app/lib/features/chat/screens/chat_screen.dart:736`

```dart
// Before
enabled: !chatState.isStreaming && !chatState.isViewingArchived,
// After
enabled: !chatState.isViewingArchived,
```

The `isStreaming` prop is still passed to `ChatInput` for the stop button UI — just not for disabling the input field.

### 5.2 Block attachments during streaming

**File**: `app/lib/features/chat/widgets/chat_input.dart`

In the attachment picker trigger, add a guard:

```dart
// Disable attachment picker while streaming (v1: text-only injection)
if (widget.isStreaming) {
  // Optionally show a brief tooltip: "Attachments available after response completes"
  return;
}
```

### 5.3 Visual indicator (minimal v1)

No special indicator in v1. The user message appears in the chat like any other user message. The assistant continues streaming below it. If the inject fails and falls back to a new turn, the message is re-sent transparently. The visual behavior is natural enough without a custom indicator.

**Rationale**: Adding a "queued" badge requires tracking per-message acknowledgment state, which adds complexity for uncertain UX benefit. Defer to v2 if users report confusion.

---

## Scope Exclusions (v1)

| Excluded | Reason | Future |
|----------|--------|--------|
| Attachments on mid-stream messages | Requires file processing pipeline | v2 |
| Bot connector injection | Per-chat locks serialize messages | v2: redesign lock to allow queue bypass |
| Sandboxed (Docker) sessions | No stdin access to container | v2: container stdin proxy |
| Per-message acknowledgment indicator | Complex lifecycle, uncertain UX value | v2 if needed |
| Interrupt vs abort distinction | Behavior change, needs design | v2 |
| Idempotency on inject endpoint | Duplicates unlikely with short timeouts | v2 if needed |

---

## Acceptance Criteria

- [ ] User can type and send messages while Claude is streaming a response
- [ ] Sent messages appear immediately in the chat UI (optimistic)
- [ ] Claude receives injected messages via the SDK's `stream_input` mechanism
- [ ] Stream completes normally after all messages are processed
- [ ] Messages queued right as `done_event` fires are drained (not lost)
- [ ] If inject returns 404 (stream ended), message is re-sent as a new turn automatically
- [ ] Queue is bounded (maxsize=20); inject returns error if full
- [ ] Inject endpoint validates message length (1-32000 chars)
- [ ] `_performMessageUpdate` finds assistant message by role, not position
- [ ] No regression in single-message flow (non-streaming send works identically)
- [ ] Stop/abort still works correctly
- [ ] Attachment picker disabled while streaming
- [ ] Message count tracking accounts for injected messages
- [ ] Queue cleaned up in orchestrator `finally` block
- [ ] Existing auth middleware applies to inject endpoint

---

## Files to Modify

| File | Phase | Changes |
|------|-------|---------|
| `computer/parachute/core/claude_sdk.py` | 1 | Add `message_queue` to `_string_to_async_iterable` and `query_streaming`; drain queue before exit |
| `computer/parachute/core/orchestrator.py` | 1 | Add `active_stream_queues` dict; create/register/cleanup queue; `inject_message()` method; message count fix |
| `computer/parachute/api/chat.py` | 2 | Add `POST /chat/{session_id}/inject` endpoint with `InjectMessageRequest` model |
| `app/lib/features/chat/services/chat_session_service.dart` | 3 | Add `injectMessage()` API method |
| `app/lib/features/chat/providers/chat_message_providers.dart` | 4 | Replace `isStreaming` guard with `_injectMessage()`; fix `_performMessageUpdate` to find assistant by role; add 404 fallback |
| `app/lib/features/chat/screens/chat_screen.dart` | 5 | Remove `!chatState.isStreaming` from input enabled |
| `app/lib/features/chat/widgets/chat_input.dart` | 5 | Block attachment picker while streaming |

---

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| SDK doesn't persist injected messages in JSONL | Low | High | Verify empirically before merging; if not, add manual transcript write |
| Message ordering breaks `_performMessageUpdate` | Medium | High | Find assistant by role, not position (Phase 4.1) |
| Queue drain misses messages in race window | Low | Medium | Drain loop + fallback re-send on 404 |
| `done_event` fires before queue message is yielded | Low | Medium | Queue drain catches this; fallback re-send is safety net |

---

## References

- Brainstorm: `docs/brainstorms/2026-02-16-mid-stream-messaging-brainstorm.md`
- Issue: #56
- Related: #48 (chat stream lifecycle fixes — poll timer, throttle reset)
- SDK docs: `stream_input()` accepts `AsyncIterable` for bidirectional communication
- Prior art: Claude Code terminal supports typing while Claude responds
