"""
Parachute CLI.

Usage:
    parachute setup                    # Configure vault path and Claude token
    parachute status                   # System overview (offline + online)
    parachute server                   # Start the server
    parachute module list              # List modules (offline)
    parachute module approve NAME      # Approve a module (offline)
    parachute module status            # Show live server status (online)
    parachute module test [NAME]       # Test module endpoints (online)
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

from parachute.core.module_loader import ModuleLoader, compute_module_hash


# --- Helpers ---


def _get_vault_path() -> Path:
    """Resolve vault path from VAULT_PATH env or default."""
    path = os.environ.get("VAULT_PATH", "./vault")
    return Path(path).resolve()


def _get_server_url() -> str:
    """Resolve server URL from PORT env or default."""
    port = os.environ.get("PORT", "3336")
    return f"http://localhost:{port}"


def _get_env_file() -> Path:
    """Get the .env file path (next to the vault)."""
    vault = _get_vault_path()
    # .env lives in the server working directory
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


# --- Top-level commands ---


def cmd_setup(args: argparse.Namespace) -> None:
    """Interactive setup: vault path, Claude token."""
    print("Parachute Setup")
    print("=" * 40)

    env = _load_env_file()

    # 1. Vault path
    current_vault = env.get("VAULT_PATH", os.environ.get("VAULT_PATH", ""))
    print(f"\nVault path [{current_vault or './vault'}]: ", end="")
    vault_input = input().strip()
    if vault_input:
        env["VAULT_PATH"] = vault_input
    elif not current_vault:
        env["VAULT_PATH"] = "./vault"

    vault_path = Path(env.get("VAULT_PATH", "./vault")).resolve()

    # Ensure vault exists
    vault_path.mkdir(parents=True, exist_ok=True)
    (vault_path / ".parachute").mkdir(exist_ok=True)
    print(f"  Vault: {vault_path}")

    # 2. Port
    current_port = env.get("PORT", os.environ.get("PORT", ""))
    print(f"\nServer port [{current_port or '3336'}]: ", end="")
    port_input = input().strip()
    if port_input:
        env["PORT"] = port_input
    elif not current_port:
        env["PORT"] = "3336"

    # 3. Claude token
    current_token = env.get("CLAUDE_CODE_OAUTH_TOKEN", os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", ""))
    has_token = bool(current_token)

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
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            print("  Token saved.")
        else:
            print("  Skipped (you can set this later).")

    # 4. Docker/container runtime detection
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

    # Save
    env_file = _save_env_file(env)
    print(f"\nConfig written to {env_file}")
    print("\nStart the server with: parachute server")


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
    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if not token:
        # Check .env file
        env = _load_env_file()
        token = env.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    print(f"\nClaude token: {'configured' if token else 'NOT SET (run: parachute setup)'}")
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


def cmd_server(args: argparse.Namespace) -> None:
    """Start the Parachute server."""
    # Load .env into environment if it exists
    env = _load_env_file()
    for key, value in env.items():
        if key not in os.environ:
            os.environ[key] = value

    vault_path = os.environ.get("VAULT_PATH", "./vault")
    port = os.environ.get("PORT", "3336")
    host = os.environ.get("HOST", "127.0.0.1")

    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if not token:
        print("Warning: CLAUDE_CODE_OAUTH_TOKEN not set. Chat will not work.")
        print("Run 'parachute setup' to configure.\n")

    print(f"Starting Parachute on {host}:{port} (vault: {vault_path})")

    try:
        import uvicorn
        uvicorn.run(
            "parachute.server:app",
            host=host,
            port=int(port),
            log_level="info",
        )
    except KeyboardInterrupt:
        print("\nServer stopped.")


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

    # setup
    subparsers.add_parser("setup", help="Configure vault path and Claude token")

    # status
    subparsers.add_parser("status", help="Show system status")

    # server
    subparsers.add_parser("server", help="Start the server")

    # module subcommand
    module_parser = subparsers.add_parser("module", help="Module management")
    module_sub = module_parser.add_subparsers(dest="action")

    # module list
    module_sub.add_parser("list", help="List modules (offline)")

    # module approve
    approve_parser = module_sub.add_parser("approve", help="Approve a module (offline)")
    approve_parser.add_argument("name", help="Module name to approve")

    # module status
    module_sub.add_parser("status", help="Show live server status (online)")

    # module test
    test_parser = module_sub.add_parser("test", help="Test module endpoints (online)")
    test_parser.add_argument("name", nargs="?", help="Specific module to test")

    args = parser.parse_args()

    if args.command == "setup":
        cmd_setup(args)
    elif args.command == "status":
        cmd_status(args)
    elif args.command == "server":
        cmd_server(args)
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
