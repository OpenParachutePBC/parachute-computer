# Hooks Expansion: Curator, Summaries, and Built-in Hooks

**Date:** 2026-02-17
**Status:** Ready for planning
**Priority:** P2
**Modules:** computer, chat

## What We're Building

Expand the hook system to provide intelligent background services: auto-titling (curator), chat summaries, and a set of useful built-in hooks. Leverage the existing dual-layer hook architecture (Claude Code CLI hooks + Parachute application hooks) rather than building new infrastructure.

## Why This Approach

We already have two complementary hook systems:

1. **Claude Code CLI hooks** (14 events, tool-use lifecycle) — configured in `.claude/settings.json`, fires on PreToolUse, PostToolUse, Stop, SessionStart, etc.
2. **Parachute application hooks** (14 events, domain-level) — Python scripts in `vault/.parachute/hooks/`, fires on session.created, message.received, session.completed, etc.

The bridge pattern exists: `activity_hook.py` already translates CLI `Stop` events into Parachute activity logs. New hooks should follow this established pattern.

## Hook Ideas

### 1. Curator Hook (Auto-Titling)
**Previously existed as a background service, now reimplemented as a hook.**

- **Trigger:** CLI `Stop` event (after each assistant turn) or Parachute `session.completed`
- **Mechanism:** `type: "prompt"` hook (Claude Code's built-in LLM evaluation) or a command hook that calls Haiku
- **Logic:** Compare current title against recent conversation content. If the title is stale, generic ("New Chat"), or no longer reflects the conversation, generate a better one.
- **Output:** Update session title via Parachute API (`PUT /api/sessions/{id}`)
- **Frequency:** Don't run on every message — perhaps every 5th message or when the conversation topic shifts significantly

### 2. Chat Summary Hook
**Generate and maintain a running summary of each chat session.**

- **Trigger:** CLI `Stop` event or Parachute `session.completed`
- **Mechanism:** Command hook calling Haiku for summarization
- **Logic:** Read the conversation, generate a concise summary (1-3 sentences for short chats, growing for longer ones). Store as session metadata.
- **Use cases:**
  - Better search results (search over summaries, not just titles)
  - Session list preview text
  - Context when resuming old conversations
  - Knowledge base for the Brain module
- **Storage:** New `summary` field on session metadata, or a sidecar file

### 3. Activity/Decision Log Hook
**Already partially implemented as `activity_hook.py`.**

- Extend to capture key decisions, not just activity
- Structure: what was discussed, what was decided, what was done
- Could feed into Daily module for end-of-day summaries

### 4. Context Re-injection Hook
**Restore important context after compaction.**

- **Trigger:** CLI `SessionStart` with `compact` matcher, or `PreCompact`
- **Logic:** Re-inject critical project context, conventions, or decisions that would be lost during context window compaction
- **Pattern:** Already documented in Claude Code hooks guide

## Research: External Patterns

### Claude Code CLI Hook Types
- **Command hooks** (`type: "command"`): Shell commands, stdin JSON, stdout JSON. Best for curator/summary (call Haiku API).
- **Prompt hooks** (`type: "prompt"`): Single-turn LLM evaluation. Good for yes/no decisions (e.g., "should the title be updated?"). Default Haiku, 30s timeout.
- **Agent hooks** (`type: "agent"`): Multi-turn subagent with Read/Grep/Glob access. Overkill for our use cases.

### Craft Agents Patterns
- **Auto-label rules**: Regex patterns that scan messages and auto-tag sessions. We could implement similar auto-tagging via hooks.
- **Prompt hooks that spawn sessions**: When a status changes, create a new agent session. Interesting for automation but not needed yet.
- **Pre-computed session headers**: Fast metadata access without parsing full history. Our summary hook could populate similar metadata.

### OpenClaw Patterns
- **Memory system**: Daily memory entries (`memory/YYYY-MM-DD.md`) + vector similarity + BM25 keyword search. Our summary hook could feed a similar searchable index.
- **Heartbeat system**: Proactive periodic prompts. Could implement as a `SchedulerTick`-style event.

## Key Decisions

- Use Claude Code CLI `Stop` hook for curator and summary (fires after each assistant turn)
- Use Haiku model for cost efficiency on background evaluation tasks
- Start with curator (most immediate value), then add summary hook
- Store summaries as session metadata (new field) rather than separate files
- Rate-limit hook execution (don't re-evaluate title/summary on every single message)

## Open Questions

- What's the right cadence for curator evaluation? Every N messages? Time-based? Topic-shift detection?
- Should summaries be visible in the UI (session list) or purely for search/backend?
- How should we handle hook failures gracefully? (Current system logs errors to deque, exposed via API)
- Should hooks be configurable per-workspace? (e.g., a coding workspace might want more detailed summaries)
- How do we avoid the curator hook updating the title while the user is actively chatting? (Debounce?)
