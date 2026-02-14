---
topic: CLI Experience & Daemon Management
date: 2026-02-08
status: decided
---

# CLI Experience & Daemon Management

## What We're Building

A production-grade CLI for Parachute Computer that handles installation, background daemon management, configuration, and diagnostics. Today `parachute server` requires manual venv activation and runs in the foreground. The new CLI should feel like a proper system service — install from a git clone, auto-start on boot, manage via simple commands.

## Current State

```
git clone → cd computer → python -m venv .venv → source .venv/bin/activate → pip install -e . → parachute setup → parachute server (foreground, blocks terminal)
```

**Pain points:**
- 6 steps to get running
- Server blocks the terminal
- No logs, restart, or status without manual process management
- Config lives in `.env` at working directory (easy to lose, ambiguous location)
- No daemon/auto-start capability
- venv activation required every time

## Why This Approach

OpenClaw's pattern (npm install -g + onboard --install-daemon) provides a good reference. They use launchd on macOS and systemd on Linux for persistent background services, with a foreground mode for development. We adapt this to Python/pip with a Makefile entry point for git clone installs.

## Key Decisions

### 1. Installation: `make install` from git clone

```bash
git clone https://github.com/OpenParachutePBC/parachute-computer.git
cd parachute-computer
make install
```

The Makefile handles:
- Checks Python 3.11+ is available
- Creates `.venv` and installs the package
- Installs a wrapper script to `/usr/local/bin/parachute` (or `~/.local/bin/`)
- Runs `parachute install` which does interactive setup + daemon installation

The wrapper script activates the venv transparently — users never touch `source .venv/bin/activate` again.

### 2. Config location: Inside the vault

Config moves from `.env` in working directory to `vault/.parachute/config.yaml`.

```yaml
# vault/.parachute/config.yaml
port: 3333
host: 0.0.0.0
claude_token: sk-ant-...   # or reference to keychain
default_model: null
api_key: null
auth_mode: remote
log_level: info
```

Benefits:
- Config travels with the vault (portable)
- One canonical location (no more "which .env am I using?")
- YAML is more readable than .env for structured config
- Backward compat: still reads env vars as overrides

### 3. Server command merges foreground and daemon

```bash
parachute server              # Starts daemon (background), returns immediately
parachute server --foreground  # Dev mode, logs to terminal
parachute server stop          # Stops the daemon
parachute server restart       # Restarts the daemon
parachute server status        # Is daemon running? PID, uptime, port
```

### 4. Daemon: launchd (macOS) + systemd (Linux)

`parachute install` creates:
- **macOS**: `~/Library/LaunchAgents/io.openparachute.server.plist`
- **Linux**: `~/.config/systemd/user/parachute.service`

Auto-starts on login. Logs go to `vault/.parachute/logs/`.

### 5. Full CLI command surface

```
parachute install              # First-time: setup + daemon + auto-start
parachute server               # Start daemon (or show status if already running)
parachute server --foreground  # Dev mode (foreground, live logs)
parachute server stop          # Stop daemon
parachute server restart       # Restart daemon
parachute logs                 # Tail daemon logs (--follow by default)
parachute logs --since 1h      # Logs from last hour
parachute status               # System overview (existing, enhanced)
parachute doctor               # Diagnose issues (Python, deps, token, Docker, port, connectivity)
parachute config show          # Show current config
parachute config set KEY VALUE # Set a config value
parachute config get KEY       # Get a config value
parachute module list          # (existing) List modules
parachute module approve NAME  # (existing) Approve module
parachute module status        # (existing) Live module status
parachute module test [NAME]   # (existing) Test module endpoints
parachute setup                # (existing) Interactive wizard, now writes to vault config
```

### 6. `parachute doctor` diagnostics

Checks:
- Python version
- Package installation and dependencies
- Claude OAuth token validity (API ping)
- Docker availability and sandbox image
- Port availability (is 3333 in use?)
- Vault path exists and is writable
- Config file parseable
- Server reachability (if daemon running)
- Disk space for vault

### 7. Platform targets: macOS + Linux

macOS is primary (developer use), Linux for server deployments. No Windows for now.

## Open Questions

- **Wrapper script vs pipx**: The `make install` approach creates a shell wrapper that activates the venv. Alternatively, `pipx install .` does this automatically. Should we support both? (Makefile could detect pipx and prefer it.)
- **Token storage**: Currently the OAuth token is in the config YAML in plaintext. Should we use macOS Keychain / Linux secret-store? Or is vault-level encryption sufficient for now?
- **Log rotation**: Should we handle log rotation ourselves or rely on the OS (launchd/systemd handle this natively)?
- **Update mechanism**: `parachute update` that does `git pull && make install`? Or leave that manual for now?

## References

- Current CLI: `computer/parachute/cli.py`
- Current config: `computer/parachute/config.py`
- OpenClaw CLI patterns: https://github.com/openclaw/openclaw
- OpenClaw uses launchd/systemd daemon with `onboard --install-daemon`
