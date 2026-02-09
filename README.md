# Parachute Computer

AI orchestration server for Parachute. Runs locally, manages Claude sessions, and serves the Parachute app.

## Requirements

- Python 3.11+
- macOS or Linux
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (for the OAuth token)

## Install

```bash
git clone https://github.com/OpenParachutePBC/parachute-computer.git
cd parachute-computer
./install.sh
```

The install script will:
1. Check your Python version
2. Create a virtual environment and install dependencies
3. Add a `parachute` command to `~/.local/bin`
4. Ask for your **vault path** (default: `~/Parachute`)
5. Ask for your **Claude token** (get one with `claude setup-token`)
6. Install and start the background daemon

After install, the server is running. Verify with `parachute server status`.

## Updating

```bash
parachute update           # Pull latest from GitHub, reinstall deps, restart
parachute update --local   # Same but skip git pull (for local code changes)
```

That's it. One command handles pulling code, updating dependencies, and restarting the daemon.

If something goes wrong, re-run `./install.sh` to rebuild from scratch.

## Usage

```bash
parachute server status    # Check if running
parachute server stop      # Stop
parachute server restart   # Restart
parachute server -f        # Run in foreground (dev mode)
parachute logs             # Tail server logs
parachute logs --no-follow # Print recent logs and exit
```

### Configuration

Config lives in your vault at `~/Parachute/.parachute/config.yaml`.

```bash
parachute config show           # Show current config
parachute config set port 4444  # Change a value
parachute config get port       # Read a value
```

Available keys: `vault_path`, `port`, `host`, `default_model`, `log_level`, `cors_origins`, `auth_mode`, `debug`.

Environment variables override config.yaml (e.g., `PORT=4444 parachute server -f`).

### Diagnostics

```bash
parachute doctor    # Check python, vault, token, docker, port, server, disk
parachute status    # System overview with server + module info
```

### Modules

```bash
parachute module list           # List installed modules
parachute module approve brain  # Approve a module's hash
parachute module status         # Live server module status
parachute module test           # Test module endpoints
```

## How the daemon works

`parachute install` sets up a background daemon for your platform:

| Platform | Method | Config file |
|----------|--------|-------------|
| macOS | launchd | `~/Library/LaunchAgents/io.openparachute.server.plist` |
| Linux | systemd | `~/.config/systemd/user/parachute.service` |
| Other | PID file | `~/Parachute/.parachute/server.pid` |

The daemon starts on login and restarts on crash. Logs go to `~/Parachute/.parachute/logs/`.

## Authentication

The server needs a Claude OAuth token:

```bash
claude setup-token    # Get token from Claude Code CLI
parachute install     # Paste it during setup
```

Token is stored at `~/Parachute/.parachute/.token` (0600 permissions).

For multi-device access, API keys can be managed through the app's Settings screen.

## Troubleshooting

**`parachute: command not found`** — `~/.local/bin` is not in your PATH. Add to your shell rc file:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

**Server won't start** — Run `parachute doctor` to check all prerequisites.

**Port already in use** — Another process is on port 3333. Change it:
```bash
parachute config set port 4444
parachute server restart
```

**After git pull, things broke** — Re-run `./install.sh` to rebuild the venv from scratch.

**Daemon not starting on boot** — Check platform-specific config:
- macOS: `launchctl list | grep parachute`
- Linux: `systemctl --user status parachute`

## Development

```bash
parachute server -f   # Foreground with live output
make test             # Run test suite
make clean            # Remove venv and caches
```

## Project structure

```
parachute/
├── api/           # FastAPI routes
├── core/          # Orchestrator, sessions, modules, sandbox
├── connectors/    # Telegram + Discord bots
├── cli.py         # CLI entry point
├── config.py      # Settings (env vars + config.yaml)
├── daemon.py      # Daemon management (launchd/systemd/PID)
└── server.py      # FastAPI app
```
