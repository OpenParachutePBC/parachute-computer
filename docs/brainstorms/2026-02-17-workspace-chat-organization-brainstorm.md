# Workspace & Chat Organization Rethink

**Date:** 2026-02-17
**Status:** Needs more thinking
**Priority:** P2
**Modules:** app, computer, chat

## What We're Building

A rethink of how workspaces and chats are organized, both in the UI and on the backend. This covers the workspace model (what is a workspace, how are they created, what do they contain), the chat organization UX (how users find, filter, and manage conversations), and multi-channel considerations (app, Telegram, Discord).

## Why This Matters

The current workspace/chat organization feels awkward. Common friction points:
- Starting a casual chat shouldn't require setting up a workspace, but you often want some organization
- Chats from Telegram/Discord need to coexist with app-initiated chats
- Workspaces are currently hidden in Settings — they should be more visible and natural to use
- The relationship between workspaces, working directories, and Docker volumes needs clarifying
- It's unclear when a new workspace should be created vs. reusing an existing one

## Current State

### Workspace Model (Backend)
- Stored as YAML at `vault/.parachute/workspaces/{slug}/config.yaml`
- Fields: name, slug, description, default_trust_level, working_directory (optional), model (optional), capabilities, sandbox config
- Working directory is an absolute `/vault/...` path passed to SDK as `cwd`
- Docker sandbox: mounts specific directory as read-write, or entire vault read-only if no working directory
- CRUD via REST API at `/api/workspaces`

### Chat Organization (Frontend)
- Session list grouped by date (Today, Yesterday, This Week, Earlier)
- Optional workspace filter chip on mobile/tablet
- Workspace selector in "New Chat" sheet auto-fills working directory and trust level
- Workspace management buried in Settings screen
- No status tracking on sessions (all chats are equal — no inbox/archive/done distinction)

### Multi-Channel
- Telegram and Discord bots create sessions via the same API
- Each bot message typically creates a new session (no persistent threads yet)
- Bot sessions have per-platform trust levels

## Research: External Patterns

### OpenClaw
- **Multi-agent workspace isolation**: Each agent gets its own directory with `.claude/` context
- **Session scope modes**: "main" (all DMs share one session) vs "per-peer" (isolate by sender)
- **Three-tier config**: global → per-agent → per-session overrides
- **Session IDs encode trust**: routing AND trust boundary in one identifier

### TinyClaw (jlia0)
- **Agent-per-workspace**: Each agent has its own working directory with complete context isolation
- **File-based message queue**: Atomic filesystem operations for message routing between agents
- **Heartbeat system**: Proactive periodic agent check-ins

### Craft Agents
- **Session-as-Task**: Conversations treated as work items with status workflow (Todo → In Progress → Done)
- **Inbox/Archive pattern**: Sessions filtered by status category (open vs closed), not just date
- **Auto-label rules**: Regex patterns auto-tag sessions from message content
- **Sub-session hierarchy**: One level of parent-child nesting
- **Cascading config**: global → workspace → session
- **Pre-computed session headers**: Fast list rendering from metadata-only first line of JSONL

## Emerging Direction (Option C — Hybrid)

Initial thinking leans toward a hybrid approach:

**Workspaces are primarily organizational containers** (like Craft Agents) — they hold config defaults (model, trust level, capabilities) and optionally point to a working directory. A "General" or "Default" workspace exists for casual/freestanding chats.

**When a workspace has a working directory**, it gets full file access scoped to that directory. When it doesn't, chats have vault-level read access but no dedicated scratch space.

**Key questions still to resolve:**
- Should each new chat auto-create a workspace, or should workspaces be explicitly created?
- For Telegram/Discord chats: do they land in a default workspace, or does each channel get its own?
- Docker volumes: one per workspace with a working directory? Shared volumes for workspaces without one?
- Can a workspace span multiple repos? Which one is the "working directory"?
- Should we adopt session statuses (todo/in-progress/done) or is that too heavyweight?

## UI Considerations

### Workspace Visibility
- Workspaces should be a top-level concept in the chat tab, not buried in Settings
- Consider a sidebar or segmented control for workspace switching
- "New Chat" should make workspace selection natural, not mandatory

### Chat List Improvements
- Consider status-based filtering (active/done/archived) alongside date grouping
- Session summaries (from hooks) could provide better preview text
- Labels/tags for manual organization
- Better search leveraging summaries and auto-tags

### Multi-Channel Integration
- Telegram/Discord chats should appear in the chat list alongside app chats
- Channel indicator (icon/badge) to distinguish source
- Persistent threads for bot channels (not one session per message)

## Key Decisions

- **Hybrid model (Option C)** is the leading direction but needs more exploration
- Workspaces are organizational + optional file scope, not mandatory for every chat
- A default workspace should exist for casual chats
- Session statuses and inbox/archive pattern worth prototyping

## Open Questions (Needs More Thinking)

- What's the right default for a freestanding chat? Vault-read-only? Shared scratch space?
- How do Docker volumes map to workspaces? One volume per workspace? Shared default volume?
- Should workspace creation be automatic (from working directory selection) or always explicit?
- How does the workspace model interact with the Brain module's knowledge graph?
- What's the migration path from current workspace implementation to the new model?
- Should we adopt Craft Agents' session-as-task pattern? How heavyweight is status management?
- How should persistent bot threads work? One session per conversation? Per-peer like OpenClaw?
