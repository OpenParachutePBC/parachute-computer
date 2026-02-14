# Capabilities System Redesign

**Date**: 2026-02-09
**Status**: Brainstorm

---

## What We're Building

A redesigned capability management system for Parachute that:

1. **Uses standard formats** — Claude Code plugin format (`.claude-plugin/plugin.json`, `SKILL.md`, `.mcp.json`, agent `.md` files with YAML frontmatter) so any existing plugin/agent/skill works without modification
2. **Takes explicit control** — Parachute server constructs all SDK parameters explicitly rather than relying on `setting_sources=["project"]` auto-discovery, giving fine-grained control over what the agent sees
3. **Multiple install paths** — GitHub URL install, marketplace browsing, and conversational agent-driven creation/discovery
4. **Rich management UI** — Detailed capability views with configuration, testing, and per-workspace scoping
5. **Works in sandbox** — All capabilities function in both trusted (direct SDK) and untrusted (Docker sandbox) execution paths

---

## Why This Approach

### Problem: Current System is Fragile and Opaque

The current setup has several issues:

- **SDK auto-discovery is a black box**: Using `setting_sources=["project"]` means the SDK reads CLAUDE.md files, `.mcp.json`, and other configs from the working directory hierarchy. Parachute can't fully control or predict what the SDK will find.
- **Plugins don't work**: The plugin_dirs parameter isn't reliably supported across SDK versions. Skills are converted to runtime plugins but this is brittle.
- **The UI is placeholder-quality**: Add dialogs are basic forms. Cards show minimal info. No way to discover new capabilities.
- **No install story**: No way to install a plugin from a GitHub URL. No marketplace browsing. Only manual file creation.

### Solution: Explicit Construction + Rich UI

**Server-side**: Parachute becomes the single source of truth for what capabilities exist. It discovers them from known locations (vault, installed plugins, user-created), filters them per workspace/trust-level, and explicitly passes them to the SDK. No reliance on SDK's own discovery.

**Client-side**: The Flutter app provides a rich browsing/management experience with multiple install paths and detailed capability views.

### Why Not Build Our Own Runtime?

The Claude Agent SDK handles the hard parts: tool execution, MCP server lifecycle, streaming, error recovery. Building a custom runtime would be a massive undertaking for marginal benefit. The better approach is to use the SDK but control exactly what goes in — think of it as "headless SDK" where Parachute is the brain and the SDK is the execution engine.

---

## Key Decisions

### 1. Plugin as the Primary Package Unit

**Decision**: Adopt the Claude Code plugin format as the primary way to package and distribute capabilities. Standalone agents, skills, and MCPs are still supported but are treated as "single-capability plugins" internally.

**Rationale**: The plugin format is becoming a standard. The compound-engineering plugin demonstrates the pattern — it bundles skills, agents, hooks, and MCP configs in one distributable unit. By making plugins first-class, Parachute gets automatic compatibility with the growing Claude Code plugin ecosystem.

**What this means in practice**:
- Plugins live in `{vault}/.parachute/plugins/{slug}/` (Parachute-managed)
- Each plugin has the standard `.claude-plugin/plugin.json` manifest
- Plugin contents (skills, agents, MCPs, hooks) are discovered and indexed by the server
- Standalone capabilities (a single agent .md, a single skill .md, or an MCP config) are also supported — they just don't live in a plugin directory

### 2. Explicit SDK Parameter Construction

**Decision**: Stop using `setting_sources=["project"]` and instead explicitly construct all SDK parameters.

**What Parachute controls explicitly**:
- `system_prompt` / `system_prompt_append` — Parachute builds the full prompt from agent definition + vault CLAUDE.md + workspace context
- `tools` — Parachute passes the exact tool list from the agent definition
- `mcp_servers` — Parachute loads, validates, and passes MCP configs (not SDK auto-discovery from .mcp.json)
- `agents` — Parachute converts agent definitions to SDK format
- Skills — Parachute generates the runtime plugin directory and passes via `plugin_dirs`
- `model` — Already explicit
- `cwd` — Already explicit

**What we stop relying on**:
- SDK reading `.mcp.json` from cwd hierarchy
- SDK reading CLAUDE.md from cwd hierarchy (we pass the content ourselves)
- SDK discovering plugins from `~/.claude/plugins/`
- Any implicit SDK behavior

**Benefits**:
- Predictable behavior — Parachute knows exactly what the agent has access to
- Workspace isolation — Different workspaces can have completely different capability sets
- Trust-level enforcement — Capabilities are filtered before reaching the SDK
- Debuggability — Server logs show exactly what was passed

### 3. Three Install Paths

**a) GitHub/URL Install** (for known plugins):
- User pastes a GitHub repo URL (e.g., `https://github.com/EveryInc/compound-engineering-plugin`)
- Server clones the repo into `{vault}/.parachute/plugins/{slug}/`
- Server validates plugin structure (looks for `.claude-plugin/plugin.json`)
- Server indexes the plugin's contents (skills, agents, MCPs)
- Plugin appears in the UI as installed

**b) Marketplace Browsing** (for discovery):
- Server can fetch plugin catalogs from registered marketplace URLs (GitHub repos with an index.json, or dedicated registries)
- The Flutter UI renders a browsable, searchable catalog
- "Install" button triggers the GitHub/URL install flow
- Start with Claude's official marketplace + allow adding community marketplaces

**c) Agent-Driven Creation** (for custom capabilities):
- User tells the agent "I need a skill that reviews database schemas"
- Agent creates the skill file in `{vault}/.skills/` or as part of a workspace-specific plugin
- Agent can also configure MCP servers conversationally (writes to the vault's MCP config)
- This is the Craft Agents model — the agent is a configuration tool

### 4. Layered UI Architecture

**Decision**: The UI has two layers:

**Layer 1 — Capability Browser (Settings > Capabilities)**
- Shows ALL installed capabilities across all types
- Can filter by type (agent, skill, MCP, plugin)
- Each capability card shows rich detail: description, source plugin, tools provided, which workspaces use it, connection status (for MCPs)
- Click-through to detail/edit view
- Install button → opens install sheet (URL, marketplace, or create)

**Layer 2 — Workspace Capability Picker (in workspace settings)**
- Shows capabilities available for THIS workspace
- Simple enable/disable toggles
- "All / None / Custom" quick-set preserved from current design
- Inline checkboxes for sparse lists preserved

### 5. Capability Detail View

Each capability type gets a detail view (not just a card):

**Agent detail**: Name, description, model, tools list, MCP access, permissions, full prompt preview (collapsible), source (builtin/vault/plugin), edit button for custom agents

**Skill detail**: Name, description, version, allowed tools, full content preview, source plugin, edit button for custom skills

**MCP detail**: Name, type (stdio/HTTP), command/URL, connection status with test button, tools provided (fetched dynamically), guide text (like Craft's guide.md), source (builtin/vault/plugin)

**Plugin detail**: Name, version, author, description, contents list (X agents, Y skills, Z MCPs), install source (GitHub URL), update available indicator, uninstall button

---

## Architecture: How It All Fits Together

### Discovery Flow

```
Vault Filesystem                    Server Discovery              SDK Parameters
─────────────────                   ──────────────────            ──────────────
{vault}/.parachute/plugins/    ──→  Plugin indexer           ──→  plugin_dirs
{vault}/.parachute/agents/     ──→  Agent loader             ──→  agents dict
{vault}/agents/                ──→  Agent loader (vault)     ──→  agents dict
{vault}/.skills/               ──→  Skill discoverer         ──→  runtime plugin → plugin_dirs
{vault}/.mcp.json              ──→  MCP loader               ──→  mcp_servers dict
{vault}/CLAUDE.md              ──→  Prompt builder           ──→  system_prompt_append
Plugin internal .mcp.json      ──→  MCP loader (per-plugin)  ──→  mcp_servers dict
Plugin internal agents/        ──→  Agent loader (per-plugin) ──→  agents dict
Plugin internal skills/        ──→  Skill discoverer         ──→  runtime plugin → plugin_dirs
```

### Filtering Pipeline

```
All Discovered Capabilities
         │
         ▼
   Trust-Level Filter (Stage 1)
   - MCPs annotated with trust_level
   - Untrusted sessions lose trusted-only MCPs
         │
         ▼
   Workspace Filter (Stage 2)
   - Per-workspace capability sets (all/none/[list])
   - Applied to agents, skills, MCPs, plugins independently
         │
         ▼
   Agent Filter (Stage 3)
   - Agent definition's mcpServers, tools constraints
   - Agent may restrict to subset of workspace capabilities
         │
         ▼
   Explicit SDK Parameters
   - tools, mcp_servers, agents, plugin_dirs, system_prompt
   - Fully constructed by Parachute, no SDK auto-discovery
```

### Sandbox Path

For untrusted Docker sessions, the same filtering applies. The sandbox receives:
- `PARACHUTE_MODEL` env var (already implemented)
- `PARACHUTE_CWD` env var (already implemented, with /vault/ prefix fix)
- Capabilities JSON mounted at `/tmp/capabilities.json` (already implemented)
- Volume mounts for allowed paths (already implemented)
- Plugin directories mounted read-only at `/plugins/plugin-{i}` (already implemented)

The entrypoint reads these and passes them to the SDK inside the container. Since we're moving to explicit construction, the entrypoint should also stop using any auto-discovery.

---

## Open Questions

### Q1: Plugin Update Mechanism
How do we handle plugin updates? Options:
- **Git pull**: Since plugins are cloned from GitHub, `git pull` in the plugin directory
- **Version check**: Compare local version with remote, prompt user to update
- **Auto-update**: Like Claude Code's marketplace auto-update
- *Recommendation*: Start with manual "check for updates" button, add auto-update later

### Q2: MCP Server Lifecycle
Currently MCP servers are spawned by the SDK. With explicit construction, should Parachute manage MCP server processes itself?
- **SDK-managed** (current): Pass configs to SDK, it starts/stops servers
- **Parachute-managed**: Server starts MCP processes, manages lifecycle, passes already-running server handles to SDK
- *Recommendation*: Keep SDK-managed for now. Parachute-managed would be needed for shared MCP servers across sessions, but that's a future optimization.

### Q3: Agent-Writable Config
Should the AI agent be able to modify capability configs during a session (like Craft Agents)?
- If yes: Agent gets tools to create/modify skills, configure MCPs, install plugins
- If no: Agent can only suggest changes, user acts through UI
- *Recommendation*: Yes, but only for the vault's own capabilities (not system-level). Add "configure-capabilities" as a gated tool that requires user approval.

### Q4: Skill Invocation Mechanism
Currently skills are loaded via the runtime plugin → SDK's Skill tool. With explicit construction:
- Keep the runtime plugin approach (it works, SDK expects it)
- Or inject skill content directly into the system prompt
- *Recommendation*: Keep runtime plugin approach — it's the standard and the SDK handles invocation correctly.

### Q5: HTTP MCP Support
The SDK only supports stdio MCPs natively. HTTP/SSE MCPs are filtered out currently.
- Add a proxy layer that bridges HTTP MCPs to stdio for the SDK?
- Wait for SDK to add native HTTP MCP support?
- *Recommendation*: Wait for SDK support. HTTP MCPs are less common and the proxy adds complexity.

---

## What's NOT in Scope

- **Custom agent runtime** — We're using the Claude Agent SDK, not building our own
- **Visual node-based agent builder** — That's n8n/Langflow territory, not what Parachute is
- **Multi-provider LLM support** — Parachute is Claude-focused (via Claude Agent SDK)
- **Plugin authoring tools** — Users create plugins with their code editor, not in the Parachute UI
- **Hooks system redesign** — Hooks are a separate concern, not part of this brainstorm

---

## Success Criteria

1. User can install the compound-engineering plugin from its GitHub URL and have all its skills/agents available in Parachute sessions
2. User can browse a marketplace of available plugins and install with one click
3. User can tell the agent "create a skill that reviews my code style" and it creates a working skill
4. Capabilities screen shows rich detail for each installed capability
5. Workspace capability picker correctly filters what's available per workspace
6. All capabilities work in both trusted and untrusted (sandbox) sessions
7. Server logs clearly show which capabilities were passed to the SDK for each session
