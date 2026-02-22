---
status: pending
priority: p3
issue_id: 67
tags: [code-review, flutter, consistency]
dependencies: []
---

# textContent Doesn't Include Warnings (Asymmetry with _getFullText)

## Problem Statement

`ChatMessage.textContent` filters on `ContentType.text` only. `_getFullText()` in `message_bubble.dart` was updated to include `ContentType.warning`. This means the copy button includes warning text but `textContent` — used for previews and deduplication — does not. A warning-only message will have `textContent == ''`.

## Findings

- **Source**: pattern-recognition-specialist (confidence 82)
- **Location**: `app/lib/features/chat/models/chat_message.dart` (`textContent` getter) vs `app/lib/features/chat/widgets/message_bubble.dart` (`_getFullText`)
- **Evidence**: `textContent` filters `content.where((c) => c.type == ContentType.text)`. Copy action filters `ContentType.text || ContentType.warning`.

## Proposed Solutions

### Solution A: Include warning in textContent
Add `|| c.type == ContentType.warning` to the textContent getter.
- **Pros**: Consistent behavior, previews include warnings
- **Cons**: Could affect deduplication logic
- **Effort**: Small (1 line)
- **Risk**: Low — verify dedup logic handles it

## Recommended Action
<!-- Filled during triage -->

## Technical Details

**Affected files:**
- `app/lib/features/chat/models/chat_message.dart`

## Acceptance Criteria

- [ ] `textContent` and `_getFullText` produce consistent results regarding warnings

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #67 review | New content types need to be considered in all text-extraction paths |

## Resources

- PR: #67
- Issue: #49
