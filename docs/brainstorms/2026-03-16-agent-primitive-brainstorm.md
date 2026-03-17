# Agent Primitive — Parachute-Wide Autonomous Workers

**Status:** Brainstorm
**Priority:** P1
**Labels:** daily, computer, app
**Issue:** #280

---

## What We're Building

Rename "Callers" to "Agents" and establish the agent as a first-class Parachute primitive — an autonomous worker defined as a graph node that can be invoked by any module (Daily first, Chat later).

An agent is **not** the thing you talk to in a chat session. That's handled by the Claude SDK natively. An agent is the thing that wakes up on its own — on a schedule, when an event fires, or when manually triggered — does its work, and goes back to sleep. Parachute owns the *when*, the *what*, and the *bookkeeping*. The SDK handles the actual LLM execution.

## Why This Approach

**The name "Caller" doesn't land.** Users already see "Daily Agents" in the UI. The underlying concept — an autonomous worker with instructions and tools — is an agent. Leaning into that language makes the product clearer.

**The primitive is already built.** Callers have identity, instructions, tools, triggers (scheduled + event-driven), trust levels, and activity tracking. This isn't speculative architecture — it's a rename and conceptual upgrade of working code.

**It's Parachute-wide, not Daily-specific.** The bridge agent concept (processing chat messages post-turn) uses the same shape: system prompt + tools + trigger + memory. Daily is the first module to implement agents, but the primitive belongs at the graph level.

**The SDK agent scaffolding can be cleaned up.** The backend has a half-wired `AgentDefinition` system that was superseded by SDK-native agent discovery. The vault-agent concept is dated. Cleaning this up and letting "agent" mean one clear thing removes confusion.

## Key Decisions

### 1. Agent = a node in the graph

An agent is defined by these properties:

| Property | Description | Example |
|----------|-------------|---------|
| **Identity** | Name, display name, description | "Auto Tagger", "tags notes automatically" |
| **Instructions** | System prompt with template variables | "You are a tagging assistant. Read the note and assign relevant tags." |
| **Tools** | What capabilities it has access to | `[read_entry, update_entry_tags, read_journal]` |
| **Trigger** | When it runs | Scheduled (`03:00`), event-driven (`note.created`), manual-only |
| **Scope** | What it operates on | Day (reads across entries) or Note (single entry) |
| **Memory** | Context persistence across runs | Persistent (resumes session) or Fresh (new session each run) |
| **Trust** | What it's allowed to touch | `full`, `vault`, `sandboxed` |

### 2. Dimensions compose freely

These properties are orthogonal — not locked to specific combinations:

- A **scheduled** agent can be **fresh** (no memory of yesterday) or **persistent** (builds on previous runs)
- A **triggered** agent can have **note-scoped tools only** or **note + day-scoped tools** (e.g., auto-tagger that reads today's other entries for context)
- Tool assignment is **flexible with good defaults**: triggered agents default to note-scoped tools, scheduled agents default to day-scoped tools, but users can mix

### 3. Memory mode is a toggle

- **Persistent**: Resumes the SDK session across runs. The agent remembers what it did last time. Good for reflections that build on previous days.
- **Fresh**: New session each invocation. Stateless. Good for triggered agents processing individual notes.

Currently scheduled agents are persistent and triggered agents are fresh. Making this configurable per agent unlocks new patterns without changing the execution model.

### 4. Rename scope

The rename touches:
- **Graph schema**: `Caller` → `Agent` node type, `CallerRun` → `AgentRun`
- **API endpoints**: `/daily/callers/*` → `/daily/agents/*` (with backward-compat aliases)
- **Backend code**: `CallerDispatcher`, `run_triggered_caller()`, `caller_dispatch.py`, etc.
- **Flutter code**: `CallerTemplate`, `CallerActivity`, `CallerEditScreen`, `CallerDetailSheet`, etc.
- **User-facing strings**: Already say "Agent" mostly — align the few remaining "Caller" references

### 5. Clean up SDK agent scaffolding

The `AgentDefinition` / `AgentPermissions` / vault-agent system in `computer/parachute/models/agent.py` and `api/agents.py` is superseded. The Claude SDK discovers chat-facing agents natively from `.claude/agents/`. The capabilities screen can stay for browsing SDK agents, but the Parachute-managed agent is the Daily/autonomous agent primitive.

## Open Questions

1. **Graph node naming**: Should the graph node be literally `Agent`, or something more specific like `AutonomousAgent` to distinguish from SDK chat agents? (Leaning toward just `Agent` — keep it simple, context disambiguates.)

2. **Tool kit evolution**: As agents get more capable, do we need a formal "tool registry" where tools are named capabilities that modules register? Or is the current approach (hardcoded tool lists per scope) sufficient for now?

3. **Bridge agent migration**: The bridge agent (post-turn chat processing) currently lives in `bridge_agent.py` as its own system. Could it be expressed as an agent node with trigger=`chat.turn_complete`? That would validate the "Parachute-wide primitive" claim.

4. **Output model**: Scheduled agents produce Cards. Triggered agents produce AgentRuns. Should these converge into a single "agent output" concept, or are they genuinely different (day-scoped artifact vs. per-note activity record)?

5. **Container integration**: The container primitive (trust/isolation) is also emerging as cross-cutting. How do agents and containers relate? Is the agent's trust level just "which container does it run in"?

## What This Unlocks

- **Clearer product language**: "Agents" is immediately understandable. "Here are your agents. This one reflects on your day. This one tags your notes."
- **Composable patterns**: Mix trigger types, tool sets, and memory modes for agents we haven't imagined yet
- **Parachute Daily as agent-first**: The standalone Daily app is an app where you write notes and agents do useful things with them
- **Future bridge agent**: Express chat post-processing as just another agent in the graph
- **Simpler codebase**: One agent concept instead of Callers + half-wired SDK agents + bridge agent as separate systems
