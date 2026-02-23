---
status: complete
priority: p3
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# `_extractCommandDisplay` belongs in a display formatter, not the model layer

## Problem Statement

`SessionTranscript` is a data model whose responsibility is converting SDK JSONL events into `ChatMessage` objects. `_extractCommandDisplay` is presentation-layer formatting: it strips non-user-visible content that is an artifact of the Claude Code CLI skill injection format (`<command-name>` / `<command-args>` XML tags). This is not a data concern — it is a display concern. As the CLI skill system evolves, this parsing logic will need to track format changes, creating coupling between the CLI's internal prompt format and the model layer.

```dart
// session_transcript.dart:254 — model class handling display formatting
if (humanText.contains('<command-name>')) {
  humanText = _extractCommandDisplay(humanText);
}

static String _extractCommandDisplay(String text) {
  // strips CLI skill injection XML tags — a display/presentation concern
}
```

## Findings

- **Source**: architecture-strategist (P3, confidence: 80)
- **Location**: `app/lib/features/chat/models/session_transcript.dart:119-121, 254-273`

## Proposed Solutions

### Solution A: Extract to a `ChatDisplayFormatter` utility (Recommended)

```dart
// lib/features/chat/formatters/chat_display_formatter.dart
class ChatDisplayFormatter {
  static String formatHumanMessage(String text) {
    if (text.trimLeft().startsWith('<command-name>')) {
      return _extractCommandDisplay(text);
    }
    return text;
  }

  static String _extractCommandDisplay(String text) { ... }
}
```

Call `ChatDisplayFormatter.formatHumanMessage(humanText)` from `SessionTranscript.toMessages()` where display text is prepared.
- **Pros**: Model class stays responsible for structure; display logic is centralized; easy to add future transformations
- **Cons**: New file to maintain; minor indirection
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/models/session_transcript.dart`

## Acceptance Criteria

- [x] `SessionTranscript` contains no display-formatting logic
- [x] CLI skill tag stripping is located in a display/formatter layer

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created `app/lib/features/chat/formatters/chat_display_formatter.dart` with `ChatDisplayFormatter.extractCommandDisplay`. Removed `_extractCommandDisplay` from `SessionTranscript`. Call site in `toMessages()` updated to use the new static method. Resolved alongside todo 163 (startsWith fix). | Kept the gate condition in `session_transcript.dart` (startsWith check) rather than moving it into the formatter, so the model still controls whether to apply formatting — the formatter only performs the transformation. |

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
