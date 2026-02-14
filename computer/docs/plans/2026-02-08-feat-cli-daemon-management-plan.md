---
title: "feat: CLI Experience & Daemon Management"
type: feat
date: 2026-02-08
---

# CLI Experience & Daemon Management

## Overview

Overhaul the Parachute Computer CLI to support background daemon management, unified config, easy installation, and diagnostics. Today starting the server requires venv activation and blocks the terminal. After this work, the full flow is:

```bash
git clone https://github.com/OpenParachutePBC/parachute-computer.git
cd parachute-computer
make install    # venv, deps, wrapper script, interactive setup, daemon auto-start
```

Then: `parachute server stop`, `parachute logs`, `parachute doctor`, `parachute config set port 4444` — all just work.

## Problem Statement

**Current flow** (6 manual steps):
```
git clone → cd computer → python -m venv .venv → source .venv/bin/activate → pip install -e . → parachute setup → parachute server (blocks terminal)
```

**Pain points:**
- venv activation required every session
- Server runs in foreground (blocks terminal, dies on close)
- Config in `.env` at CWD (ambiguous, easy to lose)
- No logs, restart, or auto-start capability
- No diagnostics for debugging setup issues

## Key Design Decisions

### D1: Config location → `vault/.parachute/config.yaml`

Config moves from `.env` at CWD to `vault/.parachute/config.yaml`. This replaces the existing `server.yaml` in the same directory (merges its contents). Precedence chain:

```
env vars > config.yaml > defaults
```

The existing `.env` is auto-migrated on first `parachute install`. The `.env` file is renamed to `.env.migrated` afterward.

Schema (flat, matching existing env var names):
```yaml
# vault/.parachute/config.yaml
vault_path: ~/Parachute
port: 3333
host: 0.0.0.0
default_model: null
log_level: info
cors_origins: "*"

# Security (migrated from server.yaml)
auth_mode: remote        # remote | always | disabled
api_keys: []             # managed via app UI or CLI
```

**Token is stored separately** in `vault/.parachute/.token` with 0600 permissions. Not in config.yaml (avoids accidental sync/backup exposure).

### D2: `parachute install` replaces `parachute setup`

`parachute install` is the new first-run command. It does everything `setup` did plus daemon installation. `parachute setup` remains as a hidden alias for backward compatibility but prints a deprecation notice.

### D3: `parachute server` merges foreground and daemon

```
parachute server              # Start daemon (background). If no daemon configured, falls back to foreground.
parachute server --foreground  # Always foreground (dev mode)
parachute server stop          # Stop daemon
parachute server restart       # Restart daemon
parachute server status        # Daemon state (PID, uptime, port)
```

Breaking change: current `parachute server` blocks. New behavior returns immediately. Mitigation: if no daemon is installed (user hasn't run `parachute install`), fall back to foreground with a notice suggesting `parachute install`.

### D4: Daemon ownership → CLI is canonical

The CLI owns daemon installation. The Flutter app's `BareMetalServerService` should delegate to `parachute install` / `parachute server start` rather than generating its own plist. Both use the same launchd label: `io.openparachute.server`.

### D5: Wrapper script embeds venv path

`make install` creates `~/.local/bin/parachute` (or `/usr/local/bin/parachute` if user prefers). The wrapper calls the venv's Python directly — no activation needed:

```bash
#!/usr/bin/env bash
exec "/path/to/computer/.venv/bin/python" -m parachute "$@"
```

The path is baked in at install time. Re-run `make install` if the repo moves.

## Technical Approach

### Implementation Phases

#### Phase 1: Config System (`config.yaml` + migration)

**Goal**: Single source of truth for config, auto-migration from `.env`.

**Files to modify:**

- [ ] `computer/parachute/config.py` — Add YAML loading alongside env vars
  - Add `_load_yaml_config(vault_path)` that reads `vault/.parachute/config.yaml`
  - Modify `Settings` class to accept YAML values as fallbacks (env vars still override)
  - Remove `env_file = ".env"` from model_config (config.yaml replaces it)
  - Add `_load_token(vault_path)` that reads `vault/.parachute/.token`

- [ ] `computer/parachute/lib/server_config.py` — Deprecate in favor of config.yaml
  - `ServerConfig.load()` reads from config.yaml instead of server.yaml
  - If only server.yaml exists, migrate it to config.yaml fields

- [ ] `computer/parachute/cli.py` — Update `cmd_setup()` / new `cmd_install()`
  - `cmd_install()`: interactive wizard writes to `vault/.parachute/config.yaml` + `.token`
  - Auto-detect existing `.env`, migrate values, rename to `.env.migrated`
  - Auto-detect existing `server.yaml`, merge into config.yaml

- [ ] Tests: config loading from YAML, migration from `.env`, migration from `server.yaml`, precedence (env > yaml > defaults)

#### Phase 2: Daemon Management (launchd + systemd)

**Goal**: `parachute server` starts/stops a background daemon.

**New files:**

- [ ] `computer/parachute/daemon.py` — Platform-specific daemon management
  - `class DaemonManager` with methods: `install()`, `uninstall()`, `start()`, `stop()`, `restart()`, `status()`, `is_installed()`
  - `class LaunchdDaemon(DaemonManager)` — macOS implementation
    - Generates plist via `plistlib`
    - Uses modern `launchctl bootstrap/bootout/kickstart`
    - Label: `io.openparachute.server`
    - Plist at: `~/Library/LaunchAgents/io.openparachute.server.plist`
    - Log files at: `vault/.parachute/logs/stdout.log`, `stderr.log`
    - `ProgramArguments`: `["/path/to/.venv/bin/python", "-m", "uvicorn", "parachute.server:app", "--port", "{port}"]`
    - `KeepAlive: true`, `RunAtLoad: true`, `ThrottleInterval: 10`
    - `EnvironmentVariables`: `VAULT_PATH`, `PARACHUTE_CONFIG` (path to config.yaml)
  - `class SystemdDaemon(DaemonManager)` — Linux implementation
    - Generates unit file at `~/.config/systemd/user/parachute.service`
    - `ExecStart=/path/to/.venv/bin/python -m uvicorn parachute.server:app`
    - `Environment=PYTHONUNBUFFERED=1`
    - `Restart=on-failure`, `RestartSec=5`
    - `WantedBy=default.target`
  - `class PidDaemon(DaemonManager)` — Fallback for no service manager
    - PID file at `vault/.parachute/server.pid`
    - Fork + exec pattern
    - Stale PID detection via `os.kill(pid, 0)`
  - Factory function: `get_daemon_manager()` detects platform and returns appropriate class

- [ ] `computer/parachute/cli.py` — Extend `cmd_server()` with subcommands
  - `parachute server` (no subcommand): calls `daemon.start()`, falls back to foreground if not installed
  - `parachute server --foreground`: existing foreground behavior
  - `parachute server stop`: calls `daemon.stop()`
  - `parachute server restart`: calls `daemon.restart()`
  - `parachute server status`: calls `daemon.status()`, prints PID/uptime/port

- [ ] Update `cmd_install()` to call `daemon.install()` + `daemon.start()`

- [ ] Tests: daemon install/uninstall (mock subprocess), plist generation, systemd unit generation, PID lifecycle

#### Phase 3: CLI Commands (logs, doctor, config)

**Goal**: Full command surface for server management.

**Files to modify:**

- [ ] `computer/parachute/cli.py` — Add new commands:

  **`parachute logs`**:
  - macOS: `tail -f vault/.parachute/logs/stderr.log`
  - Linux (systemd): `journalctl --user-unit parachute -f`
  - Fallback: check common locations
  - Flags: `--follow` (default on), `--lines N` (default 50), `--since DURATION`

  **`parachute doctor`**:
  - Check Python version (>= 3.11)
  - Check package installation (can import parachute)
  - Check vault path exists and is writable
  - Check config.yaml is parseable
  - Check token file exists and is non-empty
  - Check Docker availability + sandbox image
  - Check port availability (is configured port free or bound by us?)
  - Check server reachability if daemon is running (GET /api/health)
  - Check disk space (warn if < 1GB)
  - Print summary with pass/warn/fail for each check

  **`parachute config show`**:
  - Read and display config.yaml (mask token)
  - Show effective values (with env var overrides noted)

  **`parachute config set KEY VALUE`**:
  - Validate key is known (from Settings schema)
  - Validate value type (int for port, string for path, etc.)
  - Write to config.yaml
  - Print "restart required" notice for non-hot-reloadable values
  - Refuse to set token via config set (security: use `parachute install` or write .token directly)

  **`parachute config get KEY`**:
  - Print single value

- [ ] Tests: doctor checks (mock subprocess/filesystem), config set/get roundtrip, logs command (mock tail/journalctl)

#### Phase 4: Makefile & Wrapper Script

**Goal**: `git clone && make install` works end-to-end.

**New files:**

- [ ] `computer/Makefile`
  ```makefile
  .PHONY: install venv run test clean install-global

  VENV := .venv
  BIN := $(VENV)/bin
  PY := python3

  $(VENV): pyproject.toml
  	$(PY) -m venv $(VENV)
  	$(BIN)/pip install --upgrade pip setuptools wheel
  	$(BIN)/pip install -e .
  	touch $(VENV)

  install: $(VENV)                  ## Full install: venv + deps + setup + daemon
  	$(BIN)/parachute install

  install-global: $(VENV)           ## Also install wrapper to ~/.local/bin
  	@mkdir -p $(HOME)/.local/bin
  	@printf '#!/usr/bin/env bash\nexec "$(CURDIR)/$(BIN)/python" -m parachute "$$@"\n' > $(HOME)/.local/bin/parachute
  	@chmod +x $(HOME)/.local/bin/parachute
  	@echo "Installed: $(HOME)/.local/bin/parachute"

  run: $(VENV)                      ## Start server in foreground
  	$(BIN)/parachute server --foreground

  test: $(VENV)                     ## Run tests
  	$(BIN)/python -m pytest tests/ -v

  clean:                            ## Remove venv and caches
  	rm -rf $(VENV)
  	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
  ```

- [ ] Update `computer/install.sh` to just call `make install` (backward compat)

- [ ] `parachute install` checks if `~/.local/bin` is in PATH, prints instruction if not

- [ ] Add `__main__.py` to parachute package so `python -m parachute` works:
  ```python
  from parachute.cli import main
  main()
  ```

## Acceptance Criteria

### Functional Requirements

- [ ] `make install` from fresh git clone creates venv, installs package, runs interactive setup, installs daemon, starts server
- [ ] `parachute server` starts background daemon and returns immediately
- [ ] `parachute server --foreground` runs in foreground (existing behavior preserved)
- [ ] `parachute server stop` stops the daemon
- [ ] `parachute server restart` restarts the daemon
- [ ] `parachute logs` tails daemon log output
- [ ] `parachute doctor` runs diagnostics and reports pass/warn/fail
- [ ] `parachute config show` displays current config (token masked)
- [ ] `parachute config set port 4444` updates config.yaml
- [ ] `parachute config get port` prints the value
- [ ] `parachute install` is idempotent (re-running is safe)
- [ ] Existing `.env` files are auto-migrated to config.yaml on install
- [ ] Existing `server.yaml` fields are merged into config.yaml
- [ ] Token stored in `vault/.parachute/.token` with 0600 permissions
- [ ] Daemon auto-starts on login (macOS: launchd, Linux: systemd)
- [ ] `parachute setup` still works (alias to install with deprecation notice)
- [ ] All existing commands (`status`, `module *`) unchanged

### Non-Functional Requirements

- [ ] No venv activation required by the user (wrapper script or make targets handle it)
- [ ] Config precedence: env vars > config.yaml > defaults
- [ ] Daemon restarts on crash (launchd KeepAlive, systemd Restart=on-failure)
- [ ] Log rotation: 10MB max file size, 5 backup files (RotatingFileHandler)
- [ ] Stale PID detection works correctly (process-alive check via signal 0)
- [ ] macOS and Linux supported; Windows explicitly unsupported

## Dependencies & Risks

**Dependencies:**
- `pyyaml` — for config.yaml loading (add to pyproject.toml dependencies)
- `plistlib` — stdlib, for launchd plist generation
- No new CLI framework needed — argparse is sufficient for this command surface

**Risks:**
- **`~/.local/bin` not in PATH on macOS** — Mitigated by printing instructions during install. Could offer to append to `~/.zshrc`.
- **App-CLI daemon conflict** — Mitigated by using same launchd label. Phase 2 should coordinate with app team to delegate daemon management to CLI.
- **Python version change after install** — Mitigated by `parachute doctor` checking venv health.
- **Vault on external drive** — If drive isn't mounted at boot, daemon fails. Mitigated by KeepAlive (launchd retries) and clear error in `parachute doctor`.

## Migration Path

For existing users:
1. `git pull` to get new code
2. `make install` (or `pip install -e .` + `parachute install`)
3. Install detects `.env`, migrates to `vault/.parachute/config.yaml`
4. Renames `.env` to `.env.migrated`
5. Detects `server.yaml`, merges security fields into config.yaml
6. Installs daemon, starts it
7. User can now close terminal — server keeps running

## References

- Brainstorm: `docs/brainstorms/2026-02-08-cli-experience-brainstorm.md`
- Current CLI: `computer/parachute/cli.py`
- Current config: `computer/parachute/config.py`
- Server config: `computer/parachute/lib/server_config.py`
- Existing install script: `computer/install.sh`
- App daemon manager: `app/lib/core/services/bare_metal_server_service.dart`
- OpenClaw CLI patterns: https://github.com/openclaw/openclaw
