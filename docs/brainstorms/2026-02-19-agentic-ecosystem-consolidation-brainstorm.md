# Agentic Ecosystem Consolidation

> Simplify Parachute's extension model from 12 overlapping systems to 5 clear primitives, aligned with SDK-native patterns and open standards. Make our wrapper around Claude Agent SDK thinner — closer to TinyClaw's philosophy than OpenClaw's.

**Date:** 2026-02-19
**Status:** Brainstorm
**Modules:** computer, app

---

## What We're Building

A unified, SDK-first extension architecture where:

- **5 primitives** replace the current 12 extension points
- The **vault filesystem** is the shared contract between SDK and Parachute
- The **Flutter app** has a full extensions panel for browsing and managing agents, skills, MCPs, and hooks
- **Modules remain Parachute-native** — they're server infrastructure, not user-facing extension points
- The SDK wrapper is **thin** — Parachute orchestrates and manages, the SDK executes

## Why This Approach

### The Wrapper Thickness Spectrum

| | **TinyClaw** | **Parachute** (goal) | **OpenClaw** |
|---|---|---|---|
| Wrapper thickness | ~400 lines, shell script | Thin Python server, vault-centric | Massive gateway + daemon |
| What it wraps | Claude Code + tmux | Claude Agent SDK | Any LLM provider |
| Extensions | Uses Claude Code's native plugins | SDK-native primitives + modules | Custom skill/plugin ecosystem |
| Philosophy | "Do less, rely on stable tools" | "Thin orchestration, vault is the contract" | "Rebuild everything, model-agnostic" |

**Key insight from TinyClaw:** *Delegate complexity to Claude Code rather than reimplementing it.* Parachute should be closer to TinyClaw's philosophy but with real server infrastructure (modules, auth, sandboxing, trust) that TinyClaw lacks.

**OpenClaw's mistake (for us):** Rebuilding every primitive (skills, memory, scheduling, sessions) when the SDK already provides them. We don't want to be a "thick gateway" — we want to be a thin orchestrator that adds trust, management, and UI.

### Current State: Too Many Systems

Parachute currently has 12 extension points across 7 systems:

| System | Extension Points | Problem |
|--------|-----------------|---------|
| **Hooks** | SDK hooks + HookRunner | Two parallel hook systems, HookRunner barely used |
| **Agents** | Vault agents + Custom agents + .claude agents | Three discovery paths, different formats |
| **MCPs** | Built-in + User `.mcp.json` + Plugin-embedded | Three sources, merged at runtime |
| **Skills** | `vault/.skills/` | Fine, but wrapped in runtime plugin generation |
| **Plugins** | Parachute-managed + CLI + User | Three plugin sources, complex indexing |
| **Commands** | `.claude/commands/` | Dev-only, fine as-is |
| **Modules** | `vault/.modules/` | Server infra, correctly separate |

The mental model burden is high. Adding a capability means knowing which of 12 entry points to use.

### Design Principles

1. **SDK-first**: If Claude SDK (or Goose, or future agents) already models a primitive, use it. Don't reinvent.
2. **Vault as contract**: The vault directory structure IS the API. Both SDK and app read from it.
3. **Layered complexity**: Simple things easy (pick an agent), hard things possible (write a hook).
4. **Architectural insurance**: Claude is primary, but abstractions should allow other agent runtimes (Goose) later.
5. **Thin wrapper**: Parachute adds trust, UI, and management — not a parallel execution layer.

## Consolidated Model: 5 Primitives

### 1. Agents — `vault/agents/*.md`

**What changes:**
- Kill `vault/.parachute/agents/` (custom agents) — merge into `vault/agents/`
- One format: Markdown with YAML frontmatter (already SDK-native)
- Parachute adds: trust level filtering, app UI for browsing/selecting

**Current flow (3 paths):**
```
vault/agents/*.md          → agent_loader.py → orchestrator
vault/.parachute/agents/*  → agents.py       → orchestrator (separate path)
.claude/agents/*           → SDK native      → SDK (dev-only)
```

**Consolidated flow (1 user-facing path):**
```
vault/agents/*.md  → SDK discovery + Parachute trust filtering → orchestrator
.claude/agents/*   → SDK native (dev-only, not user-facing)
```

**Open thinking:** We're not heavily using Parachute-specific agents yet. The agent format and capability model needs more thought as we build real agents. The SDK's markdown agent format is the right starting point.

### 2. MCPs — `vault/.mcp.json`

**What changes:**
- One source of truth: `vault/.mcp.json` (global)
- Built-in `parachute` MCP still hardcoded (server infrastructure)
- Plugin MCPs → installer writes to `.mcp.json` instead of embedding
- App UI: manage servers, see connection status, add/remove

**Workspace-level MCPs:**
When sandboxed Docker containers become the default, each workspace may need its own MCP configuration. The model:

- Global `vault/.mcp.json` defines all available MCP servers
- Workspace capabilities filter which MCPs are available (existing allowlist)
- Parachute **assembles** the right `.mcp.json` for each workspace container
- The container gets the assembled config mounted read-only
- The built-in `parachute` MCP runs on the host and tunnels into the container

**For skills/agents in sandboxed containers:**
- Mount as read-only bind mounts into the container's `.claude/` directory
- Parachute shapes the Claude files for a given workspace — assembling the right agents, skills, and MCPs before the SDK sees them

**Standards alignment:**
- MCP is already an open standard (Anthropic + community)
- Goose supports MCP natively
- Other agent frameworks adopting MCP
- `.mcp.json` is the SDK's native config format

### 3. Skills — `vault/.skills/`

**What changes:**
- Minimal — this already works well
- Runtime plugin generation stays (SDK needs plugins format)
- App UI: browse available skills, see descriptions

### 4. Hooks — SDK hooks (user-facing) + Internal event bus (server plumbing)

**Decision: Two clear layers with a hard boundary.**

**User-facing hooks → SDK native:**
- Configured in `.claude/settings.json` (or workspace equivalent)
- Agent lifecycle events: Stop, Start, PreToolUse, etc.
- Subprocess-based, isolated, fire-and-forget
- Example: `activity_hook.py` for auto-titling (already working)

**Internal event bus → HookRunner (demoted):**
- NOT user-facing, NOT an extension point
- Used for server-to-module and module-to-module communication
- Bot connector events (`bot.connector.down`, `bot.connector.reconnected`)
- Future: module lifecycle events, context management events
- In-process async, efficient for high-frequency internal events

**Why keep HookRunner as internal plumbing:**
- Bot connectors fire exactly 2 events through it (`BOT_CONNECTOR_DOWN`, `BOT_CONNECTOR_RECONNECTED`)
- The code is already defensive — `getattr(self.server, "hook_runner", None)` with graceful degradation
- In-process async is better for internal events than spawning subprocesses
- Ripping it out would break bot monitoring without clear benefit
- Clear boundary: internal = HookRunner, external = SDK hooks

**What changes:**
- Stop exposing HookRunner as a user extension point
- Remove `vault/.parachute/hooks/` as a user-facing directory
- Keep HookRunner in server.py for internal events only
- App UI: show SDK hooks status (from `.claude/settings.json`)

### 5. Modules — `vault/.modules/`

**What stays the same:**
- Parachute-native server infrastructure
- Brain, Chat, Daily as loadable modules
- Interface registry for inter-module communication
- Hash verification for security

**What modules are NOT:**
- Not user-facing extension points (users don't "install modules")
- Not agent primitives (they're server infrastructure)

### What Gets Killed or Absorbed

| Current System | Fate | Migration |
|---------------|------|-----------|
| `vault/.parachute/agents/` | Absorbed into `vault/agents/` | Move files, update discovery |
| HookRunner (user-facing) | Demoted to internal bus | Remove user hook discovery, keep for bot events |
| `vault/.parachute/hooks/` | Removed as extension point | Any user hooks become SDK hooks |
| Plugin system (3 sources) | Simplified to installer | Plugins = bundles that install agents/skills/MCPs to standard locations |
| Commands (`.claude/commands/`) | Kept as-is | Dev-only, no change needed |

## Key Decisions

1. **SDK-first, not SDK-only.** Modules remain Parachute-native because the SDK doesn't model server infrastructure.
2. **Vault filesystem is the contract.** No translation layers. Both SDK and app read the same files.
3. **Full extensions panel in app.** Users can browse and manage all primitives from the Flutter UI.
4. **Plugins become installers.** A plugin is just a bundle that puts agents, skills, and MCPs in the right vault locations.
5. **One agent format.** Markdown with YAML frontmatter, SDK-compatible.
6. **HookRunner stays as internal plumbing.** Not user-facing. Bot connector events and future module events use it. User hooks go through SDK.
7. **Thin wrapper philosophy.** Follow TinyClaw's lead — delegate to the SDK, don't reimplement. Parachute adds trust, UI, workspace management, and multi-device access.
8. **Workspace MCP assembly.** Parachute shapes the SDK config files for each workspace/container. Global MCPs + workspace filtering = assembled config.

## Migration Path

### Phase 1: Consolidate agents
- Merge `vault/.parachute/agents/` into `vault/agents/`
- Update discovery code to use single path
- Small, safe change

### Phase 2: Demote HookRunner
- Remove user hook discovery from `vault/.parachute/hooks/`
- Keep HookRunner for internal bot connector events
- Document the internal/external boundary in CLAUDE.md

### Phase 3: Simplify plugins
- Make plugin install write to standard locations (`vault/agents/`, `vault/.skills/`, `vault/.mcp.json`)
- Keep plugin metadata for uninstall tracking
- Plugin indexing becomes simpler

### Phase 4: App extensions panel
- Build UI that reads from the 5 standard locations
- Agent picker, MCP status, skill browser, hook viewer
- Progressive — can ship incrementally

### Phase 5: Clean up
- Remove dead code paths
- Update CLAUDE.md documentation
- Simplify orchestrator's discovery flow

## Standards to Watch

- **MCP**: Already adopted. Core to our architecture. `.mcp.json` is the standard config.
- **A2A (Agent-to-Agent)**: Google's protocol for inter-agent communication. Relevant if we do multi-agent.
- **OpenAI function calling / tool use**: Converging with MCP tool format.
- **Goose**: Block's open-source agent that supports MCP. Good test of our provider-agnosticism.
- **Claude Agent SDK**: TypeScript + Python SDKs. Our primary execution engine.

## What This Enables

1. **Clearer mental model**: "Where do I put X?" has one answer per primitive
2. **App-native extensions**: Users manage their ecosystem from the Flutter app
3. **Plugin marketplace (future)**: Plugins are just bundles of standard primitives — easy to share
4. **Provider portability**: Vault structure works with any agent runtime that supports MCP + markdown agents
5. **Simpler orchestrator**: Discovery flow goes from 7 systems to scan → 3 paths to scan
6. **Workspace sandboxing**: Parachute assembles the right SDK config per workspace container
7. **Thinner codebase**: Less custom code to maintain, more leverage from SDK improvements
