---
title: "feat(daily): DailyAgent workflow — AgentCard graph nodes linked to Day"
type: feat
date: 2026-03-04
issue: 179
---

# DailyAgent Workflow — AgentCard Graph Nodes

Replace vault-file-based agent output storage with `AgentCard` graph nodes linked to `Day`. Eliminates three FSS-dependent Flutter services and the file-sync dance; Flutter fetches cards via `GET /api/daily/agent-cards?date=`.

## Acceptance Criteria

- [ ] `AgentCard` node table and `HAS_AGENT_CARD` rel table in the daily graph schema
- [ ] `write_output` tool (in `daily_agent_tools.py`) writes `AgentCard` to graph instead of vault markdown file
- [ ] `read_journal` tool queries the graph instead of reading vault markdown files
- [ ] `GET /api/daily/agents` returns all discovered agent configs as JSON
- [ ] `GET /api/daily/agent-cards?date=YYYY-MM-DD` returns all `AgentCard` nodes for a day
- [ ] `GET /api/daily/agent-cards/{name}?date=YYYY-MM-DD` returns a single card
- [ ] `POST /api/daily/agent-cards/{name}/run` triggers `run_daily_agent()` for a date
- [ ] Flutter `agentCardsProvider` fetches from API — no `LocalAgentConfigService`, `AgentOutputService`, or `ReflectionService` reading local files
- [ ] Reflection renders in journal day view with same visual treatment as today

## Context

### Current architecture (more complete than the issue suggests)

```
computer/parachute/core/daily_agent.py        — DailyAgentConfig, DailyAgentState, run_daily_agent()
computer/parachute/core/daily_agent_tools.py  — read_journal, read_chat_log, write_output (vault-based)
computer/parachute/core/scheduler.py          — discover_daily_agents(), schedule cron jobs
computer/modules/daily/module.py              — journal API (no agent routes yet)
```

**`write_output` tool** (the critical target) writes to `vault_path / "Daily" / "{name}" / "{date}.md"` with YAML frontmatter. This is what we're replacing with a graph write.

**`read_journal` tool** reads `vault_path / "Daily" / "journals" / "{date}.md"`. Since PR #171 moved storage to the graph, new journal entries are NOT in these files. This must be fixed in the same PR — otherwise the reflection agent has incomplete context.

**`DailyAgentState`** stores SDK session ID and run history in `vault_path / "Daily" / ".{agent_name}" / "state.json"`. This is server infrastructure state (not user-facing data) and can remain in vault files for now.

**Flutter** already has `ComputerService.getDailyAgents()`, `triggerDailyAgent()`, `getDailyAgentsStatus()` calling `/api/modules/daily/agents/*` but these routes don't exist in `module.py` — they're dead code today.

**Three FSS-dependent services to remove:**
| Service | Vault path read | Flutter provider |
|---------|----------------|------------------|
| `LocalAgentConfigService` | `Daily/.agents/*.md` | `localAgentConfigServiceFutureProvider` → `localAgentConfigsProvider` |
| `AgentOutputService` | `Daily/{output-dir}/{date}.md` | `agentOutputServiceFutureProvider` → `agentOutputsForDateProvider` |
| `ReflectionService` | `Daily/reflections/{date}.md` | `reflectionServiceFutureProvider` → `selectedReflectionProvider` |

The `agentLoadingStatusProvider` in `journal_providers.dart` is an elaborate state machine (ready/checking/pulling/notAvailable/offline) that exists because syncing files across devices is complex. It collapses into a simple `FutureProvider` once output is graph-backed.

## Implementation Phases

### Phase 1 — Server: Graph schema additions (module.py)

In `DailyModule.on_load()`, after existing `ensure_node_table` calls:

```python
await graph.ensure_node_table(
    "AgentCard",
    {
        "card_id": "STRING",       # PK: "{agent_name}:{date}" for idempotent MERGE
        "agent_name": "STRING",
        "display_name": "STRING",
        "content": "STRING",       # markdown body
        "generated_at": "STRING",  # ISO timestamp
        "status": "STRING",        # "running" | "done" | "failed"
        "date": "STRING",          # YYYY-MM-DD (the day this card is for)
    },
    primary_key="card_id",
)
await graph.ensure_rel_table("HAS_AGENT_CARD", "Day", "AgentCard")
```

### Phase 2 — Server: Update agent tools (daily_agent_tools.py)

**`write_output` tool**: Accept a `graph` parameter (passed in at tool creation time via closure). Write `AgentCard` to graph instead of markdown file:

```python
# card_id is deterministic: enables idempotent MERGE
card_id = f"{config.name}:{date_str}"
await graph.execute_cypher("""
    MERGE (c:AgentCard {card_id: $card_id})
    SET c.agent_name = $agent_name,
        c.display_name = $display_name,
        c.content = $content,
        c.generated_at = $generated_at,
        c.status = 'done',
        c.date = $date
""", {"card_id": card_id, ...})

# Link to Day node (MERGE Day first for idempotency)
await graph.execute_cypher("""
    MERGE (d:Day {date: $date})
    WITH d
    MATCH (c:AgentCard {card_id: $card_id})
    MERGE (d)-[:HAS_AGENT_CARD]->(c)
""", {...})
```

Signature change in `create_daily_agent_tools()`:
```python
def create_daily_agent_tools(
    vault_path: Path,
    config: DailyAgentConfig,
    graph=None,   # ← new optional arg
) -> tuple[list, dict]:
```

**`read_journal` tool**: Update to query graph instead of reading markdown file:

```python
# Query journal entries for the date from graph
rows = await graph.execute_cypher(
    "MATCH (e:Journal_Entry) WHERE e.date = $date "
    "RETURN e.content AS content ORDER BY e.created_at ASC",
    {"date": date_str}
)
entries_text = "\n\n---\n\n".join(r["content"] for r in rows if r.get("content"))
```

Keep vault-file fallback (try graph first, fall back to markdown if graph unavailable).

**`daily_agent.py`**: Pass graph instance when calling `create_daily_agent_tools()`:

```python
from parachute.core.daily_agent_tools import create_daily_agent_tools

# In run_daily_agent():
if create_tools_fn:
    _tools, agent_mcp_config = await create_tools_fn(vault_path, config)
else:
    graph = _get_graph_for_vault(vault_path)  # new helper
    _tools, agent_mcp_config = create_daily_agent_tools(vault_path, config, graph=graph)
```

### Phase 3 — Server: New API routes (module.py)

Add to `DailyModule.get_router()`:

```python
# ── Agents ──────────────────────────────────────────────────────────────

@router.get("/agents")
async def list_agents():
    """List all configured daily agents."""
    from parachute.core.daily_agent import discover_daily_agents
    agents = discover_daily_agents(self.vault_path)
    return {
        "agents": [
            {
                "name": a.name,
                "display_name": a.display_name,
                "description": a.description,
                "schedule_enabled": a.schedule_enabled,
                "schedule_time": a.schedule_time,
            }
            for a in agents
        ]
    }

@router.get("/agent-cards")
async def list_agent_cards(date: str | None = Query(None)):
    """Fetch all AgentCard nodes, optionally filtered by date."""
    graph = self._get_graph()
    if graph is None:
        return JSONResponse(status_code=503, content={"error": "GraphDB not available"})
    if date:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
            return JSONResponse(status_code=400, content={"error": "invalid date"})
        rows = await graph.execute_cypher(
            "MATCH (c:AgentCard) WHERE c.date = $date RETURN c ORDER BY c.generated_at ASC",
            {"date": date}
        )
    else:
        rows = await graph.execute_cypher(
            "MATCH (c:AgentCard) RETURN c ORDER BY c.generated_at DESC"
        )
    return {"cards": [r["c"] for r in rows], "count": len(rows)}

@router.get("/agent-cards/{agent_name}")
async def get_agent_card(agent_name: str, date: str | None = Query(None)):
    """Get a specific agent's card for a date."""
    ...

@router.post("/agent-cards/{agent_name}/run", status_code=202)
async def run_agent(agent_name: str, date: str | None = None, force: bool = False):
    """Trigger an agent run for a date (async — returns immediately)."""
    import asyncio
    from parachute.core.daily_agent import run_daily_agent
    # Fire and forget — long-running
    asyncio.create_task(run_daily_agent(self.vault_path, agent_name, date=date, force=force))
    return {"status": "started", "agent": agent_name, "date": date}
```

### Phase 4 — Flutter: New AgentCard model + API methods

**New file: `app/lib/features/daily/journal/models/agent_card.dart`**

```dart
class AgentCard {
  final String cardId;       // "{agent_name}:{date}"
  final String agentName;
  final String displayName;
  final String content;      // markdown
  final String status;       // "running" | "done" | "failed"
  final DateTime? generatedAt;
  final String date;

  // fromJson, copyWith
}
```

**`DailyApiService` additions:**

```dart
Future<List<AgentCard>> fetchAgentCards(String date) async { ... }
Future<List<DailyAgentInfo>> fetchAgents() async { ... }
Future<bool> triggerAgentRun(String agentName, {String? date}) async { ... }
```

### Phase 5 — Flutter: Replace providers

**`journal_providers.dart` — remove:**
- `reflectionServiceFutureProvider`
- `selectedReflectionProvider`
- `localAgentConfigServiceFutureProvider`
- `agentOutputServiceFutureProvider`
- `localAgentConfigsProvider`
- `agentOutputsProvider`
- `agentOutputsForDateProvider`
- `agentLoadingStatusProvider` (the complex state machine)
- `AgentLoadingState` enum, `AgentLoadingStatus` class

**Add:**
```dart
/// Fetch all AgentCard nodes for a date from the server.
final agentCardsProvider = FutureProvider.autoDispose.family<List<AgentCard>, String>((ref, dateStr) async {
  final api = ref.watch(dailyApiServiceProvider);
  return api.fetchAgentCards(dateStr) ?? const [];
});

/// Fetch registered agent configs (for UI enumeration).
final dailyAgentsProvider = FutureProvider.autoDispose<List<DailyAgentInfo>>((ref) async {
  final api = ref.watch(dailyApiServiceProvider);
  return api.fetchAgents() ?? const [];
});
```

**Update journal day view** to render `AgentCard` nodes. Current `selectedReflectionProvider` consumers should switch to `agentCardsProvider(dateStr).value?.where((c) => c.agentName == 'reflection').firstOrNull`.

### Phase 6 — Flutter: Remove file-based services

Delete these files (their functionality is replaced by `agentCardsProvider`):
- `app/lib/features/daily/journal/services/reflection_service.dart`
- `app/lib/features/daily/journal/services/agent_output_service.dart`
- `app/lib/features/daily/journal/services/local_agent_config_service.dart`
- Related models: `app/lib/features/daily/journal/models/reflection.dart`, `agent_output.dart` (check usages first — `agent_output.dart` also defines `DailyAgentConfig` used in Flutter)

Also remove from `journal_providers.dart`:
- Imports of the deleted services
- The FSS-dependent provider definitions

## Technical Considerations

### `run_agent` endpoint fire-and-forget vs awaited

`run_daily_agent()` can take minutes (SDK round-trip + Claude API). The `POST /agent-cards/{name}/run` endpoint should return 202 Accepted immediately and run the task in the background. Flutter can poll `GET /agent-cards/{name}?date=` to see when `status` changes from `"running"` to `"done"`.

The `AgentCard` with `status: "running"` should be written to the graph at the START of `write_output`, before the content is available. Actually, better: write `status: "running"` in `run_daily_agent()` at the start of the agent run, then update to `status: "done"` when `write_output` is called.

### DailyAgentState stays vault-based

State (`sdk_session_id`, `last_processed_date`) lives in `Daily/.{agent_name}/state.json`. This is server infrastructure — no vault path dependency on the Flutter side. Leave it alone.

### read_journal graph fallback

If the graph is unavailable, `read_journal` should fall back to the markdown file. After a transition period, the fallback can be removed.

### card_id design

`card_id = f"{agent_name}:{date}"` is deterministic. This means:
- MERGEing is idempotent (re-running an agent for the same date updates the card)
- One card per agent per day (the reflection card is the card for that day)
- If we ever want multiple runs visible, the PK would need to change

### `ComputerService` methods already exist in Flutter

`getDailyAgents()`, `triggerDailyAgent()`, and `getDailyAgentsStatus()` already exist in `computer_service.dart` calling `/api/modules/daily/agents/*`. These call the module system's namespace, not the daily module's namespace (`/api/daily/agents`). These either need to be updated to use the new endpoints or removed. The new `DailyApiService` methods (which use `/api/daily/*`) are the right layer for this — `ComputerService` stubs can be removed.

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| `read_journal` reading from graph misses entries before graph migration | Keep vault-file fallback; run import before first agent run |
| `run_agent` 202 fire-and-forget leaves no progress signal | Write `AgentCard {status: "running"}` at start; Flutter polls |
| `card_id` collision if agent runs twice for same day | MERGE semantics update in place — intentional, only latest run visible |
| `DailyAgentState` still writes to vault path | Acceptable for now — server-only state, no Flutter dependency |

## References

- `computer/parachute/core/daily_agent.py` — `run_daily_agent()`, `DailyAgentConfig`, `DailyAgentState`
- `computer/parachute/core/daily_agent_tools.py` — `write_output` (target), `read_journal` (must update)
- `computer/modules/daily/module.py` — graph schema init, new routes go here
- `app/lib/features/daily/journal/providers/journal_providers.dart` — providers to replace (lines 178–440)
- `app/lib/core/services/computer_service.dart:168` — existing `getDailyAgents()` stubs to remove
- `app/lib/features/daily/journal/screens/journal_screen.dart` — renders reflection/agent output (check `selectedReflectionProvider` usages)
