---
status: ready
priority: p1
issue_id: 109
tags: [code-review, agent-native, api, server, chat, ask-user-question]
dependencies: []
---

# No `GET /chat/{session_id}/pending-questions` endpoint — answering loop not discoverable

## Problem Statement

`POST /chat/{session_id}/answer` exists and is HTTP-accessible. However, there is no GET endpoint to discover *whether* a question is pending. A bot connector (Telegram, Discord) or automated agent that resumes a session mid-question can only know a question is pending if it was subscribed to the original SSE stream when the `user_question` event fired. After session reload, `pendingUserQuestion` state is null (not persisted), so the Flutter app cannot answer the question programmatically. Meanwhile the server-side `asyncio.Future` is still alive and waiting.

The server already has `get_pending_questions()` on `PermissionHandler` (line 819 of `permission_handler.py`) — the primitive exists but is not exposed as an HTTP route.

## Findings

- **Source**: agent-native-reviewer (P1, confidence: 93)
- **Location**:
  - Server: `computer/parachute/core/permission_handler.py:819` (`get_pending_questions()` exists)
  - Missing route: `computer/parachute/api/chat.py` (no GET for pending questions)
- **Evidence**: `get_pending_questions()` returns a list of pending questions with `request_id` and `questions`. No HTTP route calls it.

## Proposed Solutions

### Solution A: Add `GET /chat/{session_id}/pending-questions` route (Recommended)
```python
# In computer/parachute/api/chat.py
@router.get("/{session_id}/pending-questions")
async def get_pending_questions(
    session_id: str,
    orchestrator: Orchestrator = Depends(get_orchestrator),
):
    handler = orchestrator.get_permission_handler(session_id)
    if handler is None:
        return {"questions": []}
    return {"questions": handler.get_pending_questions()}
```
Response shape:
```json
{
  "questions": [
    {
      "request_id": "abc-123",
      "questions": [{"question": "...", "options": [...], "multiSelect": false}]
    }
  ]
}
```
- **Pros**: Enables full agent-native loop; Flutter app can restore `pendingUserQuestion` on reload by calling this endpoint; bot connectors can poll it
- **Cons**: Adds a new API route
- **Effort**: Small
- **Risk**: None

### Solution B: Embed pending questions in `GET /chat/{session_id}/status`
Add a `pending_questions` field to the existing session status endpoint.
- **Pros**: No new route; consolidated status
- **Cons**: Existing consumers must handle new field; more surface area change
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**:
  - `computer/parachute/api/chat.py` (new route)
  - `computer/parachute/core/permission_handler.py` (existing method, no changes needed)
  - `app/lib/features/chat/providers/chat_message_providers.dart` (could call endpoint in `loadSession` to restore `pendingUserQuestion`)

## Acceptance Criteria

- [ ] `GET /chat/{session_id}/pending-questions` returns list of pending questions with `request_id`
- [ ] Returns empty list (not 404) when no questions are pending or session has no handler
- [ ] Flutter `loadSession` can use this endpoint to restore `pendingUserQuestion` state after reload
- [ ] Bot connectors can poll this endpoint to discover and answer pending questions

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
- `permission_handler.py:819`: existing `get_pending_questions()` method
- Related todo: 154 (dismiss path removed)
