# Base

AI orchestration server. Chat app requires this running.

**Repository**: https://github.com/OpenParachutePBC/parachute-base

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

## Gotchas

- SDK session IDs are stored in SQLite, but transcripts live in `~/.claude/projects/`
- The pointer architecture means session.db is metadata only
- Curator is a long-running agent with its own state file
- `VAULT_PATH` env var defaults to `./sample-vault` (set to `~/Parachute` in prod)
