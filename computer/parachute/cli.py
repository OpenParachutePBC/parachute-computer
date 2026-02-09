"""
Parachute CLI.

Usage:
    parachute install                  # First-time setup + daemon install
    parachute update                   # Pull latest code, reinstall, restart
    parachute update --local           # Reinstall + restart (no git pull)
    parachute server                   # Start daemon (background)
    parachute server --foreground      # Start in foreground (dev mode)
    parachute server stop              # Stop daemon
    parachute server restart           # Restart daemon
    parachute server status            # Daemon state
    parachute logs                     # Tail daemon logs
    parachute doctor                   # Run diagnostics
    parachute config show              # Show current config
    parachute config set KEY VALUE     # Set a config value
    parachute config get KEY           # Get a config value
    parachute status                   # System overview
    parachute module list              # List modules (offline)
    parachute module approve NAME      # Approve a module (offline)
    parachute module status            # Show live server status (online)
    parachute module test [NAME]       # Test module endpoints (online)
"""

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

import yaml

from parachute.config import (
    CONFIG_KEYS,
    _load_yaml_config,
    get_config_path,
    save_token,
    save_yaml_config,
)
from parachute.core.module_loader import ModuleLoader, compute_module_hash


# --- Helpers ---


def _get_vault_path() -> Path:
    """Resolve vault path from env, config.yaml, or default."""
    path = os.environ.get("VAULT_PATH", "")
    if path:
        return Path(path).expanduser().resolve()

    # Check .env for backward compat
    env = _load_env_file()
    if "VAULT_PATH" in env:
        return Path(env["VAULT_PATH"]).expanduser().resolve()

    # Check config.yaml in common locations (~/Parachute or via symlink)
    home_vault = Path.home() / "Parachute"
    if (home_vault / ".parachute" / "config.yaml").exists():
        # Read vault_path from config.yaml to get the canonical path
        config = _load_yaml_config(home_vault)
        if "vault_path" in config:
            return Path(config["vault_path"]).expanduser().resolve()
        return home_vault.resolve()

    return Path("./vault").resolve()


def _get_server_url() -> str:
    """Resolve server URL from PORT env or default."""
    port = os.environ.get("PORT", "3333")
    return f"http://localhost:{port}"


def _get_env_file() -> Path:
    """Get the .env file path (in CWD)."""
    return Path.cwd() / ".env"


def _load_env_file() -> dict[str, str]:
    """Load key=value pairs from .env file."""
    env_file = _get_env_file()
    env = {}
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, value = line.partition("=")
                env[key.strip()] = value.strip()
    return env


def _save_env_file(env: dict[str, str]) -> Path:
    """Save key=value pairs to .env file."""
    env_file = _get_env_file()
    lines = []
    for key, value in sorted(env.items()):
        lines.append(f"{key}={value}")
    env_file.write_text("\n".join(lines) + "\n")
    return env_file


def _api_get(url: str) -> dict:
    """Make a GET request to the server API."""
    req = Request(url)
    req.add_header("Accept", "application/json")
    with urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


def _api_post(url: str, data: dict | None = None) -> dict:
    """Make a POST request to the server API."""
    body = json.dumps(data or {}).encode()
    req = Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    with urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


def _port_in_use(port: int) -> bool:
    """Check if a port is already in use."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def _process_alive(pid: int) -> bool:
    """Check if a process is alive."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


# --- Migration ---


def _migrate_env_to_yaml(vault_path: Path) -> bool:
    """Migrate .env file to config.yaml. Returns True if migration happened."""
    env_file = _get_env_file()
    if not env_file.exists():
        return False

    env = _load_env_file()
    if not env:
        return False

    config_file = get_config_path(vault_path)
    existing = _load_yaml_config(vault_path)

    # Map env vars to config keys
    env_to_config = {
        "VAULT_PATH": "vault_path",
        "PORT": "port",
        "HOST": "host",
        "DEFAULT_MODEL": "default_model",
        "LOG_LEVEL": "log_level",
        "CORS_ORIGINS": "cors_origins",
        "DEBUG": "debug",
    }

    migrated = {}
    for env_key, config_key in env_to_config.items():
        if env_key in env and config_key not in existing:
            value = env[env_key]
            # Convert types
            if config_key == "port":
                try:
                    value = int(value)
                except ValueError:
                    pass
            elif config_key == "debug":
                value = value.lower() in ("true", "1", "yes")
            migrated[config_key] = value

    # Handle token separately
    token = env.get("CLAUDE_CODE_OAUTH_TOKEN")
    if token:
        save_token(vault_path, token)
        print(f"  Migrated token to {vault_path / '.parachute' / '.token'}")

    if migrated:
        config_data = {**existing, **migrated}
        save_yaml_config(vault_path, config_data)
        print(f"  Migrated {len(migrated)} settings to {config_file}")

    # Rename .env to .env.migrated
    migrated_file = env_file.parent / (env_file.name + ".migrated")
    env_file.rename(migrated_file)
    print(f"  Renamed .env to {migrated_file.name}")

    return True


def _migrate_server_yaml(vault_path: Path) -> bool:
    """Migrate server.yaml fields into config.yaml. Returns True if migration happened."""
    server_yaml = vault_path / ".parachute" / "server.yaml"
    if not server_yaml.exists():
        return False

    try:
        with open(server_yaml) as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        return False

    existing = _load_yaml_config(vault_path)
    migrated = {}

    # Migrate security.require_auth -> auth_mode
    if "security" in data:
        sec = data["security"]
        if "require_auth" in sec and "auth_mode" not in existing:
            migrated["auth_mode"] = sec["require_auth"]

    # Migrate server.port -> port
    if "server" in data:
        srv = data["server"]
        if "port" in srv and "port" not in existing:
            migrated["port"] = srv["port"]

    if migrated:
        config_data = {**existing, **migrated}
        save_yaml_config(vault_path, config_data)
        print(f"  Merged {len(migrated)} fields from server.yaml into config.yaml")
        return True

    return False


# --- Install command ---


def cmd_install(args: argparse.Namespace) -> None:
    """First-time setup: interactive config + daemon install + start."""
    print("Parachute Install")
    print("=" * 40)

    # 1. Vault path
    current_vault = os.environ.get("VAULT_PATH", "")
    default_vault = str(Path.home() / "Parachute")

    if not current_vault:
        # Check if we have one from .env migration
        env = _load_env_file()
        current_vault = env.get("VAULT_PATH", "")

    prompt_default = current_vault or default_vault
    print(f"\nVault path [{prompt_default}]: ", end="")
    vault_input = input().strip()
    vault_str = vault_input or prompt_default
    vault_path = Path(vault_str).expanduser().resolve()

    # Ensure vault and config dir exist
    vault_path.mkdir(parents=True, exist_ok=True)
    (vault_path / ".parachute").mkdir(exist_ok=True)
    (vault_path / ".parachute" / "logs").mkdir(exist_ok=True)
    print(f"  Vault: {vault_path}")

    # 2. Migrate existing configs
    print("\nChecking for existing configuration...")
    migrated_env = _migrate_env_to_yaml(vault_path)
    migrated_server = _migrate_server_yaml(vault_path)
    if not migrated_env and not migrated_server:
        print("  No existing config to migrate.")

    # 3. Load current config (may have just been migrated)
    config = _load_yaml_config(vault_path)
    config["vault_path"] = str(vault_path)

    # 4. Port
    current_port = config.get("port", 3333)
    print(f"\nServer port [{current_port}]: ", end="")
    port_input = input().strip()
    if port_input:
        try:
            config["port"] = int(port_input)
        except ValueError:
            print(f"  Invalid port, keeping {current_port}")
    else:
        config["port"] = current_port

    # 5. Claude token
    from parachute.config import _load_token

    existing_token = _load_token(vault_path) or os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    has_token = bool(existing_token)

    print(f"\nClaude token: {'configured' if has_token else 'not set'}")

    if has_token:
        print("Update token? [y/N]: ", end="")
        update = input().strip().lower()
        if update != "y":
            print("  Keeping existing token.")
        else:
            has_token = False

    if not has_token:
        print("\nTo get a token, run: claude setup-token")
        print("Then paste it here.")
        print("\nCLAUDE_CODE_OAUTH_TOKEN: ", end="")
        token = input().strip()
        if token:
            save_token(vault_path, token)
            print("  Token saved.")
        else:
            print("  Skipped (you can set this later).")

    # 6. Docker check
    print("\nContainer runtime:")
    docker_path = shutil.which("docker")
    if docker_path:
        print(f"  Docker: {docker_path}")
        try:
            result = subprocess.run(
                ["docker", "info"],
                capture_output=True,
                timeout=5,
            )
            if result.returncode == 0:
                print("  Daemon: running")
            else:
                print("  Daemon: not running (sandbox features unavailable)")
        except (subprocess.TimeoutExpired, OSError):
            print("  Daemon: check timed out")
    else:
        print("  Docker: not found")
        print("  Tip: Install OrbStack (https://orbstack.dev) for sandbox features")

    # 7. Save config
    config_file = save_yaml_config(vault_path, config)
    print(f"\nConfig written to {config_file}")

    # 8. Install and start daemon
    print("\nInstalling daemon...")
    try:
        from parachute.daemon import get_daemon_manager

        daemon = get_daemon_manager(vault_path, config)
        daemon.install()
        print("  Daemon installed.")

        daemon.start()
        print("  Daemon started.")
        print(f"\n  Server running on port {config.get('port', 3333)}")
    except Exception as e:
        print(f"  Daemon install failed: {e}")
        print("  You can start manually with: parachute server --foreground")

    # 9. Check PATH
    _check_path()

    print("\nDone! Use 'parachute server status' to check the daemon.")


def _check_path() -> None:
    """Check if ~/.local/bin is in PATH and advise if not."""
    local_bin = Path.home() / ".local" / "bin"
    path_dirs = os.environ.get("PATH", "").split(os.pathsep)
    if str(local_bin) not in path_dirs:
        shell = os.environ.get("SHELL", "")
        if "zsh" in shell:
            rc_file = "~/.zshrc"
        elif "bash" in shell:
            rc_file = "~/.bashrc"
        else:
            rc_file = "your shell rc file"
        print(f"\nNote: {local_bin} is not in your PATH.")
        print(f"  Add this to {rc_file}:")
        print(f'  export PATH="$HOME/.local/bin:$PATH"')



# --- Update command ---


def _get_repo_dir() -> Path:
    """Find the repo root from the installed package location."""
    import parachute as pkg

    # Editable install: parachute/__init__.py is inside the repo
    pkg_dir = Path(pkg.__file__).parent  # parachute/
    repo_dir = pkg_dir.parent            # computer/
    if (repo_dir / "pyproject.toml").exists():
        return repo_dir
    # Fallback: CWD
    return Path.cwd()


def cmd_update(args: argparse.Namespace) -> None:
    """Pull latest code, reinstall deps, and restart daemon."""
    local_only = getattr(args, "local", False)
    repo_dir = _get_repo_dir()
    venv_pip = Path(sys.executable).parent / "pip"

    print(f"Updating Parachute ({repo_dir})")
    print("=" * 40)

    # 1. Git pull (unless --local)
    if not local_only:
        if (repo_dir / ".git").exists():
            print("\nPulling latest code...")
            # Try git pull, fall back to git pull origin main if no upstream
            result = subprocess.run(
                ["git", "pull"],
                cwd=repo_dir,
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode != 0 and "no tracking information" in result.stderr:
                # Try pulling from origin main directly
                result = subprocess.run(
                    ["git", "pull", "origin", "main"],
                    cwd=repo_dir,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
            if result.returncode != 0:
                print(f"  git pull failed: {result.stderr.strip()}")
                print("  Try pulling manually, or use: parachute update --local")
                sys.exit(1)
            output = result.stdout.strip()
            if "Already up to date" in output:
                print("  Already up to date.")
            else:
                print(f"  {output}")
        else:
            print("\nNot a git repo — skipping pull.")
            print("  (Install from git clone for auto-updates)")

    # 2. Reinstall deps
    print("\nInstalling dependencies...")
    result = subprocess.run(
        [str(venv_pip), "install", "-e", str(repo_dir), "-q"],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        print(f"  pip install failed: {result.stderr.strip()}")
        sys.exit(1)
    print("  Dependencies updated.")

    # 3. Restart daemon if running
    vault_path = _get_vault_path()
    config = _load_yaml_config(vault_path)

    try:
        from parachute.daemon import get_daemon_manager

        daemon = get_daemon_manager(vault_path, config)
        status = daemon.status()

        if status.get("running"):
            print("\nRestarting server...")
            daemon.restart()
            print("  Server restarted.")
        elif daemon.is_installed():
            print("\nStarting server...")
            daemon.start()
            print("  Server started.")
        else:
            print("\nDaemon not installed. Run 'parachute install' for daemon support.")
    except Exception as e:
        print(f"\nCouldn't restart daemon: {e}")
        print("  Restart manually: parachute server restart")

    print("\nDone!")


# --- Server command ---


def cmd_server(args: argparse.Namespace) -> None:
    """Start/stop/restart the Parachute server daemon."""
    action = getattr(args, "action", None)

    if action == "stop":
        _server_stop()
    elif action == "restart":
        _server_restart()
    elif action == "status":
        _server_status()
    elif getattr(args, "foreground", False):
        _server_foreground()
    else:
        _server_start()


def _server_foreground() -> None:
    """Start server in foreground (dev mode)."""
    # Load config from all sources
    env = _load_env_file()
    for key, value in env.items():
        if key not in os.environ:
            os.environ[key] = value

    vault_path = _get_vault_path()
    yaml_config = _load_yaml_config(vault_path)

    port = int(os.environ.get("PORT", yaml_config.get("port", 3333)))
    host = os.environ.get("HOST", yaml_config.get("host", "0.0.0.0"))

    # Load token from .token file if not in env
    if not os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        from parachute.config import _load_token

        token = _load_token(vault_path)
        if token:
            os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = token

    if not os.environ.get("VAULT_PATH"):
        os.environ["VAULT_PATH"] = str(vault_path)

    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if not token:
        print("Warning: CLAUDE_CODE_OAUTH_TOKEN not set. Chat will not work.")
        print("Run 'parachute install' to configure.\n")

    print(f"Starting Parachute on {host}:{port} (vault: {vault_path})")

    try:
        import uvicorn
        uvicorn.run(
            "parachute.server:app",
            host=host,
            port=port,
            log_level="info",
        )
    except KeyboardInterrupt:
        print("\nServer stopped.")


def _server_start() -> None:
    """Start the server as a background daemon."""
    vault_path = _get_vault_path()
    config = _load_yaml_config(vault_path)

    try:
        from parachute.daemon import get_daemon_manager

        daemon = get_daemon_manager(vault_path, config)

        if not daemon.is_installed():
            print("Daemon not installed. Falling back to foreground mode.")
            print("Tip: Run 'parachute install' for background daemon support.\n")
            _server_foreground()
            return

        port = config.get("port", 3333)
        status = daemon.status()

        # Check if actually responding, not just loaded
        if status.get("running") or _port_in_use(port):
            try:
                _api_get(f"http://localhost:{port}/api/health")
                print(f"Server already running (PID {status.get('pid')}, port {port})")
                return
            except Exception:
                # Loaded but not responding — restart it
                print("Server loaded but not responding. Restarting...")
                daemon.stop()
                time.sleep(1)

        daemon.start()
        print(f"Server started (port {config.get('port', 3333)})")
        print("Use 'parachute logs' to view output, 'parachute server stop' to stop.")

    except Exception as e:
        print(f"Failed to start daemon: {e}")
        print("Falling back to foreground mode.\n")
        _server_foreground()


def _server_stop() -> None:
    """Stop the daemon."""
    vault_path = _get_vault_path()
    config = _load_yaml_config(vault_path)

    try:
        from parachute.daemon import get_daemon_manager

        daemon = get_daemon_manager(vault_path, config)
        daemon.stop()
        print("Server stopped.")
    except Exception as e:
        print(f"Failed to stop server: {e}")
        sys.exit(1)


def _server_restart() -> None:
    """Restart the daemon."""
    vault_path = _get_vault_path()
    config = _load_yaml_config(vault_path)

    try:
        from parachute.daemon import get_daemon_manager

        daemon = get_daemon_manager(vault_path, config)
        daemon.restart()
        print("Server restarted.")
    except Exception as e:
        print(f"Failed to restart server: {e}")
        sys.exit(1)


def _server_status() -> None:
    """Show daemon status with HTTP health correlation."""
    vault_path = _get_vault_path()
    config = _load_yaml_config(vault_path)
    port = config.get("port", 3333)

    try:
        from parachute.daemon import get_daemon_manager

        daemon = get_daemon_manager(vault_path, config)
        status = daemon.status()

        # Check actual HTTP health
        http_ok = False
        try:
            health = _api_get(f"http://localhost:{port}/api/health")
            http_ok = True
        except Exception:
            pass

        if status.get("running") and http_ok:
            print(f"Server: running (PID {status.get('pid')})")
            print(f"  Port: {port}")
        elif http_ok:
            print(f"Server: running on port {port}")
            print(f"  (not managed by daemon)")
        elif status.get("loaded") and not status.get("running"):
            print("Server: crashed")
            if status.get("last_exit"):
                print(f"  {status['last_exit']}")
            if status.get("state"):
                print(f"  State: {status['state']}")
            print("  Check logs: parachute logs")
        else:
            print("Server: not running")

        if status.get("installed") or status.get("loaded"):
            print(f"  Daemon: installed ({status.get('type', 'unknown')})")
        else:
            print("  Daemon: not installed")

    except Exception as e:
        print(f"Error checking status: {e}")


# --- Status command ---


def cmd_status(args: argparse.Namespace) -> None:
    """Show system status: vault, token, server, modules."""
    vault_path = _get_vault_path()
    server_url = _get_server_url()

    print("Parachute Status")
    print("=" * 40)

    # Vault
    vault_exists = vault_path.exists()
    print(f"\nVault: {vault_path}")
    print(f"  exists: {'yes' if vault_exists else 'NO'}")
    if vault_exists:
        modules_dir = vault_path / ".modules"
        if modules_dir.exists():
            module_count = sum(1 for d in modules_dir.iterdir() if d.is_dir())
            print(f"  modules: {module_count}")

    # Token
    from parachute.config import _load_token

    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if not token:
        token = _load_token(vault_path) or ""
    if not token:
        env = _load_env_file()
        token = env.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    print(f"\nClaude token: {'configured' if token else 'NOT SET (run: parachute install)'}")
    if token:
        print(f"  prefix: {token[:16]}...")

    # Server
    print(f"\nServer: {server_url}")
    try:
        health = _api_get(f"{server_url}/api/health?detailed=true")
        version = health.get("version", "?")
        commit = health.get("commit", "")
        uptime = health.get("uptime", 0)
        print(f"  status: running (v{version} {commit})")
        print(f"  uptime: {uptime:.0f}s")

        # Modules
        modules = health.get("modules", [])
        if modules:
            print(f"\n  Modules ({len(modules)}):")
            for m in modules:
                print(f"    {m['name']}: {m['status']}")

        # Docker
        docker = health.get("docker", {})
        if docker:
            available = docker.get("available", False)
            print(f"\n  Docker: {'available' if available else 'not available'}")
            if available:
                image_exists = docker.get("image_exists", False)
                print(f"  Sandbox image: {'ready' if image_exists else 'not built'}")
    except (URLError, OSError):
        print("  status: not running")

    print()


# --- Logs command ---


def cmd_logs(args: argparse.Namespace) -> None:
    """Tail daemon log output."""
    vault_path = _get_vault_path()
    lines = getattr(args, "lines", 50)
    follow = getattr(args, "follow", True)

    # Platform-specific log locations (must match daemon.py)
    if sys.platform == "darwin":
        log_dir = Path.home() / "Library" / "Logs" / "Parachute"
    else:
        log_dir = Path.home() / ".local" / "state" / "parachute" / "logs"
    stderr_log = log_dir / "stderr.log"
    stdout_log = log_dir / "stdout.log"

    if stderr_log.exists():
        log_file = stderr_log
    elif stdout_log.exists():
        log_file = stdout_log
    else:
        # Try systemd journal on Linux
        if sys.platform == "linux":
            cmd = ["journalctl", "--user-unit", "parachute", "-n", str(lines)]
            if follow:
                cmd.append("-f")
            try:
                subprocess.run(cmd)
                return
            except FileNotFoundError:
                pass

        print(f"No log files found at {log_dir}")
        print("Is the daemon running? Try: parachute server status")
        return

    print(f"Tailing {log_file}...\n")
    cmd = ["tail", "-n", str(lines)]
    if follow:
        cmd.append("-f")
    cmd.append(str(log_file))

    try:
        subprocess.run(cmd)
    except KeyboardInterrupt:
        pass


# --- Doctor command ---


def cmd_doctor(args: argparse.Namespace) -> None:
    """Run diagnostics and report pass/warn/fail for each check."""
    vault_path = _get_vault_path()
    config = _load_yaml_config(vault_path)
    port = config.get("port", 3333)
    results = []

    def check(name: str, fn):
        try:
            ok, detail = fn()
            status = "PASS" if ok else "WARN"
            results.append((status, name, detail))
        except Exception as e:
            results.append(("FAIL", name, str(e)))

    # 1. Python version
    def check_python():
        v = sys.version_info
        version_str = f"{v.major}.{v.minor}.{v.micro}"
        if v >= (3, 11):
            return True, version_str
        return False, f"{version_str} (requires >= 3.11)"

    check("Python version", check_python)

    # 2. Package import
    def check_package():
        try:
            import parachute  # noqa: F401
            return True, "parachute importable"
        except ImportError as e:
            return False, str(e)

    check("Package installed", check_package)

    # 3. Vault path
    def check_vault():
        if not vault_path.exists():
            return False, f"{vault_path} does not exist"
        if not os.access(vault_path, os.W_OK):
            return False, f"{vault_path} not writable"
        return True, str(vault_path)

    check("Vault path", check_vault)

    # 4. Config file
    def check_config():
        config_file = get_config_path(vault_path)
        if not config_file.exists():
            return False, "config.yaml not found (run: parachute install)"
        try:
            with open(config_file) as f:
                yaml.safe_load(f)
            return True, str(config_file)
        except Exception as e:
            return False, f"config.yaml parse error: {e}"

    check("Config file", check_config)

    # 5. Token
    def check_token():
        from parachute.config import _load_token

        token = _load_token(vault_path) or os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
        if token:
            return True, f"{token[:12]}..."
        return False, "no token found (run: parachute install)"

    check("Claude token", check_token)

    # 6. Docker
    def check_docker():
        docker_path = shutil.which("docker")
        if not docker_path:
            return False, "docker not found"
        result = subprocess.run(
            ["docker", "info"],
            capture_output=True,
            timeout=5,
        )
        if result.returncode != 0:
            return False, "docker not running"

        # Check sandbox image
        result = subprocess.run(
            ["docker", "images", "-q", "parachute-sandbox"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        has_image = bool(result.stdout.strip())
        return True, f"running, sandbox image {'ready' if has_image else 'not built'}"

    check("Docker", check_docker)

    # 7. Port availability
    def check_port():
        if _port_in_use(port):
            # Check if it's our server
            try:
                health = _api_get(f"http://localhost:{port}/api/health")
                return True, f"port {port} in use by Parachute server"
            except Exception:
                return False, f"port {port} in use by another process"
        return True, f"port {port} available"

    check("Port", check_port)

    # 8. Server reachability
    def check_server():
        try:
            health = _api_get(f"http://localhost:{port}/api/health?detailed=true")
            version = health.get("version", "?")
            return True, f"reachable (v{version})"
        except Exception:
            return False, "not reachable (is daemon running?)"

    check("Server", check_server)

    # 9. Disk space
    def check_disk():
        if vault_path.exists():
            stat = os.statvfs(vault_path)
            free_gb = (stat.f_bavail * stat.f_frsize) / (1024 ** 3)
            if free_gb < 1.0:
                return False, f"{free_gb:.1f} GB free (< 1 GB)"
            return True, f"{free_gb:.1f} GB free"
        return False, "vault path does not exist"

    check("Disk space", check_disk)

    # Print results
    print("\nParachute Doctor")
    print("=" * 40)

    for status, name, detail in results:
        icon = {"PASS": "+", "WARN": "!", "FAIL": "x"}[status]
        print(f"  [{icon}] {name}: {detail}")

    passes = sum(1 for s, _, _ in results if s == "PASS")
    warns = sum(1 for s, _, _ in results if s == "WARN")
    fails = sum(1 for s, _, _ in results if s == "FAIL")
    print(f"\n  {passes} passed, {warns} warnings, {fails} failures")

    if fails:
        sys.exit(1)


# --- Config commands ---


def cmd_config(args: argparse.Namespace) -> None:
    """Config management: show, set, get."""
    action = getattr(args, "action", None)

    if action == "show":
        _config_show()
    elif action == "set":
        _config_set(args.key, args.value)
    elif action == "get":
        _config_get(args.key)
    else:
        print("Usage: parachute config {show|set|get}")


def _config_show() -> None:
    """Show current config with effective values."""
    vault_path = _get_vault_path()
    config = _load_yaml_config(vault_path)

    print(f"\nConfig: {get_config_path(vault_path)}")
    print("-" * 40)

    if not config:
        print("  (empty — run 'parachute install' to configure)")
        return

    for key, value in config.items():
        # Mask token-like values
        display = value
        if isinstance(value, str) and ("token" in key.lower() or "key" in key.lower()):
            if len(value) > 12:
                display = value[:12] + "..."

        # Note env var overrides
        env_val = os.environ.get(key.upper()) or os.environ.get(key)
        override = f" (overridden by env: {key.upper()})" if env_val else ""
        print(f"  {key}: {display}{override}")

    # Show token status
    from parachute.config import _load_token

    token = _load_token(vault_path)
    print(f"\n  token: {'configured' if token else 'not set'} ({vault_path / '.parachute' / '.token'})")


def _config_set(key: str, value: str) -> None:
    """Set a config value."""
    if key in ("token", "claude_code_oauth_token"):
        print("Error: Use 'parachute install' to set the token, or write to .token directly.")
        sys.exit(1)

    if key not in CONFIG_KEYS:
        print(f"Unknown key: {key}")
        print(f"Valid keys: {', '.join(sorted(CONFIG_KEYS))}")
        sys.exit(1)

    vault_path = _get_vault_path()
    config = _load_yaml_config(vault_path)

    # Type conversion
    if key == "port":
        try:
            value = int(value)
        except ValueError:
            print(f"Error: port must be an integer, got '{value}'")
            sys.exit(1)
    elif key == "debug":
        value = value.lower() in ("true", "1", "yes")

    config[key] = value
    save_yaml_config(vault_path, config)
    print(f"Set {key} = {value}")
    print("Note: Restart the server for changes to take effect.")


def _config_get(key: str) -> None:
    """Get a single config value."""
    vault_path = _get_vault_path()
    config = _load_yaml_config(vault_path)

    # Check env override first
    env_val = os.environ.get(key.upper()) or os.environ.get(key)
    if env_val:
        print(env_val)
        return

    if key in config:
        print(config[key])
    else:
        print(f"Key '{key}' not set in config.yaml")
        sys.exit(1)


# --- Module commands ---


def cmd_module_list(args: argparse.Namespace) -> None:
    """List modules from vault (offline — no server needed)."""
    vault_path = _get_vault_path()
    loader = ModuleLoader(vault_path)
    modules = loader.scan_offline_status()

    if not modules:
        print("No modules found.")
        return

    modules_dir = vault_path / ".modules"
    print(f"\nModules in {modules_dir}/:\n")

    name_width = max(len(m["name"]) for m in modules)
    ver_width = max(len(m["version"]) for m in modules)

    for m in modules:
        provides_str = ", ".join(m["provides"]) if m["provides"] else "(none)"
        print(
            f"  {m['name']:<{name_width}}  "
            f"v{m['version']:<{ver_width}}  "
            f"{m['status']:<10}  "
            f"provides: {provides_str}"
        )

    # Summary
    approved = sum(1 for m in modules if m["status"] == "approved")
    new = sum(1 for m in modules if m["status"] == "new")
    modified = sum(1 for m in modules if m["status"] == "modified")

    parts = []
    if approved:
        parts.append(f"{approved} approved")
    if new:
        parts.append(f"{new} new")
    if modified:
        parts.append(f"{modified} modified")

    print(f"\nHash status: {', '.join(parts)}")


def cmd_module_approve(args: argparse.Namespace) -> None:
    """Approve a module by recording its hash (offline)."""
    vault_path = _get_vault_path()
    modules_dir = vault_path / ".modules"

    module_dir = modules_dir / args.name
    if not module_dir.exists():
        print(f"Module '{args.name}' not found at {module_dir}")
        sys.exit(1)

    current_hash = compute_module_hash(module_dir)

    # Use ModuleLoader to load/save hashes consistently
    loader = ModuleLoader(vault_path)
    known_hashes = loader._load_known_hashes()
    known_hashes[args.name] = current_hash
    loader._save_known_hashes(known_hashes)

    print(f"\nComputed hash: {current_hash[:12]}...")
    print(f"Wrote to {loader._hash_file}")
    print("Restart server to load module.")


def cmd_module_status(args: argparse.Namespace) -> None:
    """Show live server module status (requires running server)."""
    server_url = _get_server_url()

    try:
        modules_data = _api_get(f"{server_url}/api/modules")
        health_data = _api_get(f"{server_url}/api/health?detailed=true")
    except URLError:
        print(f"Cannot connect to server at {server_url}")
        print("Start the server first, or use 'module list' for offline status.")
        sys.exit(1)

    print(f"\nServer: {server_url}")
    print(f"Version: {health_data.get('version', '?')}", end="")
    if health_data.get("commit"):
        print(f" ({health_data['commit']})", end="")
    print()

    modules = modules_data.get("modules", [])
    if not modules:
        print("\nNo modules loaded.")
        return

    print(f"\nModules ({len(modules)}):\n")

    name_width = max(len(m["name"]) for m in modules)

    for m in modules:
        provides = m.get("provides", [])
        provides_str = ", ".join(provides) if provides else "(no interfaces)"
        has_router = m.get("has_router", False)
        router_str = f"/api/{m['name']}/*" if has_router else "(no routes)"

        print(
            f"  {m['name']:<{name_width}}  "
            f"{m['status']:<18}  "
            f"{provides_str:<25}  "
            f"{router_str}"
        )

    # Vault status
    vault = health_data.get("vault", {})
    if vault:
        print(f"\nVault: {vault.get('path', '?')} ({vault.get('status', '?')})")


def cmd_module_test(args: argparse.Namespace) -> None:
    """Test module endpoints (requires running server)."""
    server_url = _get_server_url()

    try:
        modules_data = _api_get(f"{server_url}/api/modules")
    except URLError:
        print(f"Cannot connect to server at {server_url}")
        print("Start the server first.")
        sys.exit(1)

    modules = modules_data.get("modules", [])

    # Filter to specific module if requested
    if args.name:
        modules = [m for m in modules if m["name"] == args.name]
        if not modules:
            print(f"Module '{args.name}' not found on server.")
            sys.exit(1)

    # Define test endpoints per module
    test_endpoints: dict[str, list[tuple[str, str, int]]] = {
        "brain": [
            ("GET", "/api/brain/search?q=test", 200),
            ("POST", "/api/brain/reload", 200),
        ],
        "daily": [
            ("GET", "/api/daily/entries", 200),
        ],
    }

    passed = 0
    failed = 0
    skipped = 0

    print()
    for m in modules:
        name = m["name"]
        has_router = m.get("has_router", False)

        if not has_router or name not in test_endpoints:
            print(f"Testing {name}...")
            print("  (no routes to test)")
            print("  SKIP\n")
            skipped += 1
            continue

        print(f"Testing {name}...")
        module_passed = True

        for method, path, expected_status in test_endpoints[name]:
            url = f"{server_url}{path}"
            try:
                if method == "GET":
                    result = _api_get(url)
                else:
                    result = _api_post(url)

                # Count items if present
                detail = ""
                if isinstance(result, dict):
                    for key in ("results", "entries", "modules", "entities"):
                        if key in result:
                            items = result[key]
                            if isinstance(items, list):
                                detail = f" ({len(items)} {key})"
                                break

                print(f"  {method} {path}  -> 200 OK{detail}")

            except Exception as e:
                print(f"  {method} {path}  -> FAILED: {e}")
                module_passed = False

        if module_passed:
            print("  PASS\n")
            passed += 1
        else:
            print("  FAIL\n")
            failed += 1

    print(f"Results: {passed} passed, {failed} failed, {skipped} skipped")
    if failed > 0:
        sys.exit(1)


# --- CLI entry point ---


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="parachute",
        description="Parachute — local-first AI computer",
    )
    subparsers = parser.add_subparsers(dest="command")

    # install
    subparsers.add_parser("install", help="First-time setup + daemon install")

    # update
    update_parser = subparsers.add_parser("update", help="Pull latest code, reinstall, restart")
    update_parser.add_argument(
        "--local", action="store_true",
        help="Skip git pull (just reinstall deps + restart)",
    )

    # status
    subparsers.add_parser("status", help="Show system status")

    # server subcommand
    server_parser = subparsers.add_parser("server", help="Server management")
    server_parser.add_argument(
        "--foreground", "-f", action="store_true",
        help="Run in foreground (dev mode)",
    )
    server_sub = server_parser.add_subparsers(dest="action")
    server_sub.add_parser("stop", help="Stop the daemon")
    server_sub.add_parser("restart", help="Restart the daemon")
    server_sub.add_parser("status", help="Show daemon status")

    # logs
    logs_parser = subparsers.add_parser("logs", help="Tail daemon logs")
    logs_parser.add_argument(
        "--lines", "-n", type=int, default=50,
        help="Number of lines to show (default: 50)",
    )
    logs_parser.add_argument(
        "--no-follow", action="store_true",
        help="Don't follow (just print and exit)",
    )

    # doctor
    subparsers.add_parser("doctor", help="Run diagnostics")

    # config subcommand
    config_parser = subparsers.add_parser("config", help="Configuration management")
    config_sub = config_parser.add_subparsers(dest="action")
    config_sub.add_parser("show", help="Show current config")
    config_set_parser = config_sub.add_parser("set", help="Set a config value")
    config_set_parser.add_argument("key", help="Config key")
    config_set_parser.add_argument("value", help="Config value")
    config_get_parser = config_sub.add_parser("get", help="Get a config value")
    config_get_parser.add_argument("key", help="Config key")

    # module subcommand
    module_parser = subparsers.add_parser("module", help="Module management")
    module_sub = module_parser.add_subparsers(dest="action")
    module_sub.add_parser("list", help="List modules (offline)")
    approve_parser = module_sub.add_parser("approve", help="Approve a module (offline)")
    approve_parser.add_argument("name", help="Module name to approve")
    module_sub.add_parser("status", help="Show live server status (online)")
    test_parser = module_sub.add_parser("test", help="Test module endpoints (online)")
    test_parser.add_argument("name", nargs="?", help="Specific module to test")

    # help (alias for --help)
    subparsers.add_parser("help", help="Show this help message")

    args = parser.parse_args()

    if args.command == "install":
        cmd_install(args)
    elif args.command == "update":
        cmd_update(args)
    elif args.command == "status":
        cmd_status(args)
    elif args.command == "server":
        cmd_server(args)
    elif args.command == "logs":
        args.follow = not getattr(args, "no_follow", False)
        cmd_logs(args)
    elif args.command == "doctor":
        cmd_doctor(args)
    elif args.command == "config":
        cmd_config(args)
    elif args.command == "module":
        if args.action == "list":
            cmd_module_list(args)
        elif args.action == "approve":
            cmd_module_approve(args)
        elif args.action == "status":
            cmd_module_status(args)
        elif args.action == "test":
            cmd_module_test(args)
        else:
            module_parser.print_help()
    else:
        parser.print_help()
