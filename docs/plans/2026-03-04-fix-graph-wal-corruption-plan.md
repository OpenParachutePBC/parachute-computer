---
title: Graph WAL corruption — checkpoint strategy + clean shutdown backup
type: fix
date: 2026-03-04
issue: 175
---

# Graph WAL Corruption — Checkpoint Strategy + Clean Shutdown Backup

An unclean server shutdown (kill -9, power loss, OS crash) can leave the LadybugDB WAL in a dirty state. On next startup, LadybugDB rolls back — potentially wiping all Journal_Entry, Day, Chat_Exchange, and session nodes written since the last WAL flush. The failure is silent to the user. Now that graph is core infrastructure (not just the Brain module), the blast radius is everything.

## Problem Statement

LadybugDB (Kuzu) uses a write-ahead log. The WAL is flushed to the main DB file only at explicit checkpoints (or at connection close). Between checkpoints, all writes exist only in the WAL file. If the WAL is corrupted on unclean shutdown, those writes are lost.

`connect()` in `graph.py` already detects corrupt WAL at startup and backs it up before retrying — but this means the data is gone, just not silently.

## Proposed Solution

Three-layer defence:

### Part A — Checkpoint on clean shutdown (highest bang/line)

Add `CHECKPOINT` Cypher execution to `GraphService.close()` before `self._conn.close()`. This flushes WAL → main DB file. The lifespan shutdown in `server.py` already calls `await app.state.graph.close()`, so this is zero additional wiring.

```python
async def close(self) -> None:
    """Close the database connection, checkpointing WAL first."""
    if self._conn is not None:
        try:
            await self._conn.execute("CHECKPOINT")
            logger.info("GraphService: WAL checkpointed on shutdown")
        except Exception as e:
            logger.warning(f"GraphService: checkpoint failed: {e}")
        try:
            self._conn.close()
        except Exception as e:
            logger.warning(f"GraphService: error closing connection: {e}")
    self._connected = False
    self._conn = None
    self._db = None
```

### Part B — Periodic checkpoint (background task)

Register an `asyncio.Task` in `GraphService` that runs `CHECKPOINT` every 5 minutes while the server is running. This caps the WAL rollback window at ~5 minutes of writes rather than the full uptime.

- `GraphService.start_checkpoint_loop(interval_seconds=300)` — starts background task
- `GraphService.stop_checkpoint_loop()` — cancels task, called in `close()`
- Task runs `await self._conn.execute("CHECKPOINT")` and logs any failure (never raises)
- Server lifespan calls `graph.start_checkpoint_loop()` after `graph.connect()`

### Part C — JSONL redo log for daily entries

The CHECKPOINT approach reduces risk but doesn't eliminate it for power-loss scenarios. For daily journal entries specifically (irreplaceable personal data), append each new entry to a compact JSONL file at `~/.parachute/daily/entries.jsonl` immediately after the graph write.

On server startup, after graph and daily module init, check: if `Journal_Entry` table is empty and `entries.jsonl` exists with records, offer auto-recovery by replaying the JSONL (same path as `POST /api/daily/import` but from local file). Log a warning if recovery is performed.

**JSONL record shape** (minimal, human-readable):
```json
{"id": "2026-03-04T10:00:00", "date": "2026-03-04", "content": "...", "metadata": {...}}
```

File location: `~/.parachute/daily/entries.jsonl` (one record per line, append-only).

Rolling: truncate entries older than 90 days on each startup (keep file manageable).

## Acceptance Criteria

- [ ] `parachute server stop` + `parachute server start` does not lose any data that was written before the stop
- [ ] Unclean shutdown (simulated via `kill -9 $(parachute server pid)`) loses at most ~5 minutes of writes
- [ ] If WAL corruption is detected on startup and data is lost, server logs a clear warning with entry count from JSONL redo log, and auto-replays the redo log if Journal_Entry table is empty
- [ ] JSONL redo log exists and contains all entries written in the last 90 days
- [ ] All existing tests pass

## Files to Change

| File | Change |
|------|--------|
| `computer/parachute/db/graph.py` | Add `CHECKPOINT` to `close()`, add `start_checkpoint_loop()` / `stop_checkpoint_loop()` |
| `computer/parachute/server.py` | Call `graph.start_checkpoint_loop()` after `graph.connect()` |
| `computer/modules/daily/module.py` | Append to `entries.jsonl` in `_write_to_graph()`, add startup recovery in `setup()` |

## Technical Notes

- `CHECKPOINT` is a valid Kuzu Cypher statement, executable via `conn.execute("CHECKPOINT")`
- LadybugDB `AsyncConnection` does not expose a direct checkpoint method — must use Cypher
- The background task must use `asyncio.Lock` (already `_write_lock`) to avoid concurrent checkpoint + write conflicts
- `close()` should cancel the checkpoint loop task before executing the final `CHECKPOINT` (to avoid double-checkpoint race)
- JSONL append should happen **outside** the write_lock (lock is for graph writes, not filesystem writes)

## Out of Scope

- Replication / remote backup
- Checkpoint for non-daily data (Chat_Exchange, session nodes) — the SDK JSONL transcripts already provide recovery for sessions; daily voice entries have no other backup
