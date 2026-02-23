---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, flutter, brain, data-loss]
dependencies: []
---

# BrainTypeManagerSheet edit mode silently shows empty form if schema provider still loading

## Problem Statement
`_loadExistingType()` uses `ref.read(brainSchemaDetailProvider).whenData(...)`. If the provider is still in loading or error state when the post-frame callback fires, `whenData` silently does nothing — the edit form renders with all fields blank. User could then "save" the type, effectively wiping all field definitions by submitting an empty field list.

## Findings
- app/lib/features/brain/widgets/brain_type_manager_sheet.dart:52-70 — `ref.read(brainSchemaDetailProvider).whenData(...)` with no loading or error branch

If `AsyncLoading`, silent no-op. Flutter reviewer confidence 88.

## Proposed Solutions
### Option 1: Replace whenData with full when()
Replace `whenData` with full `when(loading:, error:, data:)`. Show loading indicator or disable save button while loading. Show error message if failed.

### Option 2: Watch provider and react to state changes
Watch `brainSchemaDetailProvider` and react to its state instead of one-shot read in post-frame callback.

## Recommended Action
Option 1 — minimal targeted fix.

## Technical Details
**Affected files:**
- app/lib/features/brain/widgets/brain_type_manager_sheet.dart:52-70

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Edit mode shows loading indicator while schema loads
- [ ] Error state shown if load fails
- [ ] Save button disabled until data is loaded

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- `AsyncValue.whenData()` is a silent no-op for loading and error states — it should never be used where loading/error require handling
- The data-loss risk here is high: user sees empty form, doesn't notice, saves — all fields deleted silently
