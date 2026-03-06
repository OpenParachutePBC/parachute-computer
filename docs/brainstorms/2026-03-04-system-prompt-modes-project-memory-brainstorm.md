---
title: System Prompt Modes + Project Memory
date: 2026-03-04
status: brainstorm
priority: P2
labels: brainstorm, computer, app, chat
---

# System Prompt Modes + Project Memory

## What We're Building

A context-appropriate prompt system where the AI identity and tooling shift based on what the user is doing. Two explicit modes — **converse** and **cocreate** — replace the current one-size-fits-all Claude Code preset approach. Additionally, a lightweight path for `ContainerEnv` to evolve into a project with its own instructions and memory, mirroring how Claude's Projects feature works.

## Why This Approach

The Claude Code preset is great for programming but actively wrong for casual conversation — it sets a developer-brained persona that feels out of place. Most Parachute sessions aren't coding sessions. The system prompt should match the context: a thinking-partner identity (closer to Claude Desktop) by default, and a cocreation mode (covering both Cowork-style knowledge work AND coding, oriented further by the project's CLAUDE.md) when explicitly invoked. Projects are the natural home for per-context memory and instructions.

## Current State

- One prompt path: Claude Code preset always on, vault content appended via `system_prompt_append`
- `DEFAULT_VAULT_PROMPT` is the vault-agent append content (thinking partner role, vault search, tools)
- `ContainerEnv` exists as `Parachute_ContainerEnv` in graph DB — has `slug`, `display_name`, `created_at` only
- MCP `list_projects` already aliases `/container_envs` — container-as-project is conceptually in place
- `setting_sources=["project"]` causes SDK to auto-discover `vault/.claude/agents/*.md` — deprecated per user
- `prior_conversation` injection (XML-wrapped session import) — wired but de-prioritized

## Key Decisions

### 1. Mode flag: `converse` | `cocreate` (explicit, not inferred)

Add `mode` to `ChatRequest` and `SessionCreate`. Default: `converse`. Per-session, not per-message.

**Converse mode** (default):
- Full custom Parachute identity prompt — replaces preset entirely, `use_claude_code_preset=False`
- Tone: thinking partner, collaborative, direct, vault-aware
- Modeled on Claude Desktop's interaction style: prose-first, no agentic scaffolding
- Vault tools available (search sessions, journals); no file writes

**Cocreate mode** (explicit toggle):
- Covers both Cowork-style knowledge work AND coding — the project CLAUDE.md orients it further
- Claude Code preset enabled OR Parachute's own coding instructions (see transparency question)
- Minimal Parachute additions: vocabulary bridge, vault tool access, user context
- Cowork patterns borrowed: clarify before executing, TodoWrite for multi-step tasks
- Working directory + project instructions shape the specific behavior

**Why cocreate, not code**: Coding is one type of creation. Writing, designing, researching, building — all fall under cocreate. The project CLAUDE.md (or AGENTS.md) is what tells the agent it's a coding project vs. a writing project vs. a data project. The mode sets capability level; the project sets orientation.

**Granularity decision**: Start **coarse** — one system seed node per mode (`converse-default`, `cocreate-default`). Split into finer-grained nodes (persona, behavior, tool-access, vocabulary) only when there's a clear need to override a specific section independently.

### 2. Rewrite the Parachute identity (converse mode)

Modeled on Claude Desktop's published prompt structure, but adapted for Parachute's vault context:
- Prose-first, no agentic scaffolding
- Thinking partner: asks good questions, challenges assumptions, makes connections
- Vault-aware: searches past conversations and journals for personal context
- Not developer-brained — doesn't default to code when it's not needed
- Parachute identity at position zero (Claude Desktop does "The assistant is Claude, created by Anthropic" — ours does "You are Parachute, [user]'s thinking partner")

### 3. Project memory as opt-in evolution of ContainerEnv

`ContainerEnv` is already the right shape. Don't pre-add fields — let the user explicitly promote a container to a project by adding instructions.

**Evolution path:**
- `ContainerEnv` gains optional `instructions: str | None` and `memory: str | None` fields in graph
- These are `NULL` by default — a container without instructions is just a container
- When a session runs in a `container_env_id` that has `instructions`, those are injected into the assembled prompt as a "## Project Instructions" section
- Memory file would be a persistent text block the AI can read/append to across sessions (details TBD in plan)

This mirrors Claude's Projects: a project IS a named context with instructions + memory. Here, a container becomes a project when the user gives it instructions.

### 4. Scope vault agent discovery — don't drop setting_sources entirely

`setting_sources=["project"]` serves two distinct purposes:
- **Repo context** (working directory's `.claude/CLAUDE.md`, agents, commands) — should keep working. If someone opens a repo with its own Claude setup, that should load naturally. This is core Cowork behavior.
- **Vault-level agent discovery** (`vault/.claude/agents/*.md`) — this is what's deprecated.

The fix is not removing `setting_sources`, but ensuring the vault isn't being treated as a project source for agent definitions. In code mode with a working directory set, SDK discovery of that repo's `.claude/` should work exactly as expected. In converse mode without a working directory, there's nothing to discover and the setting is effectively a no-op.

### 5. Prior conversation — keep, don't prioritize

The session import feature (Claude Code, Claude Web, ChatGPT imports) still works via `prior_conversation`. No change needed — just not a focus area. The XML injection stays as-is until we have a reason to revisit.

## Graph-Native Instruction Architecture

The graph DB (LadybugDB) already stores sessions, entities, container envs. Instructions can be nodes too — making the prompt system composable, queryable, and agent-native rather than hardcoded strings in Python.

### Instructions as `Parachute_Instruction` nodes

Each node carries: `slug` (unique ID), `content` (the prompt text), `modes` (which modes it applies to), `priority` (assembly order), `scope` (`global` | `project` | `user`), `tags`.

Relationships:
- `APPLIES_TO_MODE` → links node to one or more modes
- `SCOPED_TO_PROJECT` → scopes a node to a `ContainerEnv`
- `OVERRIDES` → a project node can override a global one with the same slug
- `EXTENDS` → appends to rather than replaces

### `_build_system_prompt()` becomes a graph query

```
MATCH (i:Parachute_Instruction)
WHERE $mode IN i.modes
  AND (i.scope = 'global' OR i.project_slug = $project_slug)
RETURN i ORDER BY i.priority ASC
```

Priority ordering then assembles the sections. Project-scoped instructions shadow global ones with the same slug. The result is a dynamically assembled prompt from composable pieces — not a static string.

### What this unlocks

**Fork the Claude Code instructions**: Instead of using the opaque preset, store Parachute's own coding instructions as nodes — based on Claude Code's extracted content but modified to fit Parachute's context and vocabulary. Fully transparent, fully owned, evolvable without touching Python code.

**Mode-as-selector**: Modes (`converse`, `explore`, `code`) are just queries, not separate monolithic prompts. A node tagged `["converse", "explore"]` appears in both. A global persona node tagged `["*"]` appears in all modes. Adding a new mode is adding a new tag value, not a new code path.

**Project instructions as scoped nodes**: Instead of a flat `instructions` string on `ContainerEnv`, a project owns a set of `Parachute_Instruction` nodes. The project "inherits" all global nodes and can override or add to them. Exactly like CSS cascade — global styles, then project overrides.

**Agent-native prompt management**: The agent can read its own instruction nodes, propose additions, suggest edits based on session patterns. "I've noticed you always want examples — want me to add that to your project instructions?" The agent is making a graph write, not editing a Python file.

**App-visible and editable**: Instruction nodes are readable/writable via the graph API. The app can show the user their active instructions, let them edit nodes, see what's scoped globally vs. per-project. Full transparency — no black box.

**Ownership model — defaults + user overrides**:
- `source: "system"` nodes are seeded at server init (idempotent upsert, won't duplicate on redeploy). Content lives as constants in the server codebase — version-controlled, reviewable in PRs.
- `source: "user"` nodes are created by the user or agent. When a user node shares a slug with a system node, the assembly query prefers the user version — shadowing without deleting.
- `source: "project"` nodes are scoped to a `ContainerEnv` and layer on top of both.
- **Reset is trivial**: delete the user override node, system default re-emerges automatically. No need to remember what the default was — it's always there underneath.
- **Starting set**: `converse-default` and `cocreate-default` — two nodes. Expand when users have a reason to override a specific section independently.

## Reference: Claude Desktop and Cowork Prompts

**Claude Desktop** (publicly published by Anthropic as of Claude 4.5/4.6):
- Opens with: `"The assistant is Claude, created by Anthropic."` — third person, no agentic framing
- XML-structured sections: `<general_claude_info>`, `<behavior_instructions>`, `<tone_and_formatting>`, `<user_wellbeing>`, tool definitions (~70-80% of total length)
- 23k tokens total. Prose-first tone. Anti-sycophancy rules explicit ("never start with 'fascinating'"). One question max per response.
- Tool set: web_search, web_fetch, conversation_search, bash, file editing, artifacts (React/HTML/SVG/Mermaid/PDF)
- No skills system, no AskUserQuestion, no TodoWrite

**Claude Cowork** (leaked Jan 16 2026 — cross-validated by security researchers):
- Opens with: `"Claude is a Claude agent, built on Anthropic's Claude Agent SDK, powering Cowork mode."` — agent-first identity
- Runs in a lightweight Linux VM. Three explicit directories: `/mnt/user-data/uploads/`, `/home/claude/` (working), `/mnt/user-data/outputs/` (final deliverables)
- **Mandatory `AskUserQuestion`** before any multi-step work: "Even requests that sound simple are often underspecified. Asking upfront prevents wasted effort."
- **`TodoWrite` for virtually ALL tool-using tasks** — rendered as a visible widget to the user
- Skills system (docx, pptx, pdf, xlsx, canvas-design) — Claude reads SKILL.md before executing relevant tasks
- Sub-agent coordination for complex parallel workstreams
- Same tone/safety/copyright rules as Desktop

**Key takeaway for cocreate mode**: Cowork's interaction patterns are the model — clarify-first, TodoWrite for multi-step, skills as composable capabilities. The VM/directory structure maps naturally to Parachute's container file browser (already built). Converse mode mirrors Desktop's conversational posture.

## Research Findings (from landscape scan)

After reviewing 20+ tools — Goose, Aider, Roo Code, Cursor, Windsurf, Claude Code, Open WebUI, AnythingLLM, Letta, Mem0, Zep, Dust, Dify, Perplexity Spaces — several strong patterns emerged.

### Industry-converging patterns

**The four-tier layer cake**: Every sophisticated system separates instructions into base (code) → project (CLAUDE.md/AGENTS.md) → session (mode) → turn (dynamic injection). Parachute has base and nascent project layers. Session (modes) and turn (dynamic injection) are the gaps.

**Plan/Act boundary is universal**: Aider (`/ask`+`/code`), Roo Code (Architect+Code), Cursor (Plan+Agent), OpenCode (Plan+Build) all separate read-only research from execution. The boundary is about user trust, not just UX — when an agent reads and presents a plan, users have a checkpoint before anything changes.

**AGENTS.md as the emerging standard**: Anthropic, OpenAI, Google, Block, Cursor, Windsurf, Aider — all participating in the Linux Foundation's Agentic AI Foundation, converging on AGENTS.md. 60,000+ projects already use it. Supporting AGENTS.md alongside CLAUDE.md would make Parachute compatible with any project that already has agent instructions.

**roleDefinition at position zero**: Across every mode-aware system, the role definition goes at the very top of the system prompt. Models attend more strongly to early tokens. Strong formulation includes: name, domain of expertise, style, stakeholder, and temporal orientation — not just "you are a helpful assistant."

**Claude Code's prompt is modular, not monolithic**: ~40 runtime reminders (short, contextual injections that fire based on state) rather than one large static block. Tool descriptions are themselves major prompt contributors. The preset is community-extracted (Piebald AI repo) — it's not truly unknowable.

### Ideas beyond current thinking

**Explore mode as a third mode** (from Aider `/ask`, Roo Architect, OpenCode Plan):
A read-only middle mode — can traverse vault + brain, synthesize, analyze, but **cannot write**. Safe for "look at my notes and find patterns." Three-mode taxonomy:
- **Converse**: Pure dialogue, no tool access, thinking partner
- **Explore**: Read vault + brain, no writes, safe research
- **Code**: Full agentic, Claude Code preset, file writes

**Letta memory blocks as a better project memory model** (from MemGPT):
Instead of a flat `instructions` string on ContainerEnv, named blocks with labels, size limits, and descriptions that guide the agent when to use them. Standard blocks: `persona` (how Parachute behaves with this user), `user` (what it knows about them), `project` (current project context), `observations` (accumulated patterns). The agent can be given tools to update blocks.

**Vocabulary bridge as a mandatory prompt section**:
A section that maps Parachute-specific terms to underlying capabilities. Without it, users who say "put this in my brain" or "check my daily notes" get confused responses. Every successful domain-specific agent (Cursor's `{{CURSOR_RULES}}`, AnythingLLM's `{{char_name}}`) has explicit vocabulary bridging.

**@agent inline activation** (from AnythingLLM):
Within converse mode, `@code` spawns a code subagent inline. The conversation continues, the operation surfaces back in context. Mode-switch without full session reset.

**Source-validated prompt injection** (from Notion vulnerability):
Parachute reads user-authored content (CLAUDE.md, vault files, brain graph) and injects it into the system prompt — this is a prompt injection risk. Wrapping injected user content in clear markers (`<user-authored-content>`) prevents vault documents from overriding system behavior.

**"Instructions" not "system prompt" in UI** (from Dust):
Dust deliberately uses "instructions" rather than "system prompt" — the latter is practitioner vocabulary. For project memory UI: "Tell Parachute how to work with you on this project" not "Edit system prompt."

**Automated instruction improvement** (from Dust Tracker):
When sessions repeatedly handle a type of question poorly, surface a suggestion: "I've noticed you often ask about X — want me to add that to my instructions for this project?" Prompt engineering as continuous feedback loop, not one-time setup.

**Temporal memory** (from Zep/Graphiti):
Vault context facts have validity periods. "Working on the API redesign" (current) vs "was working on auth system" (prior). Most memory systems overwrite; temporal memory archives with timestamps and serves the most recent.

## Seed Prompt Sketches

Not full prompts — just the shape of each. Full content is implementation work.

### Converse seed (`converse-default`)

**Identity opener**: `"You are Parachute, [user_name]'s thinking partner."` — personalized, not generic, not agent-brained. The vault knows the user's name; inject it.

**Behavioral contract**:
- Prose-first, collaborative, direct
- One question at a time — pick the best one, not all of them
- Think alongside, not just for — help the user develop their own thinking
- No flattery, no filler ("Certainly!", "Great question!")
- Draw connections between what you know about their projects, interests, and past thinking

**Tools available**:
- Vault search: `search_sessions`, `list_recent_sessions`, `get_session`, `search_journals`, `get_journal`
- Web: `WebSearch`, `WebFetch`
- Nothing else — no bash, no file writes, no TodoWrite

**Explicit boundary**: "In this mode you don't write files, execute code, or manage tasks. You think, discuss, and remember. Switch to cocreate mode to build things."

**vs. Claude Desktop**: Desktop is generic; Parachute is personalized via vault. Desktop has artifacts, complex tool suite, copyright rules. Converse is simpler and more focused — it's a thinking partner, not an all-purpose assistant.

---

### Cocreate seed (`cocreate-default`)

**Identity opener**: `"You are Parachute in cocreate mode — an agentic partner for building, writing, coding, and creating."` Agent-first, task-capable, but Parachute-branded.

**Behavioral contract**:
- **Clarify before executing** multi-step tasks — "even simple-sounding requests are often underspecified" (Cowork's lesson)
- **TodoWrite for multi-step tasks** — makes progress visible, keeps work on track
- Loop in the user at natural checkpoints, especially before irreversible actions
- Follow the project's CLAUDE.md/AGENTS.md — that's what orients this session toward coding vs. writing vs. research
- Check `.skills/` when a task seems to call for one

**Tools available**: Full access — bash, file read/write, web, vault MCPs, MCP connectors, skills. Working directory and container file system accessible.

**Orientation**: Leans coding (because that's the primary use case) but stays deliberately general — project CLAUDE.md is the fine-tuning layer. A writing project's CLAUDE.md turns this into a writing agent; a code project's CLAUDE.md turns it into a coding agent.

**vs. Claude Cowork**: Cowork is file-management + knowledge work, non-technical. Cocreate covers all of that AND coding. Cowork runs in a VM with strict directory layout; cocreate has both container environments (for sandboxed work) and direct working directory access (for coding). Cowork's skills system maps to Parachute's `.skills/` directory.

**vs. current state**: Today every session gets the Claude Code preset regardless of context. Cocreate makes this explicit and opt-in, and wraps it in Parachute identity and vault context.

---

### Implementation note — first pass is minimal

The first implementation doesn't need the graph-native architecture. Just:
1. Add `mode: "converse" | "cocreate"` to `SessionCreate` and `ChatRequest` (default: `converse`)
2. In `_build_system_prompt()`: branch on mode — converse uses a new Parachute identity constant, cocreate uses current behavior (preset + append) but with updated append content
3. The two seed strings live as Python constants for now — migrate to graph nodes later when the editing/override UX is built

The graph architecture, project-scoped overrides, user customization, and app UI all come in subsequent iterations.

## What's Intentionally Deferred

- Detailed memory format for projects (file vs graph field vs both)
- Explore mode (depends on mode system being in place first)
- Memory blocks (deeper architecture; start with flat instructions on ContainerEnv)
- App UI for mode switching (toggle, button placement)
- App UI for adding project instructions to a ContainerEnv
- How code mode interacts with project instructions (does project override? merge?)
- AGENTS.md support (alongside CLAUDE.md)

## Open Questions

- Should code mode be per-session or per-message? (Leaning: per-session, like trust level)
- What's the minimal "Parachute context" appended in code mode? Just vault tool list, or also user identity?
- Does mode live on `SessionCreate` or only on `ChatRequest`? (Session-level makes more sense for consistency)
- When a ContainerEnv has instructions, what's the UI verb? "Add instructions", "Tell Parachute how to work", "Configure project"?
- Does converse mode have any tool access at all, or is it purely dialogue? (Letta/Roo suggests: pure dialogue is one thing, vault-read is another — those could be two distinct modes)

### System Prompt Transparency

The Claude Code preset is a black box — `/prompt/preview` can show the append content but not the base preset. However: the community has extracted Claude Code's prompt (Piebald AI repo). It's modular — base identity, tool descriptions, sub-agent prompts, ~40 runtime reminders. It's not entirely unknowable.

**Option A — Keep the preset**: Accept partial transparency; good enough for code mode where preset quality is high. Reference the community extraction for debugging.
**Option B — Build our own**: Full transparency and control, but we maintain the prompt; code mode would need to replicate Claude Code's coding instructions.

The modular structure of Claude Code's prompt (base identity + tool descriptions + reminders) is a design worth emulating in our own converse mode prompt regardless of which option is chosen for code mode.

**Issue:** #193
