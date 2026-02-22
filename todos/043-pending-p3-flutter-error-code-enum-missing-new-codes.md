---
status: pending
priority: p3
issue_id: 67
tags: [code-review, flutter, agent-native]
dependencies: []
---

# Flutter ErrorCode Enum Missing New Server Codes

## Problem Statement

Server added `mcp_load_failed` and `attachment_save_failed` to `ErrorCode`. The Flutter enum in `typed_error.dart` has no corresponding entries. `fromString` silently falls back to `unknownError`. Not a functional bug (warnings don't use the Flutter ErrorCode enum), but a parity gap if typed errors with these codes are ever sent.

## Findings

- **Source**: agent-native-reviewer (confidence 90)
- **Location**: `app/lib/features/chat/models/typed_error.dart:4-40`
- **Evidence**: Server `ErrorCode` has `mcp_load_failed` and `attachment_save_failed`; Flutter `ErrorCode` does not.

## Proposed Solutions

### Solution A: Add entries to Flutter ErrorCode enum
Add `mcpLoadFailed` and `attachmentSaveFailed` to the enum and the `fromString` parser.
- **Pros**: Parity with server, ready for future use
- **Cons**: Currently unused
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

**Affected files:**
- `app/lib/features/chat/models/typed_error.dart`

## Acceptance Criteria

- [ ] Flutter ErrorCode enum includes `mcpLoadFailed` and `attachmentSaveFailed`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #67 review | Keep client/server ErrorCode enums in sync |

## Resources

- PR: #67
- Issue: #49
