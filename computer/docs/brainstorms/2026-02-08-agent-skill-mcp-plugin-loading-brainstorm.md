# Agent, Skill, MCP & Plugin Loading Strategy

**Date**: 2026-02-08
**Status**: Brainstorm
**Topic**: How should Parachute load and manage agents, skills, MCPs, and plugins across all execution contexts?

---

## The Question

How should Parachute load agents, skills, MCPs, and plugins? Is the current approach (largely Claude defaults) ideal going forward? If so, we need to make sure everything gets passed through correctly. If not, what should change?

Key concerns:
- Compound Engineering workflows weren't available in agent sessions (plugins not passed?)
- Sandbox sessions need capabilities surfaced properly too
- Want to get this right before building more on top

---

## Current State: How Things Work Today

### The Loading Chain

```
orchestrator.run_streaming()
    │
    ├── load_mcp_servers()          → .mcp.json + built-in parachute MCP
    ├── generate_runtime_plugin()   → .skills/ → .parachute/runtime/skills-plugin/
    ├── discover_agents()           → .parachute/agents/*.yaml|json|md
    ├── _build_system_prompt()      → vault agent prompt + runtime context
    │
    └── query_streaming()
            │
            ├── mcp_servers      → dict of MCP configs (stdio only to SDK)
            ├── plugins          → [{"type": "local", "path": "..."}]
            ├── agents           → {"name": {description, prompt, tools, model}}
            ├── setting_sources  → ["project"] (enables CLAUDE.md hierarchy)
            └── cwd              → vault or working directory
```

### What the SDK Actually Supports

From `ClaudeAgentOptions`:

| Feature | SDK Parameter | Format | Status |
|---------|--------------|--------|--------|
| MCP Servers | `mcp_servers` | Dict of stdio/sse/http/sdk configs | Working |
| Plugins | `plugins` | `[{"type": "local", "path": "..."}]` | Working |
| Agents (subagents) | `agents` | Dict of AgentDefinition | Working |
| CLAUDE.md | `setting_sources` + `cwd` | Auto-discovered from cwd hierarchy | Working |
| Sandbox | `sandbox` | `SandboxSettings` (native CLI sandbox) | Not used |
| Hooks | `hooks` | Dict of hook matchers | Not used via SDK |
| `add_dirs` | `add_dirs` | Additional project directories | Not used |

### What Gets Passed Where

| Capability | Full Trust | Vault Trust | Sandboxed (Docker) |
|-----------|-----------|-------------|-------------------|
| MCP servers | Yes | Yes | **No** (runs inside Docker) |
| Plugins/Skills | Yes | Yes | **No** (Docker has own FS) |
| Custom agents | Yes | Yes | **No** (Docker has own FS) |
| CLAUDE.md | Yes (via cwd) | Yes (via cwd) | **No** (Docker has own FS) |
| System prompt | Yes | Yes | **No** (passed as message only) |

### The Gaps

1. **Sandbox gets nothing** — Docker sandbox runs a bare `claude` process inside a container. No MCPs, no plugins, no agents, no CLAUDE.md. It only gets the user message via stdin.

2. **Subagent inheritance is unclear** — When the main agent spawns a subagent via the Task tool, does the subagent inherit MCPs? Plugins? The SDK's `AgentDefinition` only has `description`, `prompt`, `tools`, `model` — no `mcp_servers` or `plugins` fields. This means subagents likely don't get MCPs or plugins.

3. **Skills require filesystem** — The skills system generates a runtime plugin directory on disk. This works for direct execution but breaks in Docker sandbox where the vault filesystem layout is different.

4. **MCP built-in server assumes local** — The Parachute MCP server runs as a subprocess (`python -m parachute.mcp_server`). Inside Docker, this binary may not exist or may not have the right paths.

---

## Key Design Questions

### Q1: Should we keep using the Claude default loading mechanisms?

**Argument FOR (current approach + fixes)**:
- The SDK has first-class support for plugins, MCPs, agents, CLAUDE.md
- We're already using these. Just need to make sure they work in all contexts.
- Claude Code CLI handles resolution, version management, skill invocation
- Fighting the SDK means maintaining a parallel system
- SDK keeps improving — we get features for free

**Argument AGAINST (custom layer)**:
- Docker sandbox bypasses the SDK entirely (runs claude CLI directly)
- We have no control over what subagents inherit
- The SDK's AgentDefinition is limited (no MCP or plugin fields for subagents)
- We need trust-level-aware capability filtering

**Recommendation**: Keep Claude defaults as the foundation. Fix the gaps rather than rebuilding. The SDK is the right abstraction — we just need to pass things through correctly.

### Q2: How do we get capabilities into sandbox sessions?

Three approaches:

**A) Mount capabilities into Docker container**
- Mount `.mcp.json`, `.skills/`, `.parachute/agents/` into the container
- Pre-install the Parachute MCP server in the Docker image
- Let the Claude CLI inside Docker discover everything naturally
- Pro: Same mechanisms everywhere. Con: Need to maintain Docker image.

**B) Use SDK's native sandbox instead of Docker**
- The SDK has `SandboxSettings` with network control, command filtering, etc.
- This runs Claude in the same process but with a sandbox wrapper
- Pro: All SDK features work naturally. Con: Less isolation than Docker.

**C) Hybrid: SDK sandbox for most, Docker for untrusted**
- Use SDK's native sandbox for `vault` trust (restricted paths, filtered tools)
- Use Docker only for truly untrusted code (sandboxed trust level)
- Mount capabilities into Docker when used
- Pro: Best of both worlds. Con: Two sandbox mechanisms.

**Recommendation**: Option C. The SDK's native sandbox handles most use cases. Docker is only needed for maximum isolation (untrusted bot sessions). For Docker sessions, mount the capability files in.

### Q3: How do we ensure subagents get MCPs and plugins?

The SDK's `AgentDefinition` only supports: `description`, `prompt`, `tools`, `model`. No way to pass MCPs or plugins to subagents.

However, since subagents run within the same Claude Code process, they likely **inherit** the parent's MCPs and plugins. The `tools` list in AgentDefinition restricts which tools the subagent can use, but MCP tools (prefixed `mcp__*`) are tools — so they should be accessible if listed in `tools` or if `tools` is None (unrestricted).

**To verify**: Check if a subagent can use `mcp__parachute__search` when the parent has the Parachute MCP loaded and the subagent's tools list includes MCP tools or is unrestricted.

**If subagents DO inherit MCPs/plugins**: No changes needed. Just make sure agent definitions in `.parachute/agents/` include MCP tool names in their `tools` list (or leave tools empty for unrestricted access).

**If subagents DON'T inherit**: We'd need to either:
1. Inject MCP tool documentation into the subagent's prompt (hacky)
2. Request SDK feature: MCP/plugin inheritance for subagents
3. Use `add_dirs` or other SDK features to ensure plugin discovery

### Q4: How should trust levels filter capabilities?

Current trust levels only affect filesystem access and execution environment. But they should also filter capabilities:

| Capability | Full | Vault | Sandboxed |
|-----------|------|-------|-----------|
| All MCPs | Yes | Vault-safe MCPs only | Built-in only |
| All plugins | Yes | Yes | Built-in only |
| Custom agents | Yes | Yes | Restricted |
| Bash tool | Yes | Restricted paths | Container only |
| Network (WebSearch etc) | Yes | Yes | No (except API) |

**Not currently enforced** — all trust levels get the same MCPs, plugins, and agents. Only the filesystem boundary changes.

### Q5: Where should capability configuration live?

Currently spread across:
- `.mcp.json` — MCP servers (Claude standard)
- `.skills/` — Skills (Claude standard)
- `.parachute/agents/` — Custom agents (Parachute-specific)
- `.parachute/config.yaml` — Server settings
- `CLAUDE.md` — Project settings (Claude standard)

This is reasonable. The Claude-standard locations (`.mcp.json`, `.skills/`, `CLAUDE.md`) should stay. The Parachute-specific agents directory is fine since the SDK supports agents natively.

**One addition to consider**: A unified capabilities manifest at `.parachute/capabilities.yaml` that declares what's available and maps trust levels to capability sets. This would be the single source of truth for "what can this session access?"

---

## Proposed Architecture

### Layer 1: Capability Discovery (already works)

```
discover_mcps()    → .mcp.json
discover_skills()  → .skills/
discover_agents()  → .parachute/agents/
discover_claude_md() → CLAUDE.md hierarchy (SDK handles)
```

### Layer 2: Trust-Level Filtering (NEW)

```python
def filter_capabilities_by_trust(
    trust_level: TrustLevel,
    mcps: dict,
    plugins: list,
    agents: list,
) -> FilteredCapabilities:
    """
    Apply trust-level restrictions to discovered capabilities.

    - FULL: Everything available
    - VAULT: Filter out MCPs that access outside vault
    - SANDBOXED: Only built-in MCP, no external plugins/agents
    """
```

### Layer 3: Execution Context Assembly (fix gaps)

**For direct execution (full/vault trust)**:
```python
# Already working — pass to SDK
options = ClaudeAgentOptions(
    mcp_servers=filtered_mcps,
    plugins=filtered_plugins,
    agents=filtered_agents,
    setting_sources=["project"],
    cwd=effective_cwd,
    # NEW: Use SDK's native sandbox for vault trust
    sandbox=sandbox_settings if trust == "vault" else None,
)
```

**For Docker sandbox (sandboxed trust)**:
```python
# FIX: Mount capability files into container
docker_mounts = [
    # Vault (read-only or scoped)
    f"{vault}:/vault:ro",
    # MCP config (so Claude CLI inside discovers it)
    f"{vault}/.mcp.json:/home/parachute/.mcp.json:ro",
    # Skills
    f"{vault}/.skills:/home/parachute/.skills:ro",
    # Agents
    f"{vault}/.parachute/agents:/home/parachute/.parachute/agents:ro",
    # CLAUDE.md
    f"{vault}/CLAUDE.md:/home/parachute/CLAUDE.md:ro",
]
```

### Layer 4: SDK Native Sandbox (NEW — for vault trust)

Instead of our custom Docker sandbox for vault trust, use the SDK's native sandbox:

```python
vault_sandbox = SandboxSettings(
    enabled=True,
    autoAllowBashIfSandboxed=False,
    excludedCommands=["rm -rf", "sudo"],
    allowUnsandboxedCommands=False,
    network=SandboxNetworkConfig(
        allowLocalBinding=True,
        allowAllUnixSockets=False,
    ),
)
```

This gives us sandbox isolation while keeping all SDK features (MCPs, plugins, agents, CLAUDE.md) working naturally.

---

## What Went Wrong: Why Compound Engineering Didn't Work

The user tried to invoke a Compound Engineering workflow from within a chat session and it wasn't available. Here's why:

1. **Compound Engineering is a Claude Code plugin** — it gets loaded via the user's `~/.claude/plugins/` directory
2. **Parachute's SDK sessions don't inherit the user's plugin directory** — we only pass plugins from `{vault}/.skills/`
3. **The `setting_sources` parameter controls this** — we use `["project"]` which loads project-level settings but NOT user-level

To fix this, we could:
- **Option A**: Add `"user"` to `setting_sources` → `["user", "project"]`. This would load the user's Claude Code plugins, including Compound Engineering. But it also loads ALL user settings which may not be desired for a server context.
- **Option B**: Copy/symlink desired plugins into the vault's skills directory. More explicit but requires manual setup.
- **Option C**: Use `add_dirs` SDK parameter to add the user's plugin directories without loading all user settings.
- **Option D**: Make plugin loading configurable in `.parachute/config.yaml` — specify which plugin directories to include.

**Recommendation**: Option D with a sensible default. Config file specifies plugin directories. On personal installs, default to including `~/.claude/plugins/`. On shared installs, default to vault-only.

```yaml
# .parachute/config.yaml
plugins:
  include_user_plugins: true  # Load ~/.claude/plugins/
  additional_dirs:
    - /path/to/shared/plugins
```

---

## Implementation Priority

### P0: Fix the immediate problem (Compound Engineering not available)
- Add user plugin directory discovery
- Pass through via `plugin_dirs` to SDK
- Config option to control this

### P1: Fix sandbox capability gap
- Mount capability files into Docker containers
- Pre-install Parachute MCP server in Docker image
- Ensure CLAUDE.md is available inside sandbox

### P2: Trust-level capability filtering
- Add `filter_capabilities_by_trust()` to orchestrator
- Define which MCPs/plugins/agents are safe at each trust level
- Document the trust model

### P3: Explore SDK native sandbox
- Test `SandboxSettings` as replacement for Docker sandbox at vault trust
- Compare isolation guarantees
- Consider hybrid approach (SDK sandbox + Docker)

### P4: Unified capabilities manifest
- `.parachute/capabilities.yaml` as single source of truth
- Maps trust levels to capability sets
- Enables admin control over what agents can access

---

## Open Questions

1. **Do subagents inherit MCPs and plugins?** Need to test empirically. If they do, our agent definitions just need the right tool lists. If not, we need a workaround.

2. **Should the built-in Parachute MCP server work inside Docker?** It searches the vault — if the vault is mounted read-only, can it still index and search?

3. **Is the SDK's native sandbox sufficient for vault trust?** Or do we need Docker for filesystem-level isolation? The SDK sandbox uses process-level restrictions which may be less robust.

4. **How do we handle MCP server lifecycle?** Currently MCPs are started per-query. Should they be persistent? The SDK handles lifecycle but restarts them on each invocation.

5. **What about remote MCP servers?** The SDK supports HTTP MCPs now. These would work in any execution context (including Docker) since they're network calls. Should we push users toward remote MCPs for sandbox compatibility?

---

## Summary

The current approach is fundamentally sound — using Claude's native mechanisms for plugins, MCPs, agents, and CLAUDE.md. The gaps are:

1. **User plugins not passed through** (why Compound Engineering didn't work)
2. **Docker sandbox gets nothing** (no MCPs, plugins, agents, or CLAUDE.md)
3. **No trust-level filtering** (all sessions get all capabilities)

The fix is evolutionary, not revolutionary: pass more things through to the SDK, mount files into Docker, and add trust-level filtering. The SDK is the right abstraction layer — we should lean into it, not fight it.

---

## Workspace Model: Per-Environment Capability Configuration

### The Insight

The question isn't just "how do we pass capabilities through" — it's **"how does the user control what each environment gets?"** Different sessions need different capability sets. A coding workspace needs everything. A research assistant needs web search and brain, not bash. A Telegram bot for friends needs almost nothing.

This points toward **workspaces** as a first-class concept: a named configuration that bundles together everything a session needs.

### Prior Art: Craft Agents

The `craft-agents-oss` codebase has a mature workspace model worth studying:

```
~/.craft-agent/workspaces/{slug}/
├── config.json          # Name, defaults (model, permission mode, working dir)
├── .claude-plugin/      # Plugin manifest (enables SDK plugin loading)
│   └── plugin.json
├── sources/             # MCP data sources (per-workspace)
├── sessions/            # Chat sessions (scoped to workspace)
└── skills/              # Skills (per-workspace)
```

Key ideas from Craft:
- **Workspace = isolation boundary** — sessions, sources, skills are all scoped
- **Workspace IS a plugin** — each workspace has `.claude-plugin/plugin.json` so the SDK loads it as a plugin directory, automatically discovering skills and agents
- **Sources are per-workspace** — different workspaces connect to different MCP servers
- **Defaults cascade** — global defaults → workspace defaults → session overrides
- **Permission modes per workspace** — safe/ask/allow-all (similar to our trust levels)

### Parachute Workspace Model

Adapting this to Parachute's architecture (server-side, multi-user):

```
vault/.parachute/workspaces/{slug}/
├── config.yaml          # Workspace configuration
├── .mcp.json            # MCP servers for this workspace (overrides vault-level)
├── .skills/             # Skills available in this workspace
├── agents/              # Custom agents for this workspace
└── CLAUDE.md            # Workspace-level instructions
```

**Workspace config.yaml**:
```yaml
name: "Coding"
description: "Full-powered development environment"

# Execution environment
trust_level: full          # full | vault | sandboxed
working_directory: ~/Projects
model: opus                # Default model for new sessions

# Capability sets — what's available in this workspace
capabilities:
  mcps: all                # all | none | [list of names]
  skills: all              # all | none | [list of names]
  agents: all              # all | none | [list of names]
  plugins:                 # Additional plugin directories
    include_user: true     # Load ~/.claude/plugins/
    dirs: []               # Extra plugin paths

  # Tool restrictions
  tools:
    allow: all             # all | [list of tool names]
    deny: []               # Tools to block

  # Network
  network:
    web_search: true
    web_fetch: true

# Docker config (only applies if trust_level=sandboxed)
sandbox:
  memory: "512m"
  cpu: "1.0"
  timeout: 300
  mount_paths:             # Additional paths to mount
    - ~/Projects/data:ro
```

**Inheritance chain**:
```
vault-level defaults
    └── workspace config.yaml
        └── session-level overrides (trust level, model)
```

### How It Maps to Current Code

Today's `NewChatConfig` already captures the seeds of this:
```dart
class NewChatConfig {
  final String? workingDirectory;
  final String? agentType;
  final String? agentPath;
  final TrustLevel? trustLevel;
}
```

A workspace is essentially a **saved NewChatConfig** plus capability declarations. The "New Chat" flow becomes:

1. **Pick a workspace** (or create one)
2. Workspace provides all defaults: trust, model, working dir, capabilities
3. User can override per-session (narrow only, never widen trust)
4. Start chatting — orchestrator loads workspace config and assembles the environment

### Server-Side Changes

**Orchestrator gets workspace awareness**:
```python
async def run_streaming(self, ..., workspace: str = None):
    # Load workspace config (or use vault defaults)
    ws_config = load_workspace_config(self.vault_path, workspace)

    # Discover ALL capabilities, then filter by workspace
    all_mcps = await load_mcp_servers(self.vault_path)
    all_skills = discover_skills(self.vault_path)
    all_agents = discover_agents(self.vault_path)

    # Also discover workspace-local capabilities
    if ws_config.path:
        ws_mcps = await load_mcp_servers(ws_config.path)
        ws_skills = discover_skills(ws_config.path)
        ws_agents = discover_agents(ws_config.path)
        # Merge: workspace overrides vault

    # Filter by workspace config
    filtered = filter_capabilities(ws_config, merged_mcps, merged_skills, merged_agents)

    # Assemble execution context
    ...
```

**Session metadata stores workspace**:
```python
# sessions.db gets a workspace_id column
session = Session(
    workspace="coding",  # Links to workspace config
    trust_level="full",  # From workspace default or overridden
    ...
)
```

### App-Side UI Changes

**New Chat flow becomes workspace-aware**:

```
┌─────────────────────────┐
│       New Chat           │
├─────────────────────────┤
│ Workspace                │
│ ┌───────┐ ┌──────────┐  │
│ │Coding │ │ Research  │  │
│ └───────┘ └──────────┘  │
│ ┌───────┐ ┌──────────┐  │
│ │Writing│ │ + Custom  │  │
│ └───────┘ └──────────┘  │
├─────────────────────────┤
│ Using: opus · full trust │
│ MCPs: all · Skills: all  │
│ Dir: ~/Projects          │
├─────────────────────────┤
│      [Start Chat]        │
└─────────────────────────┘
```

**Session config sheet shows workspace**:
- Current workspace badge
- Can change trust level (narrow only)
- Can change model
- Can see active capabilities (read-only)

**Settings gets workspace management**:
- Create/edit/delete workspaces
- Configure capabilities per workspace
- Set defaults

### Bot Connector Integration

Bot connectors already have per-platform trust levels. Workspaces extend this naturally:

```yaml
# bots.yaml
telegram:
  token: "..."
  trust_level: sandboxed
  workspace: telegram-bot    # <-- NEW: links to workspace config

discord:
  token: "..."
  trust_level: vault
  workspace: discord-bot
```

Each bot gets its own workspace with tailored capabilities. The "Telegram bot" workspace might have:
- No bash, no file write
- Brain MCP for knowledge queries
- Web search for lookups
- Restricted agent set

### Docker Sandbox + Workspaces

For sandboxed workspaces, the Docker container gets assembled from the workspace config:

```python
def _build_mounts_from_workspace(self, ws_config: WorkspaceConfig) -> list[str]:
    mounts = []

    # Mount workspace-specific capabilities
    ws_path = ws_config.path
    if ws_path.exists():
        mounts.extend(["-v", f"{ws_path}:/workspace:ro"])

    # Mount workspace MCP config
    mcp_json = ws_path / ".mcp.json"
    if mcp_json.exists():
        mounts.extend(["-v", f"{mcp_json}:/home/user/.mcp.json:ro"])

    # Mount workspace skills
    skills_dir = ws_path / ".skills"
    if skills_dir.exists():
        mounts.extend(["-v", f"{skills_dir}:/home/user/.skills:ro"])

    # Mount working directory (read-write)
    if ws_config.working_directory:
        mounts.extend(["-v", f"{ws_config.working_directory}:/project:rw"])

    return mounts
```

The container is a fully-equipped environment — but only with what the workspace specifies. Not everything. Not nothing. Exactly what's configured.

### Migration Path

This doesn't need to be built all at once. Incremental path:

**Phase 1: Implicit workspaces (now → soon)**
- Keep current behavior as the "default" workspace
- Add `workspace` field to session metadata (nullable, defaults to "default")
- No UI changes yet — existing flows work unchanged

**Phase 2: Server-side workspace configs (near-term)**
- Support `vault/.parachute/workspaces/` directory
- Orchestrator reads workspace config when specified
- API accepts `workspace` parameter on session creation
- CLI can list/create workspaces

**Phase 3: App workspace picker (medium-term)**
- New Chat sheet shows workspace selector
- Session config sheet shows current workspace
- Settings gets workspace management page

**Phase 4: Full capability filtering (later)**
- Workspace config controls exactly which MCPs, skills, agents are available
- Docker containers assembled from workspace config
- Bot connectors linked to workspaces

### Open Design Questions

1. **Workspace scope: vault-level or global?**
   - Vault-level (`vault/.parachute/workspaces/`) means workspaces are per-vault
   - Global (`~/.parachute/workspaces/`) means workspaces span vaults
   - Vault-level feels right — workspaces are about what's available in THIS vault

2. **Can workspaces ADD capabilities or only restrict?**
   - If workspace "coding" says `mcps: all`, it gets all vault MCPs
   - But can it add an MCP that isn't in the vault's `.mcp.json`?
   - Workspace-local `.mcp.json` could provide additions (merged with vault)
   - This is powerful but complex — maybe phase 4

3. **How do workspace-local skills/agents interact with vault-level ones?**
   - Workspace `.skills/` could override or supplement vault `.skills/`
   - Need clear merge semantics: workspace wins? or additive?
   - Recommendation: additive by default, workspace can exclude vault items

4. **Should workspaces be shareable?**
   - Export workspace config as a template others can import?
   - Useful for teams — "here's our coding workspace setup"
   - Low priority but nice to design for

---

## Chat UI Overhaul

The current Chat UI was built incrementally and feels dated. With workspaces becoming a first-class concept, this is the right time for a comprehensive redesign. The Craft Agents OSS UI provides excellent reference patterns.

### Current State Assessment

**ChatHubScreen** (`chat/screens/chat_hub_screen.dart`):
- Simple flat `ListView` of sessions — no grouping, no search
- Single archive toggle button in app bar
- FAB for new chat (jumps straight to ChatScreen with no config)
- No workspace awareness
- ~620 lines including pairing approval dialog (mixed concerns)

**ChatScreen** (`chat/screens/chat_screen.dart`):
- Monolithic ~1500 lines doing too much
- Trust level selector embedded in empty state
- 6+ action buttons crowding the app bar (refresh, folder, tune, info, curator, settings, overflow menu)
- Session title tappable for session switcher (bottom sheet)
- Model badge, agent badge, working directory all in app bar
- No workspace indicator

**SessionListItem** (`chat/widgets/session_list_item.dart`):
- Good: source-based icons, badges (pending/archived/trust), swipe actions
- Missing: date grouping, search, unread indicators, last message preview

**NewChatSheet** (`chat/widgets/new_chat_sheet.dart`):
- Working directory picker, agent selector, trust level chips
- No workspace concept — user configures everything individually each time

### Design Vision: What It Should Feel Like

The chat experience should feel like a **focused, workspace-aware workspace** — not a list of disconnected conversations. Key shifts:

1. **Workspace-first navigation** — Pick your workspace, then work within it
2. **Temporal context** — Sessions grouped by date like Craft's SessionList
3. **Desktop-optimized layout** — Multi-panel when screen width allows
4. **Less chrome, more content** — Consolidate app bar clutter into contextual surfaces
5. **Quick actions** — Keyboard shortcuts, search, swipe gestures

### Reference: Craft Agents Patterns Worth Adopting

From studying `SessionList.tsx`, `WorkspaceSwitcher.tsx`, and `AppShell.tsx`:

| Pattern | Craft Implementation | Parachute Adaptation |
|---------|---------------------|---------------------|
| Date-grouped sessions | "Today", "Yesterday", "Last 7 days", "Last 30 days", month groups | Same grouping in Flutter `SliverList` with sticky headers |
| Workspace switcher | Dropdown with avatars, crossfade animation, "New workspace" overlay | Horizontal chips or dropdown in app bar, workspace creation sheet |
| 3-panel layout | LeftSidebar (20%) \| SessionList (32%) \| MainContent (48%) | `Row` with `Expanded` children on desktop, single-column on mobile |
| Session search | Inline search with text highlighting, keyboard-focused | `SearchBar` at top of session list with filter chips |
| Context menus | Right-click menu with archive, delete, rename, copy link | Long-press bottom sheet (already partially done) |
| Keyboard navigation | j/k to move, Enter to select, / to search, n for new chat | Desktop-only keyboard shortcuts via `FocusNode` |
| Unread indicators | Dot indicator + bold text for sessions with new activity | Blue dot for sessions updated since last view |
| Source management | Dedicated "Sources" panel for MCP configuration | Workspace settings page with source list |
| Session status | Todo states (open, in_progress, done, etc.) | Trust level + status badge (pending/active/archived) |

### Proposed Layout: Adaptive Multi-Panel

```
┌──────────────────────────────────────────────────────────┐
│ DESKTOP (>1200px): 3-panel                                │
│                                                           │
│ ┌──────────┬──────────────┬─────────────────────────────┐ │
│ │ Sidebar  │ Session List  │     Chat Content            │ │
│ │          │               │                             │ │
│ │ Workspaces│ Search [___] │  [Messages...]              │ │
│ │ ● Coding │               │                             │ │
│ │ ○ Research│ Today        │                             │ │
│ │ ○ Writing │ ▸ Fix auth..│                             │ │
│ │          │ ▸ Deploy...  │                             │ │
│ │ ─────── │               │                             │ │
│ │ Sources  │ Yesterday    │                             │ │
│ │ Skills   │ ▸ Brain API..│                             │ │
│ │ Settings │               │  [Input]                    │ │
│ └──────────┴──────────────┴─────────────────────────────┘ │
│                                                           │
│ TABLET (600-1200px): 2-panel                              │
│                                                           │
│ ┌──────────────┬────────────────────────────────────────┐ │
│ │ Session List  │     Chat Content                       │ │
│ │ + Workspace  │                                        │ │
│ │   Switcher   │                                        │ │
│ └──────────────┴────────────────────────────────────────┘ │
│                                                           │
│ MOBILE (<600px): Single column with navigation            │
│                                                           │
│ ┌──────────────────────────────────────────────────────┐  │
│ │ [Hub]  ←→  [Chat]  (push navigation)                 │  │
│ └──────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

**Implementation approach**: Use `LayoutBuilder` to detect width and render the appropriate layout. The session list and chat content are the same widgets — just composed differently.

### Surface-by-Surface Redesign

#### 1. Chat Hub → Session List Panel

**Current**: Flat `ListView` with `SessionListItem` widgets, FAB for new chat.

**Redesigned**:

```
┌─────────────────────────────┐
│ [Workspace ▾]  [🔍] [+]    │  ← Workspace picker, search, new chat
├─────────────────────────────┤
│ Filter: All | Active | Pending │  ← Tab bar replacing archive toggle
├─────────────────────────────┤
│                              │
│ TODAY                        │  ← Sticky date group headers
│ ┌──────────────────────────┐ │
│ │ 🟢 Fix auth middleware    │ │  ← Status dot + title
│ │    Coding · opus · 2m ago │ │  ← Workspace · model · time
│ └──────────────────────────┘ │
│ ┌──────────────────────────┐ │
│ │ 🟡 Review PR #42         │ │  ← Pending approval (amber)
│ │    via Telegram · 15m ago │ │
│ └──────────────────────────┘ │
│                              │
│ YESTERDAY                    │
│ ┌──────────────────────────┐ │
│ │ ⚪ Brain search query     │ │
│ │    Research · haiku · 1d  │ │
│ └──────────────────────────┘ │
│                              │
│ LAST 7 DAYS                  │
│ ...                          │
└─────────────────────────────┘
```

**Key changes**:
- Date-grouped sessions with sticky headers (use `sliver_tools` or custom `SliverList`)
- Workspace badge on each session (visible when viewing "All" workspaces)
- Status dots: green (active), amber (pending approval), gray (idle/archived)
- Three filter tabs: All, Active, Pending (replaces archive toggle)
- Search bar that filters sessions by title, agent name, content
- New chat button in header (not FAB) — tapping shows workspace-aware new chat sheet

#### 2. New Chat Flow → Workspace-Aware Sheet

**Current**: `NewChatSheet` with individual pickers for directory, agent, trust level.

**Redesigned**:

```
┌─────────────────────────────┐
│       Start a New Chat       │
├─────────────────────────────┤
│                              │
│ Workspace                    │
│ ┌─────┐ ┌────────┐ ┌──────┐ │
│ │ 💻  │ │ 🔬     │ │ ✏️   │ │
│ │Code │ │Research│ │Write │ │
│ │ ───  │ │  ───   │ │ ───  │ │
│ │opus │ │ haiku  │ │sonnet│ │
│ │full │ │ vault  │ │ full │ │
│ └─────┘ └────────┘ └──────┘ │
│                              │
│ ── or configure manually ── │
│                              │
│ Model     [Sonnet ▾]        │
│ Trust     [● Full ○ Vault ○ Isolated] │
│ Directory [~/Projects ▾]    │
│ Agent     [Default ▾]       │
│                              │
│      [ Start Chat ]          │
└─────────────────────────────┘
```

**Key changes**:
- Workspace cards as primary selection (one tap to start with all defaults)
- Manual configuration collapses below (for power users or one-off sessions)
- Each workspace card shows: icon, name, default model, trust level
- Tapping a workspace card immediately starts a chat (no extra confirmation)
- "Configure manually" expands the current pickers

#### 3. Chat Screen → Focused Content Area

**Current**: Monolithic 1500-line widget with many app bar actions.

**Redesigned app bar** (simplified):

```
┌──────────────────────────────────────────┐
│ ← │ Session Title          │ ⚙️ │ ··· │
│   │ Coding · opus          │    │     │
└──────────────────────────────────────────┘
```

- **Left**: Back arrow (mobile) or nothing (desktop multi-panel)
- **Center**: Session title + workspace/model subtitle (tappable to rename)
- **Right**: Settings gear (opens session config), overflow (archive/delete)
- **Removed from app bar**: folder, tune, info, curator, refresh — move to session config sheet or context menu

**Redesigned session config** (consolidate scattered controls):

```
┌─────────────────────────────┐
│ Session Settings             │
├─────────────────────────────┤
│ Workspace: Coding            │
│ Trust: Full  [Change ▾]     │
│ Model: opus  [Change ▾]     │
│ Directory: ~/Projects        │
│ Agent: Vault Agent           │
├─────────────────────────────┤
│ Context Files                │
│ ☑ CLAUDE.md                  │
│ ☑ .parachute/config.yaml    │
│ ☐ notes/todo.md             │
│ [Reload CLAUDE.md]           │
├─────────────────────────────┤
│ Session Info                 │
│ ID: sess_abc123              │
│ Created: 2 hours ago         │
│ Messages: 24                 │
│ Tokens: 12,340 in / 8,921 out│
├─────────────────────────────┤
│ Curator Status               │
│ Background tasks: 2 running  │
│ [View Details]               │
└─────────────────────────────┘
```

This consolidates 4 separate sheets (session config, context settings, session info, curator) into one organized settings panel. On desktop, this could be a right sidebar instead of a bottom sheet.

#### 4. Desktop Sidebar → Navigation & Workspace Management

**New concept** — only shown on desktop/tablet:

```
┌──────────────┐
│ 🪂 Parachute  │
├──────────────┤
│              │
│ WORKSPACES   │
│ ● Coding     │  ← Active workspace (highlighted)
│ ○ Research   │
│ ○ Writing    │
│ ○ Telegram   │  ← Bot workspace
│              │
│ [+ New]      │
│              │
├──────────────┤
│ QUICK ACCESS │
│ 📋 Sources   │  ← Opens source management
│ ⚡ Skills    │  ← Opens skill browser
│ 🤖 Agents    │  ← Opens agent gallery
│              │
├──────────────┤
│ ⚙️ Settings  │
│ 📊 Usage     │
└──────────────┘
```

This sidebar is the workspace command center. On mobile, workspace switching happens via the dropdown in the session list header.

### Component Architecture

The redesign suggests this component hierarchy:

```
ChatShell (adaptive layout manager)
├── WorkspaceSidebar (desktop only)
│   ├── WorkspaceList
│   └── QuickAccessMenu
├── SessionListPanel
│   ├── WorkspacePicker (mobile: dropdown, desktop: sidebar handles this)
│   ├── SessionSearch
│   ├── SessionFilterTabs
│   └── DateGroupedSessionList
│       ├── DateGroupHeader (sticky)
│       └── SessionListItem (enhanced)
├── ChatContentPanel
│   ├── ChatAppBar (simplified)
│   ├── MessageList
│   ├── ChatInput
│   └── UserQuestionCard
└── SessionSettingsPanel (right sidebar on desktop, bottom sheet on mobile)
    ├── WorkspaceInfo
    ├── TrustModelSelector
    ├── ContextFileManager
    ├── SessionMetadata
    └── CuratorStatus
```

**Key architectural decision**: `ChatShell` replaces the current `ChatHubScreen` + `ChatScreen` as separate routes. Instead, they become panels within a single shell that adapts to screen size. On mobile, `SessionListPanel` and `ChatContentPanel` use `Navigator` for push/pop. On desktop, they sit side by side.

### Migration Strategy

This is a big redesign. Break it into phases:

**Phase 1: Improve what exists (small PR)**
- Add date grouping to session list
- Add search to chat hub
- Consolidate app bar actions in ChatScreen
- No layout changes

**Phase 2: Adaptive layout (medium PR)**
- Introduce `ChatShell` as the layout manager
- Two-panel layout on desktop (session list + chat)
- Existing navigation preserved on mobile
- No workspace features yet

**Phase 3: Workspace integration (large PR, after server-side workspace support)**
- Add workspace picker to session list
- Add workspace sidebar on desktop
- New chat flow with workspace cards
- Session config consolidation

**Phase 4: Polish (medium PR)**
- Keyboard navigation on desktop
- Unread indicators
- Animation polish (Craft's crossfade workspace transitions)
- Right sidebar for session settings on desktop

### Open UI Questions

1. **Tab bar vs bottom nav**: Currently Chat is one of four bottom tabs. Should the desktop layout put all four tabs in the sidebar instead? Or keep bottom nav on mobile and sidebar on desktop?

2. **Session list always visible on desktop?**: On desktop, should the session list always be visible (Craft's approach) or collapsible? Always-visible means context switching is fast but uses screen space.

3. **Workspace creation flow**: How much config is needed upfront? Craft lets you create a workspace with just a name and directory. Should Parachute require trust level and model selection, or default everything?

4. **Bot sessions in the main list or separate?**: Currently bot sessions (Telegram, Discord) appear in the main session list with source badges. Should they have their own section or workspace?

5. **Mobile-first or desktop-first?**: The current UI is mobile-first. Should the redesign prioritize desktop (where most power users are) and adapt down, or continue mobile-first?
