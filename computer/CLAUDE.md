# Parachute Computer

AI orchestration server with modular architecture. The unified Parachute app requires this running for Chat, Daily, Brain, and Vault features.

**Repository**: https://github.com/OpenParachutePBC/parachute-computer

**Related**: [App (Flutter Client)](../app/CLAUDE.md) | [Parent Project](../CLAUDE.md)

---

## Architecture

```
Router → Orchestrator → Claude Agent SDK → AI
              ↓                    ↑
         SessionManager      ModuleLoader
              ↓                    ↓
         SQLite DB          vault/.modules/
                                   ↓
                            brain | chat | daily
```

**Core:**
- `parachute/core/orchestrator.py` - Agent execution with trust levels and sandbox support
- `parachute/core/session_manager.py` - Session lifecycle
- `parachute/core/claude_sdk.py` - SDK wrapper (CLAUDE_CODE_OAUTH_TOKEN auth)
- `parachute/core/module_loader.py` - Module discovery, hash verification, bootstrap
- `parachute/core/sandbox.py` - Docker container execution for sandboxed sessions
- `parachute/core/hooks/` - Pre/post event hook system

**Connectors:**
- `parachute/connectors/telegram.py` - Telegram bot connector
- `parachute/connectors/discord_bot.py` - Discord bot connector
- `parachute/connectors/config.py` - Bot config from `vault/.parachute/bots.yaml`

**Data storage:**
- Session metadata: `Chat/sessions.db` (SQLite)
- Message transcripts: JSONL files (Claude SDK managed)
- Module hashes: `vault/.parachute/module_hashes.json`
- Bot config: `vault/.parachute/bots.yaml`

---

## Module System

Modules live in `modules/` (bundled, version-controlled). On first startup, `ModuleLoader` copies them to `vault/.modules/`. Each module has:
- `manifest.yaml` — name, version, provides, dependencies
- `module.py` — Module class with `setup()` and optional `get_router()`

Modules are SHA-256 hash-verified. New/modified modules must be approved:
```bash
parachute module list      # See status (new/approved/modified)
parachute module approve brain  # Record hash
```

---

## Trust Levels

| Level | Behavior | Use Case |
|-------|----------|----------|
| `full` | Unrestricted tool access | Local development |
| `vault` | Restricted to vault directory | Standard usage |
| `sandboxed` | Docker container execution | Untrusted sessions, bot DMs |

Trust level is stored per-session in the database and persists across messages.

---

## Conventions

### Project structure
```
parachute/
├── api/           # FastAPI route handlers
├── connectors/    # Bot connectors (Telegram, Discord)
├── core/          # Business logic
│   ├── hooks/     # Event hook system
│   ├── orchestrator.py
│   ├── session_manager.py
│   ├── module_loader.py
│   └── sandbox.py
├── db/            # SQLite database layer
├── docker/        # Sandbox Dockerfile + entrypoint
├── lib/           # Utilities
├── models/        # Pydantic models
├── cli.py         # CLI (parachute setup/status/server/module)
├── config.py      # Settings via pydantic-settings
└── server.py      # FastAPI application

modules/           # Bundled modules (brain, chat, daily)
```

### Patterns
- **Routers** call orchestrator, never touch DB directly
- **Orchestrator** manages agent execution with trust level enforcement
- **Pydantic models** everywhere for validation
- **SSE streaming** via async generators in orchestrator
- **Logging**: module-level `logger = logging.getLogger(__name__)`
- **Config**: `config.py` with empty `env_prefix` — field names map directly to env vars

---

## Running

```bash
parachute setup    # Configure vault path, port, Claude token
parachute server   # Start on configured port (default 3333)
parachute status   # System overview
```

Or directly:
```bash
source .venv/bin/activate
VAULT_PATH=./vault uvicorn parachute.server:app --port 3333
```

---

## Authentication

Claude Agent SDK auth uses `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`).

API key authentication for multi-device access:

| Mode | Behavior |
|------|----------|
| `remote` (default) | Localhost bypasses, remote requires key |
| `always` | All requests require valid API key |
| `disabled` | No authentication |

---

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_PATH` | `./sample-vault` | Path to vault directory |
| `PORT` | `3333` | Server port |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth token for Claude SDK |
| `DEFAULT_MODEL` | — | Optional model override (uses SDK default if unset) |
| `API_KEY` | — | Optional API key for remote auth |

---

## Gotchas

- SDK session IDs are in SQLite, but transcripts are SDK-managed JSONL files
- The pointer architecture means sessions.db is metadata only
- `VAULT_PATH` defaults to `./sample-vault` (set to `~/Parachute` in prod)
- `config.py` has `env_prefix: ""` — env var names match field names exactly
- Modules must be approved (hash verified) before the server loads them
- Bot connectors use per-platform trust levels configured in `bots.yaml`
- Docker must be running for sandboxed sessions (falls back to vault trust)
