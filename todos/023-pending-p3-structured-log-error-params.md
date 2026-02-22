---
status: pending
priority: p3
issue_id: 50
tags: [code-review, flutter, logging]
dependencies: []
---

# `_log.error()` Uses String Interpolation Instead of Structured `data:` Parameter

## Problem Statement

Fix 4 in PR #65 enhanced typedError logging but used string interpolation in the message and passed `errorMsg` (a String) as the `error:` parameter. The `ComponentLogger.error()` method supports a `data:` named parameter for structured fields, which would be more useful for log aggregation and searching.

## Findings

- **Source**: architecture-strategist (85), code-simplicity-reviewer (82), pattern-recognition-specialist (85)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart` — typedError case in stream event handler
- **Evidence**: Current code: `_log.error('Stream typed error: code=${typedErr.code}, ...', error: errorMsg)`. The `error:` parameter should receive the actual error object, and structured fields should use `data:`.

## Proposed Solutions

### Solution A: Use `data:` parameter and pass error object
```dart
_log.error('Stream typed error',
    error: typedErr,
    data: {'code': typedErr.code, 'canRetry': typedErr.canRetry});
```
- **Pros**: Structured, searchable, follows logger conventions
- **Cons**: Minor change
- **Effort**: Small
- **Risk**: Low

### Solution B: Use `typedErr.toJson()` one-liner
```dart
_log.error('Stream typed error', error: typedErr, data: typedErr.toJson());
```
- **Pros**: Even simpler, captures all fields
- **Cons**: May include unnecessary fields
- **Effort**: Small
- **Risk**: Low

## Technical Details

- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria

- [ ] `_log.error()` uses `data:` parameter for structured fields
- [ ] `error:` parameter receives the actual error object, not a string

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #65 review | Three agents flagged same issue |

## Resources

- PR: #65
- Issue: #50
