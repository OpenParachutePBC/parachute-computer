---
issue: 323
date: 2026-03-23
status: brainstorm
---

# Generalize Agents: process-note and process-day patterns

## Core Insight

Two agent runners exist today (`run_daily_agent` and `run_triggered_agent`) that share ~70% of their logic but diverge on what data the agent operates on. Unify them into one runner where **scope** — the input to a specific run — is just data, not a class hierarchy.

## Key Concepts

### Config (the agent's identity)
Lives in the graph. Doesn't change between runs.
- system_prompt, tools list, trust_level, memory_mode, trigger_event, schedule

### Scope (the run's input)
A dict of contextual data created at trigger time. Determines how tools get bound to concrete data.

```python
# Triggered by note.transcription_complete
scope = {"entry_id": "abc123", "event": "note.transcription_complete"}

# Triggered by schedule (daily reflection)
scope = {"date": "2026-03-22"}

# Future: triggered by tag.added, carries both
scope = {"entry_id": "abc123", "event": "tag.added", "date": "2026-03-22", "tag": "important"}
```

Scope is just data. No DayScope/NoteScope classes. The runner resolves tools based on what keys are present in the scope dict.

### Tool binding via scope keys
Each tool implementation declares what scope keys it needs:

| Tool | Required scope keys | What it does |
|------|-------------------|-------------|
| `read_entry` | `entry_id` | Read this specific note |
| `update_entry_content` | `entry_id` | Update this specific note |
| `add_tags` | `entry_id` | Add tags to this note |
| `read_journal` | `date` | Read journal entries for this date |
| `read_chat_log` | `date` | Read chat logs for this date |
| `write_card` | (none — uses agent config + output_date) | Write agent output as Card |

If the agent config declares `read_entry` but scope doesn't have `entry_id`, that's a clear error at tool binding time. No class hierarchy needed — the data tells you what's available.

This also means a future agent can mix scope data naturally. An agent triggered by `note.created` that also wants to read other journal entries from that day just needs both `entry_id` and `date` in scope — no special "combined scope type."

### Runner (generic execution)
One function: `run_agent(agent_name, scope)`

1. Load config from graph
2. Bind tools: match agent's declared tools against scope keys
3. Build prompt: inject scope data into system_prompt template vars
4. Pre-check: validate scope data (entry exists? journal exists for date?)
5. Route execution by trust_level (sandbox vs direct)
6. Handle memory_mode (persistent vs fresh)
7. Record AgentRun (with scope stored for observability)
8. Dedup: if scope has `date`, check last_processed_date

### Prompt context injection
The agent's system_prompt has template vars that get filled from scope + user context:
- `{date}`, `{entry_id}`, `{event}` — from scope
- `{user_name}`, `{user_context}` — from profile/context notes
- `{entry_content}` — resolved from scope (if entry_id present, load content)

## Agent Renames

| Current | New |
|---------|-----|
| `daily-reflection` | `process-day` |
| `post-process` | `process-note` |

Template versioning handles migration. User-modified agents are left alone with "update available" note.

## What Changes

### Unified runner: `run_agent(agent_name, scope)`
Replaces both `run_daily_agent()` and `run_triggered_agent()`. The runner handles:
- Config loading
- Tool binding from scope
- Execution routing (sandbox vs direct)
- Memory management (persistent vs fresh)
- AgentRun bookkeeping (scope stored on AgentRun for observability)
- Token creation/revocation for sandbox
- Event capture (session_id, model, output detection)

### Entry points become thin
- Scheduler calls: `run_agent("process-day", {"date": yesterday})`
- Event dispatcher calls: `run_agent("process-note", {"entry_id": id, "event": event})`
- Manual API calls: `run_agent(agent_name, {"date": date})`

### Tool implementations stay where they are
- `daily_agent_tools.py` — day-scoped tools (read_journal, read_chat_log, etc.)
- `triggered_agent_tools.py` — note-scoped tools (read_entry, update_entry_content, etc.)
- A tool registry maps tool names to (implementation_fn, required_scope_keys)
- Runner creates only the tools the agent config declares, binding from scope

### AgentRun stores scope
The AgentRun node gets a `scope` field (JSON string) so you can see what each run operated on:
```json
{"entry_id": "abc123", "event": "note.transcription_complete"}
```

## What Stays The Same

- Agent graph schema (just rename built-in agents + bump template_version)
- Card/Note output models
- Sandbox vs direct execution mechanics
- MCP bridge tool scoping (#318 — allowed_tools on sandbox tokens)
- Tool implementations (daily_agent_tools.py, triggered_agent_tools.py)

## Future Extensions (not this PR)

- New scope keys: `session_id` (process a chat), `tag` (react to tag changes), `start_date`/`end_date` (weekly review)
- New tools that declare new scope key requirements
- Agents that mix scope data (note + date, entry + tag)
- Custom tools via plugin modules

## Resolved Questions

1. **Scope stored on AgentRun?** Yes — useful for debugging and UI.
2. **Agents declare scope types?** No — tool binding validates naturally. If tool needs `entry_id` and scope doesn't have it, that's an error. No need for explicit scope type declarations.
3. **API surface:** Keep it simple — `/agents/{name}/run` takes scope as a JSON body. The keys present determine what kind of run it is.

## Relationship to Other Issues

- #318 (scoped MCP tools) — `allowed_tools` on sandbox tokens. Runner sets these from agent config when creating tokens.
- #319 (declarative tool scoping) — future: agent configs in YAML. Aligns with tools-as-data model.
- #322 (persistent cards) — process-day writes Cards, card types come from config
- #325 (suggested edits) — future tool variant: `suggest_edit` instead of `update_entry_content`
