"""Tests for workspace storage and management."""

import shutil
from pathlib import Path

import pytest
import yaml

from parachute.core.workspaces import (
    create_workspace,
    delete_workspace,
    generate_slug,
    get_workspace,
    list_workspaces,
    update_workspace,
)
from parachute.models.workspace import (
    WorkspaceCapabilities,
    WorkspaceCreate,
    WorkspaceUpdate,
)


@pytest.fixture
def vault_path(tmp_path):
    """Create a temporary vault directory."""
    return tmp_path / "vault"


class TestGenerateSlug:
    """Tests for slug generation."""

    def test_basic_slug(self):
        assert generate_slug("My Workspace") == "my-workspace"

    def test_special_characters(self):
        assert generate_slug("Hello, World!") == "hello-world"

    def test_collapse_hyphens(self):
        assert generate_slug("a  --  b") == "a-b"

    def test_empty_fallback(self):
        assert generate_slug("!!!") == "workspace"

    def test_collision_adds_suffix(self):
        existing = ["my-workspace"]
        assert generate_slug("My Workspace", existing) == "my-workspace-2"

    def test_collision_increments(self):
        existing = ["coding", "coding-2", "coding-3"]
        assert generate_slug("Coding", existing) == "coding-4"

    def test_no_collision_no_suffix(self):
        existing = ["other"]
        assert generate_slug("My Workspace", existing) == "my-workspace"


class TestWorkspaceCRUD:
    """Tests for workspace CRUD operations."""

    def test_create_workspace(self, vault_path):
        create = WorkspaceCreate(name="Coding", default_trust_level="direct")
        workspace = create_workspace(vault_path, create)

        assert workspace.name == "Coding"
        assert workspace.slug == "coding"
        assert workspace.default_trust_level == "direct"

        # Verify file was created
        config_file = vault_path / ".parachute/workspaces/coding/config.yaml"
        assert config_file.exists()

        with open(config_file) as f:
            data = yaml.safe_load(f)
        assert data["name"] == "Coding"

    def test_create_workspace_slug_collision(self, vault_path):
        create_workspace(vault_path, WorkspaceCreate(name="Coding"))
        ws2 = create_workspace(vault_path, WorkspaceCreate(name="Coding"))
        assert ws2.slug == "coding-2"

    def test_list_workspaces_empty(self, vault_path):
        assert list_workspaces(vault_path) == []

    def test_list_workspaces(self, vault_path):
        create_workspace(vault_path, WorkspaceCreate(name="Alpha"))
        create_workspace(vault_path, WorkspaceCreate(name="Beta"))

        result = list_workspaces(vault_path)
        assert len(result) == 2
        slugs = [w.slug for w in result]
        assert "alpha" in slugs
        assert "beta" in slugs

    def test_get_workspace(self, vault_path):
        create_workspace(vault_path, WorkspaceCreate(name="Test", description="A test"))
        workspace = get_workspace(vault_path, "test")
        assert workspace is not None
        assert workspace.name == "Test"
        assert workspace.description == "A test"

    def test_get_workspace_not_found(self, vault_path):
        assert get_workspace(vault_path, "nonexistent") is None

    def test_update_workspace(self, vault_path):
        create_workspace(vault_path, WorkspaceCreate(name="Test"))
        updated = update_workspace(
            vault_path, "test",
            WorkspaceUpdate(description="Updated", default_trust_level="sandboxed"),
        )
        assert updated is not None
        assert updated.description == "Updated"
        assert updated.default_trust_level == "sandboxed"
        assert updated.name == "Test"  # unchanged
        assert updated.slug == "test"  # cannot change

    def test_update_workspace_not_found(self, vault_path):
        assert update_workspace(vault_path, "nope", WorkspaceUpdate(name="X")) is None

    def test_delete_workspace(self, vault_path):
        create_workspace(vault_path, WorkspaceCreate(name="Test"))
        assert delete_workspace(vault_path, "test") is True
        assert get_workspace(vault_path, "test") is None

    def test_delete_workspace_not_found(self, vault_path):
        assert delete_workspace(vault_path, "nope") is False

    def test_workspace_with_capabilities(self, vault_path):
        caps = WorkspaceCapabilities(
            mcps=["parachute"],
            skills="none",
            agents="all",
        )
        create = WorkspaceCreate(name="Restricted", capabilities=caps)
        workspace = create_workspace(vault_path, create)

        # Reload and verify
        loaded = get_workspace(vault_path, "restricted")
        assert loaded is not None
        assert loaded.capabilities.mcps == ["parachute"]
        assert loaded.capabilities.skills == "none"
        assert loaded.capabilities.agents == "all"

    def test_workspace_with_model(self, vault_path):
        create = WorkspaceCreate(name="Opus", model="opus")
        workspace = create_workspace(vault_path, create)
        assert workspace.model == "opus"

        loaded = get_workspace(vault_path, "opus")
        assert loaded.model == "opus"

    def test_workspace_to_api_dict(self, vault_path):
        create = WorkspaceCreate(name="Test", default_trust_level="sandboxed")
        workspace = create_workspace(vault_path, create)
        api_dict = workspace.to_api_dict()

        assert api_dict["name"] == "Test"
        assert api_dict["slug"] == "test"
        assert api_dict["default_trust_level"] == "sandboxed"
        assert "capabilities" in api_dict
