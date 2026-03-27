# Tool as Universal Primitive

**Status:** Brainstorm
**Priority:** P2
**Modules:** daily, computer, app
**Issue:** #355

---

## What We're Building

A unified model where **Tool is the single primitive** in the Parachute agent system. Everything — graph queries, LLM transforms, reasoning agents, MCP operations — is a Tool node in the graph. What we currently call "agents" are just Tools with triggers and more autonomy.

Four concepts, clean separation:

- **Tool** — what it does (query, transform, agent, mcp)
- **Trigger** — when it runs (schedule, event)
- **ToolRun** — what happened (observability)
- **Connection** — how to reach external services (later, maybe)

### The Problem Today

Three disconnected sources of truth for tool metadata:

1. **Python `TOOL_FACTORIES`** — runtime behavior, descriptions only visible to the AI agent, scope requirements
2. **Python `AGENT_TEMPLATES`** — default tool lists baked into source code
3. **Flutter `_ToolDef`** — hardcoded labels, icons, descriptions using *different names* than the backend

These don't validate against each other. Flutter uses old names (`read_journal`, `read_entry`) while the backend registers different names (`read_days_notes`, `read_this_note`). Ghost tool names exist in agent configs that don't resolve to anything. Adding or modifying a tool requires editing Python source *and* Flutter source.

Beyond the naming mess:
- Users can't see what a tool does, what data it reads/writes, or what happened when it ran
- The Haiku sub-agent inside `summarize_chat` is invisible — no indication a second LLM call happens
- Tools can't be created, modified, or composed without editing parachute-computer source
- The Parachute MCP already exposes ~9 tools (search_memory, list_notes, etc.) that are graph queries — but they're defined in Python handlers, disconnected from the daily agent tool system

### The Key Insight

Tools and agents aren't fundamentally different things. They live on a spectrum of autonomy:

| Current concept | What it actually does | Autonomy |
|---|---|---|
| `search_memory` (MCP) | Execute a Cypher query, return results | None — pure function |
| `read_days_notes` (factory) | Execute a Cypher query, return results | None — pure function |
| `process-note` (agent) | Read a note, clean up transcript, write back | Minimal — single LLM pass |
| `summarize_chat` (factory) | Query messages, summarize with Haiku, persist | Minimal — single LLM pass |
| `process-day` (agent) | Read multiple sources, reason about connections, synthesize | High — multi-step, decisions |

The MCP tools, daily agent tools, and "agents" themselves are the same thing at different points on this spectrum. The difference isn't type — it's execution mode.

### The Parachute MCP Is the Tool Execution Layer

The Parachute MCP server already exposes tools that are graph queries:

| MCP Tool | Graph Operation |
|---|---|
| `search_memory` | Cypher across Chats, Messages, Notes |
| `list_notes` | Cypher on Notes with date/type filters |
| `list_chats` | Cypher on Chats with filters |
| `get_chat` | Cypher: Chat + HAS_MESSAGE + Messages |
| `write_card` | Cypher MERGE on Card |

The daily agent tools (`read_days_notes`, `read_days_chats`) do the same thing — Cypher queries. They're just defined differently (factory closures vs MCP handlers).

The MCP server should become the universal execution layer: read Tool definitions from the graph, expose them as MCP operations. Any runner (Claude SDK, Cloudflare Agents, Goose) calls tools through standard MCP protocol.

```
Graph (Tool nodes) ← single source of truth
    ↓
Parachute MCP Server ← reads Tool definitions, exposes as MCP operations
    ↓
Runner (Claude SDK / Cloudflare / Goose) ← calls tools via MCP
```

This is critical for the Daily split: Daily on Cloudflare calls the same Tool nodes through the same MCP interface, just with a different runner backend.

## Why This Approach

**One node type, one graph schema.** No more parallel definitions. The graph is the single source of truth. Flutter discovers tools from the graph. The Python runner reads from the graph. Adding a tool means adding a graph node.

**Configurable without touching source.** Tools defined in the graph can be created, modified, and composed through the app or directly via Cypher. Power users build custom tools. Beta users get good defaults. Same underlying system, different exposure.

**Transparent and observable.** Every callable is a Tool node — trace exactly what happened: which Tools were called, in what order, what they returned. `:CALLED` relationships make runs fully visible.

**Backend-agnostic.** Tool definitions are graph data. The execution layer (Claude SDK, Cloudflare Agents, Goose, local models) is an implementation detail. The Daily app and Computer app share the same Tool definitions with different runners.

**Composable.** Multiple triggers per tool. One trigger invoking multiple tools. Tools calling tools. All expressible through graph relationships.

## Key Decisions

### Tool is the universal primitive

Everything callable is a `Tool` node — graph queries, LLM transforms, agents, MCP operations. No subtypes (Kuzu doesn't support them; neither does SQLite on D1). The `mode` field is the discriminator. Different modes have different relevant fields; unused fields for a given mode are empty/null. This is the same pattern used throughout the codebase (`entity_type` on Brain_Entity, `card_type` on Card, `note_type` on Note).

### Execution modes

- **`query`** — pure graph operation. Cypher template with scope interpolation. Microseconds, no LLM, no API cost. Example: `read-days-notes`, `search-memory`.
- **`transform`** — single LLM pass. Input data → prompt template → model → output. One API call, no tool-calling, no multi-turn. Example: `process-note`, `summarize-chat`.
- **`agent`** — reasoning loop. System prompt, can call other Tools, multi-turn. Uses whatever SDK/runner is configured. Example: `process-day`.
- **`mcp`** — operation served by an external MCP server. Discovered dynamically at connection time. Example: third-party MCP tools.

### Triggers are their own table

Triggers are separated from Tools. A Tool is purely "what I do." A Trigger is "when to do it."

```
(:Trigger {
  name: STRING,
  type: STRING,            -- "schedule" | "event"
  schedule_time: STRING,   -- "4:00" (if schedule)
  schedule_cron: STRING,   -- future: complex scheduling
  event: STRING,           -- "note.transcription_complete" (if event)
  event_filter: STRING,    -- JSON filter
  enabled: BOOL,
  scope: STRING,           -- JSON: default scope to pass, e.g. {"date": "yesterday"}
  created_at: STRING,
})

(:Trigger)-[:INVOKES]->(:Tool)
```

This enables:
- **Multiple triggers per tool.** Run `process-day` on schedule AND on manual invoke with different scope.
- **One trigger, multiple tools.** "When note transcribed" → run `process-note` AND `tag-note` AND `notify`.
- **Triggers on any tool mode.** Schedule a `mode: query` tool directly — no full agent needed.
- **Portable triggers.** Trigger nodes map to Cloudflare scheduled/event model for the Daily split.

### Agent is a role, not a type

"Agent" is what we call a Tool in the UI when it:
- Has `mode: agent` (reasoning loop)
- Has a Trigger attached (or can be manually invoked)
- Is the outermost Tool the user interacts with

This is a UI/UX distinction, not a data model distinction. Flutter shows "Agents" as the top-level view. Tapping in reveals the Tools it calls. Same graph, different presentation layer.

### Graph schema

```
(:Tool {
  name: STRING,           -- primary key, e.g. "read-days-notes"
  display_name: STRING,   -- human label, e.g. "Today's Notes"
  description: STRING,    -- what it does, for both humans and AI
  mode: STRING,           -- "query" | "transform" | "agent" | "mcp"
  scope_keys: STRING,     -- JSON array of required scope keys, e.g. ["date"]
  input_schema: STRING,   -- JSON schema for tool parameters

  -- mode=query
  query: STRING,          -- Cypher template with $param placeholders

  -- mode=transform
  transform_prompt: STRING,
  transform_model: STRING,  -- "haiku", "sonnet", etc.
  write_query: STRING,      -- optional Cypher to persist result

  -- mode=agent
  system_prompt: STRING,
  model: STRING,
  memory_mode: STRING,    -- "persistent" | "fresh"

  -- mode=mcp
  server_name: STRING,    -- which MCP server provides this

  -- metadata
  builtin: BOOL,
  enabled: BOOL,
  created_at: STRING,
  updated_at: STRING,
})

(:Tool)-[:CAN_CALL]->(:Tool)          -- this tool may invoke that tool
(:Trigger)-[:INVOKES]->(:Tool)        -- when to run
(:ToolRun)-[:CALLED]->(:Tool)         -- observability: what was actually invoked
(:ToolRun)-[:PRODUCED]->(:Card)       -- what output was generated
```

### MCP tools are Tool nodes

Each operation an MCP server exposes becomes a Tool node with `mode: mcp`. When a server connects, its advertised tools sync into the graph. If the tool list changes on reconnection, nodes are updated (removed tools marked inactive, not deleted — preserves `:CAN_CALL` edges).

MCP tools are discoverable, attachable to agents, and observable via the same relationships as local tools. An agent's `:CAN_CALL` edges are uniform — it doesn't matter whether the target is a local query or an MCP operation.

### ToolRun replaces AgentRun

Runtime state (what happened, when, how long) lives on `ToolRun` nodes:

```
(:ToolRun {
  run_id: STRING,           -- UUID
  tool_name: STRING,        -- which Tool ran
  trigger_name: STRING,     -- which Trigger fired (or "manual")
  status: STRING,           -- "running" | "success" | "error"
  started_at: STRING,
  completed_at: STRING,
  duration_seconds: DOUBLE,
  session_id: STRING,       -- SDK session (for mode=agent)
  scope: STRING,            -- JSON: scope data for this run
  error: STRING,
  created_at: STRING,
})
```

Derived state (run_count, last_run_at, sdk_session_id for resume) is queried from ToolRun nodes rather than cached on the Tool node. For `memory_mode: persistent`, the session_id from the latest successful run is used for resume.

### No migration needed

Current usage is minimal — only Notes and Chats have data worth preserving (and those aren't changing). Agent configs and AgentRun records can be recreated from templates. Move fast, don't worry about migrating the old Agent/AgentRun schema.

## Open Questions

1. **Script-backed tools.** Should `mode: script` be a fifth mode, pointing to `~/.parachute/tools/my-tool.py`? Maximum flexibility for power users. Not urgent.

2. **Security of query/transform modes.** A `query` tool executing Cypher is a power-user feature. Beta users should see curated tools only. Gate via `builtin: true` vs user-created, or a `visibility` field.

3. **Sandbox interaction.** Sandboxed agents get tools via MCP bridge with `allowed_tools` ceiling. Graph-defined tools need to register with the bridge — but the bridge already filters by tool name, so this is mostly wiring.

4. **Sub-agent observability.** When a `mode: agent` Tool calls a `mode: transform` Tool, surface via nested `(:ToolRun)-[:CALLED]->(:Tool)` relationships. The run log shows the full call chain.

5. **MCP server connection tracking.** Separate `Connection` node type or just `server_name` field on mcp-mode Tools? Leaning toward simple `server_name` for now, Connection node later if needed.

6. **Runner abstraction.** The `mode: agent` runner is the one piece that's SDK-specific. Should Tool nodes have a `runner` field ("claude", "cloudflare", "goose") or is that a deployment-level config? For Daily split, the runner is determined by which app is executing, not by the Tool definition.

## Starting Point

Simplest first move that establishes the foundation:

1. **Create Tool nodes** for the ~15 existing tools (MCP tools + daily agent tools + agent-mode tools). Seed like we seed Agent templates. Name, description, mode, scope_keys.
2. **Create Trigger nodes** for existing schedules and events. Link to Tools via `:INVOKES`.
3. **Add `:CAN_CALL` edges** from agent-mode Tools to their child Tools.
4. **Add `GET /tools` endpoint** returning Tool nodes from graph. Flutter reads from this — delete hardcoded `_ToolDef`.
5. **Rename AgentRun → ToolRun**, collapse Agent node into Tool nodes.
6. **Keep current execution backends** (Python factories, MCP handlers). Tool nodes are metadata; execution still goes through existing code, matched by `Tool.name`.

Phase 2 (later): MCP handlers read Cypher from Tool node's `query` field. Tools become truly graph-defined, not just graph-described.

## What This Unlocks

- **User-created tools** — define a query + transform in the graph, attach it to an agent
- **Composable triggers** — multiple triggers per tool, one trigger invoking multiple tools
- **Full observability** — every invocation traced as ToolRun with `:CALLED` edges
- **Backend portability** — Computer uses Claude SDK, Daily uses Cloudflare Agents, same Tool definitions
- **Single source of truth** — Flutter, Python runtime, and MCP server all read from the same Tool nodes
- **MCP as execution layer** — Parachute MCP becomes the universal tool runner, any client can call it
