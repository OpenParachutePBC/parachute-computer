# Refactor: Agentic Ecosystem Consolidation

> Simplify from 12 extension points to 5 primitives. Make our Claude Agent SDK wrapper thinner — closer to TinyClaw's "delegate to the SDK" philosophy than OpenClaw's "rebuild everything" approach.

**Date:** 2026-02-19
**Type:** refactor
**Modules:** computer, app
**Brainstorm:** #74
**Effort:** ~12-13 person-days across 5 phases

---

## Overview

Parachute currently has 12 overlapping extension points across 7 systems. Agents are discovered from 3 paths, MCPs from 3 sources, plugins from 3 locations, and we have 2 parallel hook systems. This creates high mental model burden and makes the codebase harder to maintain.

This plan consolidates to **5 clear primitives**, each with one canonical location:

| Primitive | Location | Discovery | Parachute Adds |
|-----------|----------|-----------|----------------|
| **Agents** | `vault/agents/*.md` | SDK-native markdown | Trust filtering, app UI |
| **MCPs** | `vault/.mcp.json` | SDK-native config | App management, workspace assembly |
| **Skills** | `vault/.skills/` | Runtime plugin generation | App browsing |
| **Hooks** | `.claude/settings.json` (user) / HookRunner (internal) | SDK hooks + internal bus | Status in app |
| **Modules** | `vault/.modules/` | Parachute-native | Server infrastructure only |

## Problem Statement

**Too many systems:**
- 3 agent paths: `vault/agents/`, `vault/.parachute/agents/`, `.claude/agents/`
- 3 MCP sources: built-in, `vault/.mcp.json`, plugin-embedded
- 3 plugin sources: Parachute-managed, CLI, legacy user
- 2 hook systems: SDK hooks + HookRunner (HookRunner fires only 2 bot events)
- 7 discovery calls per stream in the orchestrator

**Orchestrator is too thick:**
- `execute_stream()` runs discovery for skills, plugins (3x), agents, MCPs, and merges them all
- Each stream re-discovers everything (no caching)
- Plugin MCPs are merged into global MCPs at runtime with no namespace isolation

**App has APIs but no UI:**
- `/api/agents`, `/api/skills`, `/api/mcp`, `/api/plugins`, `/api/hooks` all exist
- The Flutter app surfaces none of this — no extensions panel

## Technical Approach

### Architecture

**Before:** 7 systems, 12 extension points, thick orchestrator
```
Orchestrator
├── load_agent()           → agent_loader.py (vault/agents/)
├── discover_agents()      → agents.py (vault/.parachute/agents/)
├── load_mcp_servers()     → mcp_loader.py (vault/.mcp.json + built-in)
├── discover_skills()      → skills.py (vault/.skills/)
├── generate_runtime_plugin() → skills → plugin format
├── discover_plugins()     → plugins.py (3 sources, recursive indexing)
├── merge plugin MCPs      → inline in orchestrator
├── merge plugin agents    → get_plugin_dirs()
└── filter_by_trust_level() → 2 passes (MCPs + capabilities)
```

**After:** 5 primitives, thin orchestrator
```
Orchestrator
├── load_agent()           → agent_loader.py (vault/agents/ — single path)
├── load_mcp_servers()     → mcp_loader.py (vault/.mcp.json — single file)
├── discover_skills()      → skills.py (vault/.skills/ — unchanged)
├── get_plugin_dirs()      → plugins.py (metadata-only, contents in standard locations)
└── filter_by_trust_level() → single pass
```

### Implementation Phases

---

#### Phase 1: Consolidate Agents (~1 day)

**Goal:** One agent location, one format, one discovery path.

**Changes:**

`computer/parachute/core/agents.py`:
- Remove `discover_agents()` function (custom agent discovery from `.parachute/agents/`)
- Remove `agents_to_sdk_format()` conversion
- Keep only the `get_agents_for_system_prompt()` function, updated to read from `vault/agents/`

`computer/parachute/lib/agent_loader.py`:
- Already handles `vault/agents/*.md` — no changes needed
- This becomes the single agent discovery path

`computer/parachute/core/orchestrator.py` (~line 597):
- Remove `discover_agents(vault_path)` call
- Remove custom agents dict construction
- Vault agents from `load_agent()` / `load_all_agents()` are the only agents

`computer/parachute/api/agents.py`:
- `POST /agents` — change write target from `.parachute/agents/` to `vault/agents/`
- `GET /agents` — remove custom agents section (lines 86-99), keep vault agents + built-in
- `DELETE /agents/{name}` — update path to `vault/agents/`

**Migration:**
- On server start, if `vault/.parachute/agents/` has files:
  - Copy each to `vault/agents/` (converting YAML/JSON to Markdown if needed)
  - Log migration notice
  - Leave originals in place (no deletion)
- Add deprecation warning in logs if `.parachute/agents/` still has files after 2 releases

**Edge cases:**
- Name collision: If both paths have same-named agent, vault agent wins, migration logs a warning
- Format conversion: `AgentConfig` (simple YAML) → `AgentDefinition` (markdown + frontmatter). Map `description` → frontmatter, `prompt` → body, `tools`/`model` → frontmatter fields

**Acceptance criteria:**
- [ ] `vault/agents/*.md` is the only user-facing agent location
- [ ] `POST /agents` creates in `vault/agents/`
- [ ] `GET /agents` returns vault agents + built-in only
- [ ] Orchestrator no longer calls `discover_agents()`
- [ ] Existing `.parachute/agents/` files auto-migrated on startup
- [ ] Tests updated: agent discovery, API creation, API listing

---

#### Phase 2: Demote HookRunner (~0.5 day)

**Goal:** SDK hooks are the user-facing hook system. HookRunner becomes internal plumbing only.

**Changes:**

`computer/parachute/core/hooks/runner.py`:
- Keep `HookRunner` class entirely — it works, bot connectors use it
- Remove user hook discovery from `vault/.parachute/hooks/` in `discover()` method
- HookRunner only fires internal events (bot connector up/down)
- Add docstring: "Internal event bus for server-to-module communication. Not user-facing."

`computer/parachute/server.py`:
- Keep HookRunner initialization (bot connectors need it)
- Remove user hook discovery step
- Simplify init to: `hook_runner = HookRunner(); app.state.hook_runner = hook_runner`

`computer/parachute/api/hooks.py`:
- `GET /hooks` — return SDK hooks from `.claude/settings.json` instead of HookRunner registry
- `GET /hooks/errors` — keep for internal hook error monitoring

**No migration needed:**
- No known user hooks exist in `vault/.parachute/hooks/`
- If any are found at startup, log a deprecation notice

**Acceptance criteria:**
- [ ] HookRunner no longer discovers user hooks from `vault/.parachute/hooks/`
- [ ] Bot connector events (`BOT_CONNECTOR_DOWN`, `BOT_CONNECTOR_RECONNECTED`) still fire
- [ ] `GET /hooks` returns SDK hook config
- [ ] Tests updated: bot connector hook firing still works
- [ ] CLAUDE.md updated: document internal vs external hook boundary

---

#### Phase 3: Simplify Plugins (~3 days)

**Goal:** Plugins become installers that write to standard locations. Plugin dirs only carry metadata.

**Changes:**

`computer/parachute/core/plugin_installer.py`:
- Rewrite `install_plugin_from_url()`:
  1. Clone to temp directory
  2. Read `.claude-plugin/plugin.json` manifest
  3. Copy `agents/*.md` → `vault/agents/` (with `plugin-{slug}-` prefix for namespacing)
  4. Copy `skills/` → `vault/.skills/` (with prefix)
  5. Merge `.mcp.json` → `vault/.mcp.json` (error on conflict)
  6. Write install manifest to `vault/.parachute/installed_plugins.json`
  7. Keep plugin dir for metadata/uninstall tracking only
  8. Clean up temp directory

`vault/.parachute/installed_plugins.json` schema:
```json
{
  "version": 1,
  "plugins": {
    "plugin-slug": {
      "source_url": "https://github.com/org/plugin",
      "installed_at": "2026-02-19T...",
      "version": "1.0.0",
      "installed_files": {
        "agents": ["vault/agents/plugin-slug-reviewer.md"],
        "skills": ["vault/.skills/plugin-slug-brainstorm/"],
        "mcps": ["github-tools"]
      }
    }
  }
}
```

`computer/parachute/core/plugins.py`:
- Simplify `discover_plugins()` — read metadata only from manifest, no recursive indexing
- Remove `_index_plugin()`, `_discover_plugin_skills()`, `_discover_plugin_agents()`, `_discover_plugin_mcps()`
- Keep `get_plugin_dirs()` for CLI/legacy plugins that haven't been migrated

`computer/parachute/core/orchestrator.py`:
- Remove plugin MCP merging (lines 572-579) — MCPs already in `.mcp.json`
- Simplify plugin_dirs to only SDK-required paths

**Uninstall flow:**
1. Read manifest to get installed file paths
2. Delete each file
3. Remove MCP entries from `vault/.mcp.json`
4. Remove manifest entry

**Migration:**
- On first run with new code, scan existing plugins in `vault/.parachute/plugins/`
- For each, run the new install flow (copy embedded content to standard locations)
- Write manifest for each
- Log migration progress

**Edge cases:**
- Plugin update: Uninstall (tracked files), then reinstall from new source
- Name conflict on install: Error with message "Agent 'reviewer' already exists. Use --force to overwrite."
- User edits installed agent: Uninstall warns "Modified files will be deleted"

**Acceptance criteria:**
- [ ] `POST /plugins/install` copies content to standard locations
- [ ] `DELETE /plugins/{slug}` removes tracked files
- [ ] Install manifest tracks all files per plugin
- [ ] Orchestrator no longer merges plugin MCPs inline
- [ ] Existing plugins auto-migrated on startup
- [ ] Tests: install, uninstall, update, conflict detection

---

#### Phase 4: App Extensions Panel (~5 days)

**Goal:** Full extensions UI in Flutter app — browse and manage agents, skills, MCPs, hooks.

**App changes** (`app/lib/features/settings/`):

New sections in Settings:

**`extensions_section.dart`** — Parent container with tabs:
- Agents tab
- Skills tab
- MCPs tab
- Hooks tab

**`agent_browser_section.dart`**:
- List all agents from `GET /agents`
- Show name, description, type, source (built-in vs vault)
- Tap to view full agent definition
- FAB to create new agent (calls `POST /agents`)
- Swipe to delete (calls `DELETE /agents/{name}`)

**`skill_browser_section.dart`**:
- List all skills from `GET /skills`
- Show name, description, version
- Tap to view skill content

**`mcp_manager_section.dart`**:
- List all MCP servers from `GET /mcp`
- Show name, type (stdio/http), validation status
- Add new MCP (calls `POST /mcp`)
- Remove MCP (calls `DELETE /mcp/{name}`)

**`hook_viewer_section.dart`**:
- Show SDK hooks from `GET /hooks`
- Display hook command, event type, matcher
- Show recent errors from `GET /hooks/errors`

**Providers** (`app/lib/features/settings/providers/`):
- `extensions_provider.dart` — fetches all extension data
- Uses existing API client patterns from settings providers

**Design:**
- Match existing settings panel style (list tiles, sections)
- Show workspace filtering: items grayed out if not available in current workspace
- Pull-to-refresh for live updates

**Acceptance criteria:**
- [ ] Extensions section visible in Settings
- [ ] All 4 tabs (Agents, Skills, MCPs, Hooks) functional
- [ ] Agent creation and deletion from app
- [ ] MCP add/remove from app
- [ ] Workspace trust filtering indicated visually
- [ ] Follows existing Riverpod/provider patterns

---

#### Phase 5: Clean Up (~1 day)

**Goal:** Remove dead code, update docs, simplify orchestrator.

**After Phases 1-4 have been stable for 2+ release cycles:**

**Code removal:**
- [ ] Delete `computer/parachute/core/agents.py` `discover_agents()` function
- [ ] Delete `computer/parachute/core/plugins.py` indexing functions (`_index_plugin`, `_discover_plugin_*`)
- [ ] Remove dual-path fallbacks added during migration
- [ ] Remove deprecation warnings
- [ ] Clean up unused imports

**Documentation:**
- [ ] Update `computer/CLAUDE.md` — document 5 primitives model
- [ ] Update `app/CLAUDE.md` — document extensions panel
- [ ] Update root `CLAUDE.md` — reflect consolidated architecture

**Orchestrator simplification:**
- [ ] Verify discovery flow is now 4 calls (agent, MCP, skills, plugins metadata)
- [ ] Remove any remaining merge logic

**Acceptance criteria:**
- [ ] No references to `.parachute/agents/` in codebase (except migration code if kept)
- [ ] No user-facing references to HookRunner
- [ ] CLAUDE.md files document the 5 primitives model
- [ ] Orchestrator discovery is measurably simpler

---

## Acceptance Criteria

### Functional Requirements

- [ ] Agents: Single discovery path (`vault/agents/`) with auto-migration from old path
- [ ] Hooks: SDK hooks user-facing, HookRunner internal-only, bot events still fire
- [ ] Plugins: Install copies to standard locations, uninstall removes tracked files
- [ ] App: Full extensions panel with 4 tabs (Agents, Skills, MCPs, Hooks)
- [ ] Orchestrator: Reduced from 7 to 4 discovery calls per stream

### Non-Functional Requirements

- [ ] No breaking changes without migration path
- [ ] Each phase deployable independently (except Phase 5)
- [ ] Bot connectors unaffected (Telegram, Discord)
- [ ] Trust level filtering still works across all primitives

### Quality Gates

- [ ] All existing tests pass after each phase
- [ ] New tests for migration logic, plugin install/uninstall
- [ ] CLAUDE.md updated after each phase

## Dependencies & Prerequisites

- Phase 1 (agents) has no dependencies — can start immediately
- Phase 2 (hooks) has no dependencies — can start immediately
- Phase 3 (plugins) depends on Phase 1 (agents must be consolidated first)
- Phase 4 (app) can start in parallel with Phases 1-3 (uses existing APIs)
- Phase 5 (cleanup) depends on all prior phases being stable

## Risk Analysis & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Existing custom agents lost during migration | HIGH | Auto-copy, never delete originals, log migration |
| Plugin uninstall deletes user-modified files | MEDIUM | Warn before delete, check for modifications |
| HookRunner removal breaks bot monitoring | HIGH | Keep HookRunner as internal bus, only remove user discovery |
| App UI shows stale data after install | LOW | SSE events for capability changes, pull-to-refresh |
| In-flight sessions reference deleted paths | MEDIUM | Graceful fallback to vault-agent if agent not found |

## References

### Internal

- Brainstorm: `docs/brainstorms/2026-02-19-agentic-ecosystem-consolidation-brainstorm.md`
- GitHub Issue: #74
- Hooks expansion brainstorm: `docs/brainstorms/2026-02-17-hooks-expansion-brainstorm.md`

### Key Files

- `computer/parachute/core/orchestrator.py` — Central discovery flow (lines 234-670)
- `computer/parachute/core/agents.py` — Custom agent discovery (to be simplified)
- `computer/parachute/lib/agent_loader.py` — Vault agent loader (becomes canonical)
- `computer/parachute/core/plugins.py` — Plugin system (to be simplified)
- `computer/parachute/core/hooks/runner.py` — HookRunner (to be demoted)
- `computer/parachute/api/agents.py` — Agent API endpoints
- `computer/parachute/api/plugins.py` — Plugin API endpoints

### External

- TinyClaw philosophy: https://github.com/jlia0/tinyclaw — "delegate to Claude Code"
- MCP standard: https://modelcontextprotocol.io
- Claude Agent SDK: https://platform.claude.com/docs/en/agent-sdk/overview
