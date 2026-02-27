---
title: "brainstorm: Brain bridge agent — ambient context enrichment"
type: brainstorm
date: 2026-02-27
issue:
modules: brain, chat
tags: [bridge-agent, context-enrichment, architecture]
---

# Brainstorm: Brain Bridge Agent — Ambient Context Enrichment

> Source: Collaborative brainstorm, 2026-02-27. Captures architectural thinking for Phase 3+ of Brain.

---

## The Core Problem

Without a bridge agent, the brain is purely reactive — you have to explicitly ask the chat agent to query it, or the chat agent has to guess when to use its brain tools. Two failure modes:

1. **Over-enrichment**: Bridge pre-loads context for "find people who work on regenerative tech and think about how they relate to Biotelia" — but the chat agent was going to do this query itself, more intentionally. Now you have shallow pre-loaded context AND deep query results cluttering the context window.

2. **Under-enrichment**: "I need to finish that letter by Friday" — the chat agent has no reason to go query the brain itself. But the bridge should load the relevant context (what letter? what's the Flock Safety situation?) because it knows the conversation history.

The bridge agent solves both by making an intent judgment on every turn.

---

## The Bridge Agent

A **Haiku** agent that runs before the chat agent on every user message.

### Inputs
- The incoming user message
- A running conversation summary (updated each turn)
- A log of what brain context has already been loaded into this chat session

### The Judgment

Three modes:

**Enrich** — "I need to finish that letter by Friday"
- The user is making a request the chat agent will handle
- The chat agent has no reason to query brain directly
- Bridge translates "that letter" → specific brain query, loads context

**Step back** — "Find people in my graph who work on regenerative tech"
- The user explicitly wants to work with the brain through the chat agent
- Loading partial context would interfere with the chat agent's deeper query
- Bridge loads minimal orientation context only, or nothing

**Pass through** — "What's 2+2?"
- Normal conversation with no brain involvement needed
- Bridge does nothing (saves tokens and latency)

The Haiku call is fast and cheap. Most turns, the bridge does nothing. This is better than the naive "load context on every turn" approach that burns tokens and latency on every message.

### Post-turn write-back

After the chat agent responds:
- Bridge evaluates what happened
- If something significant occurred (commitment, decision, new relationship, realization) → formulates specific `remember` calls
- Updates conversation summary
- Updates log of loaded/stored context
- Most turns: nothing significant happened, bridge does nothing on write side either

### Episodes as provenance

Each bridge invocation that results in brain interaction (read or write) is an Episode. Every entity and fact traces back to the episode that created it, which traces back to the chat session and turn. Enables "where did I learn this?" queries.

---

## The `remember`/`recall` Interface

Higher-level NL methods that sit above the CRUD tools. The bridge calls these; the chat agent calls the more granular MCP tools for intentional queries.

```
recall(query, time_range?, lens?)
  → Hybrid retrieval: semantic + BM25 + graph traversal
  → Returns structured context bundle

remember(content, context, source_episode)
  → Entity resolution + graph writes
  → Returns what was created/updated, any ambiguities

invalidate(entity_or_relationship_id, reason)
  → Sets valid_until, marks superseded
  → Preserves history

curate(question, entity_id?)
  → Queues ambiguity for user review
  → "Is Sarah C. the same as Sarah Chen?"

evolve_schema(proposed_type, rationale)
  → Proposes new node/relationship type
  → Requires human approval
```

---

## Entity Resolution Cascade

When `remember` is called with a reference like "Sarah" or "the woman from the HRC meeting":

1. **Exact match** on name
2. **Alias match** against accumulated alias lists
3. **Vector similarity** (HNSW index — handles spelling, abbreviations, nicknames)
4. **Contextual graph traversal** — if content mentions "HRC meeting," look for entities connected to HRC-related nodes
5. **LLM reasoning** — Haiku evaluates ambiguous candidates using content + graph context
6. **Ask user** — if genuinely unresolvable, queue a curation question

Each confirmed match adds to the entity's alias list. The system improves deterministically through use.

---

## Temporal Model

### Relationship edges

Add `valid_until TIMESTAMP DEFAULT NULL` to `Brain_Relationship`. A NULL `valid_until` means currently valid. When facts change, `valid_until` is set on the old edge and a new edge is created. Nothing is deleted — the graph remembers history.

### Assertion node type

A first-class entity type representing facts, commitments, decisions, observations, and questions with their own lifecycle.

```yaml
Assertion:
  content: {type: text, description: "The assertion or fact"}
  assertion_type: {type: text, description: "fact / commitment / decision / question / observation"}
  status: {type: text, description: "active / completed / superseded / expired"}
  deadline: {type: text, description: "Due date if applicable"}
  confidence: {type: text, description: "high / medium / low"}
```

Relationships from Assertion: `INVOLVES`, `ABOUT`, `SOURCE` (→ Episode), `SUPERSEDES` (→ Assertion)

---

## Message Flow

```
User sends message
  ↓
Bridge agent (Haiku) evaluates:
  - Reads message + conversation summary + log of already-loaded brain context
  - Judges: enrich with brain context? Step back for intentional query? Pass through?
  - If enriching: translates references → specific brain service queries, gets context
  ↓
Chat agent (Sonnet/Opus) runs:
  - Has any bridge-loaded context in its prompt
  - Has brain MCP tools for intentional direct queries
  - Produces response for user
  ↓
Response delivered to user
(UI can surface what brain context was loaded and from where)
  ↓
Bridge agent evaluates exchange:
  - Anything significant to store?
  - If yes: formulates specific remember calls to brain service
  - Updates conversation summary
  - Updates log of loaded/stored context
  ↓
Brain service processes any writes:
  - Resolves entities (exact → alias → vector → contextual → LLM → ask)
  - Creates/updates nodes and relationships
  - Tracks temporality
  - Updates episode provenance
```

---

## Pre-hook Latency

The bridge runs before every message. Latency budget:
- Haiku call with short context: ~200-400ms
- Brain recall query: ~50-100ms
- Total: ~300-500ms overhead per turn

This is acceptable for a background enrichment step. The UI can show a subtle "thinking" state while the bridge runs.

Design consideration: if the bridge consistently adds 400ms, users will notice. Options:
- Skip bridge entirely for very short messages (< 5 words)
- Run bridge in parallel with initial chat agent setup (if feasible)
- Cache conversation summary to reduce bridge context size

---

## What This Is NOT

- **Not a replacement for direct brain queries** — the chat agent still has MCP tools for intentional graph work
- **Not always loading context** — the bridge steps back for intentional queries, passes through for normal conversation
- **Not a new database** — same LadybugDB backend, same MCP tools, just a smarter access pattern
- **Not Phase 1** — Phase 1 is the CRUD foundation. Bridge agent is Phase 3.

---

## Open Questions

- Whether the brain service evolves into a persistent brain agent with rolling cross-chat context, or whether the bridge agents reading shared state is sufficient for cross-chat awareness
- How the bridge's conversation summary is maintained — what detail level, how it's compressed over long conversations
- The exact boundary between "enrich" and "step back" intent — will be refined through experience
- How curation questions surface in the Flutter UI — inline, dedicated curation mode, or daily digest

---

## Implementation Order

This is Phase 3, after:
- **Phase 1** (#129): LadybugDB backend, MCP tools — `feat/brain-v3-ladybugdb` ← current
- **Phase 2** (#129): Flutter UI (entity browser, inline editing, schema editor)
- **Phase 3** (new issue): Bridge agent, `remember`/`recall` interface, conversation summary, episode provenance
- **Phase 4** (future): Entity resolution cascade with alias tracking + vector search
- **Phase 5** (future): Schema evolution (`evolve_schema`), Assertion type, curation flows

---

## References

- Current plan: `docs/plans/2026-02-26-feat-brain-v3-ladybugdb-plan.md`
- Graphiti temporal model: arXiv:2501.13956
- LadybugDB HNSW: for vector search in Phase 4
