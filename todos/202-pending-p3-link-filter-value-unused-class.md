---
status: pending
priority: p3
issue_id: "202"
tags: [code-review, flutter, brain, cleanup, yagni]
dependencies: []
---

# LinkFilterValue sealed class is never constructed anywhere — dead code

## Problem Statement
`brain_filter.dart` defines `LinkFilterValue` as part of the sealed `FilterValue` hierarchy, with a unique `entityId` field. However, `LinkFilterValue` is never instantiated anywhere in the codebase. `_applyFilter` only creates `IntFilterValue`, `EnumFilterValue`, or `StringFilterValue`. `fromJson` does not reconstruct it. The class represents a "link field filter" feature that has not been implemented.

## Findings
- `brain_filter.dart:13-17` — `LinkFilterValue` class definition with `entityId` field
- No instantiation sites found anywhere in the codebase
- `_applyFilter` does not produce `LinkFilterValue`
- `fromJson` does not reconstruct `LinkFilterValue`
- Simplicity reviewer confidence: 85

## Proposed Solutions
### Option 1: Remove the class
Delete `LinkFilterValue` from `brain_filter.dart`. Re-add when link field filtering is actually implemented, at which point the full design (MCP tools, UI, serialization) can be done together.

## Recommended Action

## Technical Details
**Affected files:**
- app/lib/features/brain/models/brain_filter.dart:13-17

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `LinkFilterValue` class is removed from `brain_filter.dart`
- [ ] No references to `LinkFilterValue` remain in the codebase
- [ ] Flutter analyzer reports no new errors after removal

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
