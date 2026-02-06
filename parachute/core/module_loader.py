"""
Module loader for Parachute modular architecture.

Discovers and loads modules from vault/.modules/ directory.
Each module has a manifest.yaml and a module.py entry point.

Includes hash verification to prevent unauthorized module modifications.
On hash mismatch, modules are blocked from loading until approved.
"""

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
        self.modules_dir = vault_path / ".modules"
        self._hash_file = vault_path / ".parachute" / "module_hashes.json"
        self._known_hashes: dict[str, str] = {}
        self._pending_approval: dict[str, dict] = {}  # name -> {hash, path}

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
        """Approve a pending module by recording its current hash."""
        if name not in self._pending_approval:
            return False
        info = self._pending_approval.pop(name)
        self._known_hashes[name] = info["hash"]
        self._save_known_hashes(self._known_hashes)
        logger.info(f"Module approved: {name} (hash: {info['hash'][:12]}...)")
        return True

    async def discover_and_load(self) -> dict[str, Any]:
        """Discover and load all modules from vault/.modules/"""
        from parachute.core.interfaces import get_registry
        registry = get_registry()
        modules = {}

        if not self.modules_dir.exists():
            logger.info("No .modules directory found")
            return modules

        self._known_hashes = self._load_known_hashes()

        for module_dir in sorted(self.modules_dir.iterdir()):
            if not module_dir.is_dir():
                continue

            manifest_path = module_dir / "manifest.yaml"
            if not manifest_path.exists():
                continue

            # Read manifest to get module name for hash check
            try:
                with open(manifest_path) as f:
                    manifest = yaml.safe_load(f)
                name = manifest.get("name", module_dir.name)
            except Exception:
                name = module_dir.name

            # Hash verification
            current_hash = compute_module_hash(module_dir)
            known_hash = self._known_hashes.get(name)

            if known_hash is None:
                # First time seeing this module - auto-approve and record hash
                self._known_hashes[name] = current_hash
                self._save_known_hashes(self._known_hashes)
                logger.info(f"New module registered: {name} (hash: {current_hash[:12]}...)")
            elif not verify_module(module_dir, known_hash):
                # Hash mismatch - block module
                logger.warning(
                    f"Module '{name}' hash mismatch! "
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
                    logger.info(f"Loaded module: {module.name}")

                    for interface_name in getattr(module, 'provides', []):
                        registry.publish(interface_name, module)
                        logger.info(f"Published interface: {interface_name} from {module.name}")

            except Exception as e:
                logger.error(f"Failed to load module from {module_dir}: {e}")

        return modules

    async def _load_module(self, module_dir: Path, manifest_path: Path) -> Any:
        """Load a single module from its directory."""
        with open(manifest_path) as f:
            manifest = yaml.safe_load(f)

        name = manifest.get("name")
        module_file = manifest.get("module", "module.py")
        module_path = module_dir / module_file

        if not module_path.exists():
            raise FileNotFoundError(f"Module file not found: {module_path}")

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
                return instance

        raise ValueError(f"No Module class found in {module_path}")

    def get_module_status(self) -> list[dict]:
        """Return status of all known modules (for /api/modules endpoint)."""
        status = []
        for name, hash_val in self._known_hashes.items():
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
