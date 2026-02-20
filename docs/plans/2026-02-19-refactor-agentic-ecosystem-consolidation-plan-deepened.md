# Refactor: Agentic Ecosystem Consolidation (Deepened)

> Simplify from 12 extension points to 5 primitives. Make our Claude Agent SDK wrapper thinner — closer to TinyClaw's "delegate to the SDK" philosophy than OpenClaw's "rebuild everything" approach.

**Date:** 2026-02-19
**Type:** refactor
**Modules:** computer, app
**Brainstorm:** #74
**Effort:** ~12-13 person-days across 5 phases
**Deepened from:** `2026-02-19-refactor-agentic-ecosystem-consolidation-plan.md`

---

## Key Insights from Deepening

Research uncovered several important findings that reshape the plan:

### 1. The Agent System Is Overbuilt

Two parallel agent systems exist:
- **AgentDefinition** (`vault/agents/*.md`) — rich schema with permissions, triggers, constraints, spawns. Full Pydantic model. Used in API listings.
- **AgentConfig** (`vault/.parachute/agents/*.md`) — simple schema with name/prompt/tools/model. Converted to SDK subagent format at runtime.

Neither is heavily used. No custom agents are known to exist in either location. These are **subagent templates** (invoked via Task tool during chat), not persistent agents. They don't affect the system prompt — system prompt assembly is a completely separate concern in `orchestrator._build_system_prompt()`.

**Implication:** Phase 1 may be simpler than anticipated — we might be consolidating two unused systems rather than migrating active content. The bigger question is whether "custom subagent templates" is even a feature users want right now, or if we should simplify to just the built-in vault-agent + SDK-native `.claude/agents/`.

### 2. System Prompt ≠ Agents

The plan originally conflated these. They're separate concerns:
- **System prompt**: Assembled from CLAUDE.md files, vault context, conversation history. Tells the agent how to behave.
- **Agents**: SDK subagent templates invoked via Task tool. Allow spawning specialized workers.

The system prompt assembly path (`_build_system_prompt()`) is its own future work — how we compose the right context for each chat. That's not part of this consolidation.

### 3. HookRunner Is Clean to Demote

Two separate hook systems:
- **HookRunner** (`.parachute/hooks/*.py`): Internal event bus. 14 event types. Bot connectors fire `BOT_CONNECTOR_DOWN` and `BOT_CONNECTOR_RECONNECTED` through it. Essentially an observability layer.
- **SDK hooks** (`.claude/settings.json`): Native hook system. The curator/auto-titler from PR #73 runs here.

If HookRunner stops discovering user hooks, nothing breaks. Bot connectors check defensively (`getattr(self.server, "hook_runner", None)`). The demotion is safe.

### 4. Security & Data Integrity Gaps Found

Spec-flow analysis identified 28 gaps. Critical ones:
- **Path traversal in agent names**: `POST /api/agents` uses the name directly as a filename with no sanitization. Names like `../../etc/malicious` would escape the agents directory.
- **No atomic writes to `.mcp.json`**: Concurrent writes (app + plugin installer) can corrupt the file.
- **No agent name validation**: Client or server side. Spaces, special characters, collisions — all unhandled.
- **Plugin MCP merging has no conflict detection**: Silent overwrite of user config.

### 5. Plugin System Is a Custom Invention — Should Align with SDK Conventions

`.claude-plugin/plugin.json` is **not an SDK standard** — it's a Parachute invention. The Claude SDK has its own native directory convention:

```
project/
├── .claude/
│   ├── commands/       # Slash commands
│   ├── agents/         # Subagent definitions
│   └── settings.json   # Hooks, permissions
├── .mcp.json           # MCP server config
└── CLAUDE.md           # System prompt context
```

The SDK discovers all of these via `setting_sources=["project"]` when given a project directory. There is no SDK-native "plugin" or "package" concept — just directories with those standard files.

**Implication:** Our plugin system should not define a custom manifest format. A "plugin" should just be a git repo with SDK-layout files. Parachute's job is: (1) clone it, (2) copy its contents to the vault's standard locations, (3) track what was installed for uninstall. No custom `.claude-plugin/plugin.json` needed.

This is a bigger change to Phase 3 than the original plan anticipated.

### 6. App UI Has a Capabilities Screen Already

The Flutter app already has a `CapabilitiesScreen` with 4 tabs (Agents, Skills, MCPs, Plugins). Phase 4 is partially done — the UI exists but lacks polish, pull-to-refresh, name validation, and hooks integration.

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

---

## Implementation Phases

### Phase 1: Consolidate Agents (~1 day)

**Goal:** One agent location, one format, one discovery path.

**Key decision — do we need vault/agents at all?**

The two current systems are:
- `vault/agents/*.md` → `AgentDefinition` (rich, Pydantic, unused in practice)
- `vault/.parachute/agents/*.md` → `AgentConfig` (simple, converted to SDK subagent format)

Neither has active user content. Options:

| Option | Pros | Cons |
|--------|------|------|
| **A: Keep vault/agents/ as canonical** | Single path, rich schema | Overbuilt, nobody uses it |
| **B: Remove both, lean on SDK .claude/agents/** | Thinnest wrapper, SDK-native | Loses app management surface |
| **C: Keep vault/agents/ but simplify to AgentConfig format** | Simple + manageable | Still maintaining custom code |

**Recommended: Option A with format simplification.** Keep `vault/agents/` as the location but accept the simpler AgentConfig-style frontmatter (name, description, prompt, tools, model). Drop the overbuilt AgentDefinition fields (permissions, constraints, triggers, spawns) that nobody uses. This keeps the app management surface while reducing complexity.

**Changes:**

`computer/parachute/core/agents.py`:
- Remove `discover_agents()` function (custom agent discovery from `.parachute/agents/`)
- Remove `agents_to_sdk_format()` conversion
- Keep `AgentConfig` as the canonical model (simpler than AgentDefinition)

`computer/parachute/lib/agent_loader.py`:
- Simplify `AgentDefinition` to match `AgentConfig` fields (or replace entirely)
- Drop unused fields: `permissions`, `constraints`, `context`, `triggers`, `spawns`
- Accept both the current rich format and simpler format for backwards compat

`computer/parachute/core/orchestrator.py` (~line 597):
- Remove `discover_agents(vault_path)` call
- Use `load_all_agents()` as the single agent source
- Convert loaded agents to SDK format inline

`computer/parachute/api/agents.py`:
- **Security fix**: Validate agent names against `^[a-zA-Z0-9_-]+$` (path traversal prevention)
- `POST /agents` — write to `vault/agents/`, validate name
- `GET /agents` — return vault agents + built-in only (remove custom_agents section)
- `DELETE /agents/{name}` — allow deletion of non-builtin vault agents

**Migration:**
- On server start, if `vault/.parachute/agents/` has files:
  - Copy each to `vault/agents/` (converting YAML/JSON to Markdown if needed)
  - Skip files where name collision exists, log warning
  - Leave originals in place (no deletion)
- Migration is copy-not-move — safe to run multiple times

**Edge cases (from spec-flow analysis):**
- Name collision: vault agent wins, migration logs warning. User resolves manually.
- Format conversion: `AgentConfig` (YAML) → simplified `AgentDefinition` (markdown + frontmatter). Map `description` → frontmatter, `prompt` → body, `tools`/`model` → frontmatter.
- Active sessions with stale agent paths: Orchestrator falls back to vault-agent if referenced agent not found.
- API name validation: Both client and server validate `^[a-zA-Z0-9_-]+$`.

**Acceptance criteria:**
- [ ] `vault/agents/*.md` is the only user-facing agent location
- [ ] Agent names validated for filesystem safety on create
- [ ] `POST /agents` creates in `vault/agents/`
- [ ] `GET /agents` returns vault agents + built-in only
- [ ] Orchestrator no longer calls `discover_agents()`
- [ ] Existing `.parachute/agents/` files auto-migrated on startup
- [ ] Tests updated: agent discovery, API creation, API listing, name validation

---

### Phase 2: Demote HookRunner (~0.5 day)

**Goal:** SDK hooks are the user-facing hook system. HookRunner becomes internal plumbing only.

**Current state:**
- HookRunner fires 14 event types, but only 2 are used by bot connectors (`BOT_CONNECTOR_DOWN`, `BOT_CONNECTOR_RECONNECTED`)
- No known user hooks exist in `vault/.parachute/hooks/`
- Bot connectors check for HookRunner defensively — they work fine without it
- SDK hooks (`.claude/settings.json`) handle the real work (curator auto-titler)

**Changes:**

`computer/parachute/core/hooks/runner.py`:
- Remove user hook discovery from `vault/.parachute/hooks/` in `discover()` method
- Keep `HookRunner` class — bot connectors use it for internal events
- Add docstring: "Internal event bus for server-to-module communication. Not user-facing."
- Consider: reduce to only the 2 bot connector events + `SERVER_STARTED`/`SERVER_STOPPING`

`computer/parachute/server.py`:
- Keep HookRunner initialization (simplified)
- Remove user hook discovery step

`computer/parachute/api/hooks.py`:
- `GET /hooks` — return SDK hooks from `.claude/settings.json` instead of HookRunner registry
- Parse `.claude/settings.json` → extract `hooks` config → return formatted response
- `GET /hooks/errors` — keep for internal hook error monitoring

**App update:**
- `hooks_section.dart` empty state message currently says "Add scripts to .parachute/hooks/". Update to reference `.claude/settings.json`.
- Show SDK hook configs (command, event type, matcher) in read-only view.

**Acceptance criteria:**
- [ ] HookRunner no longer discovers user hooks from `vault/.parachute/hooks/`
- [ ] Bot connector events (`BOT_CONNECTOR_DOWN`, `BOT_CONNECTOR_RECONNECTED`) still fire
- [ ] `GET /hooks` returns SDK hook config from `.claude/settings.json`
- [ ] App hooks section shows SDK hooks, not HookRunner hooks
- [ ] Empty state text updated
- [ ] Tests: bot connector hook firing still works

---

### Phase 3: Simplify Plugins (~3 days)

**Goal:** Align plugins with SDK conventions. Drop the custom `.claude-plugin/plugin.json` format. Plugins are just git repos with SDK-layout files — Parachute installs them by copying content to vault standard locations.

**The shift:** Currently, Parachute invented its own plugin manifest (`.claude-plugin/plugin.json`) and indexes plugins by recursively scanning `skills/`, `agents/`, and MCP configs. This is a custom abstraction on top of SDK-native concepts. The SDK already knows how to discover `.claude/agents/`, `.mcp.json`, `CLAUDE.md`, etc. from a project directory.

**New model — plugins as SDK-layout repos:**

A Parachute-compatible plugin is just a git repo with standard SDK files:
```
my-plugin/
├── .claude/
│   └── agents/           # Subagent definitions (SDK-native)
├── .mcp.json             # MCP server configs (SDK-native)
├── skills/               # Skills (Parachute convention)
│   ├── my-skill.md
│   └── complex-skill/
│       └── SKILL.md
├── CLAUDE.md             # Optional: context/instructions
└── plugin.json           # Optional: metadata (name, version, author)
```

Note: `plugin.json` is optional metadata at the root — not a required manifest in a `.claude-plugin/` subdirectory. If absent, we derive name from the repo slug.

**Backwards compatibility:** We continue to recognize the old `.claude-plugin/plugin.json` format during a transition period. If found, read it for metadata. But new plugins don't need it.

**Changes:**

`computer/parachute/core/plugin_installer.py`:
- Rewrite `install_plugin_from_url()`:
  1. Clone to temp directory
  2. Read metadata from `plugin.json` (root) OR `.claude-plugin/plugin.json` (legacy) OR derive from slug
  3. Scan for SDK-layout content: `.claude/agents/`, `.mcp.json`, `skills/`
  4. Validate no name conflicts with existing content before installing
  5. Copy `.claude/agents/*.md` → `vault/agents/` (with `plugin-{slug}-` prefix)
  6. Copy `skills/` → `vault/.skills/` (with prefix)
  7. Merge `.mcp.json` → `vault/.mcp.json` (reject on conflict)
  8. Write install manifest to `vault/.parachute/plugin-manifests/{slug}.json`
  9. Clean up temp directory

**Install manifest** (`vault/.parachute/plugin-manifests/{slug}.json`):
```json
{
  "slug": "example-plugin",
  "name": "Example Plugin",
  "source_url": "https://github.com/org/plugin",
  "installed_at": "2026-02-19T10:30:00Z",
  "commit": "abc1234",
  "installed_files": {
    "agents": ["vault/agents/plugin-example-reviewer.md"],
    "skills": ["vault/.skills/plugin-example-brainstorm/"],
    "mcps": ["github-tools"]
  }
}
```

**Uninstall flow:**
1. Read manifest to get installed file paths
2. Check for user modifications (compare file hash or mtime)
3. Warn if files were modified: "Plugin file X was modified. Delete anyway?"
4. Delete tracked files
5. Remove MCP entries from `vault/.mcp.json`
6. Remove manifest file

**Data integrity improvements:**
- `.mcp.json` writes use atomic write-to-temp-then-rename pattern
- Plugin install validates all conflicts BEFORE writing any files (transactional)
- Partial install cleanup: if any step fails, roll back all copied files

`computer/parachute/core/plugins.py`:
- Simplify `discover_plugins()` — read manifests from `plugin-manifests/`, no recursive indexing
- Remove `_index_plugin()`, `_discover_plugin_skills()`, `_discover_plugin_agents()`, `_discover_plugin_mcps()`
- The installed plugin list comes from manifests, not from scanning directories

`computer/parachute/core/orchestrator.py`:
- Remove plugin MCP merging (lines 572-579) — MCPs already in `.mcp.json`
- Remove plugin agent merging — agents already in `vault/agents/`
- Remove `plugin_dirs` passing to SDK (content is now in standard locations, not plugin directories)

**Edge cases (from spec-flow analysis):**
- Name conflict on install: Error with clear message before any files are written
- User edits plugin-installed agent, then uninstalls: Warn about modification, require confirmation
- Partial install failure: Roll back all copied files, remove partial manifest
- Concurrent writes to `.mcp.json`: Atomic write pattern prevents corruption
- Plugin update: Uninstall tracked files, then reinstall from updated source
- Legacy plugins with `.claude-plugin/plugin.json`: Read old format for metadata, index using new scan paths

**Acceptance criteria:**
- [x] Plugins discovered by scanning for SDK-layout files (`.claude/agents/`, `.mcp.json`, `skills/`)
- [x] Old `.claude-plugin/plugin.json` format still recognized (backwards compat)
- [x] `POST /plugins/install` copies content to standard vault locations
- [x] Install validates conflicts before writing any files
- [x] `DELETE /plugins/{slug}` removes tracked files with modification warning
- [x] Install manifest tracks all files per plugin
- [x] `.mcp.json` uses atomic writes
- [x] Orchestrator no longer merges plugin MCPs or agents inline (manifest-based)
- [x] Orchestrator no longer passes `plugin_dirs` to SDK for manifest-based plugins
- [ ] Tests: install (new format), install (legacy format), uninstall, update, conflict detection, rollback

---

### Phase 4: App Extensions Panel Polish (~3 days, reduced from 5)

**Goal:** Polish existing CapabilitiesScreen — it already has the 4 tabs.

**Note:** The Flutter app already has `CapabilitiesScreen` with Agents, Skills, MCPs, and Plugins tabs. This phase polishes rather than builds from scratch.

**App changes:**

**All tabs — shared improvements:**
- Add `RefreshIndicator` wrapping each tab's `ListView` for pull-to-refresh
- Invalidate Riverpod provider on refresh: `ref.invalidate(provider)`
- Add empty state with guidance text (not referencing deprecated paths)
- Add error state with retry button

**Agent tab (`capabilities_screen.dart` agent section):**
- Add client-side name validation: `RegExp(r'^[a-zA-Z0-9_-]+$')` in Create Agent dialog
- Show source badge: "built-in", "user", "plugin-{slug}"
- Check for name collision before sending create request

**MCP tab:**
- Show validation status indicator (connected/error)
- Conflict warning when adding MCP with existing name

**Hooks tab (new or relocated):**
- Read from updated `GET /hooks` endpoint (SDK hooks, not HookRunner)
- Read-only view: hook command, event binding, matcher pattern
- Show recent errors from `GET /hooks/errors`
- Update empty state: reference `.claude/settings.json`

**Decision: Where do hooks live in the app?**
Currently hooks are a separate settings section. The Capabilities screen has 4 tabs. Options:
- **A: Add hooks as 5th tab in Capabilities** — all extensions in one place
- **B: Keep hooks in settings, just update the data source** — less disruption
- **Recommended: B** — hooks are configuration, not "capabilities" the user browses. Update the existing hooks section to read SDK hook data.

**Acceptance criteria:**
- [x] Pull-to-refresh on all Capabilities tabs
- [x] Agent name validation (client-side)
- [x] Source badges on agents (built-in/user/plugin)
- [x] Hooks section shows SDK hook config (Phase 2)
- [x] Empty states reference correct paths
- [x] Error states have retry buttons

---

### Phase 5: Clean Up (~1 day)

**Goal:** Remove dead code, update docs, simplify orchestrator.

**After Phases 1-4 have been stable for 2+ release cycles:**

**Code removal:**
- [x] Delete `core/agents.py` entirely (dead code, no production imports)
- [x] Delete `lib/agent_loader.py` entirely (dead code, no production imports)
- [x] Delete `tests/unit/test_agents.py` and `test_agent_loader.py`
- [x] Remove dead `_parse_hook()` from `core/hooks/runner.py`
- [x] Clean up integration test (remove agent discovery tests)
- [ ] Clean up unused AgentDefinition fields from `models/agent.py` (future)
- [ ] Remove unused HookEvent types (future — only bot connector + server lifecycle needed)

**Documentation:**
- [x] Update `computer/CLAUDE.md` — document 5 primitives model
- [ ] Update `app/CLAUDE.md` — document extensions panel
- [ ] Update root `CLAUDE.md` — reflect consolidated architecture

**Orchestrator simplification:**
- [x] Removed dead import comments
- [x] Plugin MCP merging scoped to legacy plugins only
- [ ] Measure: count lines in `execute_stream()` before/after (future)

**Acceptance criteria:**
- [x] No references to `.parachute/agents/` in production codebase
- [x] No user-facing references to HookRunner
- [x] `computer/CLAUDE.md` documents the 5 primitives model
- [x] Dead code removed (core/agents.py, lib/agent_loader.py)

---

## Security Fixes (Do Immediately, Before Phases)

These should be addressed independently of the consolidation:

### S1: Agent Name Path Traversal
**File:** `computer/parachute/api/agents.py` line ~172
**Issue:** `agent_file = agents_dir / f"{body.name}.md"` — no sanitization
**Fix:** Validate name matches `^[a-zA-Z0-9_-]+$` before using as filename
**Severity:** HIGH — allows writing files outside agents directory

### S2: Agent Name Validation in App
**File:** `app/lib/features/settings/screens/capabilities_screen.dart` line ~1100
**Issue:** Only checks `name.isEmpty || prompt.isEmpty`, no character validation
**Fix:** Add regex validation, check for name collision via API before submit
**Severity:** MEDIUM — bad UX, opaque server errors

### S3: Atomic Writes for .mcp.json
**File:** `computer/parachute/api/mcp.py` `save_mcp_config()`
**Issue:** Simple `write_text()` — crash or concurrent write = corruption
**Fix:** Write to temp file, then `os.rename()` (atomic on same filesystem)
**Severity:** MEDIUM — data loss on concurrent access

---

## Open Questions

### Resolved by Research

| Question | Answer |
|----------|--------|
| What happens to HookRunner? | Keep as internal bus for bot connector events. Stop discovering user hooks. |
| What's the relationship between agents and system prompt? | Completely separate. Agents = SDK subagent templates. System prompt = context assembly. |
| Are vault/agents actually used? | Not by any known users. The system is scaffolding. |
| Will removing HookRunner break bots? | No. Connectors check defensively with `getattr()`. |

### Still Open

| Question | Impact | Default Assumption |
|----------|--------|-------------------|
| Should we keep vault/agents/ or go fully SDK-native (.claude/agents/)? | HIGH — determines Phase 1 scope | Keep vault/agents/ for app management surface |
| Is "custom subagent templates" a feature users want? | MEDIUM — determines whether to invest in agent UI | Yes, but keep it simple |
| Should migration be automatic on startup or manual CLI? | LOW | Automatic with logging |
| Hook editing in app or just viewing? | LOW | View-only for now |

---

## Risk Analysis & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Path traversal via agent names | HIGH | Security fix S1 before any other work |
| Existing custom agents lost during migration | HIGH | Copy-not-move, never delete originals, log migration |
| Plugin uninstall deletes user-modified files | MEDIUM | Check modifications, warn before delete |
| HookRunner removal breaks bot monitoring | HIGH | Keep as internal bus, only remove user discovery |
| .mcp.json corruption on concurrent write | MEDIUM | Atomic writes (fix S3) |
| App UI shows stale data after install | LOW | Pull-to-refresh on all tabs |
| In-flight sessions reference deleted paths | MEDIUM | Graceful fallback to vault-agent |

---

## Dependencies & Execution Order

```
Security Fixes (S1, S2, S3) ← Do first, independent
         |
    Phase 1 (agents) ←──────── No dependencies
    Phase 2 (hooks)  ←──────── No dependencies
         |                          |
    Phase 3 (plugins) ←── Depends on Phase 1
         |
    Phase 4 (app polish) ←── Can start after Phase 2, benefits from Phase 1+3
         |
    Phase 5 (cleanup) ←── After all phases stable
```

Phases 1 and 2 can run in parallel. Phase 3 needs Phase 1 complete. Phase 4 can start early (existing UI) but should finish after Phases 1-3 land.

---

## References

### Internal
- Brainstorm: `docs/brainstorms/2026-02-19-agentic-ecosystem-consolidation-brainstorm.md`
- GitHub Issue: #74
- Original plan: `docs/plans/2026-02-19-refactor-agentic-ecosystem-consolidation-plan.md`
- Agent-native architecture skill: `.claude/skills/agent-native-architecture/`

### Key Files
- `computer/parachute/core/orchestrator.py` — Central discovery flow
- `computer/parachute/core/agents.py` — Custom agent discovery (to be removed)
- `computer/parachute/lib/agent_loader.py` — Vault agent loader (to be simplified)
- `computer/parachute/models/agent.py` — AgentDefinition model (to be simplified)
- `computer/parachute/core/plugins.py` — Plugin system (to be simplified)
- `computer/parachute/core/plugin_installer.py` — Plugin installer (to be rewritten)
- `computer/parachute/core/hooks/runner.py` — HookRunner (to be demoted)
- `computer/parachute/api/agents.py` — Agent API (security fix needed)
- `computer/parachute/api/mcp.py` — MCP API (atomic writes needed)
- `app/lib/features/settings/screens/capabilities_screen.dart` — Extensions UI

### External
- TinyClaw: https://github.com/jlia0/tinyclaw
- MCP standard: https://modelcontextprotocol.io
- Claude Agent SDK: https://platform.claude.com/docs/en/agent-sdk/overview
