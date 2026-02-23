---
status: ready
priority: p3
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# `_isInteractive` getter omits `_isSubmitting` — incomplete abstraction

## Problem Statement

`_isInteractive` is intended to express "the card is in an interactive state." However it omits `_isSubmitting`, so every call site must additionally check `_isSubmitting` separately:
```dart
// Current getter
bool get _isInteractive =>
    widget.data.status == UserQuestionStatus.pending && !_submitted;

// Callers still need to check _isSubmitting manually:
void _toggleOption(...) {
  if (!_isInteractive || _isSubmitting) return;  // two guards
```
The abstraction is incomplete — `_isInteractive` does not fully encapsulate the "can interact" concept.

## Findings

- **Source**: pattern-recognition-specialist (P3, confidence: 82)
- **Location**: `app/lib/features/chat/widgets/inline_user_question_card.dart:57-58, 61, 79, 90`

## Proposed Solutions

### Solution A: Include `_isSubmitting` in the getter (Recommended)
```dart
bool get _isInteractive =>
    widget.data.status == UserQuestionStatus.pending &&
    !_submitted &&
    !_isSubmitting;
```
Then simplify call sites from `!_isInteractive || _isSubmitting` to just `!_isInteractive`.
- **Effort**: Trivial
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/widgets/inline_user_question_card.dart`

## Acceptance Criteria

- [ ] `_isInteractive` fully encapsulates the "card can accept input" state
- [ ] No call site needs to check `_isSubmitting` separately alongside `_isInteractive`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
