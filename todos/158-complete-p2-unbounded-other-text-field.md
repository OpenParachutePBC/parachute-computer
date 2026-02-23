---
status: complete
priority: p2
issue_id: 109
tags: [code-review, security, chat, ask-user-question]
dependencies: []
---

# Unbounded "Other" text field — free-form input flows directly to Claude with no length limit

## Problem Statement

The "Other" `TextField` in `InlineUserQuestionCard` has `maxLines: null` and no `maxLength` constraint. The value is submitted without length validation in `_submitAnswers()` and sent to `/chat/{session_id}/answer`. On the server, the `answers` dict flows directly into `future.set_result(answers)`, which returns it to Claude as a tool result. Sending very large text can exhaust Claude's context window (hard API error, hanging session) or produce an HTTP 413. There is no validation on the server's `/answer` endpoint either.

## Findings

- **Source**: security-sentinel (P2, confidence: 83)
- **Location**:
  - `app/lib/features/chat/widgets/inline_user_question_card.dart:332-348` (TextField)
  - `computer/parachute/api/chat.py:218-232` (no validation of answers dict)

## Proposed Solutions

### Solution A: Add `maxLength` to TextField + client-side guard (Recommended)
```dart
TextField(
  controller: _otherControllers[question.question],
  maxLength: 500,
  inputFormatters: [LengthLimitingTextInputFormatter(500)],
  // ... existing props
)
```
And in `_submitAnswers()` before adding to answers:
```dart
if (otherText.length > 500) {
  setState(() { _errorMessage = 'Answer too long (max 500 characters).'; });
  return;
}
```
- **Pros**: Simple, user-visible limit, prevents accidental large pastes
- **Cons**: Adds a character counter UI element (can be hidden with `counterText: ''`)
- **Effort**: Trivial
- **Risk**: None

### Solution B: Add server-side validation in `/answer` endpoint
```python
for val in answers.values():
    if isinstance(val, str) and len(val) > 2000:
        raise HTTPException(status_code=400, detail="Answer value too long")
```
- **Pros**: Defense in depth; protects all answer paths (not just inline card)
- **Cons**: Requires server change
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**:
  - `app/lib/features/chat/widgets/inline_user_question_card.dart`
  - `computer/parachute/api/chat.py` (optional server-side guard)

## Acceptance Criteria

- [x] "Other" text field has a visible or enforced character limit (500 recommended)
- [x] Attempting to submit an oversized answer shows an error message, does not send
- [x] Normal answers (≤500 chars) still submit correctly

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Changed `maxLines: null` to `maxLines: 3`, added `maxLength: 500` and `maxLengthEnforcement: MaxLengthEnforcement.enforced`. Added `import 'package:flutter/services.dart'`. | Bundled with todos 150, 151, 154, 165, 167, 170 in single commit. |

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
