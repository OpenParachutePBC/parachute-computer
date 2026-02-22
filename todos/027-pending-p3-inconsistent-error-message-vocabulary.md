---
status: pending
priority: p3
issue_id: 50
tags: [code-review, flutter, ux, consistency]
dependencies: []
---

# Inconsistent Error Message Vocabulary Across Features

## Problem Statement

PR #65 introduces error messages across three features with inconsistent vocabulary: "Failed to..." (journal), "Usage unavailable" (chat), "Live transcription unavailable" (recorder). While contextually appropriate, the lack of a shared vocabulary convention may become a problem as more error messages are added.

## Findings

- **Source**: pattern-recognition-specialist (82)
- **Location**: Multiple files across journal, chat, and recorder features
- **Evidence**: Journal uses imperative failure ("Failed to add entry"), chat uses state description ("Usage unavailable"), recorder uses capability description ("Live transcription unavailable"). Each is appropriate for its context but there's no shared style guide.

## Proposed Solutions

### Solution A: Accept current vocabulary — context-appropriate
Different error types warrant different message styles. CRUD failures naturally use "Failed to...", missing data uses "...unavailable".
- **Pros**: Messages are contextually clear, no change needed
- **Cons**: No formal convention
- **Effort**: None
- **Risk**: Low

### Solution B: Create error message style guide
Document conventions for error messages (action failures vs state descriptions vs capability descriptions).
- **Pros**: Future consistency
- **Cons**: Over-engineering for current scale
- **Effort**: Small
- **Risk**: Low

## Technical Details

- **Affected files**: `journal_screen.dart`, `usage_bar.dart`, `streaming_transcription_display.dart`

## Acceptance Criteria

- [ ] Decision made: accept or establish convention

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #65 review | Contextual diversity, not true inconsistency |

## Resources

- PR: #65
- Issue: #50
