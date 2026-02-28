# Parachute Computer

AI orchestration server with modular architecture. The unified Parachute app requires this running for Chat, Daily, Brain, and Vault features.

**Related**: [App (Flutter Client)](../app/CLAUDE.md) | [Monorepo Root](../CLAUDE.md)

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
- `parachute/core/hooks/` - Internal event bus (bot connectors only; user hooks via SDK)
- `parachute/core/plugins.py` - Plugin discovery (manifest-based + legacy)
- `parachute/core/plugin_installer.py` - Plugin install/uninstall from Git URLs

**Connectors:**
- `parachute/connectors/telegram.py` - Telegram bot connector
- `parachute/connectors/discord_bot.py` - Discord bot connector
- `parachute/connectors/config.py` - Bot config from `vault/.parachute/bots.yaml`

**Data storage:**
- Session metadata: `Chat/sessions.db` (SQLite)
- Message transcripts: JSONL files (Claude SDK managed)
- Module hashes: `vault/.parachute/module_hashes.json`
- Bot config: `vault/.parachute/bots.yaml`
- Server config: `vault/.parachute/config.yaml`
- Claude token: `vault/.parachute/.token`
- Daemon logs: `vault/.parachute/logs/`

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

## Extension Points

Five SDK-native primitives — Parachute manages files, the SDK discovers them at runtime:

| Primitive | Location | Format |
|-----------|----------|--------|
| **Agents** | `vault/.claude/agents/*.md` | Markdown with YAML frontmatter |
| **Skills** | `vault/.skills/*.md` or `vault/.skills/*/SKILL.md` | Markdown with frontmatter |
| **MCPs** | `vault/.mcp.json` | JSON `{ "mcpServers": { ... } }` |
| **Hooks** | `vault/.claude/settings.json` | SDK hook config |
| **Plugins** | Installed via API → copies to above locations | Git repos with SDK-layout |

**Plugin install flow:** Clone repo → scan for `.claude/agents/`, `skills/`, `.mcp.json` → copy to vault standard locations with `plugin-{slug}-` prefix → write manifest to `vault/.parachute/plugin-manifests/{slug}.json`.

**HookRunner** (`core/hooks/runner.py`) is an internal event bus for bot connector events only. Not user-facing.

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
├── cli.py         # CLI (install/update/server/logs/doctor/config/module)
├── config.py      # Settings (env vars + config.yaml + .token)
├── daemon.py      # Daemon management (launchd/systemd/PID)
└── server.py      # FastAPI application

modules/           # Bundled modules (brain, chat, daily)
```

### Patterns
- **Routers** call orchestrator, never touch DB directly
- **Orchestrator** manages agent execution with trust level enforcement
- **Pydantic models** everywhere for validation
- **SSE streaming** via async generators in orchestrator
- **Logging**: module-level `logger = logging.getLogger(__name__)`
- **Config**: `config.py` loads env vars > `.env` > `vault/.parachute/config.yaml` > defaults
- **Daemon**: `daemon.py` manages launchd (macOS), systemd (Linux), or PID file fallback

---

## Running

```bash
./install.sh              # First-time: venv + deps + config + daemon
parachute server status   # Check daemon
parachute server -f       # Foreground (dev mode)
parachute update          # Pull latest + reinstall + restart
parachute update --local  # Reinstall + restart (no git pull)
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

## Configuration

Config precedence: env vars > `.env` file > `vault/.parachute/config.yaml` > defaults.

| Setting | Env var | Default | Description |
|---------|---------|---------|-------------|
| `vault_path` | `VAULT_PATH` | `./sample-vault` | Path to vault directory |
| `port` | `PORT` | `3333` | Server port |
| `host` | `HOST` | `0.0.0.0` | Server bind address |
| `claude_code_oauth_token` | `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth token (also read from `.token` file) |
| `default_model` | `DEFAULT_MODEL` | — | Optional model override |
| `auth_mode` | `AUTH_MODE` | `remote` | Auth mode: remote / always / disabled |
| `log_level` | `LOG_LEVEL` | `INFO` | Log level |

Token is stored separately at `vault/.parachute/.token` (0600 permissions).

Manage config via CLI: `parachute config show/set/get`.

---

## Testing

```bash
# Run all unit tests (fast, no server needed)
cd computer
.venv/bin/python -m pytest tests/unit/ -x -q

# Run a specific file
.venv/bin/python -m pytest tests/unit/test_session_manager.py -q

# Run with output on failure
.venv/bin/python -m pytest tests/unit/ -x -s
```

**Always run tests before declaring work done.** If tests fail, fix them — don't skip.

**When adding new code, add tests.** Test files mirror the source structure:
- `parachute/core/foo.py` → `tests/unit/test_foo.py`
- `modules/brain/bar.py` → `tests/unit/test_brain_bar.py`

**Test the interface, not the internals.** Focus on: what does this function return given X input? Does the MCP tool return the right shape? Does the API endpoint respond correctly?

**Known state (Feb 2026):** ~37 tests currently failing due to `TrustLevel` API rename (FULL→DIRECT, VAULT removed) and workspace model changes. These need to be updated — do not add more tests on top of broken ones without fixing the underlying drift first. Track via GitHub issue.

---

## Gotchas

- SDK session IDs are in SQLite, but transcripts are SDK-managed JSONL files
- The pointer architecture means sessions.db is metadata only
- `VAULT_PATH` defaults to `./sample-vault` (set to `~/Parachute` in prod)
- `config.py` has `env_prefix: ""` — env var names match field names exactly
- Config lives in `vault/.parachute/config.yaml`, token in `vault/.parachute/.token`
- Modules must be approved (hash verified) before the server loads them
- Bot connectors use per-platform trust levels configured in `bots.yaml`
- Docker must be running for sandboxed sessions (falls back to vault trust)
- Daemon plist/service is at `io.openparachute.server` — shared label with app
