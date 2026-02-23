---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, flutter, brain, widget-state]
dependencies: []
---

# ValueKey(i) index-based key on _FieldEditorRow causes state corruption on field removal

## Problem Statement
`_FieldEditorRow` widgets are keyed by their list index (`ValueKey(i)`). When a field is removed from the middle of the list, Flutter reassigns State objects — the row that was index 2 becomes index 1, and a different State (with different `TextEditingController`s) is associated with it. This causes enum value text fields to show wrong data after non-sequential field removal.

## Findings
- app/lib/features/brain/widgets/brain_type_manager_sheet.dart:355 — `key: ValueKey(i)`

Flutter reviewer confidence 85 — "This is a real state identity bug, not a theoretical one. It will manifest when a user adds three fields, enters an enum value in field 2, then removes field 1."

## Proposed Solutions
### Option 1: Assign stable UUID per field at creation time
Assign a UUID or stable identifier to each field at `_addField()` time; use `ValueKey(field['id'])` instead of `ValueKey(i)`.

### Option 2: Use UniqueKey()
Use `UniqueKey()` — simpler but destroys state on every list rebuild (forces all rows to re-create controllers).

## Recommended Action
Option 1 — stable UUID per field preserves state correctly.

## Technical Details
**Affected files:**
- app/lib/features/brain/widgets/brain_type_manager_sheet.dart:355

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Removing a field from middle of list does not corrupt state in remaining rows
- [ ] Enum chips/text fields maintain correct content after removal

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- Index-based `ValueKey` is a classic Flutter state identity bug: Flutter reuses State objects by matching keys, so removing index 1 causes index 2's State to be handed to the widget that was index 1
- `TextEditingController` state lives in the State object, so the displayed text follows the old State, not the new widget position
