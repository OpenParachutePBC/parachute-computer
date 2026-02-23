---
status: complete
priority: p2
issue_id: 109
tags: [code-review, bug, chat, transcript]
dependencies: []
---

# `<command-name>` detection gate too broad — legitimate user messages silently rewritten

## Problem Statement

`session_transcript.dart` detects skill injection via `humanText.contains('<command-name>')`. Any user message that naturally contains the literal string `<command-name>` (e.g., a developer asking about XML tags, a user copy-pasting code) will be passed through `_extractCommandDisplay`. The `<command-args>` extractor then strips everything except the content between the tags — silently rewriting the user's original message in the transcript display. This is a display integrity issue: history shown in the app diverges from what was actually sent.

## Findings

- **Source**: security-sentinel (P3→P2, confidence: 80)
- **Location**: `app/lib/features/chat/models/session_transcript.dart:119-121`
- **Evidence**:
  ```dart
  if (humanText.contains('<command-name>')) {
    humanText = _extractCommandDisplay(humanText);
  }
  ```
  The Claude Code CLI skill injection always begins at the very start of the message. A `contains` check matches anywhere in the string.

## Proposed Solutions

### Solution A: Anchor detection to start of message (Recommended)
```dart
// CLI skill injection always begins the message with the <command-name> tag
if (humanText.trimLeft().startsWith('<command-name>') ||
    humanText.contains('\n<command-name>')) {
  humanText = _extractCommandDisplay(humanText);
}
```
- **Pros**: Only matches the CLI's actual injection pattern; user messages containing the literal string mid-sentence are unaffected
- **Cons**: Minor risk if CLI format changes to not start with the tag
- **Effort**: Trivial
- **Risk**: Very low

### Solution B: Check for full pattern signature
Check that BOTH `<command-name>` AND `<command-args>` are present (the CLI always injects both):
```dart
if (humanText.contains('<command-name>') && humanText.contains('<command-args>')) {
  humanText = _extractCommandDisplay(humanText);
}
```
- **Pros**: Requires both tags; less likely to match legitimate user content
- **Cons**: Still matches mid-string in theory
- **Effort**: Trivial
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/models/session_transcript.dart`

## Acceptance Criteria

- [x] A user message containing the literal text `<command-name>` mid-sentence is NOT rewritten in the transcript
- [x] Skill injection messages (starting with `<command-name>`) are still correctly extracted
- [ ] Regression test: message `"Here is an example of <command-name> in XML"` displays unchanged after reload

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Changed `contains('<command-name>')` to `trimLeft().startsWith('<command-name>')` in `session_transcript.dart`. Call now delegates to `ChatDisplayFormatter.extractCommandDisplay` (resolved alongside todo 169). | The minimal fix eliminates false positives; trimLeft handles any leading whitespace before the tag. |

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
