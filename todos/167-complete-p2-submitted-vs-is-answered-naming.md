---
status: complete
priority: p2
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# `_submitted` naming in `InlineUserQuestionCard` conflicts with `_isAnswered` convention

## Problem Statement

`UserQuestionCard` (the predecessor widget) uses `_isAnswered` for the local optimistic submission flag throughout — in guards (`if (_isAnswered || _isSubmitting) return`), in `build` (`if (_isAnswered) ...`), and exposed as a constructor parameter `bool isAnswered`. The new `InlineUserQuestionCard` introduced in this PR uses `_submitted` for the same semantic concept:

```dart
// user_question_card.dart — established convention
bool _isAnswered = false;

// inline_user_question_card.dart — new, divergent name
bool _submitted = false; // locally submitted — waiting for stream to confirm
```

Both flags mean "the user has committed an answer locally before the server stream confirms it." The inconsistency creates a vocabulary split between two co-existing widgets sharing the same `UserQuestionStatus` enum.

## Findings

- **Source**: pattern-recognition-specialist (P2, confidence: 88)
- **Location**: `app/lib/features/chat/widgets/inline_user_question_card.dart:29`

## Proposed Solutions

### Solution A: Rename `_submitted` to `_isAnswered` (Recommended)

```dart
bool _isAnswered = false;
```

Update all references: `_isInteractive`, `_borderColor`, `_buildHeader`, `_submitAnswers`. This matches `UserQuestionCard`'s naming and the `UserQuestionStatus.answered` enum case.
- **Effort**: Trivial (find/replace within one file)
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/widgets/inline_user_question_card.dart`

## Acceptance Criteria

- [x] `InlineUserQuestionCard` uses `_isAnswered` (not `_submitted`) for the local optimistic submission flag
- [x] Name matches `UserQuestionCard` convention

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Renamed `_submitted` → `_isAnswered` everywhere in the file using replace_all. | Bundled with todos 150, 151, 154, 158, 165, 170 in single commit. |

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
