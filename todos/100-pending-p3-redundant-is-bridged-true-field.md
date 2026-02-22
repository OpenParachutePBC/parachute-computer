---
status: pending
priority: p3
issue_id: 91
tags: [code-review, quality, python, matrix]
dependencies: []
---

# Redundant `is_bridged: True` field in bridge metadata

## Problem Statement

`_handle_bridged_room()` stores `"is_bridged": True` in the bridge metadata dict. This field is always `True` — the method is only called when a bridge is detected, so the field carries no information. Its presence suggests a missing `False` case that doesn't exist.

## Findings

- **Source**: code-simplicity-reviewer (P3, confidence: 90)
- **Location**: `computer/parachute/connectors/matrix_bot.py` (inside `_handle_bridged_room`, bridge_metadata dict)
- **Evidence**: The `is_bridged` key is set to `True` unconditionally. There is no code path that sets it to `False`.

## Proposed Solutions

### Solution A: Remove the field (Recommended)
Remove `"is_bridged": True` from the metadata. The presence of the `bridge_metadata` key itself indicates it's bridged.

- **Pros**: Removes redundancy
- **Cons**: None
- **Effort**: Small
- **Risk**: None — check that `approve_pairing` doesn't read this field (it reads `bridge_metadata.get("is_bridged")` at line ~513, which should be changed to just check for `bridge_metadata` presence)

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/matrix_bot.py`, `computer/parachute/api/bots.py`

## Acceptance Criteria

- [ ] `is_bridged` field removed from bridge metadata
- [ ] All consumers check for `bridge_metadata` key presence instead of `is_bridged` value

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
