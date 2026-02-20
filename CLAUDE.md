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

1. **Brainstorm** — Run `/para-brainstorm` to explore an idea collaboratively. Creates a GitHub issue and writes `**Issue:** #NN` back into the brainstorm file.
2. **Pick up** — Run `/para-next` to find the next issue to work on.
3. **Plan** — Run `/para-plan #NN` to create an implementation plan. The plan replaces the issue body and the label is swapped from `brainstorm` to `plan`.
4. **Work** — Run `/para-work #NN` to implement. Creates a PR with `Closes #NN`.

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
├── commands/             # /para-brainstorm, /para-plan, /para-work, etc.
├── agents/research/      # repo-research-analyst, best-practices, framework-docs, etc.
├── agents/review/        # security-sentinel, architecture-strategist, performance-oracle, etc.
├── agents/workflow/      # bug-reproduction-validator, pr-comment-resolver, spec-flow-analyzer
└── skills/               # brainstorming, agent-native-architecture, create-agent-skills
```
