---
status: complete
priority: p1
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# `UserQuestionCard` widget class is dead code — zero callers

## Problem Statement

`UserQuestionCard` (the full-screen floating modal card) has zero callers in the codebase. PR #109 removed the only usage in `chat_screen.dart`. The file `user_question_card.dart` still contained the `UserQuestionCard` and `_UserQuestionCardState` classes (~360 LOC), but they were never instantiated. Keeping dead interactive widgets with state, animation controllers, and form controllers creates hidden maintenance burden: they accumulate undetected breakage as the API around them changes, and they inflate the `app/` binary.

The `UserQuestion` and `QuestionOption` model classes in the same file ARE used by `inline_user_question_card.dart` and must be retained.

## Findings

- **Source**: code-simplicity-reviewer (P1, confidence: 90)
- **Location**: `app/lib/features/chat/widgets/user_question_card.dart:48-408`
- **Evidence**: `grep -r "UserQuestionCard(" app/lib/` returns zero results. `inline_user_question_card.dart` imports the file only for `UserQuestion` and `QuestionOption` (line 6).

## Proposed Solutions

### Solution A: Delete `UserQuestionCard` and `_UserQuestionCardState`, retain model classes (Recommended)
Remove lines 48–408 from `user_question_card.dart`. Keep:
- `UserQuestion` class (lines 4–28)
- `QuestionOption` class (lines 31–46)

The file becomes a pure data model file. Consider renaming it to `user_question_models.dart` to reflect its actual purpose.
- **Pros**: ~360 LOC removed; no more stale widget to maintain; file name can be clarified
- **Cons**: None
- **Effort**: Small
- **Risk**: None (confirmed zero callers)

### Solution B: Delete the entire file and inline models into `inline_user_question_card.dart`
Move `UserQuestion` and `QuestionOption` into the inline card file, delete `user_question_card.dart` entirely.
- **Pros**: One fewer file
- **Cons**: Model classes not accessible if a future widget needs them separately
- **Effort**: Small
- **Risk**: Low

## Recommended Action

Implemented Solution A.

## Technical Details

- **Affected files**: `app/lib/features/chat/widgets/user_question_card.dart`

## Acceptance Criteria

- [x] `flutter analyze` reports no errors after deletion
- [x] `grep -r "UserQuestionCard(" app/lib/` returns zero results (already true, just verifying no new callers exist)
- [x] `UserQuestion.fromJson` and `QuestionOption.fromJson` remain accessible to `inline_user_question_card.dart`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Deleted `UserQuestionCard` and `_UserQuestionCardState` (~364 LOC), removed unused `package:flutter/material.dart` import. Retained `UserQuestion` and `QuestionOption` model classes. | Zero callers confirmed before and after deletion. |

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
