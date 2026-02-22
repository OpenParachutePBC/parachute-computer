---
status: pending
priority: p3
issue_id: 50
tags: [code-review, flutter, duplication]
dependencies: []
---

# Duplicated "Usage Unavailable" Widget in usage_bar.dart

## Problem Statement

Fix 3c in PR #65 added a "Usage unavailable" text widget in two places within `UsageBar.build()`: the `data:` handler (when `usage.hasError`) and the `error:` handler. The identical 10-line `Padding > Text` block is duplicated verbatim.

## Findings

- **Source**: flutter-reviewer (82), code-simplicity-reviewer (92), pattern-recognition-specialist (95)
- **Location**: `app/lib/features/chat/widgets/usage_bar.dart` — lines 21-30 and 35-44
- **Evidence**: Identical widget tree appears twice in the same method. Three agents flagged this independently.

## Proposed Solutions

### Solution A: Extract to local variable
```dart
final unavailableWidget = Padding(
  padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
  child: Text('Usage unavailable', style: TextStyle(...)),
);
```
Then reference `unavailableWidget` in both handlers.
- **Pros**: Single source of truth, easy to modify
- **Cons**: Minor refactor
- **Effort**: Small
- **Risk**: Low

## Technical Details

- **Affected files**: `app/lib/features/chat/widgets/usage_bar.dart`

## Acceptance Criteria

- [ ] "Usage unavailable" widget defined once and referenced in both handlers

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #65 review | Highest-confidence finding (95) |

## Resources

- PR: #65
- Issue: #50
