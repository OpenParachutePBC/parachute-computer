---
status: pending
priority: p3
issue_id: "206"
tags: [code-review, flutter, brain, architecture, technical-debt]
dependencies: []
---

# BrainSchema and BrainSchemaDetail parallel models — complete the migration to BrainSchemaDetail

## Problem Statement
Two parallel schema models coexist in the brain feature: `BrainSchema` (fetched from `/schemas`) and `BrainSchemaDetail` (fetched from `/types`). `BrainSchemaDetail.toSchema()` provides a bridge conversion, and `brainSchemaListProvider` is already marked as "legacy" in a comment. Two remaining callers — `brain_entity_detail_screen.dart` and `brain_entity_form_screen.dart` — still use the legacy provider. Additionally, `BrainSchema.id` is always equal to `name`, making it a noise field that could be removed once the migration is complete.

## Findings
- `brain_schema.dart:35-41` — `toSchema()` bridge method converting `BrainSchemaDetail` to `BrainSchema`
- `brain_ui_state_provider.dart:35` — `brainSchemaListProvider` with "legacy" comment
- `brain_entity_detail_screen.dart` — uses legacy `brainSchemaListProvider`
- `brain_entity_form_screen.dart` — uses legacy `brainSchemaListProvider`
- `BrainSchema.id` is always `== name` (redundant field)
- Simplicity reviewer confidence: 83

## Proposed Solutions
### Option 1: Complete the migration
1. Update `brain_entity_detail_screen.dart` to use `brainSchemaDetailProvider` (consuming `BrainSchemaDetail` directly or via `.toSchema()` as needed).
2. Update `brain_entity_form_screen.dart` similarly.
3. Delete `brainSchemaListProvider` and `brain_schema_provider.dart` if no longer referenced.
4. Remove `BrainSchema.id` field once all callers have migrated away from it.

## Recommended Action

## Technical Details
**Affected files:**
- app/lib/features/brain/models/brain_schema.dart:35-41
- app/lib/features/brain/providers/brain_ui_state_provider.dart:35
- app/lib/features/brain/screens/brain_entity_detail_screen.dart
- app/lib/features/brain/screens/brain_entity_form_screen.dart
- app/lib/features/brain/providers/brain_schema_provider.dart (candidate for deletion)

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `brain_entity_detail_screen.dart` no longer uses `brainSchemaListProvider`
- [ ] `brain_entity_form_screen.dart` no longer uses `brainSchemaListProvider`
- [ ] `brainSchemaListProvider` is deleted (or the "legacy" comment is removed if kept intentionally)
- [ ] `brain_schema_provider.dart` is deleted if it has no remaining callers
- [ ] `BrainSchema.id` field is removed
- [ ] Flutter analyzer reports no errors after the migration

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
