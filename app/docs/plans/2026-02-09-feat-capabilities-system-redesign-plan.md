---
title: "feat: Capabilities system redesign — plugins, explicit SDK control, rich UI"
type: feat
date: 2026-02-09
brainstorm: docs/brainstorms/2026-02-09-capabilities-system-brainstorm.md
---

# Capabilities System Redesign

## Overview

Redesign Parachute's capability management system across server and app to support:

1. **Plugin-first architecture** — Claude Code plugin format (`.claude-plugin/plugin.json`) as the primary package unit
2. **Explicit SDK construction** — Remove `setting_sources` reliance; Parachute constructs all SDK parameters
3. **Plugin installation** — Install plugins from GitHub URLs, with future marketplace browsing
4. **Rich management UI** — Detailed capability views, connection testing, per-workspace scoping
5. **Sandbox compatibility** — All capabilities function in both trusted and Docker sandbox paths

## Problem Statement

The current system has several issues:

- **SDK auto-discovery is unpredictable** — `setting_sources=["project"]` causes the SDK to read CLAUDE.md, `.mcp.json`, and other configs from the working directory hierarchy. Parachute can't control what the SDK finds, leading to unexpected behavior.
- **Plugins don't work** — `plugin_dirs` isn't reliably passed; skills are converted to runtime plugins but the pipeline is brittle; user plugins from `~/.claude/plugins/` are discovered but not tested.
- **No install story** — No way to install a plugin from a GitHub URL. Only manual file creation via basic form dialogs.
- **Shallow UI** — Capability cards show only name and description. No detail views, no configuration, no connection testing for MCPs.

## Proposed Solution

### Architecture Summary

```
Discovery Layer          Filtering Pipeline         SDK Parameters
──────────────           ──────────────────         ──────────────
Installed plugins   ──→                         ──→  plugin_dirs
Custom agents       ──→  Trust filter           ──→  agents dict
Vault agents        ──→     ↓                   ──→  agents dict
Skills (.skills/)   ──→  Workspace filter       ──→  runtime plugin → plugin_dirs
MCPs (.mcp.json)    ──→     ↓                   ──→  mcp_servers dict
Plugin MCPs         ──→  Agent filter           ──→  mcp_servers dict
CLAUDE.md           ──→                         ──→  system_prompt_append
```

Parachute explicitly constructs every SDK parameter. No reliance on SDK auto-discovery.

## Technical Approach

### Implementation Phases

---

#### Phase 1: Explicit SDK Control (Foundation)

Stop relying on SDK auto-discovery. Parachute becomes the single source of truth.

##### 1.1 Remove `setting_sources` from SDK calls

**File**: `parachute-computer/parachute/core/orchestrator.py`

- Remove `setting_sources=["project"]` from the `query_streaming()` call (line ~824)
- Instead, load CLAUDE.md content ourselves and pass via `system_prompt_append`

**File**: `parachute-computer/parachute/core/claude_sdk.py`

- Remove `setting_sources` from `ClaudeCodeOptions` if present
- Verify the SDK call still works without it

##### 1.2 Load CLAUDE.md explicitly

**File**: `parachute-computer/parachute/core/orchestrator.py` (new helper)

Add a function to load CLAUDE.md content from the vault/working directory:

```python
def _load_claude_md(self, cwd: str | None) -> str | None:
    """Load CLAUDE.md from vault root and working directory."""
    parts = []
    # Vault root CLAUDE.md
    vault_claude = self.vault_path / "CLAUDE.md"
    if vault_claude.exists():
        parts.append(vault_claude.read_text())
    # Working directory CLAUDE.md (if different from vault root)
    if cwd:
        cwd_path = Path(cwd)
        cwd_claude = cwd_path / "CLAUDE.md"
        if cwd_claude.exists() and cwd_claude != vault_claude:
            parts.append(cwd_claude.read_text())
    return "\n\n".join(parts) if parts else None
```

Append result to `system_prompt_append` in the SDK call.

##### 1.3 Load .mcp.json explicitly (stop SDK auto-discovery)

The server already loads MCPs via `mcp_loader.py` and passes them explicitly. Verify that removing `setting_sources` doesn't cause the SDK to also load `.mcp.json` on its own (double-loading). If it does, we may need to pass `setting_sources=[]` explicitly to suppress it.

**Verification**: Run a session with `setting_sources` removed, check server logs for which MCPs are active. Should match exactly what Parachute passes.

##### 1.4 Ensure sandbox entrypoint also uses explicit construction

**File**: `parachute-computer/parachute/docker/entrypoint.py`

- Verify the entrypoint does NOT use `setting_sources`
- Currently it doesn't — but add a comment making this explicit
- The entrypoint should pass `use_claude_code_preset=False` if we're providing the full prompt, or `True` with `system_prompt_append` if we want the preset

**Success criteria**: Sessions produce identical behavior before and after removing `setting_sources`. Server logs show exactly which capabilities were passed.

---

#### Phase 2: Plugin System (Server)

Add the ability to install, index, and manage plugins as first-class entities.

##### 2.1 Plugin model and storage

**New file**: `parachute-computer/parachute/models/plugin.py`

```python
@dataclass
class InstalledPlugin:
    slug: str                    # Directory name
    name: str                    # From plugin.json
    version: str                 # From plugin.json
    description: str             # From plugin.json
    author: str | None           # From plugin.json
    source_url: str | None       # GitHub URL if installed from remote
    path: Path                   # Absolute path on disk
    skills: list[str]            # Discovered skill names
    agents: list[str]            # Discovered agent names
    mcps: dict[str, Any]         # Discovered MCP configs
    installed_at: str            # ISO timestamp
```

**Storage**: `{vault}/.parachute/plugins/{slug}/`

Each plugin directory follows Claude Code format:
```
{slug}/
  .claude-plugin/plugin.json
  skills/
  agents/
  commands/
  hooks/
  .mcp.json
```

##### 2.2 Plugin discovery and indexing

**New file**: `parachute-computer/parachute/core/plugins.py`

```python
def discover_plugins(vault_path: Path, include_user: bool = True) -> list[InstalledPlugin]:
    """Discover all installed plugins."""
    plugins = []
    # 1. Parachute-managed plugins
    plugin_dir = vault_path / ".parachute" / "plugins"
    if plugin_dir.is_dir():
        for entry in plugin_dir.iterdir():
            if (entry / ".claude-plugin" / "plugin.json").exists():
                plugins.append(_index_plugin(entry))
    # 2. User plugins (~/.claude/plugins/) if enabled
    if include_user:
        user_dir = Path.home() / ".claude" / "plugins"
        if user_dir.is_dir():
            for entry in user_dir.iterdir():
                if (entry / ".claude-plugin" / "plugin.json").exists():
                    plugins.append(_index_plugin(entry, source="user"))
    return plugins

def _index_plugin(path: Path, source: str = "parachute") -> InstalledPlugin:
    """Index a plugin directory — read manifest, discover contents."""
    manifest = json.loads((path / ".claude-plugin" / "plugin.json").read_text())
    # Discover skills
    skills = _discover_plugin_skills(path)
    # Discover agents
    agents = _discover_plugin_agents(path)
    # Discover MCPs
    mcps = _discover_plugin_mcps(path)
    return InstalledPlugin(
        slug=path.name,
        name=manifest.get("name", path.name),
        version=manifest.get("version", "0.0.0"),
        description=manifest.get("description", ""),
        author=manifest.get("author"),
        source_url=manifest.get("source_url"),
        path=path,
        skills=skills,
        agents=agents,
        mcps=mcps,
        installed_at=manifest.get("installed_at", ""),
    )
```

##### 2.3 Plugin installation from GitHub URL

**New file**: `parachute-computer/parachute/core/plugin_installer.py`

```python
async def install_plugin_from_url(
    vault_path: Path, url: str, slug: str | None = None
) -> InstalledPlugin:
    """Clone a plugin from a GitHub URL."""
    # 1. Parse URL → derive slug from repo name if not provided
    # 2. Clone into {vault}/.parachute/plugins/{slug}/
    # 3. Validate: .claude-plugin/plugin.json must exist
    # 4. Index the plugin
    # 5. Write source_url into plugin.json for update tracking
    # 6. Return InstalledPlugin

async def uninstall_plugin(vault_path: Path, slug: str) -> bool:
    """Remove an installed plugin directory."""
    # Only removes from .parachute/plugins/, not user plugins

async def check_plugin_updates(plugin: InstalledPlugin) -> dict | None:
    """Check if a newer version is available (git fetch --dry-run)."""
    # Returns None if up to date, or {current, latest, url} if update available

async def update_plugin(vault_path: Path, slug: str) -> InstalledPlugin:
    """Pull latest from remote."""
    # git pull in the plugin directory
    # Re-index
```

##### 2.4 Plugin API endpoints

**New file**: `parachute-computer/parachute/api/plugins.py`

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `GET /api/plugins` | GET | List installed plugins with contents summary |
| `GET /api/plugins/{slug}` | GET | Plugin detail with full contents |
| `POST /api/plugins/install` | POST | Install from URL `{url: "https://github.com/...", slug?: "custom-name"}` |
| `DELETE /api/plugins/{slug}` | DELETE | Uninstall plugin (parachute-managed only) |
| `POST /api/plugins/{slug}/update` | POST | Pull latest from remote |
| `GET /api/plugins/{slug}/check-update` | GET | Check if update available |

Register in `parachute/server.py` alongside existing routers.

##### 2.5 Integrate plugins into orchestrator discovery

**File**: `parachute-computer/parachute/core/orchestrator.py`

Update the capability discovery section (~line 494) to include plugin-sourced capabilities:

```python
# Current flow:
# 1. Discover skills → generate runtime plugin → plugin_dirs
# 2. Discover user plugins → plugin_dirs
# 3. Load configured plugin dirs → plugin_dirs

# New flow:
# 1. Discover installed plugins (parachute-managed + user)
# 2. For each plugin:
#    a. Add plugin dir to plugin_dirs (skills loaded by SDK)
#    b. Collect plugin MCPs → merge into global MCPs
#    c. Collect plugin agents → merge into agents_dict
# 3. Discover standalone skills → generate runtime plugin → plugin_dirs
# 4. Load standalone MCPs from vault .mcp.json
# 5. Load standalone agents from vault agents dirs
```

**Key change**: Plugin MCPs and agents are merged into the global pools BEFORE workspace filtering. This means workspace filters can include/exclude plugin capabilities by name just like any other capability.

##### 2.6 Workspace filtering for plugins

**File**: `parachute-computer/parachute/core/capability_filter.py`

Add `plugins` to `WorkspaceCapabilities` filtering. Currently plugins are controlled by `include_user` and `dirs`. Extend to support named plugin filtering:

```python
class WorkspaceCapabilities:
    plugins: Union[Literal["all", "none"], list[str]] = "all"  # Plugin slugs
    # Remove the old PluginConfig object — simplify to match other capability types
```

This lets workspaces say: `plugins: ["compound-engineering", "suno"]` to include only those plugins.

**Migration**: Convert existing `PluginConfig` format to the simpler string-based format. Old `include_user: true` becomes `plugins: "all"`.

---

#### Phase 3: Rich Capability UI (Flutter App)

Replace the basic capabilities screen with detailed views and install flows.

##### 3.1 Plugin provider and model

**New file**: `parachute-app/lib/features/chat/models/plugin.dart`

```dart
class PluginInfo {
  final String slug;
  final String name;
  final String version;
  final String description;
  final String? author;
  final String? sourceUrl;
  final String source; // "parachute" | "user"
  final List<String> skills;
  final List<String> agents;
  final Map<String, dynamic> mcps;
  final String installedAt;
  final bool updateAvailable;
}
```

**New file**: `parachute-app/lib/features/chat/providers/plugin_providers.dart`

```dart
final pluginsProvider = FutureProvider.autoDispose<List<PluginInfo>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  return service.getPlugins();
});
```

**File**: `parachute-app/lib/features/chat/services/chat_session_service.dart`

Add methods:
- `getPlugins()` → GET /api/plugins
- `getPlugin(slug)` → GET /api/plugins/{slug}
- `installPlugin(url, slug?)` → POST /api/plugins/install
- `uninstallPlugin(slug)` → DELETE /api/plugins/{slug}
- `updatePlugin(slug)` → POST /api/plugins/{slug}/update
- `checkPluginUpdate(slug)` → GET /api/plugins/{slug}/check-update

##### 3.2 Redesigned capabilities screen

**File**: `parachute-app/lib/features/settings/screens/capabilities_screen.dart`

Change from 3 tabs (Agents/Skills/MCPs) to 4 tabs:

**Plugins | Agents | Skills | MCPs**

**Plugins tab** (new, primary):
- Shows installed plugins as cards with: name, version, author, description, contents count (X skills, Y agents, Z MCPs), source badge (user/parachute)
- Card actions: View details, Update (if available), Uninstall
- Install FAB → opens `_InstallPluginSheet`
- Empty state: "No plugins installed. Install one from a GitHub URL."

**Agents/Skills/MCPs tabs** (enhanced):
- Show all capabilities from ALL sources (standalone + plugin-sourced)
- Each card shows source badge: "builtin", "vault", "custom", or plugin name
- Click-through to detail view
- Existing create/delete actions preserved for standalone capabilities

##### 3.3 Plugin install bottom sheet

**New widget in**: `capabilities_screen.dart`

`_InstallPluginSheet`:
- URL text field with paste button
- Optional custom slug field (collapsed by default)
- "Install" button → calls `installPlugin(url)` → shows progress → refreshes list
- Validates URL format before submitting
- Error handling: shows error in SnackBar if install fails

Layout follows CLAUDE.md conventions:
- `ConstrainedBox(maxWidth: 500)` for dialogs
- `Flexible` + `SingleChildScrollView` for bottom sheet content
- Pin drag handle and action buttons outside scroll region

##### 3.4 Capability detail views

**New file**: `parachute-app/lib/features/settings/screens/capability_detail_screen.dart`

A single screen that adapts based on capability type:

**Agent detail**:
- Name, description, model badge, source badge
- Tools list (chips)
- MCP access (all/list)
- Permissions summary
- Full prompt preview (expandable/collapsible)
- Edit button (custom agents only)
- Delete button (custom agents only)

**Skill detail**:
- Name, description, version badge, source badge
- Allowed tools (chips)
- Full content preview (expandable)
- Edit/Delete (standalone skills only)

**MCP detail**:
- Name, type badge (stdio/HTTP), source badge
- Command/URL display
- Connection status indicator (connected/error/untested)
- "Test Connection" button → calls testMcpServer()
- Tools provided (fetched dynamically if connected)
- Delete (non-builtin only)

**Plugin detail**:
- Name, version, author, description
- Source URL (linked)
- Contents: expandable sections for skills, agents, MCPs
- Each content item is a mini-card that links to its own detail
- Update button (if update available)
- Uninstall button (parachute-managed only)

Navigation: Card tap → `Navigator.push(CapabilityDetailScreen(type, name))`

##### 3.5 Workspace capability picker update

**File**: `parachute-app/lib/features/chat/widgets/capability_selector.dart`

Add a **Plugins** section to the workspace capability picker, alongside existing Agents/Skills/MCPs sections. Uses the same All/None/Custom pattern.

---

#### Phase 4: Sandbox Plugin Support

Ensure plugins work correctly in Docker sandbox sessions.

##### 4.1 Mount plugin directories in sandbox

**File**: `parachute-computer/parachute/core/sandbox.py`

Update `_build_capability_mounts()` to mount all plugin directories (not just plugin_dirs from skills):

```python
def _build_capability_mounts(self, config: AgentSandboxConfig) -> list[str]:
    mounts = []
    # ... existing mounts ...
    # Mount all plugin directories (read-only)
    for i, plugin_dir in enumerate(config.plugin_dirs):
        if plugin_dir.is_dir():
            mounts.extend(["-v", f"{plugin_dir}:/plugins/plugin-{i}:ro"])
    return mounts
```

This already exists but verify it handles the new plugin paths correctly.

##### 4.2 Pass plugin MCPs and agents to sandbox

Plugin-sourced MCPs and agents should already be in the global pools by the time they reach the sandbox config (from Phase 2.5). Verify this works end-to-end:

1. Install a plugin with an MCP server
2. Create an untrusted workspace that includes this plugin
3. Start a session → verify the MCP is available inside the container

##### 4.3 System prompt in sandbox

**File**: `parachute-computer/parachute/docker/entrypoint.py`

Currently the sandbox entrypoint doesn't receive the system prompt. Add:

- `PARACHUTE_SYSTEM_PROMPT` env var (or better: mount a file to avoid env var size limits)
- Mount system prompt as `/tmp/system_prompt.txt` in the container
- Entrypoint reads it and passes to SDK as `system_prompt_append`

**File**: `parachute-computer/parachute/core/sandbox.py`

In `_build_run_args()`, write the system prompt to a temp file and mount it:

```python
if config.system_prompt:
    fd3, prompt_file = tempfile.mkstemp(suffix='.txt', prefix='parachute-prompt-')
    with os.fdopen(fd3, 'w') as f:
        f.write(config.system_prompt)
    args.extend(["-v", f"{prompt_file}:/tmp/system_prompt.txt:ro"])
```

Add `system_prompt` field to `AgentSandboxConfig`.

---

## Acceptance Criteria

### Functional Requirements

- [x] Plugins can be installed from a GitHub URL via API and Flutter UI
- [x] Installed plugins are indexed — their skills, agents, and MCPs are discovered
- [x] Plugin capabilities appear in the global capability pools and are filterable per workspace
- [x] `setting_sources` is removed — Parachute explicitly constructs all SDK parameters
- [x] CLAUDE.md content is loaded by Parachute and passed via `system_prompt_append`
- [x] The capabilities screen shows 4 tabs: Plugins, Agents, Skills, MCPs
- [x] Each capability has a detail view with rich information
- [x] Plugins can be uninstalled and updated from the UI
- [x] Workspace capability picker includes a Plugins section
- [x] All capabilities work in Docker sandbox sessions

### Non-Functional Requirements

- [ ] Plugin install completes in <30 seconds for typical repos
- [ ] Capability discovery adds <500ms to session startup
- [ ] No regression in existing agent/skill/MCP behavior
- [ ] Plugin format is 100% compatible with Claude Code plugin format

### Quality Gates

- [ ] Server: all existing tests pass after `setting_sources` removal
- [ ] App: `flutter analyze` returns 0 errors
- [ ] Manual test: install compound-engineering plugin from GitHub URL
- [ ] Manual test: create untrusted workspace with plugin capabilities
- [ ] Manual test: verify plugin skills appear in session via `/` invocation

## Alternative Approaches Considered

### 1. Keep SDK auto-discovery, just layer UI on top
**Rejected** — SDK auto-discovery from `setting_sources=["project"]` is unpredictable. When the working directory changes, different CLAUDE.md files and .mcp.json configs get loaded. Parachute needs deterministic control.

### 2. Build custom agent runtime (no SDK)
**Rejected** — The Claude Agent SDK handles MCP lifecycle, tool execution, streaming, error recovery. Rebuilding this is massive effort for marginal benefit. Better to use the SDK as an execution engine with explicit parameters.

### 3. Unified "source" abstraction (like Craft Agents)
**Deferred** — Appealing but requires rethinking the data model. Standard Claude Code format compatibility is higher priority. Can revisit as a future UI-layer abstraction.

## Dependencies & Prerequisites

- Docker must be installed and running for sandbox tests
- `git` must be available on the server for plugin installation from GitHub
- Claude Agent SDK must support `plugin_dirs` parameter (verified: it does, with `inspect.signature` probe in entrypoint)
- Server restart required after Phase 1 changes

## Risk Analysis & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Removing `setting_sources` breaks CLAUDE.md loading | High | Phase 1 includes explicit CLAUDE.md loading as replacement |
| Plugin repos have unexpected structure | Medium | Validate `.claude-plugin/plugin.json` exists before indexing |
| SDK doesn't load plugins from `plugin_dirs` correctly | Medium | Already have runtime plugin generation as fallback |
| Plugin MCPs conflict with vault MCPs (name collision) | Low | Namespace plugin MCPs: `{plugin-slug}/{mcp-name}` |
| Large plugin repos slow down install | Low | Shallow clone (`--depth 1`) for GitHub installs |

## Future Considerations

- **Marketplace browsing**: Fetch plugin catalogs from registered registries (Claude's official + community)
- **Agent-driven installation**: "Install a PR review plugin" → agent searches registries and installs
- **Plugin versioning**: Pin to specific versions, rollback support
- **Hot reload**: Detect plugin file changes and reload without server restart
- **MCP Apps**: Support the new `ui://` scheme for interactive MCP UI in chat
- **Source abstraction layer**: Craft-style unified "capabilities" view as UI-only layer

## References & Research

### Internal References
- Brainstorm: `docs/brainstorms/2026-02-09-capabilities-system-brainstorm.md`
- Orchestrator: `parachute-computer/parachute/core/orchestrator.py`
- Capability filter: `parachute-computer/parachute/core/capability_filter.py`
- Skills system: `parachute-computer/parachute/core/skills.py`
- MCP loader: `parachute-computer/parachute/lib/mcp_loader.py`
- Agent loader: `parachute-computer/parachute/core/agents.py`
- Sandbox: `parachute-computer/parachute/core/sandbox.py`
- Entrypoint: `parachute-computer/parachute/docker/entrypoint.py`
- Capabilities screen: `parachute-app/lib/features/settings/screens/capabilities_screen.dart`
- Workspace model: `parachute-computer/parachute/models/workspace.py`

### External References
- Claude Code plugin format: https://code.claude.com/docs/en/plugins
- Claude Code skill format: https://code.claude.com/docs/en/skills
- Craft Agents sources: https://agents.craft.do/docs/sources/overview
- MCP registry: https://github.com/modelcontextprotocol/registry
