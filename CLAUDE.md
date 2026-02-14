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

---

## Issue Tracking

GitHub Issues on this repo. Use labels:
- `brainstorm` / `plan` - Feature development workflow stages
- `daily` / `chat` / `brain` / `computer` / `app` - Module/component
- `P1` / `P2` / `P3` - Priority
- `bug` / `enhancement` / `needs-thinking` - Type
