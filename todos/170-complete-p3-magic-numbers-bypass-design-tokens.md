---
status: complete
priority: p3
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# Magic numbers in new widgets bypass the design token system

## Problem Statement

The project uses a design token system (`Spacing.*`, `Radii.*`, `TypographyTokens.*`) throughout existing code. `InlineUserQuestionCard` and the `_buildTaskAgentCard` method in `CollapsibleThinkingSection` — both introduced in this PR — use inline magic numbers instead:

```dart
// inline_user_question_card.dart — magic numbers
const SizedBox(height: 4),
padding: const EdgeInsets.symmetric(vertical: 8),
minimumSize: const Size(0, 32),
const SizedBox(height: 6),
border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
// chip radius 12, padding EdgeInsets.symmetric(horizontal: 8, vertical: 3)

// collapsible_thinking_section.dart _buildTaskAgentCard
padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
borderRadius: BorderRadius.circular(4)
```

The `MessageBubble` and main `CollapsibleThinkingSection` paths correctly use `Spacing.sm`, `Spacing.xs`, `Radii.sm`. The inconsistency is within new code in this PR, not inherited.

## Findings

- **Source**: pattern-recognition-specialist (P3, confidence: 81)
- **Location**: `app/lib/features/chat/widgets/inline_user_question_card.dart` (multiple lines), `app/lib/features/chat/widgets/collapsible_thinking_section.dart` (_buildTaskAgentCard)

## Proposed Solutions

### Solution A: Replace with design tokens (Recommended)

Audit each magic number and replace with the appropriate token:
- `height: 4` → `Spacing.xxs` or `Spacing.xs`
- `vertical: 8`, `height: 6` → `Spacing.xs`
- `horizontal: 10` → `Spacing.sm` (or nearest match)
- `BorderRadius.circular(10)` → `Radii.sm`
- `BorderRadius.circular(12)` → `Radii.md` or `Radii.sm`
- `Size(0, 32)` → document intent or use a named constant

If a token doesn't exist for a value, add it to the token system rather than using a raw number.
- **Effort**: Small
- **Risk**: Minor visual differences if token values don't exactly match magic numbers

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**:
  - `app/lib/features/chat/widgets/inline_user_question_card.dart`
  - `app/lib/features/chat/widgets/collapsible_thinking_section.dart`

## Acceptance Criteria

- [ ] No bare numeric literals for spacing, radius, or sizing in `InlineUserQuestionCard`
- [ ] `_buildTaskAgentCard` uses design tokens for padding and border radius

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
