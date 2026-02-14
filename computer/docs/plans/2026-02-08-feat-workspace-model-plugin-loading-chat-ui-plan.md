---
title: "feat: Workspace Model, Plugin Loading Fixes & Chat UI Overhaul"
type: feat
date: 2026-02-08
---

# Workspace Model, Plugin Loading Fixes & Chat UI Overhaul

## Overview

A multi-phase initiative to evolve Parachute from a flat session list with ad-hoc capability loading into a **workspace-first** environment with proper plugin/MCP passthrough, per-workspace capability configuration, and an adaptive multi-panel Chat UI.

Three interconnected problems solved together:

1. **Plugin loading gaps** — User plugins (e.g., Compound Engineering) aren't passed to agent sessions. Docker sandbox containers get no capabilities at all.
2. **No workspace concept** — Every session is configured individually. No way to save and reuse environment configurations.
3. **Chat UI is dated** — Flat session list, monolithic chat screen, no desktop layout optimization.

## Problem Statement

**Plugin loading**: The orchestrator at `computer/parachute/core/orchestrator.py:477-481` only passes plugins from `vault/.skills/`. User-level plugins at `~/.claude/plugins/` are never discovered. The `setting_sources` parameter is `["project"]` which skips user settings. Docker sandbox containers (`core/sandbox.py`) mount only vault paths — no MCPs, skills, agents, or CLAUDE.md reach the container.

**No workspaces**: Sessions are configured individually via the New Chat sheet with working directory, agent, and trust level pickers. There's no way to save these as reusable configurations. Bot connectors have per-platform trust levels but no capability control. The orchestrator has no concept of "this session should only see these MCPs."

**Chat UI limitations**: `ChatHubScreen` is a flat `ListView` with no date grouping, search, or workspace awareness. `ChatScreen` is ~1500 lines with 6+ app bar actions and 4 separate settings sheets. No adaptive layout — the app is single-column on all screen sizes.

## Proposed Solution

### Architecture

```
Workspace Config (YAML)
    │
    ├── Orchestrator reads workspace → assembles filtered capabilities
    │   ├── MCPs: only workspace-allowed servers
    │   ├── Plugins: user + workspace + vault plugins
    │   ├── Agents: workspace-allowed agents
    │   └── Trust level: workspace floor (session can only restrict)
    │
    ├── Docker sandbox mounts from workspace config
    │   ├── .mcp.json (filtered)
    │   ├── .skills/ (workspace or vault)
    │   └── agents/ (workspace or vault)
    │
    └── App displays workspace-organized sessions
        ├── Desktop: 3-panel (sidebar | sessions | chat)
        ├── Tablet: 2-panel (sessions | chat)
        └── Mobile: push navigation (current)
```

### Workspace Config Schema

```yaml
# vault/.parachute/workspaces/{slug}/config.yaml
name: "Coding"
description: "Full-powered development environment"

# Execution defaults
trust_level: full          # full | vault | sandboxed
working_directory: ~/Projects
model: opus                # sonnet | opus | haiku | null (server default)

# Capability sets
capabilities:
  mcps: all                # all | none | [parachute, context7]
  skills: all              # all | none | [skill-name-1, skill-name-2]
  agents: all              # all | none | [agent-name-1]
  plugins:
    include_user: true     # Load ~/.claude/plugins/
    dirs: []               # Additional plugin directories

# Docker sandbox config (only applies when trust_level=sandboxed)
sandbox:
  memory: "512m"
  cpu: "1.0"
  timeout: 300
```

### Trust Level Hierarchy

```
Workspace trust (floor) → Session trust (can only restrict) → Client request (can only restrict)
```

- Workspace `trust_level: vault` means sessions in this workspace can be `vault` or `sandboxed`, never `full`
- Existing "can only restrict, never escalate" pattern in `orchestrator.py:558-571` extended to workspaces

---

## Technical Approach

### Implementation Phases

#### Phase 1: Plugin Loading Fixes

**Goal**: Fix Compound Engineering not being available. Mount capabilities into Docker sandbox.

**Server changes**:

- [x] Add `plugin_dirs` field to `Settings` in `computer/parachute/config.py`
  ```python
  # config.py — new fields in Settings class
  plugin_dirs: list[str] = []        # Additional plugin directories
  include_user_plugins: bool = True  # Load ~/.claude/plugins/
  ```
- [x] Update `run_streaming()` in `computer/parachute/core/orchestrator.py` to discover user plugins
  ```python
  # orchestrator.py — after generate_runtime_plugin() call (~line 481)
  # Add user plugin directory if configured
  if settings.include_user_plugins:
      user_plugins = Path.home() / ".claude" / "plugins"
      if user_plugins.is_dir():
          plugin_dirs.append(user_plugins)
  # Add configured plugin directories
  for pd in settings.plugin_dirs:
      p = Path(pd).expanduser()
      if p.is_dir():
          plugin_dirs.append(p)
  ```
- [x] Update Docker sandbox to mount capability files in `computer/parachute/core/sandbox.py`
  ```python
  # sandbox.py — new method _build_capability_mounts()
  # Mount: vault/.mcp.json, vault/.skills/, vault/.parachute/agents/, vault/CLAUDE.md
  ```
- [x] Update Docker entrypoint at `computer/parachute/docker/entrypoint.py` to accept capability config
  - Pass MCP servers, plugin dirs, agents via a JSON config file at `/tmp/capabilities.json`
  - Entrypoint reads this and passes to `query()` kwargs
- [x] Add `parachute` package to Docker image at `computer/parachute/docker/Dockerfile.sandbox`
  - Install the MCP server module so `python -m parachute.mcp_server` works inside container
- [x] Add tests in `computer/tests/unit/test_plugin_discovery.py`

**Files modified**:
- `computer/parachute/config.py` — Add plugin_dirs, include_user_plugins fields
- `computer/parachute/core/orchestrator.py` — Plugin directory discovery (~line 477-490)
- `computer/parachute/core/sandbox.py` — `_build_capability_mounts()`, `_build_capability_config()`
- `computer/parachute/docker/entrypoint.py` — Accept capabilities JSON, pass to SDK
- `computer/parachute/docker/Dockerfile.sandbox` — Install parachute package
- `computer/tests/unit/test_plugin_discovery.py` — New test file

**Acceptance criteria**:
- [x] Compound Engineering skills are available in chat sessions when `~/.claude/plugins/` contains the plugin
- [x] Custom plugin directories in `config.yaml` are discovered and passed to SDK
- [x] Docker sandbox sessions have access to vault MCPs, skills, agents, and CLAUDE.md
- [x] Plugin directory errors (missing path, permission denied) are logged as warnings, not fatal
- [x] Existing behavior unchanged when no plugin_dirs configured

---

#### Phase 2: Workspace Model (Server-Side)

**Goal**: Server-side workspace configuration with API, session linkage, and orchestrator integration.

**Database migration**:

- [ ] Add v13 migration to `computer/parachute/db/database.py`
  ```python
  # v13: Add workspace_id to sessions
  if current_version < 13:
      try:
          await db.execute("ALTER TABLE sessions ADD COLUMN workspace_id TEXT")
      except Exception:
          pass  # Column already exists
      await db.execute("UPDATE metadata SET value = '13' WHERE key = 'schema_version'")
  ```

**Data model**:

- [ ] Create `computer/parachute/models/workspace.py`
  ```python
  class WorkspaceConfig(BaseModel):
      name: str
      slug: str  # auto-generated from name, kebab-case, unique
      description: str = ""
      trust_level: TrustLevel = TrustLevel.FULL
      working_directory: Optional[str] = None
      model: Optional[str] = None
      capabilities: WorkspaceCapabilities = WorkspaceCapabilities()
      sandbox: Optional[SandboxConfig] = None

  class WorkspaceCapabilities(BaseModel):
      mcps: Union[Literal["all", "none"], list[str]] = "all"
      skills: Union[Literal["all", "none"], list[str]] = "all"
      agents: Union[Literal["all", "none"], list[str]] = "all"
      plugins: PluginConfig = PluginConfig()

  class PluginConfig(BaseModel):
      include_user: bool = True
      dirs: list[str] = []
  ```

**Workspace storage**:

- [ ] Create `computer/parachute/core/workspaces.py`
  - `list_workspaces(vault_path)` — Scan `vault/.parachute/workspaces/*/config.yaml`
  - `get_workspace(vault_path, slug)` — Load single workspace config
  - `create_workspace(vault_path, config)` — Create directory + config.yaml
  - `update_workspace(vault_path, slug, updates)` — Partial update
  - `delete_workspace(vault_path, slug)` — Delete directory (sessions get workspace_id=NULL)
  - `generate_slug(name)` — Kebab-case, collision detection with numeric suffix

**API endpoints**:

- [ ] Create `computer/parachute/api/workspaces.py`
  ```
  GET    /api/workspaces                    — List all workspaces
  POST   /api/workspaces                    — Create workspace
  GET    /api/workspaces/{slug}             — Get workspace config
  PUT    /api/workspaces/{slug}             — Update workspace config
  DELETE /api/workspaces/{slug}             — Delete workspace
  GET    /api/workspaces/{slug}/sessions    — List sessions in workspace
  ```

**Orchestrator integration**:

- [ ] Update `run_streaming()` in `computer/parachute/core/orchestrator.py`
  - Accept `workspace_id` parameter
  - Load workspace config when specified
  - Filter MCPs, skills, agents per workspace capabilities
  - Apply workspace trust level as floor
  - Use workspace working directory as default
  - Use workspace model as default

- [ ] Update `ChatRequest` in `computer/parachute/models/requests.py`
  - Add `workspace_id: Optional[str] = None` field

**Session metadata**:

- [ ] Update session creation in `computer/parachute/core/session_manager.py`
  - Store `workspace_id` on session creation
  - Add workspace filter to `list_sessions()`

- [ ] Add `workspace_id` filter to `GET /api/sessions` endpoint

**Capability filtering logic**:

- [ ] Create `computer/parachute/core/capability_filter.py`
  ```python
  def filter_capabilities(
      workspace: WorkspaceConfig,
      all_mcps: dict,
      all_skills: list,
      all_agents: list,
      plugin_dirs: list[Path],
  ) -> FilteredCapabilities:
      """
      Apply workspace capability sets to discovered capabilities.
      "all" = pass everything through
      "none" = empty set
      [list] = only named items
      """
  ```

**Files modified/created**:
- `computer/parachute/db/database.py` — v13 migration
- `computer/parachute/models/workspace.py` — New: workspace models
- `computer/parachute/core/workspaces.py` — New: workspace storage
- `computer/parachute/api/workspaces.py` — New: workspace API router
- `computer/parachute/api/__init__.py` — Register workspaces router
- `computer/parachute/core/orchestrator.py` — Workspace-aware capability assembly
- `computer/parachute/core/capability_filter.py` — New: capability filtering
- `computer/parachute/models/requests.py` — Add workspace_id to ChatRequest
- `computer/parachute/core/session_manager.py` — Store/filter workspace_id
- `computer/tests/unit/test_workspaces.py` — New: workspace tests
- `computer/tests/unit/test_capability_filter.py` — New: filter tests

**Acceptance criteria**:
- [ ] Workspaces can be created, listed, updated, deleted via API
- [ ] Sessions created with `workspace_id` store the reference in the database
- [ ] Orchestrator loads workspace config and filters capabilities accordingly
- [ ] Workspace `trust_level` acts as a floor — sessions can only restrict
- [ ] Workspace with `mcps: [parachute]` only gets the built-in MCP, not others from `.mcp.json`
- [ ] Deleting a workspace sets `workspace_id=NULL` on linked sessions (no cascade delete)
- [ ] Existing sessions (no workspace) continue to work unchanged (backward compatible)
- [ ] Session list API supports `?workspace_id=slug` filter

---

#### Phase 3: Chat UI Quick Wins (App)

**Goal**: Improve session list with date grouping and search. Consolidate scattered settings sheets.

**Can proceed in parallel with Phase 1 and Phase 2.**

**Date-grouped session list**:

- [x] Create `app/lib/features/chat/widgets/date_grouped_session_list.dart`
  - Group sessions by: Today, Yesterday, Last 7 Days, Last 30 Days, Older
  - Use device local timezone for grouping (sessions have UTC timestamps)
  - Sticky section headers
  - Reuse existing `SessionListItem` for items

- [x] Update `ChatHubScreen` at `app/lib/features/chat/screens/chat_hub_screen.dart`
  - Replace flat `ListView` with `DateGroupedSessionList`
  - Move FAB "+" button to app bar (alongside search)

**Session search**:

- [x] Add `search` parameter to `GET /api/sessions` endpoint in `computer/parachute/api/sessions.py`
  ```python
  @router.get("/sessions")
  async def list_sessions(search: Optional[str] = None, ...):
      # Add WHERE title LIKE ? to query
  ```

- [x] Add search bar to `ChatHubScreen`
  - `SearchBar` at top of session list
  - Debounced search (300ms) triggers provider refresh
  - Clear button resets to full list

- [x] Create search provider in `app/lib/features/chat/providers/session_search_provider.dart`
  - Wraps `chatSessionsProvider` with search query parameter

**Consolidated session settings**:

- [x] Create `app/lib/features/chat/widgets/unified_session_settings.dart`
  - Merges content from: `SessionConfigSheet` (trust level), `ContextSettingsSheet` (context files), `SessionInfoSheet` (metadata)
  - Sections: Workspace (placeholder for Phase 5), Trust Level, Model, Context Files, Session Info
  - Bottom sheet on mobile, side panel potential on desktop (Phase 4)

- [x] Update `ChatScreen` at `app/lib/features/chat/screens/chat_screen.dart`
  - Replace 3 separate settings buttons with one gear icon
  - Remove: tune button (context settings), info button (session info) — consolidated into unified sheet
  - Keep: overflow menu (archive/delete), refresh button

**Simplified app bar**:

- [x] Reduce ChatScreen app bar actions
  - Left: Back arrow (mobile) or nothing (desktop)
  - Center: Session title + workspace/model subtitle
  - Right: Settings gear, overflow menu (archive/delete)
  - Move working directory, agent badge, model badge to the unified settings sheet header or subtitle

**Files modified/created**:
- `app/lib/features/chat/widgets/date_grouped_session_list.dart` — New
- `app/lib/features/chat/screens/chat_hub_screen.dart` — Use DateGroupedSessionList, add search
- `app/lib/features/chat/providers/session_search_provider.dart` — New
- `app/lib/features/chat/widgets/unified_session_settings.dart` — New
- `app/lib/features/chat/screens/chat_screen.dart` — Simplified app bar, unified settings
- `app/lib/features/chat/services/chat_service.dart` — Add search param to sessions fetch
- `computer/parachute/api/sessions.py` — Add search filter
- `computer/parachute/db/database.py` — Add title search to list_sessions query

**Acceptance criteria**:
- [x] Sessions are grouped by date with sticky headers (Today, Yesterday, Last 7 Days, etc.)
- [x] Search bar filters sessions by title (server-side, debounced)
- [x] Single settings sheet shows trust level, context files, and session info
- [x] ChatScreen app bar has at most 3 action buttons (settings, overflow, and optionally refresh)
- [x] All existing functionality is preserved (archive, delete, trust level change, context reload)

---

#### Phase 4: Adaptive Chat Layout (App)

**Goal**: Multi-panel layout on desktop/tablet. Introduce `ChatShell` as the layout manager.

**Depends on Phase 3** (uses consolidated settings sheet).

**ChatShell — adaptive layout manager**:

- [x] Create `app/lib/features/chat/screens/chat_shell.dart`
  - Uses `LayoutBuilder` for breakpoints: desktop (>1200), tablet (>600), mobile
  - Desktop: `Row` with sidebar placeholder (20%) + session list (32%) + chat content (48%)
  - Tablet: `Row` with session list (40%) + chat content (60%)
  - Mobile: Delegates to existing push navigation (ChatHubScreen → ChatScreen)

- [x] Extract session list and chat content into composable panel widgets
  - `app/lib/features/chat/widgets/session_list_panel.dart` — Extracted from ChatHubScreen
  - `app/lib/features/chat/widgets/chat_content_panel.dart` — Extracted from ChatScreen

**State management for panel mode**:

- [x] Create `app/lib/features/chat/providers/chat_layout_provider.dart`
  - `chatLayoutModeProvider` — Tracks current layout mode (3-panel, 2-panel, push)
  - In panel mode, `currentSessionIdProvider` drives the chat content panel directly
  - In push mode, existing Navigator.push behavior preserved

- [x] Update session selection logic
  - In panel mode: Selecting a session updates `currentSessionIdProvider` (no navigation)
  - In push mode: Selecting a session does `Navigator.push` (current behavior)
  - The selection handler checks layout mode to decide behavior

**Empty state in panel mode**:

- [x] Create "Select a conversation" placeholder for the chat content panel
  - Shown when no session is selected in 2/3-panel modes
  - Includes "New Chat" button as primary action

**Integration with main.dart**:

- [x] Replace `ChatHubScreen` with `ChatShell` as the Chat tab content in `app/lib/main.dart`
  - On mobile: ChatShell renders SessionListPanel directly (identical to current)
  - On desktop/tablet: ChatShell renders the multi-panel layout
  - Per-tab Navigator preserved for mobile push navigation

**Sidebar placeholder**:

- [x] Create minimal sidebar for Phase 4 (before workspace content in Phase 5)
  - App icon at top
  - Chat, Vault, Brain, Settings navigation icons
  - Active state indicator for current section

**Files modified/created**:
- `app/lib/features/chat/screens/chat_shell.dart` — New: adaptive layout manager
- `app/lib/features/chat/widgets/session_list_panel.dart` — Extracted from ChatHubScreen
- `app/lib/features/chat/widgets/chat_content_panel.dart` — Extracted from ChatScreen
- `app/lib/features/chat/providers/chat_layout_provider.dart` — New: layout mode
- `app/lib/main.dart` — Replace ChatHubScreen with ChatShell in Chat tab

**Acceptance criteria**:
- [x] Desktop (>1200px): 3-panel layout with sidebar, session list, and chat content
- [x] Tablet (600-1200px): 2-panel layout with session list and chat content
- [x] Mobile (<600px): Push navigation identical to current behavior
- [x] Selecting a session in panel mode updates chat content without navigation
- [x] Window resize transitions smoothly between layouts
- [x] Session state preserved across layout transitions
- [x] Empty state shows "Select a conversation" when no session is active in panel mode

---

#### Phase 5: Workspace UI Integration (App)

**Depends on Phase 2** (workspace API) **and Phase 4** (adaptive layout with sidebar).

**Workspace provider layer**:

- [ ] Create `app/lib/features/chat/providers/workspace_providers.dart`
  - `workspacesProvider` — FutureProvider.autoDispose that fetches `GET /api/workspaces`
  - `activeWorkspaceProvider` — StateProvider tracking the selected workspace slug
  - `workspaceSessionsProvider` — Filtered sessions for active workspace

- [ ] Create `app/lib/features/chat/models/workspace.dart`
  - `Workspace` model matching server's `WorkspaceConfig`
  - `WorkspaceCapabilities` model

- [ ] Create `app/lib/features/chat/services/workspace_service.dart`
  - CRUD methods calling workspace API endpoints

**Workspace sidebar (desktop)**:

- [ ] Update sidebar in `ChatShell` to show workspace list
  - List of workspaces with name and icon
  - Active workspace highlighted
  - "All Sessions" option to view unfiltered
  - "+ New Workspace" button at bottom

**Workspace picker in new chat flow**:

- [ ] Update new chat sheet to show workspace cards
  - Each card: icon, name, default model, trust level
  - Tapping a workspace starts a chat immediately with workspace defaults
  - "Custom" option expands manual pickers (current behavior)

- [ ] Add `workspace_id` to `ChatService.sendMessage()` request body

**Session list workspace filter**:

- [ ] Filter session list by active workspace
  - When a workspace is selected, only show that workspace's sessions
  - "All" shows all sessions with workspace badges

**Workspace management in Settings**:

- [ ] Create `app/lib/features/settings/widgets/workspace_management_section.dart`
  - List workspaces with edit/delete actions
  - Create workspace form: name, trust level, working directory, model
  - Capability configuration (MCPs, skills, agents) — simple checkboxes or "all/none" toggle

**Session settings workspace section**:

- [ ] Fill the workspace placeholder from Phase 3 in unified session settings
  - Show current workspace name and badge
  - Show workspace capabilities (read-only in session context)

**Files modified/created**:
- `app/lib/features/chat/providers/workspace_providers.dart` — New
- `app/lib/features/chat/models/workspace.dart` — New
- `app/lib/features/chat/services/workspace_service.dart` — New
- `app/lib/features/chat/screens/chat_shell.dart` — Workspace sidebar content
- `app/lib/features/chat/widgets/new_chat_sheet.dart` — Workspace picker cards
- `app/lib/features/chat/widgets/session_list_panel.dart` — Workspace filter
- `app/lib/features/chat/widgets/unified_session_settings.dart` — Workspace section
- `app/lib/features/settings/widgets/workspace_management_section.dart` — New
- `app/lib/features/settings/screens/settings_screen.dart` — Add workspace section
- `app/lib/features/chat/services/chat_service.dart` — Add workspace_id to requests

**Acceptance criteria**:
- [ ] Desktop sidebar shows workspace list with active indicator
- [ ] Selecting a workspace filters the session list
- [ ] New chat flow shows workspace cards for quick start
- [ ] Tapping a workspace card starts a chat with all workspace defaults
- [ ] Settings screen has workspace management (create/edit/delete)
- [ ] Session settings shows current workspace info
- [ ] Bot connector sessions appear under their linked workspace

---

#### Phase 6: Capability Filtering

**Depends on Phase 1** (capability loading) **and Phase 2** (workspace model).

**Trust-level capability annotations**:

- [x] Extend MCP config in `.mcp.json` with optional `trust_level` field
  ```json
  {
    "parachute": {
      "command": "python",
      "args": ["-m", "parachute.mcp_server"],
      "trust_level": "sandboxed"
    },
    "context7": {
      "url": "https://...",
      "trust_level": "vault"
    }
  }
  ```
  - MCPs without `trust_level` default to `"full"` (available only in full trust)
  - Built-in Parachute MCP always available at `"sandboxed"` level

- [x] Update capability filter in `computer/parachute/core/capability_filter.py`
  - Filter by trust level: only pass MCPs/tools whose `trust_level` <= session trust
  - Then filter by workspace capability set
  - Resolution order: trust filter first, then workspace filter

- [x] Docker assembly from workspace config
  - `sandbox.py` reads workspace config to determine what to mount
  - Only workspace-allowed capabilities mounted into container
  - Capabilities JSON file written for entrypoint

**Files modified/created**:
- `computer/parachute/lib/mcp_loader.py` — Parse optional trust_level from MCP config
- `computer/parachute/core/capability_filter.py` — Trust-level filtering logic
- `computer/parachute/core/sandbox.py` — Workspace-aware Docker assembly
- `computer/parachute/core/orchestrator.py` — Integrate trust + workspace filtering
- `computer/tests/unit/test_capability_filter.py` — Trust-level filter tests

**Acceptance criteria**:
- [x] MCPs with `trust_level: vault` are available in vault and full trust sessions, not sandboxed
- [x] MCPs with no trust_level annotation only appear in full trust sessions
- [x] Built-in Parachute MCP is always available regardless of trust level
- [x] Workspace `mcps: [parachute]` only passes the Parachute MCP, even if .mcp.json has more
- [x] Docker containers only mount capabilities that pass both trust and workspace filters
- [x] No regression: sessions without workspace continue to get all capabilities at their trust level

---

## Dependencies & Parallelization

```
Timeline:
═══════════════════════════════════════════════════
Phase 1 (Plugin Fixes)     ████████░░░░░░░░░░░░░░
Phase 3 (Chat UI Wins)     ████████████░░░░░░░░░░  ← parallel with Phase 1
Phase 2 (Workspace Server) ░░░░████████████░░░░░░  ← starts after Phase 1 foundations
Phase 4 (Adaptive Layout)  ░░░░░░░░████████████░░  ← starts after Phase 3
Phase 5 (Workspace UI)     ░░░░░░░░░░░░████████░░  ← needs Phase 2 + Phase 4
Phase 6 (Capability Filter)░░░░░░░░░░░░░░████████  ← needs Phase 1 + Phase 2
═══════════════════════════════════════════════════
```

**Hard dependencies**:
- Phase 5 → Phase 2 (workspace API) + Phase 4 (layout shell)
- Phase 6 → Phase 1 (capability loading) + Phase 2 (workspace config)

**Soft dependencies**:
- Phase 4 → Phase 3 (uses consolidated settings sheet)
- Phase 2 → Phase 1 (shared understanding of capability model)

**Independent**:
- Phase 1 and Phase 3 can proceed simultaneously right now

## Risk Analysis & Mitigation

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Orchestrator regression (1440 lines) | High | Medium | Comprehensive unit tests, incremental changes, review after each phase |
| Docker entrypoint redesign breaks sandbox | High | Medium | Test sandbox sessions end-to-end after Phase 1 changes |
| Adaptive layout breaks mobile experience | High | Low | Mobile path is default; desktop layout is additive. Test on both. |
| Workspace migration breaks existing sessions | Medium | Low | NULL default for workspace_id, backward compat tests |
| Flutter multi-panel state management | Medium | Medium | Use existing Riverpod providers; panel mode is just a different rendering |
| Plugin path security (user controls paths) | Medium | Low | Validate paths exist, are directories, log warnings for failures |

## Success Metrics

- Compound Engineering workflows available in chat sessions (Phase 1)
- Docker sandbox sessions have access to vault tools (Phase 1)
- Session list feels organized with date groups and search (Phase 3)
- Desktop users see a multi-panel layout that uses screen space well (Phase 4)
- Users can create workspaces and start workspace-scoped sessions (Phase 5)
- Trust levels meaningfully filter capabilities (Phase 6)

## References & Research

### Internal References

- Brainstorm: `docs/brainstorms/2026-02-08-agent-skill-mcp-plugin-loading-brainstorm.md`
- Orchestrator: `computer/parachute/core/orchestrator.py:451-649` (capability assembly)
- SDK wrapper: `computer/parachute/core/claude_sdk.py:59-188` (query_streaming)
- Docker sandbox: `computer/parachute/core/sandbox.py` (DockerSandbox class)
- Skills plugin: `computer/parachute/core/skills.py` (generate_runtime_plugin)
- Agents: `computer/parachute/core/agents.py` (discover_agents)
- MCP loader: `computer/parachute/lib/mcp_loader.py` (load/resolve/validate)
- Config: `computer/parachute/config.py` (Settings class)
- DB schema: `computer/parachute/db/database.py:166-296` (schema v12 + migrations)
- Session models: `computer/parachute/models/session.py`
- Chat request: `computer/parachute/models/requests.py:75-143`
- App main: `app/lib/main.dart` (tab navigation)
- Chat hub: `app/lib/features/chat/screens/chat_hub_screen.dart`
- Chat screen: `app/lib/features/chat/screens/chat_screen.dart`
- Session list item: `app/lib/features/chat/widgets/session_list_item.dart`
- Session config: `app/lib/features/chat/widgets/session_config_sheet.dart`
- Context settings: `app/lib/features/chat/widgets/context_settings_sheet.dart`
- Session info: `app/lib/features/chat/widgets/session_info_sheet.dart`
- New chat sheet: `app/lib/features/chat/widgets/new_chat_sheet.dart`

### Prior Art

- Craft Agents OSS: Mature workspace model at `craft-agents-oss/packages/shared/src/workspaces/`
  - `types.ts` — WorkspaceConfig with defaults, sources
  - `storage.ts` — Workspace CRUD, plugin manifest generation
  - `SessionList.tsx` — Date-grouped sessions, search, keyboard nav
  - `AppShell.tsx` — 3-panel adaptive layout
  - `WorkspaceSwitcher.tsx` — Workspace dropdown with animations

### Key Design Decisions

1. **Docker over SDK native sandbox** — Docker provides a full environment where agents can run Python, install packages, etc. SDK native sandbox is restrictive (deny-list approach). User explicitly prefers Docker model.

2. **Workspace as named config, not filesystem boundary** — Workspaces configure capability sets but don't create isolated filesystem spaces. The vault is shared; workspaces control what's visible.

3. **ChatShell wraps the Chat tab** — Rather than replacing the per-tab Navigator pattern, ChatShell manages layout within the Chat tab. Mobile preserves push navigation. Desktop uses panel state management.

4. **Trust levels can only restrict, never escalate** — Consistent with existing pattern. Workspace trust is the ceiling for all sessions within it.
