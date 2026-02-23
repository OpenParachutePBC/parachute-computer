---
status: complete
priority: p3
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# Tautological ternary `isDark ? BrandColors.error : BrandColors.error` in `_buildToolCall`

## Problem Statement

In `_buildToolCall`, the error chip color is computed as:
```dart
final chipColor = toolCall.isError
    ? (widget.isDark ? BrandColors.error : BrandColors.error)
    : (widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoise);
```
Both branches of the inner ternary return the identical value `BrandColors.error`. This is a no-op that misleads readers into thinking dark/light error colors differ.

## Findings

- **Source**: code-simplicity-reviewer (P3, confidence: 93)
- **Location**: `app/lib/features/chat/widgets/collapsible_thinking_section.dart:387-389`

## Proposed Solutions

### Solution A: Simplify (Recommended)
```dart
final chipColor = toolCall.isError
    ? BrandColors.error
    : (widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoise);
```
- **Effort**: Trivial (1-line change)
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/widgets/collapsible_thinking_section.dart`

## Acceptance Criteria

- [ ] No redundant ternary; `BrandColors.error` appears once for the error case

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
