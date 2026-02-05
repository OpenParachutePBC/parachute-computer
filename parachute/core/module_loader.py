"""
Module loader for Parachute modular architecture.

Discovers and loads modules from vault/.modules/ directory.
Each module has a manifest.yaml and a module.py entry point.
"""

import importlib.util
import logging
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)


class ModuleLoader:
    def __init__(self, vault_path: Path):
        self.vault_path = vault_path
        self.modules_dir = vault_path / ".modules"

    async def discover_and_load(self) -> dict[str, Any]:
        """Discover and load all modules from vault/.modules/"""
        from parachute.core.interfaces import get_registry
        registry = get_registry()
        modules = {}

        if not self.modules_dir.exists():
            logger.info("No .modules directory found")
            return modules

        for module_dir in sorted(self.modules_dir.iterdir()):
            if not module_dir.is_dir():
                continue

            manifest_path = module_dir / "manifest.yaml"
            if not manifest_path.exists():
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
