# Parachute Base Server (Python)

A FastAPI-based backend server for the Parachute ecosystem, providing AI agent orchestration, session management, and vault operations.

## Features

- **Claude SDK Integration** - Native Python SDK for AI interactions
- **SQLite Session Storage** - Fast, reliable session management
- **SSE Streaming** - Real-time streaming responses
- **Supervisor Service** - Health monitoring and auto-restart
- **MCP Support** - Model Context Protocol for extended tools

## Quick Start

### Prerequisites

- Python 3.10+
- Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
- Anthropic API key (`export ANTHROPIC_API_KEY=...`)

### Installation

```bash
# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# For development
pip install -r requirements-dev.txt
```

### Running the Server

```bash
# Simple start
python -m parachute.server

# With custom vault path
VAULT_PATH=/path/to/vault python -m parachute.server

# With supervisor (recommended for production)
python -m supervisor.main
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_PATH` | `./sample-vault` | Path to knowledge vault |
| `PORT` | `3333` | Server port |
| `HOST` | `0.0.0.0` | Bind address |
| `LOG_LEVEL` | `INFO` | Logging level |
| `API_KEY` | - | Optional API key for authentication |
| `CORS_ORIGINS` | `*` | Comma-separated allowed origins |

## API Endpoints

### Chat

- `POST /api/chat` - Send message, get streaming response (SSE)
- `POST /api/chat/{id}/abort` - Abort active stream

### Sessions

- `GET /api/sessions` - List sessions
- `GET /api/sessions/{id}` - Get session with messages
- `DELETE /api/sessions/{id}` - Delete session
- `POST /api/sessions/{id}/archive` - Archive session
- `POST /api/sessions/{id}/unarchive` - Unarchive session

### Modules

- `GET /api/modules` - List modules
- `GET /api/modules/{mod}/prompt` - Get module prompt
- `PUT /api/modules/{mod}/prompt` - Update module prompt
- `DELETE /api/modules/{mod}/prompt` - Reset to default
- `GET /api/modules/{mod}/search` - Search module content
- `GET /api/modules/{mod}/stats` - Get module statistics

### Health

- `GET /api/health` - Health check
- `GET /` - Server info

## Architecture

```
parachute/
├── api/           # FastAPI route handlers
├── core/          # Business logic
│   ├── orchestrator.py    # Agent execution controller
│   ├── session_manager.py # Session lifecycle
│   ├── claude_sdk.py      # SDK wrapper
│   └── permission_handler.py
├── db/            # SQLite database layer (sessions.db)
├── lib/           # Utilities
│   ├── agent_loader.py
│   ├── context_loader.py
│   ├── mcp_loader.py
│   └── vault_utils.py
├── models/        # Pydantic models
├── config.py      # Settings management
└── server.py      # FastAPI application

supervisor/        # Separate supervisor service
├── main.py        # Supervisor app with web UI
└── process_manager.py
```

## Testing

```bash
# Run all tests
pytest

# Unit tests only
pytest tests/unit/

# Integration tests (no API key needed)
pytest tests/integration/

# E2E tests (requires ANTHROPIC_API_KEY)
pytest tests/e2e/

# With coverage
pytest --cov=parachute --cov-report=html
```

## Development

```bash
# Install dev dependencies
pip install -r requirements-dev.txt

# Type checking
mypy parachute

# Linting
ruff check parachute

# Format code
ruff format parachute
```

## CLI & Service Management

The `parachute.sh` script provides easy server management:

```bash
# One-time setup (creates venv, installs deps)
./parachute.sh setup

# Start/stop/restart
./parachute.sh start      # Background
./parachute.sh stop
./parachute.sh restart
./parachute.sh status     # Check if running

# View logs
./parachute.sh logs
```

### Running as a macOS Service (Development)

For active development, you can run your local code as a launchd service that autostarts at login:

```bash
# Install service pointing to your local dev code
./parachute.sh service-install

# After making code changes, restart
./parachute.sh service-restart

# Stop the service
./parachute.sh service-stop
```

This gives you:
- **Autostart at login** - Server runs automatically when you log in
- **Auto-restart on crash** - `KeepAlive` restarts the server if it dies
- **Local dev code** - Runs from your cloned repo, not a Homebrew install
- **Standard logging** - Logs to `$(brew --prefix)/var/log/parachute.log`

> **Note:** Don't use `brew services restart parachute` if you've used `service-install` - it will overwrite your dev plist. Use `./parachute.sh service-restart` instead.

### Homebrew Installation (End Users)

For end users who just want to run Parachute:

```bash
brew tap openparachutepbc/parachute
brew install parachute
brew services start parachute
```

## Supervisor Service

The supervisor runs as a separate process to monitor and manage the main server:

```bash
# Default: supervisor on 3330, server on 3333
python -m supervisor.main

# Custom ports
SUPERVISOR_PORT=3330 SERVER_PORT=3333 python -m supervisor.main
```

The supervisor provides:
- Web UI at `http://localhost:3330`
- Health monitoring with auto-restart
- Start/stop/restart controls
- Configuration display

## SSE Event Types

Chat streaming returns these event types:

| Event | Description |
|-------|-------------|
| `session` | Session info with ID |
| `init` | Available tools and permissions |
| `model` | Model being used |
| `text` | Text content (with delta) |
| `thinking` | Agent thinking content |
| `tool_use` | Tool being invoked |
| `tool_result` | Tool result |
| `done` | Final response with stats |
| `aborted` | Stream was interrupted |
| `error` | Error occurred |
| `session_unavailable` | Session couldn't be loaded |

## Migration from Node.js

This Python implementation is a rewrite of the original Node.js base server. Key differences:

- **SQLite** instead of markdown files for session storage (`Chat/sessions.db`)
- **Native Python SDK** instead of subprocess calls
- **FastAPI** instead of Express for better async support
- **Supervisor service** for improved reliability

To migrate:
1. Stop the Node.js server
2. Start the Python server
3. Existing sessions will be created fresh (markdown sessions not migrated)
