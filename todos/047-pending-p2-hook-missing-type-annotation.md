---
status: pending
priority: p2
issue_id: 73
tags: [code-review, python, type-hints]
dependencies: []
---

# Missing Type Annotations in Hook Code

## Problem Statement

`_set_title_source()` in `orchestrator.py` has no type annotation for its `session` parameter. Additionally, `get_session_with_title()` uses `Any` instead of `Session` for its return type.

## Findings

- **Source**: python-reviewer (confidence 95, 88)
- **Locations**:
  - `computer/parachute/core/orchestrator.py:82` — `def _set_title_source(session, source: str)` missing type on `session`
  - `computer/parachute/hooks/activity_hook.py:261` — returns `tuple[Optional[Any], ...]` instead of `tuple[Optional[Session], ...]`

## Proposed Solutions

### Solution A: Add type annotations (Recommended)
```python
# orchestrator.py
def _set_title_source(session: Session, source: str) -> None:

# activity_hook.py (if function is kept after consolidation)
from parachute.models.session import Session
async def get_session_with_title(session_id: str) -> tuple[Optional[Session], Optional[str]]:
```
- **Pros**: Type safety, IDE autocomplete, consistent with project conventions
- **Effort**: Small (5 min)
- **Risk**: None

## Recommended Action

<!-- Filled during triage -->

## Acceptance Criteria

- [ ] All function parameters have type annotations
- [ ] No use of `Any` where a specific type is known

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #73 review | |

## Resources

- PR: https://github.com/OpenParachutePBC/parachute-computer/pull/73
