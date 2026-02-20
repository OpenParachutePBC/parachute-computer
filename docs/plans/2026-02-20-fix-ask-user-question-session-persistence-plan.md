---
title: "Fix: AskUserQuestion lost when switching sessions"
type: fix
date: 2026-02-20
issue: 70
---

# Fix: AskUserQuestion Lost When Switching Sessions

## Overview

When Claude asks a question via `AskUserQuestion` during chat, the question UI disappears if the user switches to a different session and returns. The user sees only raw JSON tool call data in the transcript — the interactive `UserQuestionCard` is gone.

**Root cause:** Question state lives only in `ChatMessagesState.pendingUserQuestion` (runtime-only). Session switches create a fresh `ChatMessagesState`, discarding the pending question. There is no persistence layer.

## Problem Statement

```
Agent calls AskUserQuestion → UserQuestionCard appears
  → User switches session → prepareForSessionSwitch() resets state
  → User returns → loadSession() loads transcript
  → Transcript parser sees tool_use block, renders generic ToolCall card
  → Question UI is gone ❌
```

The question data IS in the SDK transcript (as a `tool_use` block with `name: "AskUserQuestion"`), but the transcript parser (`session_transcript.dart:171-186`) treats all tool_use blocks identically — it doesn't know to render AskUserQuestion as an interactive question card.

## Proposed Solution

**Teach the transcript parser to recognize `AskUserQuestion` tool_use blocks and render them as question cards instead of generic tool calls.** This is purely a frontend fix — no backend changes required.

The SDK transcript already contains everything we need:
- `tool_use` block with `name: "AskUserQuestion"` and `input.questions` array
- `tool_result` block with the user's answers (if answered) or `{}` (if timed out)

### Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| New ContentType? | Yes — `ContentType.userQuestion` | Renders differently from generic tool calls |
| Replace or coexist with tool_use? | **Replace** — AskUserQuestion tool_use → userQuestion | Avoids duplicate cards for same event |
| New data class? | Yes — `UserQuestionData` | Holds questions, answers, status |
| Backend changes? | **None** | Transcript already has the data |
| Floating card + inline card? | **Both** — floating for pending, inline for history | Best UX: immediate interaction + persistent history |
| Bot connectors? | **Defer** — follow-up issue | Current timeout behavior is acceptable for now |
| Session list indicator? | **Defer** — follow-up issue | Not required for core fix |

## Technical Approach

### Phase 1: Data Model (`chat_message.dart`)

Add `userQuestion` to `ContentType` enum and create `UserQuestionData` class.

**`chat_message.dart`** — Add enum value and data class:

```dart
// chat_message.dart:5
enum ContentType { text, toolUse, thinking, warning, userQuestion }

// New class alongside ToolCall
class UserQuestionData {
  final String requestId;
  final String toolUseId;
  final List<Map<String, dynamic>> questions;
  final Map<String, dynamic>? answers;  // null = pending, {} = timeout, {...} = answered
  final UserQuestionStatus status;

  const UserQuestionData({
    required this.requestId,
    required this.toolUseId,
    required this.questions,
    this.answers,
    this.status = UserQuestionStatus.pending,
  });
}

enum UserQuestionStatus { pending, answered, dismissed, timeout }
```

**`MessageContent`** — Add `userQuestionData` field and factory:

```dart
// chat_message.dart:89-115
class MessageContent {
  final ContentType type;
  final String? text;
  final ToolCall? toolCall;
  final UserQuestionData? userQuestionData;  // NEW

  factory MessageContent.userQuestion(UserQuestionData data) {
    return MessageContent(type: ContentType.userQuestion, userQuestionData: data);
  }
}
```

### Phase 2: Transcript Parser (`session_transcript.dart`)

Modify `toMessages()` to detect `AskUserQuestion` tool_use blocks and create `ContentType.userQuestion` instead of `ContentType.toolUse`. Also look ahead for matching `tool_result` to determine answered status.

**`session_transcript.dart:171-186`** — Replace generic tool_use handling for AskUserQuestion:

```dart
} else if (blockType == 'tool_use') {
  // Convert preceding text to thinking (existing logic, lines 172-181)
  ...

  final toolName = block['name'] as String? ?? '';
  final toolId = block['id'] as String? ?? '';

  if (toolName == 'AskUserQuestion') {
    // Extract question data from tool input
    final input = block['input'] as Map<String, dynamic>? ?? {};
    final questions = (input['questions'] as List?)
        ?.cast<Map<String, dynamic>>() ?? [];

    // Look for matching tool_result in subsequent events to get answers
    final answers = _findToolResult(toolId);
    final status = _determineQuestionStatus(answers);

    pendingAssistantContent.add(MessageContent.userQuestion(
      UserQuestionData(
        requestId: '', // Will be populated from SSE or reconstructed
        toolUseId: toolId,
        questions: questions,
        answers: answers,
        status: status,
      ),
    ));
  } else {
    // Existing tool_use handling (lines 182-186)
    pendingAssistantContent.add(MessageContent.toolUse(ToolCall(
      id: toolId,
      name: toolName,
      input: block['input'] as Map<String, dynamic>? ?? {},
    )));
  }
}
```

Add helper method to find tool_result for a given tool_use ID:

```dart
/// Find tool_result matching a tool_use ID in subsequent events
Map<String, dynamic>? _findToolResult(String toolUseId) {
  // Search events for user event containing tool_result with matching id
  for (final event in events) {
    if (event.type != 'user') continue;
    final content = event.message?['content'];
    if (content is! List) continue;
    for (final block in content) {
      if (block is! Map) continue;
      if (block['type'] == 'tool_result' && block['tool_use_id'] == toolUseId) {
        // Extract answers from the tool_result content
        return _parseAnswersFromToolResult(block);
      }
    }
  }
  return null; // No result found = still pending
}
```

Status determination logic:

```dart
UserQuestionStatus _determineQuestionStatus(Map<String, dynamic>? answers) {
  if (answers == null) return UserQuestionStatus.pending;
  if (answers.isEmpty) return UserQuestionStatus.timeout;
  return UserQuestionStatus.answered;
}
```

### Phase 3: Message Bubble Rendering (`message_bubble.dart`)

Add rendering for `ContentType.userQuestion` in the message bubble widget.

**`message_bubble.dart:141`** — Add case for userQuestion:

```dart
} else if (content.type == ContentType.userQuestion) {
  // Render inline question card (read-only for answered, interactive for pending)
  final data = content.userQuestionData!;
  widgets.add(InlineUserQuestionCard(
    questions: data.questions,
    answers: data.answers,
    status: data.status,
    onAnswer: data.status == UserQuestionStatus.pending
        ? (answers) => _handleQuestionAnswer(answers, data)
        : null,
  ));
}
```

### Phase 4: UserQuestionCard Read-Only Mode (`user_question_card.dart`)

Extend `UserQuestionCard` to support a read-only "answered" display:

- **Pending**: Full interactive card (current behavior)
- **Answered**: Collapsed card showing question + selected answer, expandable
- **Timeout**: Card with "Timed out" badge, shows question but no answers, non-interactive
- **Dismissed**: Card with "Dismissed" badge, similar to timeout

```dart
// user_question_card.dart — new constructor parameter
class UserQuestionCard extends StatefulWidget {
  final List<Map<String, dynamic>> questions;
  final Map<String, dynamic>? answers;
  final UserQuestionStatus status;
  final void Function(Map<String, dynamic>)? onAnswer;
  final VoidCallback? onDismiss;

  // status == pending → full interactive card (existing behavior)
  // status == answered → read-only with answer highlighted
  // status == timeout → read-only with timeout badge
}
```

### Phase 5: Reattach Stream Fix (`chat_message_providers.dart`)

Fix the reattach path that currently ignores `userQuestion` events.

**`chat_message_providers.dart:866-873`** — Handle userQuestion in reattach:

```dart
case StreamEventType.userQuestion:
  // Restore pendingUserQuestion when reattaching to background stream
  state = state.copyWith(
    pendingUserQuestion: {
      'requestId': event.questionRequestId,
      'sessionId': event.sessionId,
      'questions': event.questions,
    },
  );
  break;
```

### Phase 6: Graceful Timeout Handling (`chat_message_providers.dart`)

Update `answerQuestion()` to handle the case where the backend has already timed out (404 response).

**`chat_message_providers.dart:1850-1869`** — Add 404 handling:

```dart
try {
  final success = await _service.answerQuestion(
    sessionId: sessionId,
    requestId: requestId,
    answers: answers,
  );

  if (success) {
    state = state.copyWith(clearPendingUserQuestion: true);
    // Update inline card status to answered
    _updateQuestionStatus(requestId, UserQuestionStatus.answered, answers);
  } else {
    debugPrint('[ChatMessagesNotifier] Failed to submit answer');
  }

  return success;
} on NotFoundException {
  // Backend already timed out — mark as expired in UI
  state = state.copyWith(clearPendingUserQuestion: true);
  _updateQuestionStatus(requestId, UserQuestionStatus.timeout, null);
  return false;
} catch (e) {
  debugPrint('[ChatMessagesNotifier] Error answering question: $e');
  return false;
}
```

## Files to Modify

| File | Changes |
|------|---------|
| `app/lib/features/chat/models/chat_message.dart` | Add `ContentType.userQuestion`, `UserQuestionData` class, `UserQuestionStatus` enum, `MessageContent.userQuestion()` factory |
| `app/lib/features/chat/models/session_transcript.dart` | Detect AskUserQuestion in `toMessages()`, look up tool_result for answers |
| `app/lib/features/chat/widgets/message_bubble.dart` | Render `ContentType.userQuestion` as inline question card |
| `app/lib/features/chat/widgets/user_question_card.dart` | Add read-only mode (answered/timeout/dismissed states) |
| `app/lib/features/chat/providers/chat_message_providers.dart` | Fix reattach path (line 868), add 404 handling in `answerQuestion()` |
| `app/lib/features/chat/screens/chat_screen.dart` | Keep floating card for pending questions (existing), inline cards render in message bubble |

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Session switch with pending question | Question persists in transcript → inline card on return |
| App restart with pending question | If backend still waiting (< 5 min), answerable. If timed out, shows "Expired" |
| Answer after backend timeout | POST returns 404 → card transitions to "Expired" gracefully |
| Multiple sequential questions | Each renders as separate inline card in the message |
| Concurrent sessions with questions | Each session's questions are in their own transcript |
| Old session replay | Answered questions show as read-only cards with selected answers |
| Reattach to background stream | Fixed — `userQuestion` event now populates `pendingUserQuestion` |

## Out of Scope (Follow-up Issues)

- **Bot connector question handling** — Telegram/Discord have no UI for questions; currently timeout silently
- **Session list "pending question" indicator** — Useful but requires backend API changes
- **Edit previous answer** — Would need backend to rewind agent execution
- **`fromJson`/`toJson` serialization** — Only needed if JSON round-trips are used for questions (currently not)

## Acceptance Criteria

- [x] User switches sessions → question remains visible on return as inline card
- [x] Answered questions appear in chat history with selected answers highlighted
- [x] Timed-out questions show "Expired" badge, non-interactive
- [x] Reattach to background stream restores pending question
- [x] Answering after backend timeout shows graceful "Expired" message
- [x] No backend changes required
- [x] No duplicate cards (AskUserQuestion tool_use replaced by userQuestion, not both)

## References

- Current question handling: `chat_message_providers.dart:1666-1677` (SSE handler)
- Transcript parser: `session_transcript.dart:171-186` (tool_use handling)
- Question card widget: `user_question_card.dart:52-408`
- Backend permission handler: `permission_handler.py:730-801`
- Backend event emission: `orchestrator.py:1091-1109`
