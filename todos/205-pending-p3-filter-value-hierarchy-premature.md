---
status: pending
priority: p3
issue_id: "205"
tags: [code-review, flutter, brain, simplicity, yagni]
dependencies: []
---

# Sealed FilterValue hierarchy has redundant EnumFilterValue identical to StringFilterValue

## Problem Statement
`EnumFilterValue` and `StringFilterValue` are functionally identical across every code path in the brain filter implementation. They share the same display logic, the same `_valueToJson()` output (`v.value`), and the same `fromJson` deserialization — both become `StringFilterValue` on round-trip. The `EnumFilterValue` subclass exists "in case" future display behavior differs from string fields, which is speculative YAGNI complexity.

## Findings
- `brain_filter.dart:9-17` — `EnumFilterValue` and `StringFilterValue` both defined in sealed hierarchy
- `_valueToJson()` — both cases emit `v.value`, identical output
- `fromJson` — both deserialize to `StringFilterValue` (round-trip asymmetry is itself a bug symptom)
- No code path treats enum-valued filters differently from string-valued filters
- Simplicity reviewer confidence: 85

## Proposed Solutions
### Option 1: Remove EnumFilterValue
Delete `EnumFilterValue` from `brain_filter.dart`. Update `_applyFilter` to use `StringFilterValue` for enum-typed fields. Verify `fromJson` remains consistent.

## Recommended Action

## Technical Details
**Affected files:**
- app/lib/features/brain/models/brain_filter.dart:9-17
- app/lib/features/brain/models/brain_filter.dart (_valueToJson and _applyFilter methods)

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `EnumFilterValue` class is removed from `brain_filter.dart`
- [ ] `_applyFilter` uses `StringFilterValue` for enum-typed fields
- [ ] `fromJson` is consistent with the simplified hierarchy
- [ ] No references to `EnumFilterValue` remain in the codebase
- [ ] Flutter analyzer reports no errors after removal

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
