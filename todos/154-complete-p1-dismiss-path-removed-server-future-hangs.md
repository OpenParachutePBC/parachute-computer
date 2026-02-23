---
status: complete
priority: p1
issue_id: 109
tags: [code-review, flutter, bug, server, chat, ask-user-question]
dependencies: []
---

# Dismiss path removed — server `asyncio.Future` blocks for full 5-minute timeout

## Problem Statement

PR #109 removed the `onDismiss` callback from the floating `UserQuestionCard`. That callback called `answerQuestion({})` before `dismissPendingQuestion()`, which sent an empty-answer HTTP POST to `/chat/{session_id}/answer`. On the server, this resolved the blocking `asyncio.Future` in `permission_handler.py` immediately, allowing Claude's tool call to complete (as a timeout/dismissed case). The new `InlineUserQuestionCard` has no dismiss button. If the user navigates away, force-quits the app, or simply decides not to answer, the server's asyncio Future blocks for the full 300-second timeout before Claude can continue.

This is a regression from the explicit dismiss design introduced in commit `48b00ab` (Feb 15).

## Findings

- **Sources**: security-sentinel (P2, confidence: 88), agent-native-reviewer (P1, confidence: 91), git-history-analyzer (P1, high recurrence risk)
- **Location**:
  - Removed from `app/lib/features/chat/screens/chat_screen.dart` (PR #109 diff)
  - Server blocks at: `computer/parachute/core/permission_handler.py:784`
- **Evidence**:
  ```python
  # permission_handler.py line 784 — blocks here for up to 300 seconds
  answers = await asyncio.wait_for(
      future, timeout=self.question_timeout_seconds  # 300 seconds
  )
  ```
  The only unblock paths now are: (a) successful submit, or (b) server-side timeout after 5 minutes.

## Proposed Solutions

### Solution A: Add dismiss button to `InlineUserQuestionCard` header (Recommended)
Add a small close/dismiss button to the pending card's header row that calls `answerQuestion({})`:
```dart
// In _buildHeader(), add to the Row when _isInteractive:
if (_isInteractive)
  GestureDetector(
    onTap: () => ref.read(chatMessagesProvider.notifier).answerQuestion({}),
    child: Icon(Icons.close, size: 14, color: color),
  ),
```
- **Pros**: Restores the explicit dismiss UX; user has clear way to skip; server unblocked immediately
- **Cons**: Adds a button to the header
- **Effort**: Small
- **Risk**: None

### Solution B: Auto-unblock in `_resetTransientState()`
When `_resetTransientState()` fires while `pendingUserQuestion` is non-null, automatically send `answerQuestion({})` to unblock the server before clearing state.
```dart
void _resetTransientState() {
  // Unblock any hanging server future before clearing state
  if (state.pendingUserQuestion != null) {
    // Fire-and-forget to unblock server
    _service.answerQuestion(
      sessionId: state.pendingUserQuestion!['sessionId'] as String? ?? '',
      requestId: state.pendingUserQuestion!['requestId'] as String? ?? '',
      answers: {},
    );
  }
  // ... existing reset code
}
```
- **Pros**: Automatic — no UI change needed; works on session switch, app background, etc.
- **Cons**: Sends empty-answer even when not desired; may race if session is still active
- **Effort**: Small
- **Risk**: Low — fire-and-forget, server handles gracefully

### Solution C: Expose `POST /answer` with `{}` as documented dismiss API
Document that sending `{"answers": {}}` is the canonical dismiss path; ensure bot connectors and automated clients know about it.
- **Pros**: Makes programmatic dismiss explicit and discoverable
- **Cons**: Doesn't fix the human user case
- **Effort**: Small (docs only)
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**:
  - `app/lib/features/chat/widgets/inline_user_question_card.dart`
  - `computer/parachute/core/permission_handler.py` (server side — for reference)

## Acceptance Criteria

- [x] User can dismiss a pending question without submitting an answer
- [x] Dismissing sends `answerQuestion({})` to unblock the server Future
- [x] Server timeout path still works as fallback if dismiss is not used
- [ ] Bot connectors / programmatic clients have a documented way to skip a question

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Added `_dismissQuestion()` method and a "Skip" TextButton below the Submit button. Calls `answerQuestion({})` to unblock server Future immediately. | Bundled with todos 150, 151, 158, 165, 167, 170 in single commit. |

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
- Original dismiss design: commit `48b00ab` (Feb 15 2026)
- Related todo: 155 (missing GET /pending-questions endpoint)
