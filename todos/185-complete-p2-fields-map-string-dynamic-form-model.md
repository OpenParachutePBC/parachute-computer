---
status: complete
priority: p2
issue_id: "185"
tags: [code-review, flutter, brain, type-safety]
dependencies: []
---

# _BrainTypeManagerSheetState._fields uses List<Map<String, dynamic>> as form state model

## Problem Statement
The field definitions in the type manager form are stored as `List<Map<String, dynamic>>`. Field values are accessed via string keys (`field['type']`, `field['required']`, `field['values']`, `field['link_type']`) in 6+ locations. Key typos are silent compile-time errors. `_FieldEditorRow` also accepts `Map<String, dynamic>` in its constructor.

## Findings
- brain_type_manager_sheet.dart:28 — `_fields` declared as `List<Map<String, dynamic>>`
- Flutter reviewer confidence 90 — "This is explicitly called out as a failure case in the review principles: FAIL: Map<String, dynamic> as a data model."
- String key access in 6+ locations throughout the form state

## Proposed Solutions
### Option 1: Create a FieldDraft value class
Create a `FieldDraft` value class with typed fields (`String type`, `bool required`, `List<String>? values`, `String? linkType`, `String? description`). Replace all map accesses with typed property access. `_FieldEditorRow` accepts typed `FieldDraft`.

## Recommended Action

## Technical Details
**Affected files:**
- app/lib/features/brain/widgets/brain_type_manager_sheet.dart:28

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `_fields` list uses typed `FieldDraft` objects
- [ ] No string-key map access in form state
- [ ] `_FieldEditorRow` accepts typed `FieldDraft`

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
