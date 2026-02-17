---
status: pending
priority: p2
issue_id: 33
tags: [code-review, consistency, api]
dependencies: []
---

# Error Event Key Inconsistency Between sandbox.py and entrypoint.py

## Problem Statement

`sandbox.py` emits error events with `"message"` key while `entrypoint.py` uses `"error"` key. Consumers need to check both keys to handle errors, which is fragile and confusing.

## Findings

- **Source**: pattern-recognition-specialist
- **Location**: `computer/parachute/core/sandbox.py` vs `computer/parachute/docker/entrypoint.py`
- **Evidence**: `sandbox.py`: `{"type": "error", "message": "..."}` vs `entrypoint.py`: `{"type": "error", "error": "..."}`

## Proposed Solutions

### Solution A: Standardize on `"error"` key (Recommended)
Change sandbox.py to use `"error"` key to match entrypoint.py.
- **Pros**: Consistent, `"error"` is more conventional for error events
- **Cons**: May need to update consumers
- **Effort**: Small
- **Risk**: Low — check all consumers first

## Technical Details

- **Affected files**: `computer/parachute/core/sandbox.py`

## Acceptance Criteria

- [ ] All error events use the same key name
- [ ] Consumers handle the standardized key

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
