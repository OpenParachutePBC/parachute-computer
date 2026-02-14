---
title: "feat: Agent, Skill & MCP Server Management UI"
type: feat
date: 2026-02-09
---

# Agent, Skill & MCP Server Management UI

## Overview

Surface the three SDK capability types -- agents, skills, and MCP servers -- as first-class visible objects in the Parachute app. Users can browse what is available, enable/disable them per workspace, and understand what tools their AI session has access to. The server already discovers, loads, and filters all three types; the gap is API endpoints for listing agents and a comprehensive app UI.

## Problem Statement

Today agents, skills, and MCP servers are loaded behind the scenes and passed to the Claude SDK with no user visibility:

1. **Agents** are hardcoded in the Flutter `new_chat_sheet.dart` as a static `_availableAgents` list. The server discovers agents from two directories (`vault/agents/` and `vault/.parachute/agents/`) but has no API to list them.

2. **Skills** have a CRUD API (`/api/skills`) and discovery (`core/skills.py`) but no app UI to browse or manage them. Users must manually create `.skills/` files.

3. **MCP servers** have a full CRUD API (`/api/mcps`) with test endpoints but no app UI. Users must edit `.mcp.json` or use the CLI.

4. **Per-workspace capability configuration** exists in the data model (`WorkspaceCapabilities.mcps`, `.skills`, `.agents`) and is enforced at runtime by `capability_filter.py`, but there is no UI for users to configure which capabilities a workspace allows.

## Current Pipeline

### Discovery

| Type | Discovery Location | Code |
|------|--------------------|------|
| Agents (markdown) | `vault/agents/*.md` | `lib/agent_loader.py:load_all_agents()` |
| Agents (custom subagents) | `vault/.parachute/agents/*.{yaml,json,md}` | `core/agents.py:discover_agents()` |
| Skills | `vault/.skills/*.md` or `vault/.skills/*/SKILL.md` | `core/skills.py:discover_skills()` |
| MCP servers (built-in) | Hardcoded in `lib/mcp_loader.py` | `_get_builtin_mcp_servers()` |
| MCP servers (user) | `vault/.mcp.json` | `lib/mcp_loader.py:load_mcp_servers()` |

### Loading & Transformation

| Type | Transformation | Code |
|------|----------------|------|
| Agents (markdown) | YAML frontmatter -> `AgentDefinition` model | `lib/agent_loader.py:load_agent()` |
| Agents (custom) | YAML/JSON/md -> `AgentConfig` -> SDK format dict | `core/agents.py:agents_to_sdk_format()` |
| Skills | Markdown -> `SkillInfo` -> runtime plugin directory structure | `core/skills.py:generate_runtime_plugin()` |
| MCP servers | JSON -> env var substitution -> validation | `lib/mcp_loader.py:load_mcp_servers()` |

### Filtering

Two-stage filtering applied in `core/orchestrator.py:run_streaming()` (lines 573-600):

1. **Trust-level filter** (`capability_filter.py:filter_by_trust_level()`): MCPs with `trust_level` annotation are only available at matching trust levels.

2. **Workspace capability filter** (`capability_filter.py:filter_capabilities()`): Applies the workspace's `WorkspaceCapabilities` config -- `"all"`, `"none"`, or an explicit name list for each of MCPs, skills, and agents.

### SDK Injection

The orchestrator passes filtered capabilities to `query_streaming()`:

- `mcp_servers=resolved_mcps` -- MCP server configs (dict)
- `plugin_dirs=plugin_dirs` -- Skills are packaged as runtime plugins (list of Paths)
- `agents=agents_dict` -- Custom agents in SDK format (dict)

For Docker sandbox sessions, capabilities are serialized as JSON and mounted into the container via `AgentSandboxConfig` (see `core/sandbox.py`).

## What Exists vs What Needs Building

### Already Exists (Server)

| Feature | Endpoint | Notes |
|---------|----------|-------|
| List MCP servers | `GET /api/mcps` | Full CRUD + test |
| Add/remove MCP | `POST/DELETE /api/mcps` | Works |
| List skills | `GET /api/skills` | Read + create + delete |
| Upload skill | `POST /api/skills/upload` | ZIP upload |
| List workspaces | `GET /api/workspaces` | Full CRUD |
| Workspace capabilities model | `WorkspaceCapabilities` | mcps/skills/agents: "all"/"none"/[list] |
| Capability filtering | `capability_filter.py` | Trust + workspace filtering |

### Missing (Server)

| Feature | Notes |
|---------|-------|
| **List agents API** | No endpoint. Both `agent_loader.py` and `core/agents.py` have discovery but no API route. |
| **Unified capabilities summary** | No single endpoint that returns all available agents + skills + MCPs together (for workspace config UI). |

### Already Exists (App)

| Feature | Location | Notes |
|---------|----------|-------|
| Agent picker (hardcoded) | `new_chat_sheet.dart` | Static list of 2 agents |
| Agent badge display | `chat_screen.dart` | Shows agent name in AppBar |
| Workspace selector | `new_chat_sheet.dart`, `chat_screen.dart` | Chip-based selector |
| Workspace model | `models/workspace.dart` | Has `WorkspaceCapabilities` with mcps/skills/agents |

### Missing (App)

| Feature | Notes |
|---------|-------|
| **Dynamic agent picker** | Fetch agents from server instead of hardcoded list |
| **Skills browser** | View available skills, their descriptions, invoke/manage |
| **MCP servers browser** | View configured MCPs, test connectivity, add/remove |
| **Workspace capability editor** | UI to configure which agents/skills/MCPs are allowed per workspace |
| **Capability indicators** | Show what capabilities are active in current session |

## Technical Approach

### Architecture

```
Before:
  App → hardcoded agent list
  App → no skill/MCP visibility
  Workspace → capabilities stored but not configurable via UI

After:
  App → GET /api/agents → dynamic agent picker
  App → GET /api/skills → skills browser
  App → GET /api/mcps → MCP browser (existing)
  App → GET /api/capabilities → unified summary for workspace editor
  Workspace edit → PUT /api/workspaces/{slug} with capabilities
```

### Implementation Phases

#### Phase 1: Server -- Agent List API & Capabilities Summary

- [x] Create `parachute/api/agents.py` with a router for agent management
  - `GET /api/agents` -- list all available agents (merge both sources)
    - Discover from `vault/agents/*.md` via `load_all_agents()`
    - Discover from `vault/.parachute/agents/` via `discover_agents()`
    - Return unified list with: `name`, `description`, `type`, `model`, `tools`, `path`, `source` ("vault_agents" or "custom_agents")
  - `GET /api/agents/{name}` -- get single agent details including system prompt preview (truncated)
- [x] Register the agents router in `parachute/api/__init__.py`
  ```python
  from parachute.api import agents
  api_router.include_router(agents.router, tags=["agents"])
  ```
- [x] Create `GET /api/capabilities` -- unified summary endpoint
  - Returns all three lists in one call:
    ```json
    {
      "agents": [{"name": "...", "description": "...", "source": "..."}],
      "skills": [{"name": "...", "description": "...", "version": "..."}],
      "mcps": [{"name": "...", "type": "stdio|http", "builtin": true}]
    }
  ```
  - This is a read-only convenience endpoint for the workspace capability editor
  - Calls `load_all_agents()`, `discover_agents()`, `discover_skills()`, and `load_mcp_servers()` internally
  - Could live in `agents.py` or a new `capabilities.py`; since it aggregates across types, a separate file `parachute/api/capabilities.py` is cleaner

#### Phase 2: App -- Dynamic Agent Picker

- [x] Create `AgentService` in `app/lib/features/chat/services/agent_service.dart`
  - `fetchAgents()` -> calls `GET /api/agents`
  - Returns `List<AgentInfo>` with name, description, type, model, path, source
- [x] Create `AgentInfo` model in `app/lib/features/chat/models/agent_info.dart`
  ```dart
  class AgentInfo {
    final String name;
    final String? description;
    final String type; // chatbot, doc, standalone
    final String? model;
    final String path; // for agent_path param
    final String source; // vault_agents, custom_agents
  }
  ```
- [x] Create `agentsProvider` in `app/lib/features/chat/providers/agent_providers.dart`
  - `FutureProvider.autoDispose` that fetches from `AgentService`
  - Returns `List<AgentInfo>`
- [x] Replace hardcoded `_availableAgents` in `new_chat_sheet.dart`
  - Watch `agentsProvider` to build agent chips dynamically
  - Show loading shimmer while fetching
  - Fallback to "Default" agent if fetch fails
  - Prepend a synthetic "Default" entry (null path = vault-agent)
  - Show agent's `description`, `model`, and `source` badge in the chip
- [x] Update `chat_screen.dart` empty state agent selector to use dynamic list (N/A: empty state has no agent selector)

#### Phase 3: App -- Capabilities Browser (Settings)

This adds browsable lists of agents, skills, and MCPs to the Settings screen.

- [x] Create `CapabilitiesScreen` in `app/lib/features/settings/screens/capabilities_screen.dart`
  - Three tabs: Agents, Skills, MCP Servers
  - Navigation: Settings screen -> "Capabilities" row -> CapabilitiesScreen
- [x] **Agents tab**
  - List all agents from `agentsProvider`
  - Each card shows: name, description, type badge, model badge, source badge
  - Tapping opens detail view showing: full description, tools list, permissions, constraints
  - No create/edit (agents are markdown files in the vault -- edit via Chat or file manager)
- [x] **Skills tab**
  - List all skills from new `skillsProvider` (calls `GET /api/skills`)
  - Each card shows: name, description, version, allowed tools
  - Tapping opens detail with full content preview
  - "Create Skill" FAB opens a sheet: name, description, content (markdown editor)
  - Swipe-to-delete with confirmation
  - Upload `.skill` ZIP file option
- [x] **MCP Servers tab**
  - List all MCPs from new `mcpServersProvider` (calls `GET /api/mcps`)
  - Each card shows: name, type badge (stdio/http), builtin badge, display command
  - "Test" button per server (calls `POST /api/mcps/{name}/test`)
  - Status indicator (ok/error/untested)
  - "Add MCP" FAB for stdio (command + args) or http (url + auth)
  - Swipe-to-delete for non-builtin servers
- [x] Create service classes:
  - Service methods added to `ChatSessionService` extension (follows existing pattern)
- [x] Create providers:
  - `skillsProvider` -- `FutureProvider.autoDispose`
  - `mcpServersProvider` -- `FutureProvider.autoDispose`
- [x] Create models:
  - `SkillInfo` in `app/lib/features/chat/models/skill_info.dart`
  - `McpServerInfo` in `app/lib/features/chat/models/mcp_server_info.dart`
- [x] Add "Capabilities" entry to `SettingsScreen`
  - Icon: `Icons.extension_outlined`
  - Subtitle: "Agents, Skills & MCP Servers"
  - Navigates to `CapabilitiesScreen`

#### Phase 4: App -- Workspace Capability Editor

- [x] Add "Capabilities" section to workspace create/edit UI
  - Lives in the workspace detail screen (or create workspace sheet)
  - Three sections: Agents, Skills, MCP Servers
  - Each section has a toggle: "All" / "None" / "Custom"
    - "All" -> `capabilities.agents = "all"` (default)
    - "None" -> `capabilities.agents = "none"`
    - "Custom" -> shows checkboxes from the capabilities list, yields a list of names
- [x] Fetch available capabilities via existing providers (agents, skills, MCPs)
  - Reuses existing `agentsProvider`, `skillsProvider`, `mcpServersProvider`
- [x] Create `CapabilitySelector` reusable widget (`CapabilitiesEditor` + `_CapabilitySection`)
  - Toggle button group: All | None | Custom via `SegmentedButton`
  - When "Custom" is selected, show checkable list of items
- [x] Wire up workspace create/edit to include capabilities in `PUT /api/workspaces/{slug}`
  - Edit dialog passes `_capabilities.toJson()` in the updates map
  - Create dialog passes `capabilities:` parameter
- [x] `WorkspaceService` already supports capabilities in create (existing) and update (raw map)

#### Phase 5: Session Capability Indicators

- [x] Add capability summary to the `PromptMetadataEvent`
  - The server already sends `available_agents` in prompt metadata
  - Add `available_skills: list[str]` and `available_mcps: list[str]` to `PromptMetadataEvent`
  - Populate from the filtered capabilities in `orchestrator.py`
- [x] Update `PromptMetadata` model in the Flutter app to include skills and MCPs
- [x] Add capability indicator to session settings (`UnifiedSessionSettings`)
  - New "Active Capabilities" section showing:
    - Agents: count or list
    - Skills: count or list
    - MCPs: count or list with status badges
  - Tappable to expand and see the full list with descriptions
- [ ] Show capability badge in chat AppBar when workspace has custom restrictions
  - Small icon (e.g., `Icons.tune`) next to workspace name
  - Tooltip: "3 MCPs, 2 skills, all agents"

#### Phase 6: Docker Sandbox Capability Propagation

The sandbox already handles MCP servers and agents. Ensure skills and plugins also work correctly.

- [x] Verify skills plugin directory is mounted into Docker containers
  - `AgentSandboxConfig` already has `plugin_dirs` but these are not populated from the skills plugin in the orchestrator for sandbox sessions
  - In `orchestrator.py`, the sandbox path (line 688) creates `AgentSandboxConfig` without `plugin_dirs`
  - Fix: pass `plugin_dirs=plugin_dirs` to `AgentSandboxConfig` in the sandbox branch
  - The `DockerSandbox._build_docker_cmd()` already mounts plugin dirs as read-only volumes
- [x] Verify `.skills/` directory is mounted into Docker containers
  - Skills are copied to `vault/.parachute/runtime/skills-plugin/` by `generate_runtime_plugin()`
  - This directory needs to be within the vault mount or mounted separately
  - Since `vault/.parachute/` is under the vault, it should already be accessible
  - Verify by checking the Docker `-v` mount commands in `sandbox.py`
- [x] Verify custom agents dict is passed to sandbox
  - `AgentSandboxConfig.agents` field exists but is not populated in the orchestrator sandbox branch
  - Fix: pass `agents=agents_dict` to `AgentSandboxConfig`
- [ ] Add integration test: sandbox session with a custom skill and custom agent
  - Verify both are available inside the container

## API Design

### `GET /api/agents`

```json
{
  "agents": [
    {
      "name": "vault-agent",
      "description": "General vault assistant",
      "type": "chatbot",
      "model": null,
      "path": null,
      "source": "builtin",
      "tools": ["Read", "Write", "Edit", "Bash", "..."]
    },
    {
      "name": "orchestrator",
      "description": "Thinking partner for your day",
      "type": "chatbot",
      "model": null,
      "path": "Daily/.agents/orchestrator.md",
      "source": "vault_agents",
      "tools": ["Read", "Bash"]
    },
    {
      "name": "reviewer",
      "description": "Reviews code for quality and best practices",
      "type": "chatbot",
      "model": "sonnet",
      "path": ".parachute/agents/reviewer.yaml",
      "source": "custom_agents",
      "tools": ["Read", "Grep", "Glob"]
    }
  ]
}
```

Notes:
- `source` distinguishes origin: `"builtin"` (vault-agent), `"vault_agents"` (from `vault/agents/`), `"custom_agents"` (from `vault/.parachute/agents/`)
- `path` is the value to pass as `agent_path` when starting a chat (null for builtin)
- The builtin vault-agent should always appear first

### `GET /api/capabilities`

```json
{
  "agents": [
    {"name": "vault-agent", "description": "General vault assistant", "source": "builtin"},
    {"name": "orchestrator", "description": "Thinking partner for your day", "source": "vault_agents"}
  ],
  "skills": [
    {"name": "creative-studio", "description": "Image generation workflow", "version": "1.0.0"},
    {"name": "code-review", "description": "Structured code review", "version": "1.0.0"}
  ],
  "mcps": [
    {"name": "parachute", "type": "stdio", "builtin": true},
    {"name": "github", "type": "stdio", "builtin": false}
  ]
}
```

Notes:
- Lightweight summary -- just names and enough info for the workspace capability selector
- Does not include full config details (command, args, system_prompt)
- Used by the workspace capability editor's checkbox lists

### Updated `PromptMetadataEvent`

Add to the existing SSE event:

```json
{
  "type": "prompt_metadata",
  "agentName": "vault-agent",
  "availableAgents": ["orchestrator", "reviewer"],
  "availableSkills": ["creative-studio", "code-review"],
  "availableMcps": ["parachute", "github"],
  "...existing fields..."
}
```

## App UI Design

### Capabilities Browser (Settings > Capabilities)

```
+------------------------------------------+
|  < Capabilities                          |
+------------------------------------------+
|  [Agents]  [Skills]  [MCP Servers]       |  <- TabBar
+------------------------------------------+
|                                          |
|  AGENTS (5)                              |
|                                          |
|  +------------------------------------+ |
|  | vault-agent              [builtin] | |
|  | General vault assistant            | |
|  +------------------------------------+ |
|  |                                    | |
|  | orchestrator          [vault_agents]| |
|  | Thinking partner for your day      | |
|  | Model: default   Type: chatbot     | |
|  +------------------------------------+ |
|  |                                    | |
|  | reviewer             [custom_agents]| |
|  | Reviews code for quality           | |
|  | Model: sonnet    Type: chatbot     | |
|  +------------------------------------+ |
|                                          |
+------------------------------------------+
```

Skills and MCP Servers tabs follow the same pattern, with add/delete actions for user-created items.

### Workspace Capability Editor

Appears as a section within the workspace create/edit UI:

```
+------------------------------------------+
|  CAPABILITIES                            |
+------------------------------------------+
|                                          |
|  MCP Servers    [All] [None] [Custom]    |
|    (all 3 servers allowed)               |
|                                          |
|  Skills         [All] [None] [Custom]    |
|    (all 2 skills allowed)                |
|                                          |
|  Agents         [All] [None] [Custom]    |
|    (all 5 agents allowed)                |
|                                          |
+------------------------------------------+
```

When "Custom" is selected:

```
+------------------------------------------+
|  MCP Servers    [All] [None] [Custom]    |
|                                          |
|  [x] parachute     (stdio, builtin)     |
|  [x] github        (stdio)              |
|  [ ] experimental  (http)               |
|                                          |
+------------------------------------------+
```

### Dynamic Agent Picker (New Chat Sheet)

Replaces the hardcoded chips with server-fetched agents:

```
+------------------------------------------+
|  Agent                                   |
|                                          |
|  [Default]  [Orchestrator]  [Reviewer]   |
|                                          |
|  (Loading shimmer if still fetching)     |
+------------------------------------------+
```

- Horizontal scrollable chip row (or Wrap) for many agents
- Each chip shows icon + name
- Long-press or info icon shows full description and model

### Session Active Capabilities

In `UnifiedSessionSettings` bottom sheet:

```
+------------------------------------------+
|  ACTIVE CAPABILITIES                     |
+------------------------------------------+
|                                          |
|  Agents:  5 available                    |
|  Skills:  2 available                    |
|  MCPs:    3 connected                    |
|                                          |
|  (tap to expand full list)               |
+------------------------------------------+
```

## Data Model Changes

### Server

No database schema changes required. All capability data is file-based:
- Agents: `vault/agents/` and `vault/.parachute/agents/`
- Skills: `vault/.skills/`
- MCP servers: `vault/.mcp.json` + built-in
- Workspace capabilities: `vault/.parachute/workspaces/{slug}/config.yaml`

New Pydantic response models needed:

```python
# In parachute/api/agents.py
class AgentListItem(BaseModel):
    name: str
    description: Optional[str] = None
    type: str = "chatbot"
    model: Optional[str] = None
    path: Optional[str] = None
    source: str  # "builtin", "vault_agents", "custom_agents"
    tools: list[str] = []

# In parachute/api/capabilities.py
class CapabilitySummary(BaseModel):
    agents: list[dict[str, Any]]
    skills: list[dict[str, Any]]
    mcps: list[dict[str, Any]]
```

### App (Flutter)

New models:

```dart
// agent_info.dart
class AgentInfo {
  final String name;
  final String? description;
  final String type;
  final String? model;
  final String? path;
  final String source;
  final List<String> tools;
}

// skill_info.dart
class SkillInfo {
  final String name;
  final String description;
  final String? content;
  final String version;
  final List<String>? allowedTools;
  final int? size;
  final String? modified;
}

// mcp_server_info.dart
class McpServerInfo {
  final String name;
  final String displayType;
  final String displayCommand;
  final bool builtin;
  final List<String>? validationErrors;
}
```

## Testing Strategy

### Server Tests

- [ ] Test `GET /api/agents` returns agents from both sources
- [ ] Test `GET /api/agents` with empty directories returns just builtin vault-agent
- [ ] Test `GET /api/capabilities` returns all three types
- [ ] Test workspace capability filtering in orchestrator with custom agent/skill/MCP lists
- [ ] Test sandbox session receives filtered capabilities (plugin_dirs, agents_dict)

### App Tests

- [ ] Unit test: `AgentInfo.fromJson()` parses server response correctly
- [ ] Widget test: dynamic agent picker shows fetched agents
- [ ] Widget test: capability selector toggles between All/None/Custom
- [ ] Widget test: workspace editor saves capabilities
- [ ] Integration test: new chat with custom agent via dynamic picker

## Risk Analysis

### Low Risk
- New `GET /api/agents` endpoint -- read-only, similar pattern to existing skills/mcps
- Dynamic agent picker -- replaces hardcoded data with API data, fallback to "Default"
- Capability indicators -- display-only, no behavior change

### Medium Risk
- Workspace capability editor -- writes to workspace YAML, existing save logic must handle capabilities correctly
  - Mitigation: `WorkspaceUpdate` model already accepts capabilities, just need UI
- Skills plugin dir not mounted in sandbox -- may need orchestrator fix
  - Mitigation: verify with manual Docker test before implementing

### Low Priority / Future Work
- Full skill editor with syntax highlighting (just a textarea is fine for now)
- MCP server tool discovery (`GET /api/mcps/{name}/tools` returns empty list currently)
- Agent creation wizard (agents are markdown files -- create via Chat or file manager)
- Skill marketplace / sharing (out of scope for this iteration)

## Migration & Backwards Compatibility

No breaking changes:
- All new endpoints are additive
- The hardcoded agent list can be kept as a fallback while the dynamic list loads
- Workspace capabilities default to `"all"` so existing workspaces are unaffected
- The `PromptMetadataEvent` additions are new optional fields
