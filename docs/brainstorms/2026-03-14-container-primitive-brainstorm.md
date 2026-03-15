---
date: 2026-03-14
topic: container-primitive
**Issue:** #264
---

# Container as Core Primitive

## What We're Building

Rename `Project` → `Container` and make every sandboxed execution environment a first-class node in the graph from the moment it's created. Today, containers exist in Docker but are only tracked in the graph when a user explicitly creates a "Project." This creates an artificial gap — the environment is already there, we're just not acknowledging it.

The change makes Container a core primitive alongside Chat, Exchange, Caller, Card, and Note. Every sandboxed chat gets a Container node. Naming a container is a promotion act that makes it findable, reusable, and selectable — not a separate creation step.

## Context

This emerged from work surfacing HTTP MCPs (like BrowserOS) into sandboxed sessions. After getting BrowserOS working in sandboxes, Suno MCP was installed directly inside a sandbox container — proving that containers naturally accumulate capabilities. But that container was trapped in a single chat session with no way to reuse it, name it, or route other chats/callers into it.

The existing `Project` model was already renamed once (from `Parachute_ContainerEnv` → `Project` in issue #196). But "Project" implies something heavier than what this is. A Container is literally what exists — a Docker environment with files, tools, and state. "Project" can become a higher-level concept later that connects to a Container but adds organizational structure.

## Why This Approach

**Container as the primitive, not Project.** The graph should reflect reality. Every sandboxed chat already has a Docker container. Tracking it as a node makes the system honest about what exists and enables connections (which Chats ran here, which Callers use this, what tools are installed).

**Naming as promotion.** A Container with `display_name = null` is ephemeral and mostly invisible. Setting a display name is the organic act that promotes it — "this is my music studio." No separate creation flow needed. The container was already there from the first chat.

**Scoping boundary.** Container becomes an adjustable visibility boundary. Today any chat can query the full graph. Eventually the parachute MCP could scope queries to "only chats in this container." How tight the circle is can vary, but the boundary exists as a concept.

**Single concept, graduated visibility.** Named containers surface in the UI for selection (new chats, caller routing). Unnamed containers are queryable but don't clutter the primary UI. One model, one table, one API — no join between "Project" and "Container."

### Alternatives Considered

**Container wraps Project (layered):** Keep Project as a separate concept, add Container underneath. Project = organizational intent, Container = execution environment. Rejected — adds a join and two concepts that are almost the same thing. Premature abstraction.

**Shadow + Promote (incremental):** Keep Project as-is, add Container as a separate graph node, link them on promotion. Less churn but creates two nearly-identical entities that eventually need merging. Defers the right design without reducing complexity.

## Key Decisions

1. **Rename Project → Container** across the full stack (model, API, graph table, Flutter). Since Project isn't really in active use yet, there's no migration concern.

2. **Every sandboxed chat creates a Container node** in the graph from the start. The auto-generated slug and "Session {id}" display name pattern already exists — we just make it a real tracked entity rather than an invisible record.

3. **Naming a container is the promotion act.** Setting `display_name` to something meaningful (vs the auto-generated "Session abc123") is what makes it surface in selection UIs and become reusable.

4. **Three integration gaps to close:**
   - **Container promotion UI:** From within a chat, name/rename the container you're in. Turns an ephemeral environment into a reusable one.
   - **Container selection UI:** When starting a new chat, pick which named container to run in (or create a fresh unnamed one).
   - **Caller → Container routing:** Callers can target a named container instead of always getting their own `caller-{name}` container. Enables a caller to run in an environment that has specific tools installed.

5. **Container is a graph hub node.** Chats connect to it (ran here), Callers connect to it (runs here), and eventually MCPs/tools could connect to it (installed here). The node is relational, not just a record.

6. **Future: Project as a higher-level concept.** Project could return later as something that connects to a Container but adds more — planning, goals, team membership. But right now we're working at the primitives layer, and Container is the right primitive.

## Open Questions

- **Container listing in the app:** How should unnamed containers appear? Probably a secondary/collapsed section below named ones. Or maybe they only appear in a "recent environments" view, not the main container list.

- **Container cleanup policy:** Today, private containers are deleted when their session is deleted. With containers as tracked graph nodes, do we want a different lifecycle? Maybe unnamed containers auto-archive after N days of inactivity, but named ones persist indefinitely.

- **Caller container flexibility:** Should callers be able to share a container with chat sessions? E.g., a "music-scout" caller running in the "music-studio" container alongside interactive chats. The plumbing supports it (just set `project_slug` to the named container), but there might be concurrency considerations.

- **MCP scoping per container:** The current implementation surfaces HTTP MCPs globally (all sandboxed sessions get the same set based on `trust_level`). Eventually, containers might specify which MCPs they want. This connects to the `enabled_mcps` field discussed in the MCP surfacing work but isn't needed yet.

## Scope

### In Scope
- Rename Project → Container (model, API, graph, Flutter)
- Track all sandboxed containers as graph nodes from creation
- Container promotion (naming) from within a chat
- Container selection when starting a new chat
- Caller → named container routing

### Out of Scope (Future)
- Per-container MCP configuration
- Container-scoped graph queries (parachute MCP only shows chats in same container)
- Project as a higher-level concept connecting to Container
- Note/Card containment within containers
- Container sharing across users (multi-tenant)
