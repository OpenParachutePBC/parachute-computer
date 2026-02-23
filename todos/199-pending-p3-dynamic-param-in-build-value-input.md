---
status: pending
priority: p3
issue_id: "199"
tags: [code-review, flutter, brain, type-safety]
dependencies: []
---

# _buildValueInput uses dynamic parameter where BrainField? is available

## Problem Statement
In `brain_query_bar.dart:468`, the method `Widget _buildValueInput(bool isDark, dynamic field)` declares its second parameter as `dynamic` despite being used only to read `field?.type`. The caller at line 447 passes `selectedBrainField`, which is typed as `BrainField?`. Using `dynamic` defeats Flutter's type system and suppresses any type errors at the call site or inside the method.

## Findings
- `brain_query_bar.dart:468` — method signature uses `dynamic field`
- `brain_query_bar.dart:447` — caller passes `selectedBrainField` typed as `BrainField?`
- Flutter reviewer confidence: 90

## Proposed Solutions
### Option 1: Change dynamic to BrainField?
Replace `dynamic field` with `BrainField? field` in the method signature. No other changes needed — the body already accesses only `field?.type`, which is valid on `BrainField?`.

## Recommended Action

## Technical Details
**Affected files:**
- app/lib/features/brain/widgets/brain_query_bar.dart:447
- app/lib/features/brain/widgets/brain_query_bar.dart:468

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `_buildValueInput` signature uses `BrainField? field` instead of `dynamic field`
- [ ] Flutter analyzer reports no new warnings or errors after the change

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
