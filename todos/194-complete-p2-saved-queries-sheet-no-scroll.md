---
status: complete
priority: p2
issue_id: "194"
tags: [code-review, flutter, brain, ui]
dependencies: []
---

# _SavedQueriesSheet missing Flexible + SingleChildScrollView — will overflow with many saved queries

## Problem Statement
`_SavedQueriesSheet` uses `Column(mainAxisSize: min)` with `ListTile`s mapped directly into it. No scroll wrapping. If user has many saved queries, the column overflows with no scroll. CLAUDE.md pattern: "Bottom sheets: Always wrap content in Flexible + SingleChildScrollView".

## Findings
- brain_query_bar.dart:596-734 — `_SavedQueriesSheet` implementation
- Flutter reviewer confidence 82

## Proposed Solutions
### Option 1: Wrap list in Flexible + SingleChildScrollView
Wrap the list section in `Flexible(child: SingleChildScrollView(child: Column(...)))` or use a `ConstrainedBox` with `maxHeight` before `ListView`.

## Recommended Action

## Technical Details
**Affected files:**
- app/lib/features/brain/widgets/brain_query_bar.dart:596-734

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `_SavedQueriesSheet` scrollable
- [ ] No overflow with 10+ saved queries

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
