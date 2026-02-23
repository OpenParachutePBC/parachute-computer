---
status: pending
priority: p3
issue_id: 107
tags: [code-review, flutter, accessibility, ux]
dependencies: []
---

# Add Accessibility Semantics to WorkspaceChipRow

## Problem Statement

**What's broken/missing:**
`_WorkspaceChip` uses `GestureDetector` + `Container` with no `Semantics` widget. Screen readers cannot announce the chip name or whether it's selected.

**Why it matters:**
- New widget introduced in this PR, should be accessible from the start
- The existing trust-level chips have the same issue (pre-existing), but those weren't introduced here

## Findings

**From flutter-reviewer (Confidence: 85):**
> `GestureDetector` in new `_WorkspaceChip` has no accessibility semantics. Screen reader won't announce chip name or selected state.

## Proposed Solution

Wrap the `Container` in a `Semantics` widget:

```dart
Semantics(
  label: workspace == null ? 'No workspace' : '$label workspace',
  button: true,
  selected: isSelected,
  child: GestureDetector(onTap: onTap, child: Container(...)),
)
```

Or replace `GestureDetector` + `Container` with `InkWell` + `Ink` for material ripple feedback, which also carries accessibility semantics via `Tooltip`.

**Effort:** Small
**Risk:** None

## Acceptance Criteria
- [ ] Screen reader announces chip label and selected state
- [ ] "None" chip is announced as "No workspace" or equivalent
- [ ] Selected state announced correctly

## Resources
- File: `app/lib/features/chat/widgets/workspace_chip_row.dart` (around `_WorkspaceChip.build`)
