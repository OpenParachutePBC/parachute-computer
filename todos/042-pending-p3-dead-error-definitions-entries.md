---
status: pending
priority: p3
issue_id: 67
tags: [code-review, python, simplicity]
dependencies: []
---

# Dead ERROR_DEFINITIONS Entries for Warning-Only Codes

## Problem Statement

`MCP_LOAD_FAILED` and `ATTACHMENT_SAVE_FAILED` entries in `ERROR_DEFINITIONS` have zero consumers. `WarningEvent` constructors in `orchestrator.py` pass title/message inline. `parse_error()` has no branch that routes to either code. The `RecoveryAction` objects inside are unused since warnings render as passive callouts with no retry mechanism.

## Findings

- **Source**: code-simplicity-reviewer (90), python-reviewer (90)
- **Location**: `computer/parachute/lib/typed_errors.py:182-190, 199-207`
- **Evidence**: No code path calls `ERROR_DEFINITIONS[ErrorCode.MCP_LOAD_FAILED]` or `ERROR_DEFINITIONS[ErrorCode.ATTACHMENT_SAVE_FAILED]`.

## Proposed Solutions

### Solution A: Remove definitions, keep enum values
Delete the 18 lines of `ERROR_DEFINITIONS` entries. The `ErrorCode` enum values are still used by `WarningEvent`.
- **Pros**: No dead code
- **Cons**: Must add back if warnings later need recovery actions
- **Effort**: Small
- **Risk**: None

### Solution B: Add comment marking as warning-only
Add `# Warning-only — not used by parse_error()` comment.
- **Pros**: Documents intent, available for future use
- **Cons**: Still dead code
- **Effort**: Trivial
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

**Affected files:**
- `computer/parachute/lib/typed_errors.py`

## Acceptance Criteria

- [ ] Dead ERROR_DEFINITIONS entries are either removed or documented

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #67 review | Warning codes don't need ERROR_DEFINITIONS unless parse_error() can produce them |

## Resources

- PR: #67
- Issue: #49
