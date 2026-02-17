---
status: pending
priority: p2
issue_id: 33
tags: [code-review, error-handling]
dependencies: []
---

# Bare `except Exception` in Workspaces DELETE Swallows Errors

## Problem Statement

The workspace DELETE endpoint catches all exceptions from `sandbox.stop_container()` silently. If the container stop fails (e.g., Docker daemon down), the workspace is still deleted but the orphaned container keeps running with no indication to the caller.

## Findings

- **Source**: security-sentinel (M3), python-reviewer
- **Location**: `computer/parachute/api/workspaces.py` — DELETE endpoint
- **Evidence**: `except Exception` with only a log message, no error surfaced to caller

## Proposed Solutions

### Solution A: Log warning and continue (current behavior is acceptable with better logging)
Keep current behavior but add structured logging with container name and error details.
- **Pros**: Non-blocking delete is actually desirable UX
- **Cons**: Container may be orphaned
- **Effort**: Small
- **Risk**: Low

### Solution B: Return warning in response body
Continue with deletion but include a warning in the response that container cleanup failed.
- **Pros**: Caller knows about the issue
- **Cons**: Slightly more complex response
- **Effort**: Small
- **Risk**: Low

## Technical Details

- **Affected files**: `computer/parachute/api/workspaces.py`

## Acceptance Criteria

- [ ] Container stop failure is logged with container name and error details
- [ ] Workspace deletion still succeeds even if container stop fails

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
