---
status: ready
priority: p2
issue_id: 109
tags: [code-review, flutter, bug, chat, ask-user-question]
dependencies: [155]
---

# `pendingUserQuestion` null after page reload — `answerQuestion()` silently fails

## Problem Statement

`state.pendingUserQuestion` is set from the SSE `userQuestion` event but is never persisted and never restored by `loadSession`. After a session reload, `pendingUserQuestion` is null even though `_determineQuestionStatus` returns `UserQuestionStatus.pending` from the transcript (card looks interactive). When the user taps Submit on the inline card, `answerQuestion()` reads `state.pendingUserQuestion`, finds null, logs "No pending user question to answer", and returns `false`. The card shows "Failed to submit — tap to retry." with no recovery path.

This is the most likely cause of user-visible submit failures in practice.

## Findings

- **Sources**: architecture-strategist (P2, confidence: 85), git-history-analyzer (P2, moderate recurrence risk)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart:1854-1866` (`answerQuestion`), `loadSession` (~line 486)
- **Evidence**:
  ```dart
  // loadSession — never restores pendingUserQuestion
  state = ChatMessagesState(
    messages: loadedMessages,
    sessionId: sessionId,
    // ... no pendingUserQuestion
  );
  ```

## Proposed Solutions

### Solution A: Call `GET /pending-questions` during `loadSession` (Recommended — depends on todo 155)
After loading messages, call the new pending-questions endpoint and restore `pendingUserQuestion` if the question is still live on the server:
```dart
final pending = await _service.getPendingQuestions(sessionId);
if (pending != null) {
  state = state.copyWith(pendingUserQuestion: pending);
}
```
- **Pros**: Correct and complete; works after any reload; enables inline card to be answerable
- **Cons**: Requires new API endpoint (todo 155)
- **Effort**: Small (once endpoint exists)
- **Risk**: None

### Solution B: Embed `requestId` in `UserQuestionData` and pass it through the card
Move `requestId` and `sessionId` into `UserQuestionData` (available at time of `userQuestion` event). Update `answerQuestion()` to accept them directly rather than reading from `pendingUserQuestion` state:
```dart
Future<bool> answerQuestion(Map<String, dynamic> answers, {
  required String requestId,
  required String sessionId,
}) async { ... }
```
The inline card passes the values it already has. Eliminates the hidden state dependency entirely.
- **Pros**: No server changes needed; eliminates global state dependency
- **Cons**: `UserQuestionData` model change; `session_transcript.dart` would need to store requestId in the model (not currently available in JSONL)
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**:
  - `app/lib/features/chat/providers/chat_message_providers.dart`
  - `app/lib/features/chat/models/chat_message.dart` (if embedding requestId)
  - `app/lib/features/chat/services/chat_session_service.dart`

## Acceptance Criteria

- [ ] After session reload, submitting an answer from the inline card succeeds (returns true)
- [ ] The card transitions to "Answered" state after successful submit post-reload
- [ ] No "Failed to submit — tap to retry" error when question is still live on server

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
- Related todo: 155 (pending-questions API endpoint)
