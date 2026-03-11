---
issue: 'TBD'
type: plan
status: draft
---

# Caller State → Graph Migration & Legacy Path Cleanup

## Context

`DailyAgentState` stores runtime state (`sdk_session_id`, `last_run_at`, `run_count`, `last_processed_date`) in JSON files at `~/Parachute/Daily/.{agent_name}/state.json`. This is wrong for two reasons:

1. **The vault `Daily/` folder no longer exists as a concept.** Callers are graph nodes — their state should live there too.
2. **File I/O is slower and more fragile.** We already had to wrap it in `asyncio.to_thread()` to avoid blocking. Graph SET queries are async-native.

Additionally, legacy vault paths (`Daily/.agents/`, `Daily/journals/`, `Parachute/Daily/journals/`) are hardcoded in the codebase. These paths no longer exist and will cause confusion or silent failures. The flexible import system already accepts user-specified `source_dir`, making the auto-scan paths unnecessary and potentially harmful.

## Phase 1: Add state fields to Caller graph node

**File:** `computer/modules/daily/module.py`

Add new columns to the Caller table schema in `on_load()`:

```python
"sdk_session_id": "STRING",      # Claude SDK session ID for resume
"last_run_at": "STRING",         # ISO timestamp of last run
"last_processed_date": "STRING", # YYYY-MM-DD of last processed journal date
"run_count": "INT64",            # Total number of runs
```

Add migration in `_ensure_new_columns()` for existing databases:

```python
caller_new_cols = {
    "sdk_session_id": ("STRING", "DEFAULT ''"),
    "last_run_at": ("STRING", "DEFAULT ''"),
    "last_processed_date": ("STRING", "DEFAULT ''"),
    "run_count": ("INT64", "DEFAULT 0"),
}
```

## Phase 2: Replace DailyAgentState with graph operations

**File:** `computer/parachute/core/daily_agent.py`

Delete the `DailyAgentState` class entirely. Replace with two async helper functions:

```python
async def _load_caller_state(graph, agent_name: str) -> dict:
    """Load runtime state fields from the Caller graph node."""
    rows = await graph.execute_cypher(
        "MATCH (c:Caller {name: $name}) "
        "RETURN c.sdk_session_id AS sdk_session_id, "
        "       c.last_run_at AS last_run_at, "
        "       c.last_processed_date AS last_processed_date, "
        "       c.run_count AS run_count",
        {"name": agent_name},
    )
    if not rows:
        return {"sdk_session_id": None, "last_run_at": None, "last_processed_date": None, "run_count": 0}
    row = rows[0]
    return {
        "sdk_session_id": row.get("sdk_session_id") or None,
        "last_run_at": row.get("last_run_at") or None,
        "last_processed_date": row.get("last_processed_date") or None,
        "run_count": row.get("run_count") or 0,
    }

async def _record_caller_run(graph, agent_name: str, date: str,
                              session_id: str | None, model: str | None) -> None:
    """Record a completed run on the Caller node."""
    now = datetime.now(timezone.utc).isoformat()
    run_count_rows = await graph.execute_cypher(
        "MATCH (c:Caller {name: $name}) RETURN c.run_count AS rc",
        {"name": agent_name},
    )
    current_count = (run_count_rows[0].get("rc") or 0) if run_count_rows else 0
    await graph.execute_cypher(
        "MATCH (c:Caller {name: $name}) "
        "SET c.sdk_session_id = $sid, c.last_run_at = $now, "
        "    c.last_processed_date = $date, c.run_count = $rc",
        {
            "name": agent_name,
            "sid": session_id or "",
            "now": now,
            "date": date,
            "rc": current_count + 1,
        },
    )

async def _clear_caller_session(graph, agent_name: str) -> None:
    """Clear sdk_session_id on resume failure."""
    await graph.execute_cypher(
        "MATCH (c:Caller {name: $name}) SET c.sdk_session_id = ''",
        {"name": agent_name},
    )
```

Update `run_daily_agent()`:
- Replace `state = DailyAgentState(...)` / `state.load()` with `caller_state = await _load_caller_state(graph, agent_name)`
- Replace `state.last_processed_date` check with `caller_state["last_processed_date"]`
- Pass `caller_state` dict (not `state` object) to `_run_sandboxed` and `_run_direct`

Update `_run_sandboxed()`:
- Change `state: DailyAgentState` parameter to `caller_state: dict`
- Replace `state.sdk_session_id` reads with `caller_state["sdk_session_id"]`
- Replace `state.sdk_session_id = None; state.save()` with `await _clear_caller_session(graph, agent_name)`
- Replace `state.record_run(...)` with `await _record_caller_run(graph, agent_name, ...)`

Update `_run_direct()`:
- Same changes as `_run_sandboxed()`
- In `run_query_with_retry`, replace file-based session clear with `await _clear_caller_session(graph, agent_name)`

## Phase 3: Update reset endpoint

**File:** `computer/modules/daily/module.py`

Replace the file-based reset with a graph SET:

```python
@router.post("/callers/{name}/reset", status_code=200)
async def reset_caller(name: str):
    if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,63}", name):
        return JSONResponse(status_code=400, content={"error": "invalid caller name format"})
    graph = self._get_graph()
    if graph is None:
        return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
    rows = await graph.execute_cypher(
        "MATCH (c:Caller {name: $name}) RETURN c", {"name": name}
    )
    if not rows:
        return JSONResponse(status_code=404, content={"error": "not found"})
    await graph.execute_cypher(
        "MATCH (c:Caller {name: $name}) SET c.sdk_session_id = ''",
        {"name": name},
    )
    return {"status": "reset", "agent": name}
```

No more `DailyAgentState` import, no more `asyncio.to_thread()`.

## Phase 4: Remove legacy vault paths

### 4a. Remove `_migrate_callers_from_vault()`

**File:** `computer/modules/daily/module.py`

- Delete the `_migrate_callers_from_vault()` function (lines 135-175)
- Remove the call in `on_load()` (line 256)
- Callers are created via the `/callers` API; the .md-file migration is a completed one-time operation

### 4b. Remove vault file fallbacks from discovery

**File:** `computer/parachute/core/daily_agent.py`

- `discover_daily_agents()`: Remove the fallback block that scans `vault_path / "Daily" / ".agents"`. If graph fails, return empty list.
- `get_daily_agent_config()`: Remove fallback to `vault_path / "Daily" / ".agents" / f"{agent_name}.md"`. Return None if graph fails.
- `DailyAgentConfig.from_file()`: Delete entirely (no longer called)
- `DailyAgentConfig.source_file`: Remove field
- `DailyAgentConfig.output_path` / `get_output_path()`: Remove (callers write Cards to graph, not files)
- Remove `import frontmatter` if no longer used

### 4c. Remove legacy journal discovery paths

**File:** `computer/modules/daily/module.py`

- `_find_legacy_md_files()`: Remove the `Parachute/Daily/journals` path from the search list. Keep only `Daily/journals` since the old-format import endpoints still use it.
  - Actually, reconsider: if `Daily/journals` also doesn't exist anymore, remove the whole method and the `/import` and `/import/status` endpoints that depend on it. **Ask user**: do these old-format import endpoints still serve a purpose, or has the flexible import fully replaced them?
- Update docstring at top of module.py to remove references to `~/Parachute/Daily/journals/`

### 4d. Clean up module.py docstring

Update the module-level docstring to remove:
```
  ~/Parachute/Daily/journals/    ← Pre-restructure markdown files (importable on request)
```

And update the daily_agent.py module docstring to remove references to `Daily/.agents/{name}.md`.

## Phase 5: Build and test

- `flutter build macos` — verify app still compiles
- `python -m pytest` — run backend tests
- Manual check: server starts, `/api/daily/callers` returns callers with new state fields
- Verify reset endpoint works without file I/O

## Acceptance criteria

- [ ] `DailyAgentState` class deleted — no file-based state
- [ ] `sdk_session_id`, `last_run_at`, `last_processed_date`, `run_count` live on Caller graph node
- [ ] Reset endpoint uses graph SET, no file I/O
- [ ] No references to `~/Parachute/Daily/` as a live path
- [ ] No vault file fallback in agent discovery
- [ ] `DailyAgentConfig.from_file()` deleted
- [ ] Server starts and callers endpoint returns state fields
- [ ] App builds clean
