---
status: pending
priority: p3
issue_id: 73
tags: [code-review, python, simplicity]
dependencies: []
---

# Remove Placeholder Activity Logging on Cadence Skip

## Problem Statement

When `should_update_title` is False, the hook still logs an activity entry with `summary="Exchange #N (skipped summarization)"`. This creates noise in the activity log, requires 2 DB queries, and provides no actionable information. The SDK transcript already has the complete record.

## Findings

- **Sources**: code-simplicity-reviewer (confidence 85), performance-oracle (confidence 88)
- **Location**: `computer/parachute/hooks/activity_hook.py:102-112`
- **Evidence**: Placeholder text "Exchange #N (skipped summarization)" has no search or review value

## Proposed Solutions

### Solution A: Early return on skip (Recommended)
```python
if not should_update_title:
    return  # Skip entirely — transcript has the complete record
```
- **Pros**: Eliminates 2 DB queries + 1 file write for ~85% of hook invocations, removes 9 lines
- **Cons**: Activity log will have gaps (only title-update exchanges logged)
- **Effort**: Small (5 min)
- **Risk**: Low — activity log is for meaningful summaries, not audit trail

## Recommended Action

<!-- Filled during triage -->

## Acceptance Criteria

- [ ] Non-title exchanges don't write placeholder activity entries
- [ ] Activity log entries have real summaries, not "skipped" placeholders

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #73 review | |

## Resources

- PR: https://github.com/OpenParachutePBC/parachute-computer/pull/73
