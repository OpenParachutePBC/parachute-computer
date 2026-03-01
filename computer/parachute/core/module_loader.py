"""
Module loader for Parachute modular architecture.

Discovers and loads modules from two locations:

1. Built-in modules (computer/modules/) — always loaded from source, no hash check.
   These ship with the codebase (brain, chat, daily) and are inherently trusted.

2. Vault modules (vault/.modules/) — user-installed third-party modules.
   Subject to hash verification and approval before loading.

On hash mismatch for vault modules, the module is blocked until approved via API.
"""

import asyncio
import hashlib
import importlib.util
import json
import logging
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)


def compute_module_hash(module_dir: Path) -> str:
    """SHA-256 hash of all Python files + manifest in a module directory."""
    hasher = hashlib.sha256()
    for py_file in sorted(module_dir.glob("**/*.py")):
        hasher.update(py_file.read_bytes())
    manifest = module_dir / "manifest.yaml"
    if manifest.exists():
        hasher.update(manifest.read_bytes())
    return hasher.hexdigest()


def verify_module(module_dir: Path, known_hash: str) -> bool:
    """Check if module code matches a known-good hash."""
    return compute_module_hash(module_dir) == known_hash


class ModuleLoader:
    def __init__(self, vault_path: Path):
        self.vault_path = vault_path
        self.builtin_dir = Path(__file__).parent.parent.parent / "modules"
        self.modules_dir = vault_path / ".modules"
        self._hash_file = vault_path / ".parachute" / "module_hashes.json"
        self._known_hashes: dict[str, str] = {}
        self._pending_approval: dict[str, dict] = {}  # name -> {hash, path}
        self._builtin_names: set[str] = set()  # names loaded from builtin_dir

    def _load_known_hashes(self) -> dict[str, str]:
        """Load known-good module hashes from vault/.parachute/module_hashes.json."""
        if self._hash_file.exists():
            try:
                return json.loads(self._hash_file.read_text())
            except (json.JSONDecodeError, OSError) as e:
                logger.warning(f"Failed to read module hashes: {e}")
        return {}

    def _save_known_hashes(self, hashes: dict[str, str]) -> None:
        """Save known-good module hashes."""
        self._hash_file.parent.mkdir(parents=True, exist_ok=True)
        self._hash_file.write_text(json.dumps(hashes, indent=2))

    def approve_module(self, name: str) -> bool:
        """Approve a pending vault module by recording its current hash."""
        if name in self._builtin_names:
            return False  # built-ins don't need approval
        if name not in self._pending_approval:
            return False
        info = self._pending_approval.pop(name)
        self._known_hashes[name] = info["hash"]
        self._save_known_hashes(self._known_hashes)
        logger.info(f"Vault module approved: {name} (hash: {info['hash'][:12]}...)")
        return True

    async def discover_and_load(self) -> dict[str, Any]:
        """Discover and load all modules.

        Built-in modules (computer/modules/) load first from source, no hash check.
        Vault modules (vault/.modules/) load second with hash verification.
        """
        from parachute.core.interfaces import get_registry
        registry = get_registry()
        modules: dict[str, Any] = {}

        # Step 1: Load built-in modules from source (always trusted, no hash)
        if not self.builtin_dir.exists():
            logger.warning(
                f"Built-in module directory not found: {self.builtin_dir}. "
                f"No built-in modules will be loaded. "
                f"Check that the server is running from the correct directory."
            )
        if self.builtin_dir.exists():
            for module_dir in sorted(self.builtin_dir.iterdir()):
                if not module_dir.is_dir():
                    continue
                manifest_path = module_dir / "manifest.yaml"
                if not manifest_path.exists():
                    continue
                try:
                    with open(manifest_path) as f:
                        manifest = yaml.safe_load(f)
                    name = manifest.get("name", module_dir.name)
                    module = await self._load_module(module_dir, manifest_path)
                    if module:
                        modules[name] = module
                        self._builtin_names.add(name)
                        logger.info(f"Loaded built-in module: {name}")
                        for interface_name in getattr(module, 'provides', []):
                            registry.publish(interface_name, module)
                            logger.info(f"Published interface: {interface_name} from {name}")
                except Exception as e:
                    logger.error(f"Failed to load built-in module from {module_dir}: {e}")

        # Step 2: Load vault (user-installed) modules with hash verification
        if not self.modules_dir.exists():
            return modules

        self._known_hashes = self._load_known_hashes()

        for module_dir in sorted(self.modules_dir.iterdir()):
            if not module_dir.is_dir():
                continue
            manifest_path = module_dir / "manifest.yaml"
            if not manifest_path.exists():
                continue

            try:
                with open(manifest_path) as f:
                    manifest = yaml.safe_load(f)
                name = manifest.get("name", module_dir.name)
            except Exception:
                name = module_dir.name

            # Skip if already loaded as a built-in
            if name in modules:
                continue

            # Hash verification for vault modules
            current_hash = compute_module_hash(module_dir)
            known_hash = self._known_hashes.get(name)

            if known_hash is None:
                # First time — auto-approve and record
                self._known_hashes[name] = current_hash
                self._save_known_hashes(self._known_hashes)
                logger.info(f"New vault module registered: {name} (hash: {current_hash[:12]}...)")
            elif not verify_module(module_dir, known_hash):
                logger.warning(
                    f"Vault module '{name}' hash mismatch! "
                    f"Expected {known_hash[:12]}..., got {current_hash[:12]}... "
                    f"Module blocked pending approval."
                )
                self._pending_approval[name] = {
                    "hash": current_hash,
                    "path": str(module_dir),
                }
                continue

            try:
                module = await self._load_module(module_dir, manifest_path)
                if module:
                    modules[module.name] = module
                    logger.info(f"Loaded vault module: {module.name}")
                    for interface_name in getattr(module, 'provides', []):
                        registry.publish(interface_name, module)
                        logger.info(f"Published interface: {interface_name} from {module.name}")
            except Exception as e:
                logger.error(f"Failed to load vault module from {module_dir}: {e}")

        return modules

    async def _load_module(self, module_dir: Path, manifest_path: Path) -> Any:
        """Load a single module from its directory.

        Supports both single-file modules and multi-file packages (with __init__.py).
        Multi-file packages can use relative imports (e.g., from .models import ...).
        """
        import sys

        with open(manifest_path) as f:
            manifest = yaml.safe_load(f)

        name = manifest.get("name")
        module_file = manifest.get("module", "module.py")
        module_path = module_dir / module_file

        if not module_path.exists():
            raise FileNotFoundError(f"Module file not found: {module_path}")

        init_py = module_dir / "__init__.py"
        is_package = init_py.exists()

        if is_package:
            # Multi-file package: register parent dir on sys.path and set up package
            parent = str(module_dir.parent)
            if parent not in sys.path:
                sys.path.insert(0, parent)

            package_name = module_dir.name

            # Register the package so relative imports resolve
            pkg_spec = importlib.util.spec_from_file_location(
                package_name,
                str(init_py),
                submodule_search_locations=[str(module_dir)],
            )
            if not pkg_spec or not pkg_spec.loader:
                raise ImportError(f"Cannot load package: {init_py}")

            pkg = importlib.util.module_from_spec(pkg_spec)
            sys.modules[package_name] = pkg
            pkg_spec.loader.exec_module(pkg)

            # Load the module entry point as a submodule
            module_stem = module_file.removesuffix(".py")
            module_fqn = f"{package_name}.{module_stem}"
            spec = importlib.util.spec_from_file_location(module_fqn, module_path)
            if not spec or not spec.loader:
                raise ImportError(f"Cannot load module: {module_path}")

            py_module = importlib.util.module_from_spec(spec)
            sys.modules[module_fqn] = py_module
            spec.loader.exec_module(py_module)
        else:
            # Single-file module
            spec = importlib.util.spec_from_file_location(name, module_path)
            if not spec or not spec.loader:
                raise ImportError(f"Cannot load module: {module_path}")

            py_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(py_module)

        # Find the Module class
        for attr_name in dir(py_module):
            attr = getattr(py_module, attr_name)
            if isinstance(attr, type) and hasattr(attr, 'name') and attr.name == name:
                instance = attr(vault_path=self.vault_path)
                instance.manifest = manifest
                if hasattr(instance, 'on_load') and asyncio.iscoroutinefunction(instance.on_load):
                    await instance.on_load()
                return instance

        raise ValueError(f"No Module class found in {module_path}")

    def scan_offline_status(self) -> list[dict]:
        """Scan modules from disk without loading them (for CLI offline use)."""
        results = []

        # Built-in modules
        if self.builtin_dir.exists():
            for module_dir in sorted(self.builtin_dir.iterdir()):
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
                results.append({
                    "name": name,
                    "version": manifest.get("version", "?"),
                    "status": "builtin",
                    "provides": manifest.get("provides", []),
                    "trust_level": manifest.get("trust_level", "direct"),
                    "description": manifest.get("description", ""),
                    "hash": compute_module_hash(module_dir)[:12],
                })

        # Vault modules
        if self.modules_dir.exists():
            known_hashes = self._load_known_hashes()
            builtin_names = {r["name"] for r in results}
            for module_dir in sorted(self.modules_dir.iterdir()):
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
                if name in builtin_names:
                    continue
                current_hash = compute_module_hash(module_dir)
                known_hash = known_hashes.get(name)
                if known_hash is None:
                    status = "new"
                elif known_hash == current_hash:
                    status = "approved"
                else:
                    status = "modified"
                results.append({
                    "name": name,
                    "version": manifest.get("version", "?"),
                    "status": status,
                    "provides": manifest.get("provides", []),
                    "trust_level": manifest.get("trust_level", "direct"),
                    "description": manifest.get("description", ""),
                    "hash": current_hash[:12],
                })

        return results

    def get_module_status(self) -> list[dict]:
        """Return status of all known modules (for /api/modules endpoint)."""
        status = []

        # Built-in modules — always loaded, no hash dance
        for name in sorted(self._builtin_names):
            status.append({
                "name": name,
                "status": "loaded",
                "source": "builtin",
            })

        # Vault modules
        for name, hash_val in self._known_hashes.items():
            if name in self._builtin_names:
                continue  # already listed
            if name in self._pending_approval:
                status.append({
                    "name": name,
                    "status": "pending_approval",
                    "current_hash": self._pending_approval[name]["hash"][:12],
                    "known_hash": hash_val[:12],
                })
            else:
                status.append({
                    "name": name,
                    "status": "loaded",
                    "hash": hash_val[:12],
                })

        return status
