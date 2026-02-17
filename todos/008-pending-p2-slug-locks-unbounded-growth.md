---
status: pending
priority: p2
issue_id: 33
tags: [code-review, performance, memory]
dependencies: []
---

# `_slug_locks` DefaultDict Grows Unboundedly

## Problem Statement

`self._slug_locks = defaultdict(asyncio.Lock)` creates a new lock for every unique workspace slug encountered but never removes them. Over a long-running server lifetime, this leaks memory proportional to the number of unique workspaces.

## Findings

- **Source**: python-reviewer, performance-oracle, security-sentinel (L1)
- **Location**: `computer/parachute/core/sandbox.py` — line 62
- **Evidence**: `defaultdict(asyncio.Lock)` with no cleanup in `stop_container()` or elsewhere

## Proposed Solutions

### Solution A: Clean up lock in `stop_container()` (Recommended)
After stopping a container, `del self._slug_locks[slug]` if the lock is not held.
- **Pros**: Simple, bounded memory
- **Cons**: Need to check lock isn't held
- **Effort**: Small
- **Risk**: Low

### Solution B: Use a regular dict with explicit creation
Replace `defaultdict` with `dict` and explicitly create/delete locks.
- **Pros**: More explicit control
- **Cons**: More code
- **Effort**: Small
- **Risk**: Low

## Technical Details

- **Affected files**: `computer/parachute/core/sandbox.py`

## Acceptance Criteria

- [ ] Locks are cleaned up when containers are stopped
- [ ] No unbounded memory growth from slug locks

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
