---
status: complete
priority: p2
issue_id: "197"
tags: [code-review, flutter, brain, riverpod]
dependencies: []
---

# brainActiveFiltersProvider not autoDispose — filters persist across type switches via convention

## Problem Statement
`brainActiveFiltersProvider` is `NotifierProvider` (not autoDispose). Filters are semantically scoped to the selected type. Clear-on-type-switch is done explicitly in `_TypeRow.onTap` in brain_type_sidebar.dart:154. Any future code path that changes the selected type without going through `_TypeRow.onTap` will silently apply stale filters.

## Findings
- brain_ui_state_provider.dart:44-47 — non-autoDispose `NotifierProvider`
- brain_type_sidebar.dart:154 — explicit clear on type switch
- Flutter reviewer confidence 88

## Proposed Solutions
### Option 1: Make brainActiveFiltersProvider a .family provider
Make `brainActiveFiltersProvider` a `.family` provider keyed by `entityType` — filters automatically scoped and cleared per type.

### Option 2: Add autoDispose and keep explicit clear
Add `autoDispose`; rely on type-switch clear remaining consistent.

## Recommended Action
Option 1 — eliminates the convention dependency.

## Technical Details
**Affected files:**
- app/lib/features/brain/providers/brain_ui_state_provider.dart:44-47
- app/lib/features/brain/widgets/brain_type_sidebar.dart:154

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Filters scoped to entity type
- [ ] Switching types cannot apply stale filters regardless of navigation path

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
