"""
Plugin installation from GitHub URLs.

Plugins are git repos with SDK-layout files. Parachute installs them by
copying content to vault standard locations and writing an install manifest
for tracking/uninstall.

SDK-layout plugin structure:
    my-plugin/
    ├── .claude/agents/       # → vault/.claude/agents/ (prefixed)
    ├── .mcp.json             # → merged into vault/.mcp.json
    ├── skills/               # → vault/.skills/ (prefixed)
    ├── CLAUDE.md             # Informational only (not copied)
    └── plugin.json           # Optional metadata (name, version, author)
"""

import asyncio
import json
import logging
import os
import re
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Manifest helpers
# ---------------------------------------------------------------------------

def _read_plugin_manifests_dir(vault_path: Path) -> Path:
    """Return the plugin manifests directory, creating if needed."""
    d = vault_path / ".parachute" / "plugin-manifests"
    d.mkdir(parents=True, exist_ok=True)
    return d


def get_install_manifest(vault_path: Path, slug: str) -> Optional[dict[str, Any]]:
    """Read an install manifest for a plugin. Returns None if not found."""
    path = _read_plugin_manifests_dir(vault_path) / f"{slug}.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        logger.warning(f"Failed to read manifest for '{slug}': {e}")
        return None


def list_install_manifests(vault_path: Path) -> list[dict[str, Any]]:
    """List all install manifests."""
    manifests_dir = _read_plugin_manifests_dir(vault_path)
    results: list[dict[str, Any]] = []
    for f in sorted(manifests_dir.iterdir()):
        if f.suffix == ".json":
            try:
                results.append(json.loads(f.read_text(encoding="utf-8")))
            except (json.JSONDecodeError, OSError):
                pass
    return results


def _write_manifest(vault_path: Path, manifest: dict[str, Any]) -> None:
    """Atomically write an install manifest."""
    manifests_dir = _read_plugin_manifests_dir(vault_path)
    target = manifests_dir / f"{manifest['slug']}.json"
    content = json.dumps(manifest, indent=2) + "\n"

    fd, tmp_path = tempfile.mkstemp(dir=manifests_dir, suffix=".tmp", prefix=".manifest-")
    closed = False
    try:
        os.write(fd, content.encode("utf-8"))
        os.fsync(fd)
        os.close(fd)
        closed = True
        os.rename(tmp_path, target)
    except Exception:
        if not closed:
            os.close(fd)
        if Path(tmp_path).exists():
            os.unlink(tmp_path)
        raise


# ---------------------------------------------------------------------------
# Metadata reading
# ---------------------------------------------------------------------------

def _read_plugin_metadata(plugin_dir: Path, slug: str) -> dict[str, Any]:
    """Read plugin metadata from plugin.json (root) or .claude-plugin/plugin.json (legacy).

    Returns a dict with name, version, description, author.
    Falls back to slug-derived defaults if no metadata file is found.
    """
    meta: dict[str, Any] = {
        "name": slug,
        "version": "0.0.0",
        "description": "",
        "author": None,
    }

    # Try root plugin.json first (new convention)
    root_manifest = plugin_dir / "plugin.json"
    legacy_manifest = plugin_dir / ".claude-plugin" / "plugin.json"

    manifest_path = None
    if root_manifest.exists():
        manifest_path = root_manifest
    elif legacy_manifest.exists():
        manifest_path = legacy_manifest

    if manifest_path:
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
            meta["name"] = data.get("name") or slug
            meta["version"] = data.get("version", "0.0.0")
            meta["description"] = data.get("description", "")
            author = data.get("author")
            if isinstance(author, str):
                meta["author"] = author
            elif isinstance(author, dict):
                meta["author"] = author.get("name")
        except (json.JSONDecodeError, OSError) as e:
            logger.warning(f"Failed to read plugin metadata at {manifest_path}: {e}")

    return meta


# ---------------------------------------------------------------------------
# Content scanning
# ---------------------------------------------------------------------------

def _scan_plugin_content(plugin_dir: Path) -> dict[str, list[str]]:
    """Scan a plugin directory for SDK-layout content.

    Returns dict with keys: agents, skills, mcps (list of relative paths/names).
    """
    content: dict[str, list[str]] = {"agents": [], "skills": [], "mcps": []}

    # Agents: .claude/agents/*.md
    agents_dir = plugin_dir / ".claude" / "agents"
    if agents_dir.is_dir():
        for f in agents_dir.rglob("*.md"):
            content["agents"].append(str(f.relative_to(agents_dir)))

    # Skills: skills/*.md or skills/*/SKILL.md
    skills_dir = plugin_dir / "skills"
    if skills_dir.is_dir():
        for entry in skills_dir.iterdir():
            if entry.is_file() and entry.suffix == ".md":
                content["skills"].append(entry.stem)
            elif entry.is_dir():
                if (entry / "SKILL.md").exists() or (entry / "index.md").exists():
                    content["skills"].append(entry.name)

    # MCPs: .mcp.json
    mcp_json = plugin_dir / ".mcp.json"
    if mcp_json.exists():
        try:
            data = json.loads(mcp_json.read_text(encoding="utf-8"))
            servers = data.get("mcpServers", {})
            if isinstance(servers, dict):
                content["mcps"] = list(servers.keys())
        except (json.JSONDecodeError, OSError):
            pass

    return content


# ---------------------------------------------------------------------------
# Conflict checking
# ---------------------------------------------------------------------------

def _check_conflicts(
    vault_path: Path,
    slug: str,
    content: dict[str, list[str]],
    plugin_dir: Path,
) -> list[str]:
    """Check for name conflicts with existing vault content.

    Returns list of conflict descriptions (empty = no conflicts).
    """
    conflicts: list[str] = []
    prefix = f"plugin-{slug}-"

    # Check agent name conflicts
    agents_dir = vault_path / ".claude" / "agents"
    for agent_rel in content["agents"]:
        target_name = f"{prefix}{Path(agent_rel).stem}.md"
        if (agents_dir / target_name).exists():
            conflicts.append(f"Agent file already exists: .claude/agents/{target_name}")

    # Check skill name conflicts
    skills_dir = vault_path / ".skills"
    for skill_name in content["skills"]:
        target_name = f"{prefix}{skill_name}"
        if (skills_dir / f"{target_name}.md").exists():
            conflicts.append(f"Skill file already exists: .skills/{target_name}.md")
        if (skills_dir / target_name).is_dir():
            conflicts.append(f"Skill directory already exists: .skills/{target_name}/")

    # Check MCP name conflicts
    if content["mcps"]:
        mcp_path = vault_path / ".mcp.json"
        if mcp_path.exists():
            try:
                existing = json.loads(mcp_path.read_text(encoding="utf-8"))
                existing_servers = existing.get("mcpServers", {})
                for mcp_name in content["mcps"]:
                    if mcp_name in existing_servers:
                        conflicts.append(f"MCP server already configured: {mcp_name}")
            except (json.JSONDecodeError, OSError):
                pass

    return conflicts


# ---------------------------------------------------------------------------
# File installation
# ---------------------------------------------------------------------------

def _install_files(
    vault_path: Path,
    slug: str,
    plugin_dir: Path,
    content: dict[str, list[str]],
) -> dict[str, list[str]]:
    """Copy plugin files to vault standard locations.

    Returns a dict of installed file paths (relative to vault) keyed by type.
    Raises on failure (caller should roll back).
    """
    installed: dict[str, list[str]] = {"agents": [], "skills": [], "mcps": []}
    prefix = f"plugin-{slug}-"

    # Copy agents
    src_agents = plugin_dir / ".claude" / "agents"
    dst_agents = vault_path / ".claude" / "agents"
    if src_agents.is_dir() and content["agents"]:
        dst_agents.mkdir(parents=True, exist_ok=True)
        for agent_rel in content["agents"]:
            src = src_agents / agent_rel
            # Flatten nested agents into prefixed names
            flat_name = agent_rel.replace("/", "-").replace("\\", "-")
            if not flat_name.startswith(prefix):
                flat_name = f"{prefix}{flat_name}"
            dst = dst_agents / flat_name
            shutil.copy2(src, dst)
            installed["agents"].append(f".claude/agents/{flat_name}")
            logger.debug(f"Installed agent: {flat_name}")

    # Copy skills
    src_skills = plugin_dir / "skills"
    dst_skills = vault_path / ".skills"
    if src_skills.is_dir() and content["skills"]:
        dst_skills.mkdir(parents=True, exist_ok=True)
        for skill_name in content["skills"]:
            src_file = src_skills / f"{skill_name}.md"
            src_dir = src_skills / skill_name

            target_name = f"{prefix}{skill_name}"
            if src_file.is_file():
                # Single-file skill
                dst = dst_skills / f"{target_name}.md"
                shutil.copy2(src_file, dst)
                installed["skills"].append(f".skills/{target_name}.md")
            elif src_dir.is_dir():
                # Directory skill
                dst = dst_skills / target_name
                shutil.copytree(src_dir, dst)
                installed["skills"].append(f".skills/{target_name}/")
            logger.debug(f"Installed skill: {target_name}")

    # Merge MCPs into .mcp.json
    src_mcp = plugin_dir / ".mcp.json"
    if src_mcp.exists() and content["mcps"]:
        mcp_path = vault_path / ".mcp.json"

        # Read existing
        existing: dict[str, Any] = {}
        if mcp_path.exists():
            try:
                existing = json.loads(mcp_path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                existing = {}

        servers = existing.get("mcpServers", {})

        # Read plugin MCPs
        try:
            plugin_mcp_data = json.loads(src_mcp.read_text(encoding="utf-8"))
            plugin_servers = plugin_mcp_data.get("mcpServers", {})
        except (json.JSONDecodeError, OSError):
            plugin_servers = {}

        # Merge (conflicts already checked) — validate configs before merging
        for name in content["mcps"]:
            if name in plugin_servers and name not in servers:
                config = plugin_servers[name]
                if not isinstance(config, dict):
                    logger.warning(f"Skipping MCP '{name}': config is not a dict")
                    continue
                # Validate required fields have expected types
                cmd = config.get("command")
                if cmd is not None and not isinstance(cmd, str):
                    logger.warning(f"Skipping MCP '{name}': 'command' must be a string")
                    continue
                args = config.get("args")
                if args is not None and not isinstance(args, list):
                    logger.warning(f"Skipping MCP '{name}': 'args' must be a list")
                    continue
                env = config.get("env")
                if env is not None and not isinstance(env, dict):
                    logger.warning(f"Skipping MCP '{name}': 'env' must be a dict")
                    continue
                logger.info(
                    f"Plugin MCP '{name}' will run command: {cmd} {args or []}"
                )
                servers[name] = config
                installed["mcps"].append(name)
                logger.debug(f"Installed MCP: {name}")

        # Atomic write
        existing["mcpServers"] = servers
        _atomic_write_json(mcp_path, existing)

    return installed


def _atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    """Atomically write a JSON file."""
    content = json.dumps(data, indent=2) + "\n"
    fd, tmp_path = tempfile.mkstemp(dir=path.parent, suffix=".tmp", prefix=f".{path.stem}-")
    closed = False
    try:
        os.write(fd, content.encode("utf-8"))
        os.fsync(fd)
        os.close(fd)
        closed = True
        os.rename(tmp_path, path)
    except Exception:
        if not closed:
            os.close(fd)
        if Path(tmp_path).exists():
            os.unlink(tmp_path)
        raise


# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------

def _rollback_installed_files(vault_path: Path, installed: dict[str, list[str]], mcps_to_remove: list[str]) -> None:
    """Remove installed files on failure."""
    for category in ("agents", "skills"):
        for rel_path in installed.get(category, []):
            full = vault_path / rel_path
            if full.is_dir():
                shutil.rmtree(full, ignore_errors=True)
            elif full.exists():
                full.unlink(missing_ok=True)

    # Remove MCP entries
    if mcps_to_remove:
        mcp_path = vault_path / ".mcp.json"
        if mcp_path.exists():
            try:
                data = json.loads(mcp_path.read_text(encoding="utf-8"))
                servers = data.get("mcpServers", {})
                for name in mcps_to_remove:
                    servers.pop(name, None)
                data["mcpServers"] = servers
                _atomic_write_json(mcp_path, data)
            except (json.JSONDecodeError, OSError):
                pass


# ---------------------------------------------------------------------------
# Slug derivation
# ---------------------------------------------------------------------------

def _derive_slug(url: str) -> str:
    """Derive a plugin slug from a GitHub URL."""
    from urllib.parse import urlparse

    parsed = urlparse(url)
    path = parsed.path.rstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    slug = path.split("/")[-1]
    slug = re.sub(r'[^a-zA-Z0-9_-]', '-', slug).strip('-')
    return slug or "plugin"


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def install_plugin_from_url(
    vault_path: Path,
    url: str,
    slug: Optional[str] = None,
) -> dict[str, Any]:
    """Install a plugin from a Git URL.

    Clones the repo, scans for SDK-layout content, copies files to vault
    standard locations, and writes an install manifest.

    Returns the install manifest dict.

    Raises:
        ValueError: If URL is invalid, plugin has no content, or conflicts exist
        RuntimeError: If git clone fails
    """
    # Validate URL scheme
    from urllib.parse import urlparse
    parsed = urlparse(url)
    if parsed.scheme not in ("https", "http"):
        raise ValueError(
            f"Only HTTPS URLs are supported for plugin install, got: {parsed.scheme or 'none'}"
        )

    if not slug:
        slug = _derive_slug(url)

    # Check for existing installation
    existing = get_install_manifest(vault_path, slug)
    if existing:
        raise ValueError(f"Plugin '{slug}' is already installed. Uninstall first.")

    # Clone to temp directory
    tmp_dir = Path(tempfile.mkdtemp(prefix=f"parachute-plugin-{slug}-"))
    clone_dir = tmp_dir / slug

    try:
        logger.info(f"Installing plugin from {url} as '{slug}'")
        proc = await asyncio.create_subprocess_exec(
            "git", "clone", "--depth", "1", url, str(clone_dir),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)

        if proc.returncode != 0:
            error_msg = stderr.decode().strip() if stderr else "Unknown error"
            raise RuntimeError(f"Git clone failed: {error_msg}")

        # Read metadata
        meta = _read_plugin_metadata(clone_dir, slug)

        # Scan for SDK-layout content
        content = _scan_plugin_content(clone_dir)

        has_content = any(content[k] for k in content)
        if not has_content:
            raise ValueError(
                f"Plugin '{slug}' has no recognizable content. "
                f"Expected .claude/agents/, skills/, or .mcp.json"
            )

        # Check for conflicts BEFORE writing anything
        conflicts = _check_conflicts(vault_path, slug, content, clone_dir)
        if conflicts:
            raise ValueError(
                f"Plugin '{slug}' has conflicts with existing content:\n"
                + "\n".join(f"  - {c}" for c in conflicts)
            )

        # Get commit hash
        commit_hash = None
        try:
            git_proc = await asyncio.create_subprocess_exec(
                "git", "-C", str(clone_dir), "rev-parse", "HEAD",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            git_out, _ = await asyncio.wait_for(git_proc.communicate(), timeout=5)
            if git_proc.returncode == 0:
                commit_hash = git_out.decode().strip()[:12]
        except Exception:
            pass

        # Install files (copy to vault standard locations)
        installed = _install_files(vault_path, slug, clone_dir, content)

        # Write install manifest
        manifest: dict[str, Any] = {
            "slug": slug,
            "name": meta["name"],
            "version": meta["version"],
            "description": meta["description"],
            "author": meta["author"],
            "source_url": url,
            "installed_at": datetime.now(timezone.utc).isoformat(),
            "commit": commit_hash,
            "installed_files": installed,
        }
        _write_manifest(vault_path, manifest)

        logger.info(
            f"Installed plugin '{meta['name']}' v{meta['version']}: "
            f"{len(installed['agents'])} agents, {len(installed['skills'])} skills, "
            f"{len(installed['mcps'])} MCPs"
        )
        return manifest

    except Exception:
        # Rollback on failure (if we partially installed)
        # installed might not be defined if we failed before that step
        try:
            installed  # noqa: B018
            _rollback_installed_files(vault_path, installed, installed.get("mcps", []))
        except NameError:
            pass
        raise
    finally:
        # Clean up temp directory
        shutil.rmtree(tmp_dir, ignore_errors=True)


async def uninstall_plugin(vault_path: Path, slug: str) -> bool:
    """Remove a plugin by deleting its tracked files and manifest.

    Returns True if plugin was removed, False if not found.
    """
    manifest = get_install_manifest(vault_path, slug)
    if not manifest:
        # Check for legacy plugin in .parachute/plugins/
        legacy_dir = vault_path / ".parachute" / "plugins" / slug
        if legacy_dir.exists():
            try:
                legacy_dir.resolve().relative_to(
                    (vault_path / ".parachute" / "plugins").resolve()
                )
            except ValueError:
                logger.error(f"Refusing to delete plugin outside expected directory: {legacy_dir}")
                return False
            shutil.rmtree(legacy_dir)
            logger.info(f"Uninstalled legacy plugin: {slug}")
            return True
        return False

    installed = manifest.get("installed_files", {})

    # Remove agents and skills
    for category in ("agents", "skills"):
        for rel_path in installed.get(category, []):
            full = vault_path / rel_path
            if full.is_dir():
                shutil.rmtree(full, ignore_errors=True)
            elif full.exists():
                full.unlink(missing_ok=True)
            logger.debug(f"Removed {rel_path}")

    # Remove MCP entries
    mcp_names = installed.get("mcps", [])
    if mcp_names:
        mcp_path = vault_path / ".mcp.json"
        if mcp_path.exists():
            try:
                data = json.loads(mcp_path.read_text(encoding="utf-8"))
                servers = data.get("mcpServers", {})
                for name in mcp_names:
                    servers.pop(name, None)
                data["mcpServers"] = servers
                _atomic_write_json(mcp_path, data)
            except (json.JSONDecodeError, OSError) as e:
                logger.warning(f"Failed to clean MCP entries for '{slug}': {e}")

    # Remove manifest
    manifest_path = _read_plugin_manifests_dir(vault_path) / f"{slug}.json"
    manifest_path.unlink(missing_ok=True)

    logger.info(f"Uninstalled plugin: {slug}")
    return True


async def update_plugin(vault_path: Path, slug: str) -> dict[str, Any]:
    """Update a plugin by uninstalling and reinstalling from its source URL.

    Returns the new install manifest.

    Raises:
        ValueError: If plugin not found or has no source URL
        RuntimeError: If git operations fail
    """
    manifest = get_install_manifest(vault_path, slug)
    if not manifest:
        raise ValueError(f"Plugin '{slug}' not found")

    source_url = manifest.get("source_url")
    if not source_url:
        raise ValueError(f"Plugin '{slug}' has no source URL, cannot update")

    # Uninstall first
    await uninstall_plugin(vault_path, slug)

    # Reinstall from source
    return await install_plugin_from_url(vault_path, source_url, slug=slug)


async def check_plugin_update(vault_path: Path, slug: str) -> Optional[dict]:
    """Check if a newer version is available for a plugin.

    Returns None if up to date, or {"behind": N, "slug": slug} if updates available.
    """
    manifest = get_install_manifest(vault_path, slug)
    if not manifest:
        return None

    source_url = manifest.get("source_url")
    if not source_url:
        return None

    # Clone to temp for comparison
    tmp_dir = Path(tempfile.mkdtemp(prefix=f"parachute-check-{slug}-"))
    try:
        proc = await asyncio.create_subprocess_exec(
            "git", "clone", "--depth", "1", "--bare", source_url, str(tmp_dir / "repo.git"),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, _ = await asyncio.wait_for(proc.communicate(), timeout=30)

        if proc.returncode != 0:
            return None

        # Get remote HEAD
        proc2 = await asyncio.create_subprocess_exec(
            "git", "-C", str(tmp_dir / "repo.git"), "rev-parse", "HEAD",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout2, _ = await asyncio.wait_for(proc2.communicate(), timeout=5)

        if proc2.returncode != 0:
            return None

        remote_commit = stdout2.decode().strip()[:12]
        local_commit = manifest.get("commit", "")

        if remote_commit and local_commit and remote_commit != local_commit:
            return {"behind": 1, "slug": slug}  # Can't count exact commits with shallow clone

        return None
    except Exception:
        return None
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
