---
status: pending
priority: p3
issue_id: 75
tags: [code-review, quality, python]
dependencies: []
---

# agents_dict = None Dead Code in Orchestrator

## Problem Statement

`agents_dict` is unconditionally `None` but still threaded through capability filtering, prompt metadata events, sandbox config, and the SDK call. This dead code path creates reader confusion.

## Findings

- **Source**: architecture-strategist (P3, confidence 83)
- **Location**: `computer/parachute/core/orchestrator.py:593, 643, 654-655, 672, 792, 993`
- **Evidence**: `agents_dict = None` at line 593, all downstream code handles the None case defensively

## Proposed Solutions

### Solution A: Remove agents_dict variable and branching
- **Effort**: Medium (touches several locations)
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/orchestrator.py`

## Acceptance Criteria
- [ ] No `agents_dict` variable in orchestrator
- [ ] Capability filter doesn't branch on agents

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | Transitional dead code from Phase 1 |

## Resources
- PR: #75
