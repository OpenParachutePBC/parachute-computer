---
status: pending
priority: p2
issue_id: 33
tags: [code-review, architecture, conventions]
dependencies: []
---

# Workspaces API Route Bypasses Orchestrator for Container Cleanup

## Problem Statement

`workspaces.py` DELETE endpoint directly accesses the sandbox object (`request.app.state.sandbox`) to stop containers, and `server.py` accesses `orchestrator._sandbox` (a private attribute). Both bypass the Orchestrator, which should be the single coordination point for sandbox operations.

## Findings

- **Source**: architecture-strategist, parachute-conventions-reviewer (F2, F3)
- **Location**: `computer/parachute/api/workspaces.py` — DELETE endpoint; `computer/parachute/server.py` — startup
- **Evidence**: Direct sandbox access instead of going through Orchestrator methods

## Proposed Solutions

### Solution A: Add Orchestrator methods for container lifecycle (Recommended)
Add `orchestrator.stop_workspace_container(slug)` and `orchestrator.reconcile_containers()` that delegate to sandbox.
- **Pros**: Proper layering, single coordination point
- **Cons**: Adds methods to Orchestrator
- **Effort**: Small
- **Risk**: Low

### Solution B: Expose sandbox as public attribute
Rename `_sandbox` to `sandbox` on Orchestrator.
- **Pros**: Quick fix for the private access
- **Cons**: Doesn't address the architectural concern
- **Effort**: Small
- **Risk**: Low

## Technical Details

- **Affected files**: `computer/parachute/core/orchestrator.py`, `computer/parachute/api/workspaces.py`, `computer/parachute/server.py`

## Acceptance Criteria

- [ ] Container stop goes through Orchestrator, not direct sandbox access
- [ ] No private attribute access (`_sandbox`) from outside the class
- [ ] Reconcile called through Orchestrator

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
