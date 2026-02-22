---
status: pending
priority: p2
issue_id: 96
tags: [code-review, architecture, reliability, sandbox]
dependencies: []
---

# `reconcile()` Force-Kills Running Containers Without Checking Active Sessions

## Problem Statement

The `reconcile()` method removes containers whose `config_hash` label doesn't match the current hash by calling `docker rm -f <name>`, which force-kills the container regardless of whether there is an active user session running inside it. A user mid-conversation with a sandboxed agent will have their session abruptly terminated when reconcile runs (e.g., after a server restart). There is no check against the sessions database and no graceful termination.

## Findings

- **Sources**: architecture-strategist (confidence 85), parachute-conventions-reviewer (confidence 88)
- **Location**: `computer/parachute/core/sandbox.py`, `reconcile()` method (roughly lines 920-960)
- **Evidence**:
  ```python
  # reconcile() — no active session check before removal
  for name in stale_containers:
      await self._run_docker(["rm", "-f", name])  # force-kills immediately
  ```
  The `SessionOrchestrator` has a sessions database that tracks active sessions and their associated containers. `reconcile()` does not consult this.

## Proposed Solutions

### Solution A: Skip containers with active sessions, log a warning (Recommended)
Before removing a stale container, check if any session is actively using it. If so, log a warning and skip it — reconcile it on the next pass after the session ends.

```python
from parachute.db import get_active_sessions_for_container

for name in stale_containers:
    workspace_slug = name.removeprefix("parachute-ws-")
    if await get_active_sessions_for_container(workspace_slug):
        logger.warning(f"Skipping stale container {name} — has active sessions")
        continue
    await self._run_docker(["rm", "-f", name])
```

- **Pros**: Active sessions are never abruptly killed; stale containers are cleaned up after they're unused
- **Cons**: Stale containers linger until their session ends
- **Effort**: Small
- **Risk**: Low

### Solution B: Send a graceful shutdown signal, wait, then force-kill
Send `docker stop` (SIGTERM → 10s grace → SIGKILL) instead of `docker rm -f`.
- **Pros**: Gives running processes a chance to clean up
- **Cons**: Still kills active sessions; slow reconcile
- **Effort**: Small
- **Risk**: Low for new infrastructure

### Solution C: Mark containers as "pending eviction" and skip new sessions
Set a metadata flag so new sessions don't start in the stale container, then wait for existing sessions to end naturally.
- **Pros**: Zero disruption to active sessions
- **Cons**: More complex; requires session lifecycle hooks
- **Effort**: Large
- **Risk**: Medium

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/core/sandbox.py` — `reconcile()` method
- **Components**: DockerSandbox, SessionOrchestrator (session DB)

## Acceptance Criteria

- [ ] `reconcile()` does not remove a container that has an active session
- [ ] Active sessions are never abruptly terminated by reconcile
- [ ] Stale containers with no active sessions are still removed

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created from PR #96 code review | Container lifecycle management must be coordinated with session lifecycle |

## Resources

- PR #96: https://github.com/OpenParachutePBC/parachute-computer/pull/96
