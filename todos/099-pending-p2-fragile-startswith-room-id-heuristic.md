---
status: pending
priority: p2
issue_id: 91
tags: [code-review, quality, python, matrix]
dependencies: []
---

# Fragile `startswith("!")` room ID detection heuristic

## Problem Statement

In `approve_pairing()`, the code uses `pr.platform_user_id.startswith("!")` to distinguish room-based approvals from user-based approvals. While Matrix room IDs do start with `!`, this is a fragile heuristic that encodes protocol knowledge in the API layer. It would be more robust to store an explicit flag (e.g., `is_room_based`) in the pairing request or session metadata.

## Findings

- **Source**: architecture-strategist (P2, confidence: 85), pattern-recognition-specialist (P3, confidence: 80)
- **Location**: `computer/parachute/api/bots.py:497`
- **Evidence**: `if pr.platform == "matrix" and pr.platform_user_id.startswith("!")` — relies on Matrix room ID format convention.

## Proposed Solutions

### Solution A: Store `is_room_pairing` flag in metadata (Recommended)
When creating the pairing request in `_handle_bridged_room()`, store `is_room_pairing: True` in the metadata. Use that flag in `approve_pairing()` instead of the `startswith("!")` check.

- **Pros**: Explicit, not tied to protocol conventions
- **Cons**: Requires metadata field addition
- **Effort**: Small
- **Risk**: None

### Solution B: Accept the heuristic with a comment
Matrix room IDs always start with `!` per spec. Add a comment noting this convention.

- **Pros**: No change needed
- **Cons**: Still implicit
- **Effort**: None
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/api/bots.py`, `computer/parachute/connectors/matrix_bot.py`

## Acceptance Criteria

- [ ] Room-based vs user-based approval is determined by an explicit flag, not ID format
- [ ] Or: heuristic is documented with a comment explaining the Matrix convention

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
