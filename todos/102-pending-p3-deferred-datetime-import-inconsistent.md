---
status: pending
priority: p3
issue_id: 91
tags: [code-review, quality, python, matrix]
dependencies: []
---

# Deferred `datetime` import inconsistent with base/telegram

## Problem Statement

`matrix_bot.py` uses lazy imports for `datetime` and `uuid` inside methods (`from datetime import datetime, timezone` inside `_handle_bridged_room`). The base connector and telegram connector import these at module level. This inconsistency makes the codebase harder to follow.

## Findings

- **Source**: python-reviewer (P3, confidence: 88), pattern-recognition-specialist (P3, confidence: 85)
- **Location**: `computer/parachute/connectors/matrix_bot.py` (inside method bodies)
- **Evidence**: `from datetime import datetime, timezone` appears inside `_handle_bridged_room()` instead of at the top of the file. `base.py` and `telegram_bot.py` import these at module level.

## Proposed Solutions

### Solution A: Move to module-level imports (Recommended)
Move `datetime`, `timezone`, and `uuid` imports to the top of the file with other standard library imports.

- **Pros**: Consistent with other connectors
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/matrix_bot.py`

## Acceptance Criteria

- [ ] `datetime`, `timezone`, `uuid` imported at module level
- [ ] No lazy imports for standard library modules inside methods

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
