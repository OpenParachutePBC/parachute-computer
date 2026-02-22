---
status: pending
priority: p2
issue_id: 73
tags: [code-review, python, performance, quality]
dependencies: []
---

# Consolidate Redundant DB Queries in Activity Hook

## Problem Statement

The activity hook makes 2-6 separate `db.get_session()` calls per invocation, all fetching the same session row. Additionally, `get_session_with_title()` is a near-duplicate of `get_session_title()`. This wastes DB round-trips and adds unnecessary code.

## Findings

- **Sources**: pattern-recognition-specialist (confidence 88), code-simplicity-reviewer (confidence 95), performance-oracle (confidence 90)
- **Location**: `computer/parachute/hooks/activity_hook.py:100-145, 250-269`
- **Evidence**:
  - `get_session_title()` (line 250) and `get_session_with_title()` (line 261) both call `db.get_session()` identically
  - Non-title path: 2 separate `get_session()` calls (lines 104, 108)
  - Title path: up to 4 calls (lines 115, 137, 442 + update)
  - `update_session_title()` does a read-merge-write that re-fetches the session

## Proposed Solutions

### Solution A: Single fetch, reuse everywhere (Recommended)
Fetch the session once at the top of `handle_stop_hook()`, extract all needed fields, pass them through.
- **Pros**: Eliminates all redundant queries, simplifies code, removes `get_session_with_title()` entirely
- **Cons**: Slightly restructures the function
- **Effort**: Small (30 min)
- **Risk**: Low

### Solution B: Make `get_session_title()` call `get_session_with_title()` internally
Reduce duplication without restructuring the main flow.
- **Pros**: Minimal change
- **Cons**: Still has multiple DB calls per invocation
- **Effort**: Small (10 min)
- **Risk**: Low

## Recommended Action

<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/hooks/activity_hook.py`
- **Components**: Activity hook DB access layer

## Acceptance Criteria

- [ ] Single `db.get_session()` call per hook invocation
- [ ] `get_session_with_title()` removed or consolidated
- [ ] `update_session_title()` no longer re-fetches session for metadata merge

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #73 review | Multiple agents flagged this independently |

## Resources

- PR: https://github.com/OpenParachutePBC/parachute-computer/pull/73
- Issue: #61
