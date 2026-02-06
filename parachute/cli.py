"""
Parachute CLI for module management.

Usage:
    python -m parachute module list          # List modules (offline)
    python -m parachute module approve NAME  # Approve a module (offline)
    python -m parachute module status        # Show live server status (online)
    python -m parachute module test [NAME]   # Test module endpoints (online)
"""

import argparse
import json
import sys
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

import yaml

from parachute.core.module_loader import compute_module_hash


def _get_vault_path() -> Path:
    """Resolve vault path from VAULT_PATH env or default."""
    import os

    path = os.environ.get("VAULT_PATH", "./vault")
    return Path(path).resolve()


def _get_server_url() -> str:
    """Resolve server URL from PORT env or default."""
    import os

    port = os.environ.get("PORT", "3336")
    return f"http://localhost:{port}"


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


# --- Offline commands ---


def cmd_module_list(args: argparse.Namespace) -> None:
    """List modules from vault (offline — no server needed)."""
    vault_path = _get_vault_path()
    modules_dir = vault_path / ".modules"
    hash_file = vault_path / ".parachute" / "module_hashes.json"

    if not modules_dir.exists():
        print(f"No .modules directory at {modules_dir}")
        sys.exit(1)

    # Load known hashes
    known_hashes: dict[str, str] = {}
    if hash_file.exists():
        try:
            known_hashes = json.loads(hash_file.read_text())
        except (json.JSONDecodeError, OSError):
            pass

    # Scan modules
    modules = []
    for module_dir in sorted(modules_dir.iterdir()):
        if not module_dir.is_dir():
            continue

        manifest_path = module_dir / "manifest.yaml"
        if not manifest_path.exists():
            continue

        try:
            with open(manifest_path) as f:
                manifest = yaml.safe_load(f)
        except Exception:
            manifest = {}

        name = manifest.get("name", module_dir.name)
        version = manifest.get("version", "?")
        description = manifest.get("description", "")
        provides = manifest.get("provides", [])

        current_hash = compute_module_hash(module_dir)
        known_hash = known_hashes.get(name)

        if known_hash is None:
            status = "new"
        elif known_hash == current_hash:
            status = "approved"
        else:
            status = "modified"

        modules.append({
            "name": name,
            "version": version,
            "status": status,
            "provides": provides,
            "description": description,
            "hash": current_hash[:12],
        })

    if not modules:
        print("No modules found.")
        return

    # Display
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
    hash_file = vault_path / ".parachute" / "module_hashes.json"

    module_dir = modules_dir / args.name
    if not module_dir.exists():
        print(f"Module '{args.name}' not found at {module_dir}")
        sys.exit(1)

    current_hash = compute_module_hash(module_dir)

    # Load existing hashes
    known_hashes: dict[str, str] = {}
    if hash_file.exists():
        try:
            known_hashes = json.loads(hash_file.read_text())
        except (json.JSONDecodeError, OSError):
            pass

    known_hashes[args.name] = current_hash
    hash_file.parent.mkdir(parents=True, exist_ok=True)
    hash_file.write_text(json.dumps(known_hashes, indent=2))

    print(f"\nComputed hash: {current_hash[:12]}...")
    print(f"Wrote to {hash_file}")
    print("Restart server to load module.")


# --- Online commands ---


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
        description="Parachute module management CLI",
    )
    subparsers = parser.add_subparsers(dest="command")

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

    if args.command == "module":
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
