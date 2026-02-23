---
status: ready
priority: p1
issue_id: 109
tags: [code-review, flutter, performance, chat]
dependencies: []
---

# `_parsedQuestions` getter re-parses JSON on every build call

## Problem Statement

`_parsedQuestions` is a bare getter in `_InlineUserQuestionCardState` that calls `UserQuestion.fromJson` on every invocation. It is called during `build` (twice per rebuild — once for the question list spread and once via `_canSubmit`), on every keystroke via `onChanged: (_) => setState(() {})`, and in `_submitAnswers`. At typing speed (8–15 keystrokes/second), this causes 30–50 `fromJson` calls per second with 15–25 object allocations each.

## Findings

- **Sources**: flutter-reviewer (P1, confidence: 92), performance-oracle (P1, confidence: 92), pattern-recognition (P1, confidence: 92), code-simplicity-reviewer (P2, confidence: 88)
- **Location**: `app/lib/features/chat/widgets/inline_user_question_card.dart:52-53`
- **Evidence**:
  ```dart
  List<UserQuestion> get _parsedQuestions =>
      widget.data.questions.map((j) => UserQuestion.fromJson(j)).toList();
  ```
  Called at lines 36 (initState), 91 (_canSubmit), 108 (_submitAnswers), 159 (build loop). Every `onChanged` on the "Other" TextField triggers a rebuild → two redundant deserialization passes.

## Proposed Solutions

### Solution A: `late final` field parsed in `initState` (Recommended)
```dart
late final List<UserQuestion> _questions;

@override
void initState() {
  super.initState();
  _questions = widget.data.questions
      .map((j) => UserQuestion.fromJson(j))
      .toList();
  if (widget.data.status == UserQuestionStatus.pending) {
    for (final q in _questions) {
      _selectedAnswers[q.question] = {};
      _otherControllers[q.question] = TextEditingController();
      _otherSelected[q.question] = false;
    }
  }
}
```
Replace all `_parsedQuestions` usages with `_questions`. Add `didUpdateWidget` guard (see todo 151).
- **Pros**: Single parse, correct identity semantics, eliminates GC pressure
- **Cons**: None
- **Effort**: Small
- **Risk**: None

### Solution B: Cache in a `late List<UserQuestion>` with `didUpdateWidget` reset
Same as A but non-final, allowing `didUpdateWidget` to re-parse if `widget.data.questions` changes.
- **Pros**: Handles hypothetical data changes
- **Cons**: Questions never change once card is shown — late final is sufficient
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/widgets/inline_user_question_card.dart`

## Acceptance Criteria

- [ ] `UserQuestion.fromJson` is called at most once per widget instantiation
- [ ] Typing in the "Other" text field does not trigger JSON deserialization
- [ ] Submit path uses the same cached list as initState for controller key lookups

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
- Related todo: 151 (missing didUpdateWidget)
