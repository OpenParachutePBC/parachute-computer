---
status: complete
priority: p2
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# `_buildStreamingExpandedView` duplicates item iteration from post-streaming expanded view

## Problem Statement

`_buildStreamingExpandedView` (lines 211–279) and the post-streaming expanded view (lines 132–148) in `CollapsibleThinkingSection` both iterate `widget.items` with identical logic calling `_buildThinkingBlock` and `_buildToolCall`. The code is verbatim-duplicated. The only differences are the header widget (pulsing vs static) and which boolean is toggled on collapse. If a new item type is added, both locations must be updated in sync.

## Findings

- **Source**: code-simplicity-reviewer (P2, confidence: 85)
- **Location**: `app/lib/features/chat/widgets/collapsible_thinking_section.dart:134-144` and `266-275`
- **Evidence**:
  ```dart
  // Both blocks are identical:
  ...widget.items.asMap().entries.map((entry) {
    final index = entry.key;
    final item = entry.value;
    if (item.type == ContentType.thinking) {
      return _buildThinkingBlock(item.text ?? '');
    } else if (item.type == ContentType.toolUse && item.toolCall != null) {
      return _buildToolCall(index, item.toolCall!);
    }
    return const SizedBox.shrink();
  }),
  ```

## Proposed Solutions

### Solution A: Extract `_buildItemList()` helper (Recommended)
```dart
List<Widget> _buildItemList() {
  return widget.items.asMap().entries.map((entry) {
    final index = entry.key;
    final item = entry.value;
    if (item.type == ContentType.thinking) {
      return _buildThinkingBlock(item.text ?? '');
    } else if (item.type == ContentType.toolUse && item.toolCall != null) {
      return _buildToolCall(index, item.toolCall!);
    }
    return const SizedBox.shrink();
  }).toList();
}
```
Call `..._buildItemList()` in both locations.
- **Pros**: ~12 LOC removed; single maintenance point for item rendering
- **Cons**: None
- **Effort**: Trivial
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/widgets/collapsible_thinking_section.dart`

## Acceptance Criteria

- [ ] Item rendering logic exists in exactly one place
- [ ] Both streaming-expanded and post-streaming expanded views render identically

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
