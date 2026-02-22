---
status: pending
priority: p3
issue_id: 96
tags: [code-review, performance, sandbox]
dependencies: []
---

# `reconcile()` Removes Stale Containers Sequentially

## Problem Statement

The `reconcile()` method iterates through stale containers and removes them one by one with sequential `await` calls. Each `docker rm -f` is a network round-trip to the Docker daemon. With N stale containers, reconciliation takes O(N × docker_rtt) time. This is a startup cost that blocks the sandbox from being ready. If there are many stale containers (e.g., after a major image rebuild across 10 workspaces), this could introduce a multi-second delay at server startup.

## Findings

- **Sources**: performance-oracle (confidence 83)
- **Location**: `computer/parachute/core/sandbox.py`, `reconcile()` method
- **Evidence**:
  ```python
  # Sequential removal — O(N) Docker round-trips
  for name in stale_containers:
      await self._run_docker(["rm", "-f", name])
  ```
  Could be parallelized with `asyncio.gather()`.

## Proposed Solutions

### Solution A: Parallelize with `asyncio.gather()` (Recommended)
```python
if stale_containers:
    await asyncio.gather(*[
        self._run_docker(["rm", "-f", name])
        for name in stale_containers
    ])
```
- **Pros**: All removals happen concurrently; startup time scales with max Docker rtt, not sum
- **Cons**: Error handling needs to be per-task (use `return_exceptions=True`)
- **Effort**: Small
- **Risk**: Low

### Solution B: Pass all names to a single `docker rm` call
```python
if stale_containers:
    await self._run_docker(["rm", "-f", *stale_containers])
```
Docker's `rm` command accepts multiple container names. This is a single syscall to the Docker daemon.
- **Pros**: Simpler than gather; single round-trip
- **Cons**: One failure aborts all; harder to report per-container errors
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/core/sandbox.py`

## Acceptance Criteria

- [ ] Stale container removal is parallelized (gather or bulk rm)
- [ ] Error from one removal does not prevent other removals from proceeding

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created from PR #96 code review | Sequential async operations that are independent should use asyncio.gather() |

## Resources

- PR #96: https://github.com/OpenParachutePBC/parachute-computer/pull/96
