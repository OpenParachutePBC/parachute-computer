# Chat Memory & Retrieval

**Status:** Brainstorm
**Priority:** P1
**Labels:** brain, computer, chat
**Issue:** #244

---

## What We're Building

A coherent retrieval layer for chat memory — making past conversations searchable, browsable, and naturally accessible to AI agents. This includes:

1. **Unified MCP tools** for chat memory that work identically in direct and sandbox modes
2. **Bundled search results** — search returns chats with relevant exchanges grouped underneath, not just session-level pointers
3. **Exchange-level access** — browse and search through actual user messages and AI responses
4. **Terminology alignment** — rename "session" → "chat" across APIs, MCP tools, and code

## Why This Approach

The graph already stores rich data — full user messages and AI responses on every Exchange node, plus Haiku-generated descriptions and session summaries. The problem isn't storage, it's that the retrieval surface doesn't match the richness of what's stored.

Today's gaps:
- `search_memory` returns results at the chat level — "Chat X had a match" with a `matched_exchange_id` for follow-up, but doesn't surface what was actually said
- `brain_get_chat` truncates exchanges at 2000 chars
- `brain_get_exchange` requires knowing the ID already
- Sandbox MCP tools are even thinner — `list_recent_sessions` is broken (#242), no exchange browsing at all
- "Session" terminology leaks everywhere despite graph nodes being `Chat` and `Exchange`

The goal is **natural recall** — the AI searches past conversations and references them without the user needing to manage anything. This requires tools that return meaningful, bundled results an agent can reason over.

## Key Decisions

### 1. Three-tool retrieval model

Design around how agents actually want to access memory:

| Tool | Purpose | Returns |
|------|---------|---------|
| `search_chats` | Search across all chats by keyword | Chats with matching exchanges bundled underneath, sorted by relevance |
| `get_chat` | Browse a specific chat | Chat metadata + exchanges (paginated, truncated) |
| `get_exchange` | Drill into one exchange | Full untruncated user message + AI response |

This replaces the current mix of `search_memory`, `brain_list_chats`, `brain_get_chat`, `brain_get_exchange`, and `list_recent_sessions`.

### 2. Bundled search results

`search_chats` should return results grouped as:

```
Chat: "Building the MCP bridge" (March 12, 2026)
  Summary: Implemented HTTP MCP bridge for sandbox containers...
  Matching exchanges:
    - ex:3 — "How should we handle auth tokens?" → snippet of AI response
    - ex:7 — "The bearer token approach works but..." → snippet of AI response

Chat: "Debugging sandbox permissions" (March 10, 2026)
  Summary: Investigated why sandbox couldn't access brain...
  Matching exchanges:
    - ex:1 — "Sandbox chat doesn't know about MCPs" → snippet of AI response
```

Each exchange result includes enough snippet context (~300 chars from the matching message) that the agent can decide whether to drill deeper with `get_exchange`.

### 3. Same tools everywhere

One tool set that works in both direct MCP (claude CLI) and sandbox HTTP bridge. No more separate registrations with different capabilities. The HTTP bridge proxies to the same handlers.

### 4. Terminology rename: session → chat

Align everything around "chat" and "exchange":
- API endpoints: `/api/brain/sessions` → `/api/brain/chats`
- MCP tools: `brain_list_chats` stays, `list_recent_sessions` → remove
- Code: `SessionStore` / `BrainSessionStore` → `ChatStore` / `BrainChatStore`
- Graph nodes: Already `Chat` and `Exchange` — no change needed
- Internal `session_id` field name can stay as-is (it's the SDK identifier, renaming PKs is high-risk for low value)

### 5. CONTAINS search first, vector later

Start with the existing `CONTAINS` substring matching. Vector/semantic search is the eventual goal but is a separate piece of work that requires embedding infrastructure. The tool design should accommodate both — the `search_chats` interface doesn't change when the backend switches from CONTAINS to vector.

### 6. Approach C (automatic context injection) is deferred

Eventually we want the AI to "just remember" without explicit tool calls — the orchestrator would automatically search past conversations and inject relevant context before each turn. This depends on vector search being in place to avoid injecting irrelevant context and adding latency. The tools we build now become the foundation that auto-injection calls later.

## Scope

**In scope:**
- New `search_chats`, `get_chat`, `get_exchange` MCP tools
- Bundled search results with exchange snippets
- Parity between direct and sandbox MCP tools
- Rename "session" → "chat" in APIs, tools, and core code
- Fix #242 (list_recent_sessions not working) — subsumed by new tool design

**Out of scope:**
- Vector/semantic search (future work)
- Automatic context injection (future work, Approach C)
- Changes to how the bridge agent writes exchanges (storage is fine)
- Changes to JSONL transcript handling

## Open Questions

1. **Pagination for `get_chat`** — Should exchanges be paginated (offset/limit) or windowed (most recent N)? Most recent N is probably more useful for agents.
2. **Search ranking** — With CONTAINS, how do we rank results? By recency? By number of matches? Description match weighted higher than raw message match?
3. **Journal entries in search** — Should `search_chats` also search Daily journal entries, or keep that separate? Currently `search_memory` merges both.
4. **Deprecation path** — Do we keep the old tool names (`brain_list_chats`, `search_memory`) as aliases during transition, or hard-cut?

## Supersedes

- #242 — MCP bridge: list_recent_sessions tool not working (subsumed by this redesign)
