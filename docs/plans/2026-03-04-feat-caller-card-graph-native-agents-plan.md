---
title: "Caller & Card — Graph-Native Agent Definitions"
type: feat
date: 2026-03-04
issue: 181
---

# Caller & Card — Graph-Native Agent Definitions

Move agent definitions from vault markdown files into the graph as `Caller` nodes. Rename `AgentCard` → `Card` throughout. Vault `.agents/*.md` files become stale artifacts.

## Acceptance Criteria

- [x] `Caller` node table exists in graph with all definition fields
- [x] On module startup, existing vault `.agents/*.md` files are MERGEd into graph (idempotent)
- [x] `discover_daily_agents()` and `get_daily_agent_config()` query graph, not filesystem
- [x] Scheduler bootstraps from graph-loaded callers
- [x] CRUD API at `/callers` (list, get, create, update, delete)
- [x] `AgentCard` → `Card`, `HAS_AGENT_CARD` → `HAS_CARD` renamed in graph + backend + Flutter
- [x] `flutter analyze` passes with no errors

## Key Files

| File | Change |
|------|--------|
| `computer/modules/daily/module.py` | Add `Caller` schema, migration, CRUD routes, rename `AgentCard`→`Card` |
| `computer/parachute/core/daily_agent.py` | `DailyAgentConfig.from_row()`, async `discover_daily_agents(graph)`, async `get_daily_agent_config(name, graph)` |
| `computer/parachute/core/scheduler.py` | Accept graph param, load callers from graph, make `reload_scheduler` async |
| `app/lib/features/daily/journal/models/agent_card.dart` → `card.dart` | Rename class |
| `app/lib/features/daily/journal/services/daily_api_service.dart` | URL changes, `fetchCallers` |
| `app/lib/features/daily/journal/providers/journal_providers.dart` | `agentCardsProvider` → `cardsProvider` |
| All widgets referencing `AgentCard` | Rename import + type |

## Implementation Phases

### Phase 1 — Graph Schema: `Caller` node

In `module.py`'s `on_load()`, add after the `AgentCard` (→ `Card`) table:

```python
await graph.ensure_node_table(
    "Caller",
    {
        "name": "STRING",            # PK: agent name, e.g. "reflection"
        "display_name": "STRING",
        "description": "STRING",
        "system_prompt": "STRING",   # full markdown body
        "tools": "STRING",           # JSON array string
        "model": "STRING",
        "schedule_enabled": "BOOLEAN",
        "schedule_time": "STRING",   # "HH:MM"
        "enabled": "BOOLEAN",
        "created_at": "STRING",
        "updated_at": "STRING",
    },
    primary_key="name",
)
```

Also in this phase: rename `AgentCard` → `Card` and `HAS_AGENT_CARD` → `HAS_CARD` in schema.

### Phase 2 — Migration: vault files → graph

New async function in `module.py` (or `daily_agent.py`):

```python
async def _migrate_callers_from_vault(vault_path: Path, graph) -> None:
    """Seed Caller nodes from vault .agents/*.md files. Idempotent MERGE."""
    agents_dir = vault_path / "Daily" / ".agents"
    if not agents_dir.exists():
        return
    for md_file in agents_dir.glob("*.md"):
        config = DailyAgentConfig.from_file(md_file)
        if config is None:
            continue
        await graph.execute_cypher(
            "MERGE (c:Caller {name: $name}) "
            "SET c.display_name = $display_name, c.description = $description, "
            "    c.system_prompt = $system_prompt, c.tools = $tools, "
            "    c.model = $model, c.schedule_enabled = $schedule_enabled, "
            "    c.schedule_time = $schedule_time, c.enabled = true, "
            "    c.updated_at = $now",
            {
                "name": config.name,
                "display_name": config.display_name,
                "description": config.description,
                "system_prompt": config.system_prompt,
                "tools": json.dumps(config.tools),
                "model": config.raw_metadata.get("model", ""),
                "schedule_enabled": config.schedule_enabled,
                "schedule_time": config.schedule_time,
                "now": datetime.now(timezone.utc).isoformat(),
            },
        )
        logger.info(f"Migrated caller: {config.name}")
```

Call `await _migrate_callers_from_vault(self.vault_path, graph)` in `on_load()`, after schema setup and before logging "graph schema ready".

### Phase 3 — Rewrite Discovery & Config Loading

**`daily_agent.py`** — add `from_row()` to `DailyAgentConfig`:

```python
@classmethod
def from_row(cls, row: dict) -> "DailyAgentConfig":
    """Build config from a Caller graph node row."""
    tools_raw = row.get("tools") or '["read_journal", "read_chat_log", "read_recent_journals"]'
    try:
        tools = json.loads(tools_raw)
    except (json.JSONDecodeError, TypeError):
        tools = ["read_journal", "read_chat_log", "read_recent_journals"]
    return cls(
        name=row["name"],
        display_name=row.get("display_name") or row["name"].replace("-", " ").title(),
        description=row.get("description") or "",
        system_prompt=row.get("system_prompt") or "",
        schedule_enabled=row.get("schedule_enabled", True),
        schedule_time=row.get("schedule_time") or "3:00",
        tools=tools,
        raw_metadata={"model": row.get("model", "")},
    )
```

Rewrite `discover_daily_agents` and `get_daily_agent_config` as async graph queries, falling back to vault file scan if graph is unavailable:

```python
async def discover_daily_agents(vault_path: Path, graph=None) -> list[DailyAgentConfig]:
    g = graph or _get_graph()
    if g:
        rows = await g.execute_cypher(
            "MATCH (c:Caller) WHERE c.enabled = true RETURN c ORDER BY c.name"
        )
        return [DailyAgentConfig.from_row(r) for r in rows]
    # Fallback: vault file scan (startup edge case before migration runs)
    ...existing file scan logic...

async def get_daily_agent_config(agent_name: str, vault_path: Path, graph=None) -> Optional[DailyAgentConfig]:
    g = graph or _get_graph()
    if g:
        rows = await g.execute_cypher(
            "MATCH (c:Caller {name: $name}) RETURN c", {"name": agent_name}
        )
        return DailyAgentConfig.from_row(rows[0]) if rows else None
    # Fallback: vault file
    return DailyAgentConfig.from_file(vault_path / "Daily" / ".agents" / f"{agent_name}.md")
```

Update all callers of `get_daily_agent_config` in `daily_agent.py` (the `run_daily_agent` function) to await the new async version.

### Phase 4 — Scheduler Updates

**`scheduler.py`** — store graph reference alongside vault_path:

```python
_graph = None  # added global

async def init_scheduler(vault_path: Path, graph=None) -> AsyncIOScheduler:
    global _scheduler, _vault_path, _graph
    _vault_path = vault_path
    _graph = graph
    ...
    agents = await discover_daily_agents(vault_path, graph=graph)
    _schedule_from_list(_scheduler, agents)
    ...

async def reload_scheduler(vault_path: Path, graph=None) -> dict:
    # Now async since discovery is async
    agents = await discover_daily_agents(vault_path, graph=graph or _graph)
    _schedule_from_list(_scheduler, agents)
    ...
```

Add `_schedule_from_list(scheduler, agents)` — sync helper that takes the pre-loaded list, replacing `_schedule_all_daily_agents`.

Update `get_scheduler_status` to accept/use graph for discovery.

Update `module.py` to pass `graph` to `init_scheduler` and `reload_scheduler`.

### Phase 5 — Caller CRUD API

Replace `/agents` with `/callers` in `module.py`. Add full CRUD:

```
GET  /callers           — MATCH (c:Caller) RETURN c ORDER BY c.name
GET  /callers/{name}    — MATCH (c:Caller {name: $name}) RETURN c
POST /callers           — MERGE + SET all fields from body
PUT  /callers/{name}    — MERGE + SET changed fields
DELETE /callers/{name}  — MATCH (c:Caller {name: $name}) DELETE c
```

Keep existing `/agent-cards` route as alias during transition, then rename to `/cards`. Update `/agent-cards/{name}/run` → `/cards/{name}/run`.

### Phase 6 — Flutter Renames

Mechanical renames across Flutter codebase:

| Old | New |
|-----|-----|
| `agent_card.dart` | `card.dart` |
| `class AgentCard` | `class Card` |
| `agentCardsProvider` | `cardsProvider` |
| `fetchAgentCards()` | `fetchCards()` |
| `fetchAgents()` | `fetchCallers()` |
| `/api/daily/agent-cards` | `/api/daily/cards` |
| `/api/daily/agents` | `/api/daily/callers` |
| `AgentOutputHeader(card: AgentCard)` | `AgentOutputHeader(card: Card)` |
| `JournalAgentOutputsSection(cards: List<AgentCard>)` | `(cards: List<Card>)` |

Also update `DailyAgentInfo` references if `fetchCallers()` returns a new `Caller` model rather than `DailyAgentInfo` (likely just add `Caller` as a new simple model with same fields).

## Dependencies & Risks

**Async cascade from discovery:** `discover_daily_agents` becoming async requires `init_scheduler` and `reload_scheduler` to be async. `reload_scheduler` is currently called from a sync API handler — ensure the API route is `async def`.

**Graph unavailable at scheduler init:** If `GraphDB` isn't registered yet when `init_scheduler` runs, discovery returns empty list. Mitigation: pass graph explicitly from `on_load()` which runs after graph registration.

**Kuzu `BOOLEAN` field:** LadybugDB's `ensure_node_table` may not support `BOOLEAN` type — use `"STRING"` for `schedule_enabled` and `enabled` if needed, store `"true"/"false"`.

**`tools` as JSON string in graph:** Kuzu doesn't have array columns in open-schema mode. Store as JSON string, parse on read.

**Flutter `Card` name collision:** `Card` is a Flutter widget. Name the Dart class `AgentCard` still in file `card.dart`, OR pick `CallerCard`, OR keep `AgentCard`. Evaluate at implementation time — if there's a collision, use `CallerCard` instead.

## References

- Brainstorm: `docs/brainstorms/2026-03-04-caller-card-graph-native-agents-brainstorm.md`
- Prior PR: #179 (AgentCard graph nodes)
- `computer/parachute/core/daily_agent.py` — `DailyAgentConfig`, `discover_daily_agents`, `get_daily_agent_config`
- `computer/parachute/core/scheduler.py` — `init_scheduler`, `reload_scheduler`
- `computer/modules/daily/module.py` — `on_load()`, agent routes
