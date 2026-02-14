---
topic: Multi-track improvements — UI polish, Docker model, workspace trust, agent/skill/MCP strategy
date: 2026-02-09
status: decided
---

# Multi-Track Improvements Brainstorm

Three parallel improvement tracks identified from a single conversation. Each should become its own plan.

---

## Track 1: UI Polish & Overflow Audit

### What We're Building

Focused fix pass on known overflow and responsive rendering issues, plus preventive patterns to stop future occurrences.

### Known Problem Areas

- **New chat sheet**: Rendering looks off at certain screen widths (likely the workspace/trust selectors wrapping poorly at tablet breakpoints)
- **Workspace dialog**: Working directory field is a plain TextField — should be a folder picker that browses vault subdirectories
- **Session config sheet**: Potential overflow in trust/workspace chips at narrow widths
- **General**: Scattered overflow bugs where `Row` children don't have `Expanded`/`Flexible`

### Key Decisions

- **Scope**: Fix known issues + establish preventive patterns (not a full app audit)
- **Directory picker**: Replace TextField with a vault folder browser (list subdirectories from the server, let user tap to select). Needs a new API endpoint: `GET /api/vault/directories?path=Projects` returning subdirectory names.
- **Preventive**: Document overflow patterns in app CLAUDE.md — when to use `Wrap` vs `Row`, when `TextOverflow.ellipsis` is needed, responsive breakpoint guidance

### Open Questions

- Should the directory picker also allow creating new folders?
- Do we need a dedicated responsive testing pass at 600px and 1200px breakpoints?

---

## Track 2: Workspace Trust & Docker Model

### What We're Building

Two related changes:

1. **Workspace trust level becomes a default, not a floor.** Workspaces set the default trust level for new sessions, but any session can override to trusted or untrusted. This reflects reality — most workspaces will have both trusted and untrusted sessions.

2. **Persistent Docker containers per workspace.** Instead of a fresh container per session that's destroyed after, each workspace with untrusted sessions gets a persistent container that auto-stops after idle time.

### Current Behavior (Problems)

- **Trust floor**: Workspace trust level acts as a minimum — if workspace is "untrusted", you can't create trusted sessions in it. This is too rigid; a "Projects" workspace naturally has both.
- **Fresh containers**: Each untrusted session gets a brand new Docker container. Container is destroyed after (`--rm`). Transcripts are lost (synthetic JSONL saved to host). No shared state between sessions in the same workspace.
- **No reuse**: Two untrusted sessions in the same workspace each spin up independent containers with independent volume mounts. There's no shared workspace filesystem context.

### Key Decisions

- **Trust default, not floor**: Workspace `trust_level` becomes `default_trust_level`. New sessions inherit it, but can change to either value. UI shows it as "Default" not as a constraint.
- **Persistent containers**: One container per workspace for untrusted sessions. Named `parachute-ws-{workspace_slug}`. Multiple sessions share the same container.
- **Auto-stop after idle**: Container stops after 15 minutes of no activity. Restarts on next message (small startup delay acceptable). Expected 4-10 workspaces, so resource management matters.
- **Shared volume**: Workspace's working directory is mounted RW. Multiple sessions see the same filesystem state. This is the key value — an agent in one session can see files created by another session in the same workspace.
- **Container lifecycle managed by server**: Server tracks running containers via `docker ps`. On message to untrusted session, check if workspace container is running → start if needed → exec into it.

### Architecture Implications

- `sandbox.py` changes from "run container per message" to "manage container pool keyed by workspace"
- Need a `ContainerManager` or similar that tracks workspace → container mapping
- `docker run --rm` replaced with `docker run -d` (detached) + `docker exec` for messages
- Idle detection: background task that checks `docker inspect` for last activity, stops idle containers
- Transcript handling changes: container persists, so SDK transcripts survive between messages (no more synthetic JSONL)

### Open Questions

- Should the idle timeout be configurable per workspace?
- What happens when a workspace is deleted — force-stop its container?
- How do we handle container crashes/restarts gracefully?
- Should trusted sessions in a workspace also be able to "attach" to the container for debugging?

---

## Track 3: Agent, Skill, Plugin & MCP Strategy

### What We're Building

A clear user-facing model for how agents, skills, plugins, and MCP servers work in Parachute, preserving the SDK's native concepts.

### Current State

The discovery and loading pipeline exists but is mostly invisible to users:

- **Agents**: Markdown files in `vault/agents/` or `vault/.parachute/agents/` with YAML frontmatter. Discovered by `agent_loader.py` and `core/agents.py`.
- **Skills**: Directories or `.md` files in `vault/.skills/`. Converted to a runtime plugin at `.parachute/runtime/skills-plugin/`. Passed to SDK via `--plugin-dir`.
- **MCP Servers**: Configured in `vault/.mcp.json`. Loaded by `mcp_loader.py`. API at `/api/mcps` for CRUD.
- **Plugins**: Arbitrary directories mounted into Docker containers. Less defined than the others.
- **Modules**: Server-side only (brain, chat, daily). Hash-verified, approved via CLI.

### Key Decisions

- **Show SDK concepts directly**: Users see agents, skills, MCPs as separate things matching the Claude ecosystem. No "unified capabilities" abstraction — that would hide important distinctions.
- **Per-workspace configuration**: Workspaces should be able to specify which agents, skills, and MCPs are available. This is partially implemented via `filter_by_trust_level()` and agent permissions, but needs a workspace-level config.
- **Discovery UX needed**: Users currently have no way to browse available agents/skills/MCPs from the app. Need UI for:
  - Listing available agents with descriptions
  - Listing configured MCP servers with status
  - Listing available skills
  - Per-workspace: toggling which are enabled
- **Plugin vs Skill distinction**: Skills are Claude SDK skills (markdown + optional tools). Plugins are broader (arbitrary code directories). For now, focus on skills and MCPs — plugins are an implementation detail of how skills get mounted in Docker.

### Architecture Assessment

The current pipeline is solid for discovery and loading. What's missing:

1. **App-side visibility**: No UI to see or manage agents/skills/MCPs
2. **Workspace-level filtering**: Workspaces can't specify "this workspace uses agent X and MCP Y"
3. **Agent selection UX**: The new chat sheet has an agent picker but it's basic — needs better descriptions, categories
4. **MCP management**: API exists (`/api/mcps`) but app has no UI for it
5. **Skill management**: No UI at all — purely filesystem-based

### Open Questions

- Should workspace capability configuration be in the workspace dialog or a separate "capabilities" screen?
- How do we handle MCP servers that require authentication or setup?
- Should agents be creatable from the app UI, or is filesystem-only fine?
- How does capability filtering interact with the new persistent container model? (Container needs to be reconfigured when workspace capabilities change)

---

## Recommended Plan Split

These should become 3 separate plans:

| Plan | Scope | Effort |
|------|-------|--------|
| **UI polish & overflow** | Fix known issues, directory picker, preventive patterns | Small — 1 session |
| **Workspace trust + Docker model** | Trust default change, persistent containers, idle management | Large — multiple sessions |
| **Agent/skill/MCP UX** | App UI for browsing and configuring capabilities per workspace | Medium — 2-3 sessions |

**Suggested order**: UI polish first (quick wins, fixes visible bugs), then workspace trust + Docker (foundational change), then agent/skill/MCP UX (builds on workspace model).
