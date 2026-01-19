# Base

AI orchestration server. The unified Parachute app requires this running for Chat and Vault features.

**Repository**: https://github.com/OpenParachutePBC/parachute-base

**Related**: [App (Flutter Client)](../app/CLAUDE.md) | [Parent Project](../CLAUDE.md)

---

## Architecture

```
Router → Orchestrator → Claude SDK → AI
              ↓
         SessionManager → SQLite (Chat/sessions.db)
```

**Key pieces:**
- `parachute/core/orchestrator.py` - Agent execution controller
- `parachute/core/session_manager.py` - Session lifecycle
- `parachute/core/claude_sdk.py` - SDK wrapper
- `parachute/db/` - SQLite database layer

**Data storage:**
- Session metadata: `Chat/sessions.db` (SQLite)
- Message transcripts: `~/.claude/projects/` (SDK JSONL files)
- Curator state: `Daily/.curator/state.json`

---

## Conventions

### Project structure
```
parachute/
├── api/           # FastAPI route handlers
├── core/          # Business logic (orchestrator, session_manager, claude_sdk)
├── db/            # SQLite database layer
├── lib/           # Utilities (agent_loader, context_loader, mcp_loader)
├── models/        # Pydantic models
├── config.py      # Settings via pydantic-settings
└── server.py      # FastAPI application
```

### Patterns
- **Routers** call orchestrator, never touch DB directly
- **Orchestrator** manages agent execution, calls session_manager
- **Pydantic models** everywhere for validation
- **SSE streaming** via async generators in orchestrator
- **Logging**: module-level `logger = logging.getLogger(__name__)`

### Adding a new endpoint
1. Add route in `api/` (thin handler)
2. Add business logic in `core/`
3. Add Pydantic models in `models/`

---

## Running

```bash
./parachute.sh start   # Uses venv, port 3333
./parachute.sh logs    # View logs
./parachute.sh status  # Check if running
```

---

## Authentication

API key authentication for multi-device access:

| Mode | Behavior | Use Case |
|------|----------|----------|
| `remote` (default) | Localhost bypasses, remote requires key | Development |
| `always` | All requests require valid API key | Production |
| `disabled` | No authentication | Local-only |

**Key endpoints:**
- `POST /api/auth/keys` - Create new API key
- `GET /api/auth/keys` - List keys (hashed)
- `DELETE /api/auth/keys/{key_id}` - Revoke key

Keys are SHA-256 hashed before storage. The raw key is only shown once at creation.

---

## Multi-Agent Pipeline

Agents process Daily journal entries:

```
Sync Service → Reflection Agent → Content-Scout → Creative-Director
                    ↓                  ↓                 ↓
            Daily/reflection/   Daily/content-scout/   (media)
```

**Key files:**
- `parachute/core/sync_service.py` - Watches vault, triggers agents
- `parachute/core/agent_runner.py` - Executes agent pipelines
- Agent definitions: `~/Parachute/.claude/agents/`

---

## Gotchas

- SDK session IDs are stored in SQLite, but transcripts live in `~/.claude/projects/`
- The pointer architecture means session.db is metadata only
- Curator is a long-running agent with its own state file
- `VAULT_PATH` env var defaults to `./sample-vault` (set to `~/Parachute` in prod)

---

## Parachute Computer (Lima VM)

When distributed as "Parachute Computer", the base server runs inside a Lima VM:

- **Location**: `~/Library/Application Support/Parachute/base` (users) or custom path (developers)
- **Mount**: VM sees the vault at `/vault` (which is `HOME` for the Lima user)
- **Port**: 3333, forwarded to host (including `0.0.0.0` for Tailscale access)

The `/api/health` endpoint includes `version` and `commit` fields for update checking:
```json
{"status": "ok", "version": "0.1.0", "commit": "abc1234"}
```
