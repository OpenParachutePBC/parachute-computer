---
status: complete
priority: p2
issue_id: "186"
tags: [code-review, flutter, brain, performance, riverpod]
dependencies: []
---

# brainSchemaDetailProvider autoDispose causes unnecessary re-fetches on navigation

## Problem Statement
`brainSchemaDetailProvider` uses `FutureProvider.autoDispose`. Schema type list changes rarely (only on explicit create/delete/update operations). When the sidebar unmounts on mobile navigation, the provider disposes and re-fetches on return. Each re-fetch triggers N serialized count queries (see finding 171). This is O(N types) work on every navigation event for data that almost never changes.

## Findings
- brain_ui_state_provider.dart:36-40 — `FutureProvider.autoDispose` declaration
- Performance reviewer confidence 85
- Each re-fetch is O(N types) due to serialized count queries

## Proposed Solutions
### Option 1: Remove autoDispose and invalidate on mutations
Remove `autoDispose`; add explicit `ref.invalidate(brainSchemaDetailProvider)` in the three mutation paths (create type, update type, delete type). One fetch per session + one per mutation.

## Recommended Action

## Technical Details
**Affected files:**
- app/lib/features/brain/providers/brain_ui_state_provider.dart:36-40

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `brainSchemaDetailProvider` not `autoDispose`
- [ ] Mutation handlers call `ref.invalidate` after successful write
- [ ] Schema not re-fetched on navigation

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
