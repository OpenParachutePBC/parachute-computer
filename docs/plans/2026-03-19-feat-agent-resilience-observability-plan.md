---
title: "Agent Resilience, Observability, and Container Integration"
type: feat
date: 2026-03-19
issue: 296
---

# Agent Resilience, Observability, and Container Integration

Fix the daily reflection agent's silent failure, add agent run history with viewable logs, and properly integrate agents with the container primitive.

## Problem Statement

The daily reflection agent has been silently failing since creation. The root cause: `daily_agent.py` passes `agent-daily-reflection` (a slug) as both `session_id` and `container_slug`. The entrypoint passes this slug as `--session-id` to the Claude CLI, which now requires UUIDs. Every run fails with "Invalid session ID. Must be a valid UUID" — but this error is swallowed into a generic "Command failed with exit code 1" and never surfaces in the app.

Beyond the immediate bug, the system lacks agent run history and proper container integration. Agents auto-create invisible containers, can't target existing named containers, and leave no trace when they fail.

## Acceptance Criteria

- [ ] Daily reflection agent runs successfully (UUID session IDs, not slugs)
- [ ] Every agent run (scheduled, triggered, manual) creates an `AgentRun` graph node with status, error, duration, container, session ID
- [ ] Failed agent runs are visible in the Flutter app with the actual error message
- [ ] "View Log" on a failed (or successful) run opens the agent's SDK transcript / event log
- [ ] Agent config includes a `container_slug` field — defaults to dedicated container, selectable from named containers
- [ ] Agent edit screen exposes container selection
- [ ] Session ID and container slug are cleanly separated throughout the stack
- [ ] Daemon logs at `~/Library/Logs/Parachute/stdout.log` are confirmed working and accessible via `parachute logs`

## Proposed Solution

### Phase 1: Fix the UUID Bug + Error Propagation (Backend)

**Files**: `computer/parachute/core/daily_agent.py`, `computer/parachute/docker/entrypoint.py`

**1a. Separate session ID from container slug in `_run_sandboxed`** (daily_agent.py)

Currently (line 344-356):
```python
slug = f"agent-{agent_name}"
# slug used as session_id, container_slug, and token context session_id
```

Change to:
```python
container_slug = f"agent-{agent_name}"  # persistent, human-readable
run_session_id = str(uuid.uuid4())       # per-run, UUID format
```

Pass `container_slug` for container operations and `run_session_id` for SDK session tracking. The `AgentSandboxConfig.session_id` field should receive the UUID, not the slug. The container slug goes to `container_slug=` parameter of `sandbox.run_session()`.

**1b. Fix entrypoint session ID handling** (entrypoint.py)

Line 303-304 currently passes `PARACHUTE_SESSION_ID` (the slug) as `--session-id`. Two options:
- **Option A**: Don't pass `--session-id` at all when not resuming — let the CLI generate its own UUID. This is what `_run_direct` does and it works.
- **Option B**: Generate a UUID in the entrypoint if `PARACHUTE_SESSION_ID` isn't already a valid UUID.

Recommend **Option A** — simpler, matches direct mode behavior. The captured session ID comes back from the SDK's SystemMessage event and gets recorded by the orchestrator.

**1c. Improve error propagation in entrypoint** (entrypoint.py)

Lines 324-332: The generic exception handler wraps the SDK's `ProcessError` which itself wraps the CLI's stderr. The actual error message ("Invalid session ID") is in `e.stderr` but gets templated into a generic string.

Fix: when the exception has a `stderr` attribute, extract the meaningful part:
```python
error_detail = str(e)
if hasattr(e, "stderr") and e.stderr:
    # SDK ProcessError.stderr contains the CLI's actual error
    error_detail = e.stderr.strip()
```

**1d. Propagate stderr through sandbox events** (sandbox.py)

Line 490 logs stderr but the yielded `exit_error` event doesn't include it. Line 896-898 converts to a generic "Sandbox error (exit N)". Include stderr in the error event:
```python
yield {"type": "exit_error", "returncode": proc.returncode, "stderr": stderr_data.decode()}
```

And in `_run_in_container` line 898:
```python
yield {"type": "error", "error": f"Sandbox error (exit {returncode}): {event.get('stderr', '')}".strip()}
```

### Phase 2: Agent Run History (Backend)

**Files**: `computer/parachute/core/daily_agent.py`, `computer/modules/daily/module.py`

**2a. Create AgentRun graph nodes**

Add a helper function `_record_agent_run_event` that writes an `AgentRun` node to the graph on every invocation:

```
AgentRun node:
  run_id: str (UUID)
  agent_name: str
  date: str (journal date)
  trigger: str ("scheduled" | "event" | "manual")
  status: str ("running" → "completed" | "failed" | "timeout" | "completed_no_output")
  error: str | null (actual error message if failed)
  container_slug: str
  sdk_session_id: str | null (captured from SDK)
  card_id: str | null (if output was written)
  started_at: str (ISO timestamp)
  completed_at: str | null
  duration_seconds: float | null
```

Call at two points:
1. **Start of run**: Create with `status='running'`, `started_at=now`
2. **End of run** (success or failure): Update with final status, error, duration, session ID

Connect via relationship: `(Agent)-[:HAS_RUN]->(AgentRun)`

**2b. API endpoint for agent run history**

Add `GET /api/daily/agents/{agent_name}/runs` to `modules/daily/module.py`:
- Returns recent runs (last 20 by default, `?limit=N`)
- Each run includes: run_id, date, trigger, status, error, duration, card_id, started_at
- Sorted by `started_at` descending

**2c. API endpoint for agent run log**

Add `GET /api/daily/agents/{agent_name}/runs/{run_id}/log`:
- If the run has an `sdk_session_id`, read the SDK transcript JSONL file
- Return structured events (thinking, tool_use, tool_result, text, error)
- If no transcript available, return just the run metadata + error message
- This is the data source for "View Log" in the app

### Phase 3: Agent Container Integration (Backend)

**Files**: `computer/parachute/core/daily_agent.py`, `computer/modules/daily/module.py`

**3a. Add `container_slug` to Agent graph schema**

Add column `container_slug` to the Agent node. Default `null` means "use dedicated `agent-{name}` container."

Update `get_daily_agent_config` (daily_agent.py) to read this field.
Update agent CRUD endpoints to accept and return `container_slug`.

**3b. Use configured container in `_run_sandboxed`**

Replace hardcoded `slug = f"agent-{agent_name}"` with:
```python
container_slug = config.container_slug or f"agent-{agent_name}"
```

The rest of the container creation/reuse logic stays the same — `ensure_container` already handles existing containers.

**3c. Validate container exists for non-default targets**

When `container_slug` is explicitly set (not the auto-generated default), verify the container exists before attempting to run. Return a clear error if not: "Container '{slug}' not found — create it or clear the agent's container setting."

### Phase 4: Flutter UI (App)

**Files**: `app/lib/features/daily/journal/` (services, widgets, screens, providers)

**4a. Agent run history in the API service**

Add to `DailyApiService`:
- `fetchAgentRuns(agentName, {limit})` → `GET /api/daily/agents/{name}/runs`
- `fetchAgentRunLog(agentName, runId)` → `GET /api/daily/agents/{name}/runs/{runId}/log`

**4b. Show failed scheduled runs on the agent trigger card**

In `AgentTriggerCard`, when the card is in "ready" state (no output yet), check for recent failed runs:
- Fetch latest run via the runs API
- If latest run is `status: "failed"`, show error state with the actual error message
- Include "View Log" button that opens the run log
- Keep "Retry" button to manually re-trigger

States become:
1. Disconnected (server offline)
2. Ready (never run, or last run succeeded and produced output)
3. Failed (last run failed — show error + View Log + Retry)
4. Loading (currently running)
5. Success (just completed)

**4c. Agent run log viewer**

New widget/screen: `AgentRunLogScreen` (or bottom sheet)
- Shows the structured event stream from the run log API
- Thinking blocks collapsed by default
- Tool use / tool result pairs shown
- Error events highlighted
- Reuses patterns from existing chat message display where applicable

**4d. Container picker in agent edit screen**

Add to `AgentEditScreen`:
- New "Container" section below the schedule/memory sections
- Dropdown/picker showing: "Dedicated (default)" + list of named containers
- Fetches named containers from `/api/containers` (or equivalent)
- Saves `container_slug` field on the agent

### Phase 5: Daemon Log Verification

**Files**: `computer/parachute/daemon.py`

**5a. Verify launchd log routing works**

The plist sets `StandardOutPath` and `StandardErrorPath` to `~/Library/Logs/Parachute/`. Investigation showed these files DO exist and ARE being written to (8MB stdout.log, 442KB stderr.log). The initial diagnosis of "empty logs" was the vault's `.parachute/logs/` directory (which is empty) — a different path.

Confirm that `parachute logs` reads from the correct location (`~/Library/Logs/Parachute/stdout.log`, not `~/.parachute/logs/`). If it reads the wrong path, fix the `logs` CLI command.

**5b. Log rotation**

stdout.log is 8MB and growing with no rotation. Add a note/TODO — not blocking for this issue, but worth addressing. logrotate config or size-based truncation on server restart.

## Technical Considerations

### Graph Schema Changes

New `AgentRun` node table needs to be created. Use the same `ALTER TABLE ADD COLUMN` pattern used for other schema evolution — check if table exists, create if not.

The `Agent` node gains one new column: `container_slug TEXT DEFAULT ''`.

### SDK Transcript Location

Transcripts for sandboxed agents live in the container's home directory:
`vault/.parachute/sandbox/envs/{slug}/home/.claude/projects/*/sessions/`

The run log endpoint needs to know how to find them. The `sdk_session_id` from the run record + the container slug gives the path.

### Backward Compatibility

- Existing agents with no `container_slug` use the default dedicated container (no behavior change)
- Existing cards are unaffected — `AgentRun` is a new node type alongside `Card`
- API changes are additive (new endpoints, new fields on existing responses)

## Dependencies & Risks

- **Graph schema migration**: Adding `AgentRun` table and `container_slug` column to `Agent`. Low risk — additive changes.
- **Container existence validation**: If an agent targets a container that gets deleted, it should fail clearly. The validation in 3c handles this.
- **Transcript file discovery**: Finding SDK transcripts inside container home dirs may require path resolution logic. The transcript path convention is already established.

## Implementation Order

Phase 1 is the critical fix — the daily reflection agent will work after this. Phase 2 (run history) is the observability foundation. Phase 3 (container integration) and Phase 4 (Flutter UI) can proceed in parallel once the backend pieces are in place. Phase 5 is a verification task.

Recommended sequence: **1 → 2 → 3+4 → 5**

## References

- Brainstorm: `docs/brainstorms/2026-03-19-agent-resilience-observability-brainstorm.md`
- Agent Primitive: #280
- Container Primitive: #264
- Agent Completion Notifications: #272
- Current agent execution: `computer/parachute/core/daily_agent.py`
- Sandbox runner: `computer/parachute/core/sandbox.py`
- Container entrypoint: `computer/parachute/docker/entrypoint.py`
- Flutter agent UI: `app/lib/features/daily/journal/widgets/agent_trigger_card.dart`
- Flutter agent edit: `app/lib/features/daily/journal/screens/agent_edit_screen.dart`
