---
title: "Curator Revival: Background Context Agent"
date: 2026-02-24
status: brainstorm
priority: P2
labels: brainstorm, chat, computer, app
issue: "#125"
---

# Curator Revival: Background Context Agent

## What We're Building

A persistent background agent (the "curator") that runs after each conversation
exchange, using Haiku to tend to session context — updating titles, writing
activity log entries, and eventually extracting Brain knowledge. It maintains
a day-spanning SDK session for continuity, exposes MCP tools for writeback, and
surfaces its activity lightly in the UI.

This is a revival and refinement of a pattern that existed in `parachute-chat`
and `parachute-app` (archived repos, Jan 2026), distilled from lessons learned
through the hook-based and server-event-loop iterations that followed.

## Why This Approach

The current `session_summarizer.py` works but is too narrow in name and shape:
it parses `SUMMARY: / TITLE:` text output, uses the full CLI subprocess for a
task that doesn't need tools, and has no UI visibility. The scope is also about
to expand (Brain extraction, activity logging), so the shape needs to evolve
before it hardens.

The curator pattern addresses all of this:
- **Agent-native writeback** via MCP tools — transparent, extensible
- **Day-spanning continuity** — one SDK session per day that accumulates context
  across all conversations, not just one exchange
- **Light UI** — users see what the curator did without a heavy second screen
- **Haiku** — fast, cheap, right model for background observation tasks
- **Scope-ready** — adding Brain extraction means adding one more MCP tool, not
  restructuring the whole thing

## Scope for v1

**In:**
- Title generation (already working, move to curator)
- Session summary (already working, move to curator)
- Activity log entries to `Daily/.activity/{date}.jsonl`

**Out (v1, but same curator call when added):**
- Brain entity extraction — same curator call, new `write_brain_entity` tool
- Context injection (pre-response Brain queries) — separate mechanism, different trigger point

## Key Decisions

### 1. Claude Agent SDK with Haiku, long-running resumed session

The curator runs via `query_streaming()` (same as the main chat orchestrator)
but with `model="haiku"` and `resume=<daily_session_id>`. This is the right
choice for several reasons:

- **Day-spanning continuity**: `resume=` lets the curator accumulate context
  across all conversations throughout the day — it remembers what it already
  summarized, notices patterns, and makes increasingly coherent decisions
- **Proper agent loop**: the curator calls tools (`update_title`, `log_activity`,
  etc.) and the SDK handles the tool execution cycle naturally
- **Aligned with the rest of the system**: the curator is a sibling to the main
  chat session, not a lightweight one-shot call. When Brain extraction lands,
  it'll need tool access that fits naturally in this shape
- **Subprocess overhead is acceptable**: curator runs at cadence (not every
  exchange) and fire-and-forget, so 200-400ms startup doesn't block anything

The curator has its own tool set — different from the main chat session's tools.
It observes the main thread but operates with a different set of capabilities.

### 2. MCP tools for writeback (agent-native)

Rather than parsing `SUMMARY: / TITLE:` text lines, the curator responds with
tool calls. The server executes them. This means:
- The curator's reasoning is visible in the UI (tool call = explicit decision)
- Adding a new output (Brain, journal entry) = adding one more tool
- No fragile text parsing

Tools in v1:
- `update_title(title: str)` — updates session title, sets title_source=ai
- `update_summary(summary: str)` — updates session summary
- `log_activity(summary: str)` — appends to `Daily/.activity/{date}.jsonl`

### 3. Day-spanning session continuity

One curator SDK session per day, cached at `Daily/.activity/.curator_sessions.json`.
The curator accumulates context about the day's activity across all conversations —
it can see patterns, avoid redundant updates, and build richer summaries over time.

This was the `resume=` pattern from the original. Preserving it.

### 4. Fire-and-forget asyncio task, same trigger point

Same trigger as `session_summarizer.py` — `asyncio.create_task()` before
`yield DoneEvent()` in orchestrator. Cadence control preserved ({1, 3, 5}, every
10th). Replaces `session_summarizer.py` entirely.

### 5. Light UI: curator chip in chat header

Not a full bottom sheet (that's ~500+ lines of Flutter). Instead:
- A small chip/indicator in the chat session header that appears after the
  curator runs, showing what changed: "Updated title · Logged"
- Tappable to see a lightweight history view — last few curator runs, what tools
  were called, the resulting actions
- Manual trigger button (already existed in the original, useful for dev/testing)

The chip approach gives visibility without a second full screen. Can evolve to
a richer view later when Brain is integrated.

### 6. No separate DB tables for curator

The original had `curator_sessions` and `curator_queue` SQLite tables. This was
the complexity that led to the Feb 16 sweep. We don't need them:
- The curator session ID lives in the file-based cache (already implemented)
- Task status tracking isn't necessary for fire-and-forget
- Results flow back via MCP tool execution (immediate, no queue needed)

The only server state is: `sessions.db` (title/summary written via existing
`database.update_session()`) + `Daily/.activity/{date}.jsonl` (activity log).

## Architecture

```
end of exchange (orchestrator)
  ↓ asyncio.create_task()
CuratorService.observe(session_id, message, result_text, tool_calls, exchange_num)
  ├── _should_update(exchange_num)?  →  no → return
  ├── build prompt (current title, exchange content, context)
  ├── query_streaming(model="haiku", resume=daily_session_id, tools=[update_title, update_summary, log_activity])
  ├── for each tool_call in response (SDK agentic loop):
  │     update_title    → database.update_session(title=..., metadata.title_source=ai)
  │     update_summary  → database.update_session(summary=...)
  │     log_activity    → append to Daily/.activity/{date}.jsonl
  └── save curator run result (tool calls + actions) → emit via SSE or store for UI
```

## What the UI Shows

```
Chat header:
  [Session Title]  [curator chip: "Updated title · Logged"]

Tapping chip → lightweight inline view:
  Run at 3:47pm
  ├── update_title("Python Async Patterns")
  ├── update_summary("Discussed asyncio task patterns...")
  └── log_activity("Exchange 3: Explored asyncio patterns")

  Run at 3:31pm
  └── (no changes)

  [Trigger manually ▶]
```

## Open Questions

- Should the curator see the full exchange content, or just the user message +
  tool call names? (Full content gives better summaries but larger prompt)
- Does the curator session need to see summaries of *previous* exchanges in the
  same chat, or just the current one? The `resume=` pattern gives it its own
  history but not the parent chat's history.
- Should `log_activity` write a natural-language summary or a structured JSON
  entry? Current `activity_hook.py` writes JSON; curator could write richer prose.
- Brain extraction will go in the same curator call — `write_brain_entity` tool
  added alongside the others. Same agentic loop, broader mandate.

## Reference: Original Implementation

Archived repos:
- `OpenParachutePBC/parachute-chat` — Python server with `CuratorService`,
  `curator_sessions` + `curator_queue` DB tables, REST API endpoints
- `OpenParachutePBC/parachute-app` — Flutter: `curator_session.dart`,
  `curator_session_viewer_sheet.dart`, `chat_curator_providers.dart`

The original UI was two tabs ("Chat" + "Tasks"), full bottom sheet, Riverpod
providers. Solid reference for the richer UI when we get there.
