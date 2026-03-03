---
title: Container Lifecycle Cleanup
type: fix
date: 2026-03-03
issue: 166
---

# Container Lifecycle Cleanup

Fix two gaps in persistent container lifecycle management that cause orphan containers to accumulate and containers to run indefinitely after server shutdown.

## Problem Statement

After investigating container sprawl in OrbStack, two structural gaps were identified:

1. **Orphan DB records accumulate**: Every sandboxed session attempt auto-creates a `container_envs` DB record. When sessions fail (e.g., sandbox boot errors, aborted sessions) they leave behind a record with `message_count == 0`. `reconcile()` treats all DB records as "active slugs" and never removes these orphan containers.

2. **Containers run forever after shutdown**: The server shuts down without stopping `parachute-env-*` containers. They remain running in OrbStack indefinitely until manually stopped, consuming memory and VM resources.

During the investigation session, 7 containers were found running — 5 were orphans from failed test sessions.

## Acceptance Criteria

- [ ] Server shutdown stops all running `parachute-env-*` containers
- [ ] `reconcile()` at server startup removes DB records + containers for empty/abandoned envs
- [ ] No manual container cleanup needed after failed sessions
- [ ] Named container envs with real session history are never incorrectly removed
- [ ] Orphan cleanup logs clearly what was pruned and why

## Proposed Solution

### Fix 1: Container shutdown on server stop

In `server.py` lifespan shutdown, after stopping bot connectors, call a new `sandbox.stop_all_env_containers()` method.

`stop_all_env_containers()` in `sandbox.py`:
- `docker ps --filter label=app=parachute --filter label=type=env --format "{{.Names}}"`
- Fire-and-forget `docker stop -t 5` on each in parallel (short grace period — they're idle)
- Log count stopped

On next server start, `_ensure_container()` sees them as "exited" and calls `docker start` — no recreation needed, state preserved.

### Fix 2: Orphan container_env cleanup in reconcile

Add a new DB method `list_orphan_container_env_slugs(min_age_minutes: int)` that returns slugs where:
- All sessions referencing this container_env have `message_count == 0`
- The container_env was created more than `min_age_minutes` ago (prevents cleaning in-flight sessions)

Query:
```sql
SELECT slug FROM container_envs
WHERE created_at < datetime('now', '-5 minutes')
  AND slug NOT IN (
    SELECT DISTINCT container_env_id FROM sessions
    WHERE container_env_id IS NOT NULL
      AND message_count > 0
  )
```

In `orchestrator.reconcile_containers()`:
1. Query orphan slugs (age > 5 min, all sessions empty)
2. Delete each from DB (`delete_container_env(slug)`)
3. Pass remaining slugs as `active_slugs` to `sandbox.reconcile()` — orphan containers are removed by existing logic

## Technical Considerations

- **5-minute age threshold** prevents cleaning up sessions that are actively starting (container boot + first SDK response can take ~30s, but 5 min is conservative)
- **Named envs with empty sessions**: If a user creates a named env but never sends a message, it will be cleaned after 5 min. This is acceptable — named envs are recreated on next use.
- **Stop vs remove on shutdown**: `docker stop` (not `rm`) preserves container state. `ensure_container()` restarts them on next use via `docker start`. This is intentional — no data loss.
- **Short stop timeout**: 5s grace on shutdown vs normal 10s. Containers are idle (`sleep infinity`), so SIGTERM is sufficient.
- **Error handling**: Stop/cleanup errors are logged as warnings, never crash the server.

## Files to Change

| File | Change |
|------|--------|
| `computer/parachute/db/database.py` | Add `list_orphan_container_env_slugs(min_age_minutes)` |
| `computer/parachute/core/sandbox.py` | Add `stop_all_env_containers()` |
| `computer/parachute/core/orchestrator.py` | Call orphan cleanup in `reconcile_containers()` |
| `computer/parachute/server.py` | Call `stop_all_env_containers()` in lifespan shutdown |

## Out of Scope

- **Idle timeout**: Containers that have been unused for N minutes could be stopped. Deferred — the shutdown fix reduces idle accumulation significantly.
- **Config hash stale detection**: Containers with old config hashes could be rebuilt on reconcile. Deferred — manual rebuild via Settings works for now.
- **Named env lifecycle UI**: Explicit "stop"/"delete" controls in the Flutter app. Deferred.
