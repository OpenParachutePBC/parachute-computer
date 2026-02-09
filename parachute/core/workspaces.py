"""
Workspace storage and management.

Workspaces are stored as YAML files in the vault:
    vault/.parachute/workspaces/{slug}/config.yaml

The slug is the directory name and serves as the unique identifier.
"""

import logging
import re
import shutil
from pathlib import Path
from typing import Optional

import yaml

from parachute.models.workspace import (
    WorkspaceCapabilities,
    WorkspaceConfig,
    WorkspaceCreate,
    WorkspaceUpdate,
)

logger = logging.getLogger(__name__)

WORKSPACES_DIR = ".parachute/workspaces"

# Valid slug: lowercase alphanumeric with hyphens, no leading/trailing hyphens
_SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$")


def _validate_slug(slug: str) -> None:
    """Validate a workspace slug to prevent path traversal."""
    if not slug or "/" in slug or "\\" in slug or ".." in slug:
        raise ValueError(f"Invalid workspace slug: {slug!r}")
    if not _SLUG_PATTERN.match(slug):
        raise ValueError(f"Invalid workspace slug: {slug!r}")


def _workspaces_path(vault_path: Path) -> Path:
    """Get the workspaces directory path."""
    return vault_path / WORKSPACES_DIR


def generate_slug(name: str, existing_slugs: list[str] | None = None) -> str:
    """Generate a URL-safe slug from a workspace name.

    Converts to lowercase kebab-case. Appends numeric suffix on collision.
    """
    # Lowercase, replace non-alphanumeric with hyphens, collapse multiples
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    if not slug:
        slug = "workspace"

    if existing_slugs is None:
        return slug

    # Handle collisions with numeric suffix
    if slug not in existing_slugs:
        return slug

    counter = 2
    while f"{slug}-{counter}" in existing_slugs:
        counter += 1
    return f"{slug}-{counter}"


def list_workspaces(vault_path: Path) -> list[WorkspaceConfig]:
    """List all workspaces in the vault."""
    ws_dir = _workspaces_path(vault_path)
    if not ws_dir.exists():
        return []

    workspaces = []
    for entry in sorted(ws_dir.iterdir()):
        if not entry.is_dir():
            continue
        config_file = entry / "config.yaml"
        if not config_file.exists():
            logger.warning(f"Workspace directory without config.yaml: {entry.name}")
            continue
        try:
            workspace = _load_workspace(entry.name, config_file)
            workspaces.append(workspace)
        except Exception as e:
            logger.warning(f"Failed to load workspace {entry.name}: {e}")

    return workspaces


def get_workspace(vault_path: Path, slug: str) -> Optional[WorkspaceConfig]:
    """Load a single workspace by slug."""
    _validate_slug(slug)
    config_file = _workspaces_path(vault_path) / slug / "config.yaml"
    if not config_file.exists():
        return None
    try:
        return _load_workspace(slug, config_file)
    except Exception as e:
        logger.error(f"Failed to load workspace {slug}: {e}")
        return None


def create_workspace(vault_path: Path, create: WorkspaceCreate) -> WorkspaceConfig:
    """Create a new workspace.

    Creates the directory and config.yaml file.
    Returns the created WorkspaceConfig with generated slug.
    """
    ws_dir = _workspaces_path(vault_path)
    existing_slugs = [d.name for d in ws_dir.iterdir() if d.is_dir()] if ws_dir.exists() else []
    slug = generate_slug(create.name, existing_slugs)

    workspace = WorkspaceConfig(
        name=create.name,
        slug=slug,
        description=create.description,
        default_trust_level=create.default_trust_level,
        working_directory=create.working_directory,
        model=create.model,
        capabilities=create.capabilities or WorkspaceCapabilities(),
        sandbox=create.sandbox,
    )

    # Create directory and write config
    workspace_dir = ws_dir / slug
    workspace_dir.mkdir(parents=True, exist_ok=True)
    _write_workspace(workspace, workspace_dir / "config.yaml")

    logger.info(f"Created workspace: {slug} ({create.name})")
    return workspace


def update_workspace(
    vault_path: Path, slug: str, update: WorkspaceUpdate
) -> Optional[WorkspaceConfig]:
    """Update an existing workspace. Returns updated config or None if not found."""
    _validate_slug(slug)
    existing = get_workspace(vault_path, slug)
    if existing is None:
        return None

    # Apply updates
    updates = update.model_dump(exclude_none=True)
    existing_data = existing.model_dump()
    existing_data.update(updates)
    existing_data["slug"] = slug  # slug cannot change

    updated = WorkspaceConfig(**existing_data)
    config_file = _workspaces_path(vault_path) / slug / "config.yaml"
    _write_workspace(updated, config_file)

    logger.info(f"Updated workspace: {slug}")
    return updated


def delete_workspace(vault_path: Path, slug: str) -> bool:
    """Delete a workspace directory. Returns True if deleted."""
    _validate_slug(slug)
    workspace_dir = _workspaces_path(vault_path) / slug
    if not workspace_dir.exists():
        return False

    shutil.rmtree(workspace_dir)
    logger.info(f"Deleted workspace: {slug}")
    return True


def _load_workspace(slug: str, config_file: Path) -> WorkspaceConfig:
    """Load a workspace from its config.yaml file."""
    with open(config_file) as f:
        data = yaml.safe_load(f) or {}

    data["slug"] = slug
    # Migrate old field name: trust_level -> default_trust_level
    if "trust_level" in data and "default_trust_level" not in data:
        data["default_trust_level"] = data.pop("trust_level")
    return WorkspaceConfig(**data)


def _write_workspace(workspace: WorkspaceConfig, config_file: Path) -> None:
    """Write a workspace config to YAML."""
    data = workspace.to_yaml_dict()
    with open(config_file, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
