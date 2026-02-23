---
status: ready
priority: p1
issue_id: 109
tags: [code-review, flutter, bug, chat]
dependencies: []
---

# `InlineUserQuestionCard` missing `didUpdateWidget` — stale state when data changes

## Problem Statement

`_InlineUserQuestionCardState` has no `didUpdateWidget` override. The widget is embedded inside `MessageBubble` which uses `AutomaticKeepAliveClientMixin` (`wantKeepAlive: true`), meaning Flutter re-uses the same `State` instance when the parent `ChatMessage` is updated. When `widget.data.status` changes from `pending` to `answered` or `timeout` (e.g., after the stream ends and the session reloads), state fields `_submitted`, `_isSubmitting`, `_errorMessage`, and the controller map remain frozen at their pre-update values. The border colour and header icon may diverge: if `_submitted = true` but the stream delivers `status = timeout`, the border shows green (forest/answered) while the header says "Expired" (orange).

## Findings

- **Source**: flutter-reviewer (P1, confidence: 88)
- **Location**: `app/lib/features/chat/widgets/inline_user_question_card.dart` — missing `didUpdateWidget`
- **Evidence**: No `didUpdateWidget` override exists. Widget uses `AutomaticKeepAliveClientMixin` via its parent, so the same State instance is reused across data changes.

## Proposed Solutions

### Solution A: Reset interaction state in `didUpdateWidget` (Recommended)
```dart
@override
void didUpdateWidget(InlineUserQuestionCard oldWidget) {
  super.didUpdateWidget(oldWidget);
  // Reset local interaction state when the question status is resolved
  if (oldWidget.data.status == UserQuestionStatus.pending &&
      widget.data.status != UserQuestionStatus.pending) {
    setState(() {
      _submitted = false;
      _isSubmitting = false;
      _errorMessage = null;
    });
  }
}
```
- **Pros**: Keeps border/header visually consistent when status transitions; no stale optimistic state
- **Cons**: None
- **Effort**: Small
- **Risk**: None

### Solution B: Derive all visual state from `widget.data.status` alone
Remove `_submitted` entirely and rely on the provider's status field. Requires the provider to update `UserQuestionData.status` immediately when `answerQuestion` succeeds (currently it doesn't update until stream reload).
- **Pros**: Single source of truth
- **Cons**: Requires provider-side changes; latency between submit and status flip would show spinner until reload
- **Effort**: Medium
- **Risk**: Medium — needs provider changes

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/widgets/inline_user_question_card.dart`

## Acceptance Criteria

- [ ] After `answerQuestion()` succeeds and provider delivers `status = answered`, the card header shows "Answered" with green border
- [ ] After server timeout delivers `status = timeout`, the card shows "Expired" with orange border regardless of local `_submitted` state
- [ ] No visual divergence between local `_submitted` flag and the delivered `UserQuestionStatus`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
- Related todo: 150 (_parsedQuestions getter)
