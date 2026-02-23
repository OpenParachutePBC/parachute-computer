---
status: complete
priority: p2
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# `pendingUserQuestion` is an untyped `Map<String, dynamic>` — runtime cast risk

## Problem Statement

`ChatMessagesState.pendingUserQuestion` is typed as `Map<String, dynamic>?`. The `answerQuestion()` method casts its values at runtime:

```dart
final sessionId = pending['sessionId'] as String?;
final requestId = pending['requestId'] as String?;
```

If a key is missing or the value is not a `String`, this silently returns `null` and the answer call fails with no type error. Additionally, `InlineUserQuestionCard` submits answers by calling `answerQuestion()` — which reads from this untyped map — rather than using the `UserQuestionData` it already holds (which contains `toolUseId`, `questions`). The card widget holds half the data needed and the notifier holds the other half (`requestId`/`sessionId`), creating inappropriate intimacy across the widget-notifier boundary.

## Findings

- **Source**: flutter-reviewer + architecture-strategist (P2, confidence: 88)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart:110, 1854-1866`
- **Evidence**:
  ```dart
  // State field — raw dynamic map
  final Map<String, dynamic>? pendingUserQuestion;

  // Read site — runtime cast
  final sessionId = pending['sessionId'] as String?;
  final requestId = pending['requestId'] as String?;
  ```

## Proposed Solutions

### Solution A: Introduce a typed `PendingUserQuestion` model (Recommended)

```dart
class PendingUserQuestion {
  final String requestId;
  final String sessionId;
  final List<Map<String, dynamic>> questions;

  const PendingUserQuestion({
    required this.requestId,
    required this.sessionId,
    required this.questions,
  });
}
```

Replace `Map<String, dynamic>? pendingUserQuestion` with `PendingUserQuestion? pendingUserQuestion` on `ChatMessagesState`. Update construction sites (both `userQuestion` event handlers) and the `answerQuestion()` read site.
- **Pros**: Eliminates runtime casts; intent is explicit; compiler catches missing fields
- **Cons**: New model class to maintain
- **Effort**: Small
- **Risk**: None

### Solution B: Move `requestId`/`sessionId` into `UserQuestionData`

Extend `UserQuestionData` with `requestId` and `sessionId` fields. Pass them from the SSE event at the time the inline card is created. `answerQuestion()` then accepts them as parameters from the card rather than reading from global state.
- **Pros**: Eliminates the `pendingUserQuestion` field entirely; card is self-contained
- **Cons**: More invasive refactor touching model, provider, and card
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria

- [ ] No `as String?` cast on `pendingUserQuestion` map values in `answerQuestion()`
- [ ] Compiler will catch missing or renamed fields in `pendingUserQuestion`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
