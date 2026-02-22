---
status: pending
priority: p2
issue_id: 91
tags: [code-review, quality, python]
dependencies: []
---

# Triple connector lookup in `approve_pairing()`

## Problem Statement

`approve_pairing()` calls `_connectors.get(pr.platform)` three separate times: once for relay notice (line ~514), once for in-memory allowed_rooms update (line ~502), and once for send_approval_message (line ~493). Each lookup is guarded independently with `if connector and hasattr(...)`. This is repetitive and makes the method harder to follow.

## Findings

- **Source**: code-simplicity-reviewer (P2, confidence: 85), pattern-recognition-specialist (P2, confidence: 85)
- **Location**: `computer/parachute/api/bots.py:450-528`
- **Evidence**: Three separate `_connectors.get(pr.platform)` calls with overlapping guard clauses.

## Proposed Solutions

### Solution A: Single lookup at method start (Recommended)
```python
connector = _connectors.get(pr.platform)
# ... use `connector` throughout without re-fetching
```

- **Pros**: Cleaner, one lookup, consistent reference
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/api/bots.py`

## Acceptance Criteria

- [ ] Only one `_connectors.get()` call per approval
- [ ] All three uses reference the same connector instance

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
