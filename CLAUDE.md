# Parachute Computer

> Open & interoperable extended mind technology - connected tools for connected thinking

**Repository**: https://github.com/OpenParachutePBC/parachute-computer
**Company**: Open Parachute, PBC (Colorado Public Benefit Corporation)

---

## Principles

- **Interoperable** - Works with your existing tools, no lock-in
- **Intuitive** - Natural interfaces with guidance and guardrails
- **Integrated** - One cohesive system, not a bag of parts

---

## Monorepo Structure

| Directory | Purpose | Stack |
|-----------|---------|-------|
| **computer/** | AI orchestration server | Python/FastAPI |
| **app/** | Unified mobile/desktop app | Flutter/Riverpod |
| **website/** | Website at parachute.computer | Eleventy (11ty) + GitHub Pages |
| **docs/** | Brainstorms, plans, and project documentation | Markdown |

### Communication Flow

```
User -> App (Flutter) -> Parachute Computer -> Claude Agent SDK -> AI
                               |
                         ~/Parachute (vault)
                               |
                    ModuleLoader -> brain | chat | daily
```

### Key Design Decisions

- **One server, one app** - Simplifies development and user experience
- **Modular architecture** - Brain, Chat, Daily are modules loaded at runtime from `vault/.modules/`
- **Trust levels** - Three tiers: full (unrestricted), vault (directory-restricted), sandboxed (Docker)
- **SQLite for session metadata** - Fast queries, tags, permissions
- **SDK JSONL for messages** - Claude SDK stores transcripts, sessions.db is metadata only
- **Local-first transcription** - Sherpa-ONNX with Parakeet models for offline voice input
- **Bot connectors** - Telegram and Discord bots with per-platform trust levels
- **Hook system** - Pre/post event scripts in `vault/.parachute/hooks/`

---

## Starting the Server

**IMPORTANT**: Do NOT restart or install the server yourself. Ask the user to restart the server when needed — the daemon management requires their shell environment.

```bash
cd computer
./install.sh                  # First-time: venv + deps + config + daemon
parachute server status       # Check if running
parachute server -f           # Foreground (dev mode)
parachute logs                # Tail daemon logs
parachute update              # Pull latest, reinstall deps, restart
```

### Verifying it works

```bash
curl http://localhost:3333/api/health?detailed=true
curl http://localhost:3333/api/modules
```

---

## Running the App

```bash
cd app
flutter run -d macos         # macOS desktop
flutter run -d chrome        # Web
flutter run                  # Default device
```

The app connects to the server at `localhost:3333`. Chat, Vault, and Brain features require the server running. Daily works offline.

---

## Authentication

**Claude SDK auth**: `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`. Required for chat.

**API key auth** (multi-device access):

| Mode | Behavior |
|------|----------|
| `remote` (default) | Localhost bypasses auth, remote requires key |
| `always` | All requests require valid API key |
| `disabled` | No authentication required |

---

## Component Instructions

**IMPORTANT**: Before modifying files in a component directory, READ that component's CLAUDE.md first.

| Component | Instructions |
|-----------|--------------|
| **computer/** | Read [computer/CLAUDE.md](computer/CLAUDE.md) - Python server with module system |
| **app/** | Read [app/CLAUDE.md](app/CLAUDE.md) - Flutter unified app |
| **website/** | Read [website/CLAUDE.md](website/CLAUDE.md) - Website, blog, and documentation |

---

## Development Workflow

### Brainstorm → Issue → Plan → Work

The GitHub issue number is the handle that threads through the entire lifecycle:

1. **Brainstorm** — Run `/brainstorm` to explore an idea collaboratively. Creates a GitHub issue and writes `**Issue:** #NN` back into the brainstorm file.
2. **Pick up** — Run `/next` to find the next issue to work on.
3. **Plan** — Run `/plan #NN` to create an implementation plan. The plan replaces the issue body and the label is swapped from `brainstorm` to `plan`.
4. **Work** — Run `/work #NN` to implement. Creates a PR with `Closes #NN`.

All commands accept `#NN` as input. The issue is the durable tracking artifact; local files (`docs/brainstorms/`, `docs/plans/`) are working documents linked by `issue:` in their frontmatter.

### Issue Tracking

GitHub Issues on this repo. Use labels:
- `brainstorm` / `plan` - Feature development workflow stages
- `daily` / `chat` / `brain` / `computer` / `app` - Module/component
- `P1` / `P2` / `P3` - Priority
- `bug` / `enhancement` / `needs-thinking` - Type

### Engineering Tools

Workflow commands, research agents, review agents, and skills live in `.claude/` (standalone, no plugin wrapper). Forked from compound-engineering v2.30.0, trimmed for this repo.

```
.claude/
├── commands/             # /brainstorm, /plan, /work, etc.
├── agents/research/      # repo-research-analyst, best-practices, framework-docs, etc.
├── agents/review/        # security-sentinel, architecture-strategist, performance-oracle, etc.
├── agents/workflow/      # bug-reproduction-validator, pr-comment-resolver, spec-flow-analyzer
└── skills/               # brainstorming, agent-native-architecture, create-agent-skills
```

> **GitNexus scope**: `computer/` (Python backend) only. Dart/Flutter (`app/`) is not indexed — skip GitNexus tools when working in `app/`.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **parachute-computer** (4273 symbols, 8978 relationships, 272 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## When Debugging

1. `gitnexus_query({query: "<error or symptom>"})` — find execution flows related to the issue
2. `gitnexus_context({name: "<suspect function>"})` — see all callers, callees, and process participation
3. `READ gitnexus://repo/parachute-computer/process/{processName}` — trace the full execution flow step by step
4. For regressions: `gitnexus_detect_changes({scope: "compare", base_ref: "main"})` — see what your branch changed

## When Refactoring

- **Renaming**: MUST use `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` first. Review the preview — graph edits are safe, text_search edits need manual review. Then run with `dry_run: false`.
- **Extracting/Splitting**: MUST run `gitnexus_context({name: "target"})` to see all incoming/outgoing refs, then `gitnexus_impact({target: "target", direction: "upstream"})` to find all external callers before moving code.
- After any refactor: run `gitnexus_detect_changes({scope: "all"})` to verify only expected files changed.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Tools Quick Reference

| Tool | When to use | Command |
|------|-------------|---------|
| `query` | Find code by concept | `gitnexus_query({query: "auth validation"})` |
| `context` | 360-degree view of one symbol | `gitnexus_context({name: "validateUser"})` |
| `impact` | Blast radius before editing | `gitnexus_impact({target: "X", direction: "upstream"})` |
| `detect_changes` | Pre-commit scope check | `gitnexus_detect_changes({scope: "staged"})` |
| `rename` | Safe multi-file rename | `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` |
| `cypher` | Custom graph queries | `gitnexus_cypher({query: "MATCH ..."})` |

## Impact Risk Levels

| Depth | Meaning | Action |
|-------|---------|--------|
| d=1 | WILL BREAK — direct callers/importers | MUST update these |
| d=2 | LIKELY AFFECTED — indirect deps | Should test |
| d=3 | MAY NEED TESTING — transitive | Test if critical path |

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/parachute-computer/context` | Codebase overview, check index freshness |
| `gitnexus://repo/parachute-computer/clusters` | All functional areas |
| `gitnexus://repo/parachute-computer/processes` | All execution flows |
| `gitnexus://repo/parachute-computer/process/{name}` | Step-by-step execution trace |

## Self-Check Before Finishing

Before completing any code modification task, verify:
1. `gitnexus_impact` was run for all modified symbols
2. No HIGH/CRITICAL risk warnings were ignored
3. `gitnexus_detect_changes()` confirms changes match expected scope
4. All d=1 (WILL BREAK) dependents were updated

## CLI

- Re-index: `npx gitnexus analyze`
- Check freshness: `npx gitnexus status`
- Generate docs: `npx gitnexus wiki`

<!-- gitnexus:end -->
