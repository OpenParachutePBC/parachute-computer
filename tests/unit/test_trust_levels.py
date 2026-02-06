"""
Tests for trust levels, Docker sandbox, module hash verification,
and permission handler trust level integration.
"""

import json
import tempfile
from datetime import datetime
from pathlib import Path

import pytest

from parachute.models.session import (
    Session,
    SessionPermissions,
    SessionSource,
    TrustLevel,
)
from parachute.core.sandbox import (
    AgentSandboxConfig,
    DockerSandbox,
    SANDBOX_IMAGE,
    CONTAINER_MEMORY_LIMIT,
    CONTAINER_CPU_LIMIT,
)
from parachute.core.module_loader import (
    compute_module_hash,
    verify_module,
    ModuleLoader,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def vault_path(tmp_path):
    """Create a temporary vault path."""
    vault = tmp_path / "vault"
    vault.mkdir()
    (vault / ".parachute").mkdir()
    return vault


def _make_session(trust_level=None, trust_mode=True, allowed_paths=None):
    """Helper to create a session with given trust params."""
    perms = SessionPermissions(
        trustLevel=TrustLevel(trust_level) if trust_level else TrustLevel.FULL,
        trust_mode=trust_mode,
        allowedPaths=allowed_paths or [],
    )
    return Session(
        id="test-session",
        module="chat",
        source=SessionSource.PARACHUTE,
        created_at=datetime.utcnow(),
        last_accessed=datetime.utcnow(),
        metadata={"permissions": perms.model_dump(by_alias=True)},
    )


# ---------------------------------------------------------------------------
# TrustLevel model tests
# ---------------------------------------------------------------------------


class TestTrustLevel:
    def test_three_levels_exist(self):
        assert TrustLevel.FULL == "full"
        assert TrustLevel.VAULT == "vault"
        assert TrustLevel.SANDBOXED == "sandboxed"

    def test_default_is_full(self):
        perms = SessionPermissions()
        assert perms.effective_trust_level == TrustLevel.FULL

    def test_legacy_trust_mode_false_maps_to_vault(self):
        perms = SessionPermissions(trust_mode=False)
        assert perms.effective_trust_level == TrustLevel.VAULT

    def test_explicit_sandboxed_overrides_trust_mode(self):
        perms = SessionPermissions(
            trustLevel=TrustLevel.SANDBOXED, trust_mode=True
        )
        assert perms.effective_trust_level == TrustLevel.SANDBOXED

    def test_explicit_vault_overrides_trust_mode(self):
        perms = SessionPermissions(
            trustLevel=TrustLevel.VAULT, trust_mode=True
        )
        assert perms.effective_trust_level == TrustLevel.VAULT


class TestSessionPermissionsWithTrust:
    def test_vault_uses_bash_whitelist(self):
        perms = SessionPermissions(
            trustLevel=TrustLevel.VAULT, trust_mode=False
        )
        # VAULT allows whitelisted commands (ls, pwd, tree by default)
        assert perms.can_bash("ls")
        assert perms.can_bash("pwd")
        assert perms.can_bash("tree")
        # But blocks non-whitelisted commands
        assert not perms.can_bash("rm file.txt")
        assert not perms.can_bash("git status")

    def test_sandboxed_denies_bash(self):
        perms = SessionPermissions(
            trustLevel=TrustLevel.SANDBOXED, trust_mode=False
        )
        assert not perms.can_bash("ls")

    def test_vault_allows_read_with_pattern(self):
        perms = SessionPermissions(
            trustLevel=TrustLevel.VAULT,
            trust_mode=False,
            allowedPaths=["Blogs/**/*"],
        )
        assert perms.can_read("Blogs/post.md")
        assert not perms.can_read("Daily/journal.md")

    def test_vault_allows_write_with_pattern(self):
        perms = SessionPermissions(
            trustLevel=TrustLevel.VAULT,
            trust_mode=False,
            allowedPaths=["Blogs/**/*"],
        )
        assert perms.can_write("Blogs/post.md")
        assert not perms.can_write("Daily/journal.md")

    def test_full_allows_everything(self):
        perms = SessionPermissions()
        assert perms.can_read("anything")
        assert perms.can_write("anything")
        assert perms.can_bash("rm -rf everything")


class TestSessionTrustLevel:
    def test_get_trust_level_default(self):
        session = _make_session()
        assert session.get_trust_level() == TrustLevel.FULL

    def test_get_trust_level_from_field(self):
        session = Session(
            id="test",
            module="chat",
            created_at=datetime.utcnow(),
            last_accessed=datetime.utcnow(),
            trust_level="sandboxed",
        )
        assert session.get_trust_level() == TrustLevel.SANDBOXED

    def test_get_trust_level_invalid_falls_back(self):
        session = Session(
            id="test",
            module="chat",
            created_at=datetime.utcnow(),
            last_accessed=datetime.utcnow(),
            trust_level="invalid_value",
        )
        assert session.get_trust_level() == TrustLevel.FULL


# ---------------------------------------------------------------------------
# Docker sandbox tests
# ---------------------------------------------------------------------------


class TestAgentSandboxConfig:
    def test_defaults(self):
        config = AgentSandboxConfig(session_id="abc123")
        assert config.agent_type == "chat"
        assert config.allowed_paths == []
        assert config.network_enabled is False
        assert config.timeout_seconds == 300

    def test_custom_config(self):
        config = AgentSandboxConfig(
            session_id="abc123",
            agent_type="summarizer",
            allowed_paths=["Blogs/**/*"],
            network_enabled=True,
            timeout_seconds=60,
        )
        assert config.agent_type == "summarizer"
        assert config.network_enabled is True
        assert config.timeout_seconds == 60


class TestDockerSandbox:
    def test_init(self, vault_path):
        sandbox = DockerSandbox(vault_path=vault_path)
        assert sandbox.vault_path == vault_path
        assert sandbox.credentials_path == vault_path / ".claude" / "credentials.json"

    def test_custom_credentials_path(self, vault_path):
        creds = vault_path / "custom_creds.json"
        sandbox = DockerSandbox(vault_path=vault_path, credentials_path=creds)
        assert sandbox.credentials_path == creds

    def test_health_info_initial(self, vault_path):
        sandbox = DockerSandbox(vault_path=vault_path)
        info = sandbox.health_info()
        assert info["docker_available"] is None
        assert info["sandbox_image"] == SANDBOX_IMAGE

    def test_build_mounts_no_paths(self, vault_path):
        sandbox = DockerSandbox(vault_path=vault_path)
        config = AgentSandboxConfig(session_id="test")
        mounts = sandbox._build_mounts(config)
        # Should mount entire vault read-only when no allowed_paths
        assert "-v" in mounts
        assert f"{vault_path}:/vault:ro" in mounts

    def test_build_mounts_with_paths(self, vault_path):
        (vault_path / "Blogs").mkdir()
        sandbox = DockerSandbox(vault_path=vault_path)
        config = AgentSandboxConfig(
            session_id="test", allowed_paths=["Blogs/**/*"]
        )
        mounts = sandbox._build_mounts(config)
        # Should mount specific path read-write
        mount_str = " ".join(mounts)
        assert "Blogs" in mount_str
        assert ":rw" in mount_str

    def test_build_run_args_network_disabled(self, vault_path):
        sandbox = DockerSandbox(vault_path=vault_path)
        config = AgentSandboxConfig(session_id="test-session-id")
        args = sandbox._build_run_args(config)
        assert "--network" in args
        assert "none" in args
        assert "--memory" in args
        assert CONTAINER_MEMORY_LIMIT in args

    def test_build_run_args_network_enabled(self, vault_path):
        sandbox = DockerSandbox(vault_path=vault_path)
        config = AgentSandboxConfig(
            session_id="test", network_enabled=True
        )
        args = sandbox._build_run_args(config)
        assert "--network" not in args

    def test_build_run_args_container_name(self, vault_path):
        sandbox = DockerSandbox(vault_path=vault_path)
        config = AgentSandboxConfig(session_id="abcdef1234567890")
        args = sandbox._build_run_args(config)
        assert "parachute-sandbox-abcdef12" in args


# ---------------------------------------------------------------------------
# Module hash verification tests
# ---------------------------------------------------------------------------


class TestModuleHash:
    def test_compute_hash_deterministic(self, tmp_path):
        mod_dir = tmp_path / "test_module"
        mod_dir.mkdir()
        (mod_dir / "manifest.yaml").write_text("name: test\n")
        (mod_dir / "module.py").write_text("class Test:\n    name = 'test'\n")

        h1 = compute_module_hash(mod_dir)
        h2 = compute_module_hash(mod_dir)
        assert h1 == h2

    def test_hash_changes_on_modification(self, tmp_path):
        mod_dir = tmp_path / "test_module"
        mod_dir.mkdir()
        (mod_dir / "manifest.yaml").write_text("name: test\n")
        (mod_dir / "module.py").write_text("class Test:\n    name = 'test'\n")

        h1 = compute_module_hash(mod_dir)

        (mod_dir / "module.py").write_text("class Test:\n    name = 'test'\n    evil = True\n")
        h2 = compute_module_hash(mod_dir)

        assert h1 != h2

    def test_hash_includes_nested_files(self, tmp_path):
        mod_dir = tmp_path / "test_module"
        mod_dir.mkdir()
        (mod_dir / "manifest.yaml").write_text("name: test\n")
        (mod_dir / "module.py").write_text("pass\n")

        h1 = compute_module_hash(mod_dir)

        sub = mod_dir / "utils"
        sub.mkdir()
        (sub / "helper.py").write_text("def helper(): pass\n")

        h2 = compute_module_hash(mod_dir)
        assert h1 != h2

    def test_verify_module_matches(self, tmp_path):
        mod_dir = tmp_path / "test_module"
        mod_dir.mkdir()
        (mod_dir / "manifest.yaml").write_text("name: test\n")
        (mod_dir / "module.py").write_text("pass\n")

        h = compute_module_hash(mod_dir)
        assert verify_module(mod_dir, h)

    def test_verify_module_rejects_wrong_hash(self, tmp_path):
        mod_dir = tmp_path / "test_module"
        mod_dir.mkdir()
        (mod_dir / "manifest.yaml").write_text("name: test\n")
        (mod_dir / "module.py").write_text("pass\n")

        assert not verify_module(mod_dir, "deadbeef")


class TestModuleLoaderHashes:
    def test_hash_file_path(self, vault_path):
        loader = ModuleLoader(vault_path=vault_path)
        assert loader._hash_file == vault_path / ".parachute" / "module_hashes.json"

    def test_save_and_load_hashes(self, vault_path):
        loader = ModuleLoader(vault_path=vault_path)
        hashes = {"brain": "abc123", "daily": "def456"}
        loader._save_known_hashes(hashes)

        loaded = loader._load_known_hashes()
        assert loaded == hashes

    def test_load_hashes_missing_file(self, vault_path):
        loader = ModuleLoader(vault_path=vault_path)
        loaded = loader._load_known_hashes()
        assert loaded == {}

    def test_approve_module(self, vault_path):
        loader = ModuleLoader(vault_path=vault_path)
        loader._known_hashes = {"brain": "old_hash"}
        loader._pending_approval = {
            "brain": {"hash": "new_hash", "path": "/modules/brain"}
        }

        assert loader.approve_module("brain")
        assert loader._known_hashes["brain"] == "new_hash"
        assert "brain" not in loader._pending_approval

        # Verify saved to disk
        saved = json.loads(loader._hash_file.read_text())
        assert saved["brain"] == "new_hash"

    def test_approve_nonexistent_module(self, vault_path):
        loader = ModuleLoader(vault_path=vault_path)
        assert not loader.approve_module("nonexistent")

    def test_get_module_status(self, vault_path):
        loader = ModuleLoader(vault_path=vault_path)
        loader._known_hashes = {"brain": "abc123def456", "daily": "789012345678"}
        loader._pending_approval = {
            "daily": {"hash": "new_hash_here", "path": "/modules/daily"}
        }

        status = loader.get_module_status()
        assert len(status) == 2

        brain_status = next(s for s in status if s["name"] == "brain")
        assert brain_status["status"] == "loaded"

        daily_status = next(s for s in status if s["name"] == "daily")
        assert daily_status["status"] == "pending_approval"


# ---------------------------------------------------------------------------
# Permission handler trust level integration tests
# ---------------------------------------------------------------------------


class TestPermissionHandlerTrustLevels:
    @pytest.fixture
    def vault_str(self, vault_path):
        return str(vault_path)

    @pytest.mark.asyncio
    async def test_full_trust_allows_bash(self, vault_str):
        from parachute.core.permission_handler import PermissionHandler

        session = _make_session(trust_level="full")
        handler = PermissionHandler(session=session, vault_path=vault_str)
        decision = await handler.check_permission("Bash", {"command": "ls -la"})
        assert decision.behavior == "allow"

    @pytest.mark.asyncio
    async def test_vault_allows_whitelisted_bash(self, vault_str):
        from parachute.core.permission_handler import PermissionHandler

        session = _make_session(trust_level="vault", trust_mode=False)
        handler = PermissionHandler(session=session, vault_path=vault_str)
        # Whitelisted commands should be allowed
        decision = await handler.check_permission("Bash", {"command": "ls -la"})
        assert decision.behavior == "allow"

    @pytest.mark.asyncio
    async def test_vault_denies_non_whitelisted_bash(self, vault_str):
        from parachute.core.permission_handler import PermissionHandler

        session = _make_session(trust_level="vault", trust_mode=False)
        handler = PermissionHandler(session=session, vault_path=vault_str)
        handler.timeout_seconds = 1  # Short timeout for test
        # Non-whitelisted commands go to approval flow, timeout = deny
        decision = await handler.check_permission("Bash", {"command": "git status"})
        assert decision.behavior == "deny"

    @pytest.mark.asyncio
    async def test_sandboxed_denies_host_tools(self, vault_str):
        from parachute.core.permission_handler import PermissionHandler

        session = _make_session(trust_level="sandboxed", trust_mode=False)
        handler = PermissionHandler(session=session, vault_path=vault_str)

        for tool in ["Bash", "Read", "Write", "Edit", "Glob", "Grep"]:
            decision = await handler.check_permission(tool, {})
            assert decision.behavior == "deny", f"{tool} should be denied for sandboxed"

    @pytest.mark.asyncio
    async def test_sandboxed_allows_mcp_tools(self, vault_str):
        from parachute.core.permission_handler import PermissionHandler

        session = _make_session(trust_level="sandboxed", trust_mode=False)
        handler = PermissionHandler(session=session, vault_path=vault_str)
        decision = await handler.check_permission("mcp__vault__list", {})
        assert decision.behavior == "allow"

    @pytest.mark.asyncio
    async def test_sandboxed_allows_web_tools(self, vault_str):
        from parachute.core.permission_handler import PermissionHandler

        session = _make_session(trust_level="sandboxed", trust_mode=False)
        handler = PermissionHandler(session=session, vault_path=vault_str)
        decision = await handler.check_permission("WebSearch", {"query": "test"})
        assert decision.behavior == "allow"

    @pytest.mark.asyncio
    async def test_full_trust_allows_write(self, vault_str):
        from parachute.core.permission_handler import PermissionHandler

        session = _make_session(trust_level="full")
        handler = PermissionHandler(session=session, vault_path=vault_str)
        decision = await handler.check_permission("Write", {"file_path": "/tmp/test.md"})
        assert decision.behavior == "allow"
