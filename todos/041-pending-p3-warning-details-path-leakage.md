---
status: pending
priority: p3
issue_id: 67
tags: [code-review, security, python]
dependencies: []
---

# Raw Exception Strings in Warning Details (Path Leakage)

## Problem Statement

`WarningEvent.details` includes unfiltered Python exception strings that can contain absolute filesystem paths. For local-first usage this is low risk, but becomes more relevant with `auth_mode: remote`.

## Findings

- **Source**: security-sentinel (82), python-reviewer (82), parachute-conventions-reviewer (82)
- **Location**: `computer/parachute/core/orchestrator.py:464` (`f"{file_name}: {e}"`), `orchestrator.py:544` (`str(e)` for MCP)
- **Evidence**: OS-level exceptions from `write_bytes()` include full absolute paths. The codebase strips paths elsewhere (lines 1420-1423).

## Proposed Solutions

### Solution A: Simplify client-facing details
Replace `f"{file_name}: {e}"` with `f"{file_name}: save failed"`. Full exception is already logged server-side.
- **Pros**: No path leakage, cleaner UX
- **Cons**: Less diagnostic info in client
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

**Affected files:**
- `computer/parachute/core/orchestrator.py`

## Acceptance Criteria

- [ ] Warning details do not contain absolute filesystem paths

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #67 review | Always sanitize exception strings before sending to clients |

## Resources

- PR: #67
- Issue: #49
