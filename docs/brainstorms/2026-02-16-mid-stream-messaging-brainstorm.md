# Mid-Stream Messaging: Send Messages While Claude is Responding

**Status**: Brainstorm complete, ready for planning
**Priority**: P1 (Core UX)
**Modules**: app, computer

---

## What We're Building

Allow users to send new messages while Claude is actively streaming a response. Today, the chat input is disabled during streaming — the user must wait for the response to finish (or manually abort) before they can type and send. The Claude Agent SDK supports injecting messages mid-stream via its `stream_input` mechanism, so this is primarily a UI and server wiring issue.

### Current Behavior

1. **Flutter app** (`chat_screen.dart` line 736): `enabled: !chatState.isStreaming && !chatState.isViewingArchived` — input is disabled whenever `isStreaming` is true.

2. **Chat provider** (`chat_message_providers.dart` line 1026): `sendMessage()` has an early return `if (state.isStreaming) return;` — even if the UI allowed sending, the provider blocks it.

3. **Server** (`claude_sdk.py`): `_string_to_async_iterable` yields one message then blocks on `done_event`. There's no mechanism to inject additional messages into the stream.

4. **SDK capability**: The Claude Agent SDK's `stream_input()` accepts an `AsyncIterable` of messages. As long as the iterable keeps yielding, new messages are sent to the CLI subprocess. Our `done_event` pattern already keeps stdin open — we just need to yield additional messages before the event fires.

### Why This Matters

Mid-stream messaging is a natural conversational pattern. Users often think of follow-up context, corrections, or additional instructions while reading Claude's response. Forcing them to wait (especially for long tool-use chains) breaks conversational flow. Claude Code's terminal interface supports this — you can type while it's responding.

---

## Why This Approach

### The Plumbing Already Exists

Our `done_event` pattern (added in the AskUserQuestion fix) keeps the stdin AsyncIterable alive until the `result` event fires. The iterable currently yields one message then awaits `done_event`. To support mid-stream messages, we change it to:

1. Yield the initial message
2. Wait on **either** `done_event` (stream complete) or a new message arriving in a queue
3. If a new message arrives, yield it and go back to step 2
4. If `done_event` fires, stop iterating

This is a straightforward modification to `_string_to_async_iterable`.

### UI Can Be Simple

The input field stays enabled during streaming. When the user sends a message while streaming:
- Add the user message to the chat UI immediately (optimistic)
- Queue it for injection into the active stream
- The server yields it into the SDK's stdin
- Claude incorporates it into its ongoing response

---

## Key Decisions

### 1. Server: Message Queue on Active Streams

Add an `asyncio.Queue` to the streaming context. The iterable pulls from this queue between `done_event` checks:

```python
async def _string_to_async_iterable(
    s: str,
    done_event: Optional[asyncio.Event] = None,
    message_queue: Optional[asyncio.Queue] = None,
) -> AsyncGenerator[dict[str, Any], None]:
    # Yield the initial message
    yield {"type": "user", "message": {"role": "user", "content": s}}

    if done_event is not None:
        while not done_event.is_set():
            if message_queue:
                try:
                    msg = await asyncio.wait_for(message_queue.get(), timeout=0.5)
                    yield {"type": "user", "message": {"role": "user", "content": msg}}
                except asyncio.TimeoutError:
                    continue  # Check done_event again
            else:
                await done_event.wait()
                break
```

### 2. Server: New API Endpoint for Mid-Stream Messages

Add a POST endpoint like `/api/chat/{session_id}/inject` that pushes a message onto the active stream's queue:

```python
@router.post("/{session_id}/inject")
async def inject_message(session_id: str, body: InjectMessage):
    queue = orchestrator.active_stream_queues.get(session_id)
    if not queue:
        raise HTTPException(404, "No active stream for this session")
    await queue.put(body.message)
    return {"success": True}
```

### 3. Server: Store Queue in Orchestrator

The orchestrator tracks `active_stream_queues: dict[str, asyncio.Queue]` alongside `active_streams`. Created when a stream starts (with `can_use_tool` enabled), removed in the `finally` block.

### 4. App: Enable Input During Streaming

Remove the `!chatState.isStreaming` guard from the input `enabled` property:

```dart
// Before
enabled: !chatState.isStreaming && !chatState.isViewingArchived,
// After
enabled: !chatState.isViewingArchived,
```

### 5. App: Route Send to Inject When Streaming

In `sendMessage()`, instead of early-returning when streaming, call a new `injectMessage()` method:

```dart
Future<void> sendMessage({required String message, ...}) async {
    if (state.isStreaming) {
        await _injectMessage(message);
        return;
    }
    // ... existing send logic
}

Future<void> _injectMessage(String message) async {
    // Add user message to UI immediately
    final userMessage = ChatMessage(role: MessageRole.user, ...);
    state = state.copyWith(messages: [...state.messages, userMessage]);
    // POST to inject endpoint
    await _chatService.injectMessage(state.sessionId!, message);
}
```

### 6. Visual Indicator for Queued Messages

When a message is injected mid-stream, show a subtle visual indicator on the user message bubble (e.g., lighter opacity or small "sent" badge) until the assistant acknowledges it. This gives the user confidence their message was received.

---

## Architecture

### Files to Modify

**Server (computer/):**
| File | Changes |
|------|---------|
| `computer/parachute/core/claude_sdk.py` | Add `message_queue` param to `_string_to_async_iterable`; loop on queue + done_event |
| `computer/parachute/core/orchestrator.py` | Create/track `active_stream_queues`; pass queue to SDK wrapper; cleanup in `finally` |
| `computer/parachute/api/chat.py` | Add `/api/chat/{session_id}/inject` endpoint |

**App (app/):**
| File | Changes |
|------|---------|
| `app/lib/features/chat/screens/chat_screen.dart` | Remove `!chatState.isStreaming` from input enabled |
| `app/lib/features/chat/providers/chat_message_providers.dart` | Replace early return with `_injectMessage()`; add inject method |
| `app/lib/features/chat/services/chat_session_service.dart` | Add `injectMessage()` API call |

---

## Open Questions

### 1. Should mid-stream messages start a new turn or continue the current one?
The SDK's `stream_input` feeds messages into the current conversation. Claude sees them as additional context arriving during its response. It may or may not acknowledge them in the current response — that's up to the model. This is the natural behavior and matches how Claude Code terminal works.

### 2. What about attachments on mid-stream messages?
For v1, limit mid-stream injection to text-only messages. Attachments require file processing that's better handled in a new turn.

### 3. Should the stop/abort button change behavior?
Currently the stop button aborts the entire stream. With mid-stream messaging, the user might want to stop the current response but keep the conversation going. For v1, keep abort behavior as-is. A future enhancement could add "interrupt" (stop current response, process queued messages) vs "abort" (stop everything).

### 4. How does this interact with AskUserQuestion?
If Claude asks a question via AskUserQuestion while the user has already typed a mid-stream message, the question card should still appear. The user's injected message and the question answer are independent channels. No conflict — they use different mechanisms (stdin message vs `can_use_tool` response).

---

## Success Criteria

- User can type and send messages while Claude is streaming a response
- Sent messages appear immediately in the chat UI
- Claude receives injected messages and can incorporate them into its response
- The stream completes normally after all messages are processed
- No regression in single-message flow (non-streaming send still works identically)
- Stop/abort still works correctly with queued messages
