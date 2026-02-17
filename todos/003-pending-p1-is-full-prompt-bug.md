---
status: pending
priority: p1
issue_id: 33
tags: [code-review, bug, pre-existing]
dependencies: []
---

# `is_full_prompt` Referenced Before Assignment in orchestrator.py

## Problem Statement

In `orchestrator.py` around line 721, `is_full_prompt` is referenced before it's guaranteed to be assigned. If the code path skips the assignment, this causes an `UnboundLocalError`. This is a pre-existing bug, not introduced by PR #38, but it's in the modified code path.

## Findings

- **Source**: python-reviewer (CRITICAL)
- **Location**: `computer/parachute/core/orchestrator.py` ~line 721
- **Evidence**: The variable `is_full_prompt` may not be assigned if certain conditions aren't met before it's referenced in the sandbox message construction.
- **Note**: Pre-existing bug, not introduced by this PR

## Proposed Solutions

### Solution A: Initialize `is_full_prompt = False` at top of method (Recommended)
Set a safe default at the beginning of the method scope.
- **Pros**: Simple, safe default
- **Cons**: None
- **Effort**: Small
- **Risk**: Low

### Solution B: Restructure the conditional logic
Reorganize the code to ensure all paths assign the variable.
- **Pros**: Cleaner logic
- **Cons**: Larger change for a pre-existing bug
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/core/orchestrator.py`
- **Pre-existing**: Yes — not introduced by PR #38

## Acceptance Criteria

- [ ] `is_full_prompt` always has a defined value before use
- [ ] No `UnboundLocalError` possible in the sandbox code path

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | Pre-existing bug found during review |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
