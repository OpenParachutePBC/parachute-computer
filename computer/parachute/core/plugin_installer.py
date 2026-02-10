"""
Plugin installation from GitHub URLs.

Handles cloning, validation, and lifecycle management for
Parachute-managed plugins stored in {vault}/.parachute/plugins/.
"""

import asyncio
import json
import logging
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

from parachute.core.plugins import _index_plugin
from parachute.models.plugin import InstalledPlugin

logger = logging.getLogger(__name__)


def _derive_slug(url: str) -> str:
    """Derive a plugin slug from a GitHub URL.

    Examples:
        https://github.com/EveryInc/compound-engineering-plugin → compound-engineering-plugin
        https://github.com/user/my-plugin.git → my-plugin
    """
    parsed = urlparse(url)
    path = parsed.path.rstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    slug = path.split("/")[-1]
    # Sanitize: only allow alphanumeric, hyphens, underscores
    slug = re.sub(r'[^a-zA-Z0-9_-]', '-', slug).strip('-')
    return slug or "plugin"


async def install_plugin_from_url(
    vault_path: Path,
    url: str,
    slug: Optional[str] = None,
) -> InstalledPlugin:
    """Clone a plugin from a Git URL.

    Args:
        vault_path: Path to the vault directory
        url: Git-cloneable URL (https://github.com/org/repo or similar)
        slug: Optional custom slug (defaults to repo name)

    Returns:
        The installed and indexed plugin

    Raises:
        ValueError: If URL is invalid or plugin structure is invalid
        RuntimeError: If git clone fails
    """
    if not slug:
        slug = _derive_slug(url)

    plugins_dir = vault_path / ".parachute" / "plugins"
    plugins_dir.mkdir(parents=True, exist_ok=True)
    target_dir = plugins_dir / slug

    if target_dir.exists():
        raise ValueError(f"Plugin '{slug}' is already installed at {target_dir}")

    # Shallow clone for speed
    logger.info(f"Installing plugin from {url} as '{slug}'")
    proc = await asyncio.create_subprocess_exec(
        "git", "clone", "--depth", "1", url, str(target_dir),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)

    if proc.returncode != 0:
        # Clean up partial clone
        if target_dir.exists():
            shutil.rmtree(target_dir, ignore_errors=True)
        error_msg = stderr.decode().strip() if stderr else "Unknown error"
        raise RuntimeError(f"Git clone failed: {error_msg}")

    # Validate plugin structure
    manifest_path = target_dir / ".claude-plugin" / "plugin.json"
    if not manifest_path.exists():
        shutil.rmtree(target_dir, ignore_errors=True)
        raise ValueError(
            f"Not a valid plugin: {url} — missing .claude-plugin/plugin.json"
        )

    # Write install metadata into manifest
    try:
        manifest = json.loads(manifest_path.read_text())
        manifest["source_url"] = url
        manifest["installed_at"] = datetime.now(timezone.utc).isoformat()
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    except (json.JSONDecodeError, OSError) as e:
        logger.warning(f"Failed to update manifest with install metadata: {e}")

    # Index the plugin
    plugin = _index_plugin(target_dir, source="parachute")
    if not plugin:
        shutil.rmtree(target_dir, ignore_errors=True)
        raise ValueError(f"Failed to index plugin at {target_dir}")

    logger.info(
        f"Installed plugin '{plugin.name}' v{plugin.version}: "
        f"{len(plugin.skills)} skills, {len(plugin.agents)} agents, "
        f"{len(plugin.mcps)} MCPs"
    )
    return plugin


async def uninstall_plugin(vault_path: Path, slug: str) -> bool:
    """Remove a Parachute-managed plugin.

    Only removes plugins from {vault}/.parachute/plugins/.
    Will not touch user plugins in ~/.claude/plugins/.

    Returns:
        True if plugin was removed
    """
    plugin_dir = vault_path / ".parachute" / "plugins" / slug
    if not plugin_dir.exists():
        return False

    # Safety check: must be within the expected directory
    try:
        plugin_dir.resolve().relative_to((vault_path / ".parachute" / "plugins").resolve())
    except ValueError:
        logger.error(f"Refusing to delete plugin outside expected directory: {plugin_dir}")
        return False

    shutil.rmtree(plugin_dir)
    logger.info(f"Uninstalled plugin: {slug}")
    return True


async def update_plugin(vault_path: Path, slug: str) -> InstalledPlugin:
    """Pull latest changes for an installed plugin.

    Returns:
        The re-indexed plugin

    Raises:
        ValueError: If plugin not found or not git-managed
        RuntimeError: If git pull fails
    """
    plugin_dir = vault_path / ".parachute" / "plugins" / slug
    if not plugin_dir.exists():
        raise ValueError(f"Plugin '{slug}' not found")

    if not (plugin_dir / ".git").exists():
        raise ValueError(f"Plugin '{slug}' is not git-managed, cannot update")

    proc = await asyncio.create_subprocess_exec(
        "git", "-C", str(plugin_dir), "pull", "--ff-only",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)

    if proc.returncode != 0:
        error_msg = stderr.decode().strip() if stderr else "Unknown error"
        raise RuntimeError(f"Git pull failed: {error_msg}")

    # Re-index
    plugin = _index_plugin(plugin_dir, source="parachute")
    if not plugin:
        raise ValueError(f"Failed to re-index plugin after update: {slug}")

    logger.info(f"Updated plugin '{plugin.name}' to v{plugin.version}")
    return plugin


async def check_plugin_update(vault_path: Path, slug: str) -> Optional[dict]:
    """Check if a newer version is available.

    Returns:
        None if up to date, or {"behind": N, "slug": slug} if updates available
    """
    plugin_dir = vault_path / ".parachute" / "plugins" / slug
    if not plugin_dir.exists() or not (plugin_dir / ".git").exists():
        return None

    # Fetch without merging
    proc = await asyncio.create_subprocess_exec(
        "git", "-C", str(plugin_dir), "fetch", "--dry-run",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30)

    # Check if there are new commits
    proc2 = await asyncio.create_subprocess_exec(
        "git", "-C", str(plugin_dir),
        "rev-list", "--count", "HEAD..@{u}",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout2, _ = await asyncio.wait_for(proc2.communicate(), timeout=10)

    if proc2.returncode != 0:
        return None

    behind = int(stdout2.decode().strip() or "0")
    if behind > 0:
        return {"behind": behind, "slug": slug}

    return None
