"""
Tests for permission checking utilities.
"""

from datetime import datetime
from pathlib import Path

import pytest

from parachute.lib.ignore_patterns import IgnorePatterns, BUILTIN_DENY_PATTERNS
from parachute.lib.permissions import PermissionChecker
from parachute.models.session import Session, SessionPermissions, SessionSource, TrustLevel


@pytest.fixture
def vault_path(tmp_path):
    """Create a temporary vault path."""
    return tmp_path / "vault"


@pytest.fixture
def basic_session():
    """Create a basic session with sandboxed (restricted) trust level."""
    permissions = SessionPermissions(trustLevel=TrustLevel.SANDBOXED)
    return Session(
        id="test-session-123",
        title="Test Session",
        module="chat",
        source=SessionSource.PARACHUTE,
        created_at=datetime.utcnow(),
        last_accessed=datetime.utcnow(),
        metadata={"permissions": permissions.model_dump(by_alias=True)},
    )


@pytest.fixture
def session_with_read_permission():
    """Create a sandboxed session with read permission for Blogs/."""
    permissions = SessionPermissions(
        trustLevel=TrustLevel.SANDBOXED,
        read=["Blogs/**/*"],
        write=["Chat/artifacts/*"],
    )
    return Session(
        id="test-session-123",
        title="Test Session",
        module="chat",
        source=SessionSource.PARACHUTE,
        created_at=datetime.utcnow(),
        last_accessed=datetime.utcnow(),
        metadata={"permissions": permissions.model_dump(by_alias=True)},
    )


@pytest.fixture
def trust_mode_session():
    """Create a session with direct trust level (allows all)."""
    permissions = SessionPermissions(trustLevel=TrustLevel.DIRECT)
    return Session(
        id="test-session-123",
        title="Test Session",
        module="chat",
        source=SessionSource.PARACHUTE,
        created_at=datetime.utcnow(),
        last_accessed=datetime.utcnow(),
        metadata={"permissions": permissions.model_dump(by_alias=True)},
    )


class TestSessionPermissions:
    """Tests for SessionPermissions model."""

    def test_default_permissions(self):
        """Test default permission values."""
        perms = SessionPermissions()
        assert perms.read == []
        assert perms.write == ["Chat/artifacts/*"]
        assert perms.bash == ["ls", "pwd", "tree"]
        # Default trust level is DIRECT (bare metal)
        assert perms.trust_level == TrustLevel.DIRECT

    def test_direct_trust_allows_all(self):
        """Test that direct trust bypasses permission checks."""
        perms = SessionPermissions()  # DIRECT by default
        assert perms.can_read("any/path.txt")
        assert perms.can_write("any/path.txt")
        assert perms.can_bash("rm -rf everything")

    def test_sandboxed_read_denied(self):
        """Test that reading is denied in sandboxed mode (no allowed paths)."""
        perms = SessionPermissions(trustLevel=TrustLevel.SANDBOXED)
        assert not perms.can_read("Blogs/post.md")
        assert not perms.can_read("Daily/journals/2024-01-01.md")

    def test_can_read_with_pattern(self):
        """Test reading with granted read pattern in sandboxed mode."""
        perms = SessionPermissions(trustLevel=TrustLevel.SANDBOXED, read=["Blogs/**/*"])
        assert perms.can_read("Blogs/post.md")
        assert perms.can_read("Blogs/drafts/new-post.md")
        assert not perms.can_read("Daily/journals/2024-01-01.md")

    def test_sandboxed_write_artifacts(self):
        """Test that Chat/artifacts is writable by default in sandboxed mode."""
        perms = SessionPermissions(trustLevel=TrustLevel.SANDBOXED)
        assert perms.can_write("Chat/artifacts/output.txt")
        assert not perms.can_write("Blogs/post.md")

    def test_sandboxed_denies_all_bash(self):
        """Test that sandboxed mode denies all bash (Docker runs, no host bash)."""
        perms = SessionPermissions(trustLevel=TrustLevel.SANDBOXED)
        assert not perms.can_bash("ls")
        assert not perms.can_bash("pwd")
        assert not perms.can_bash("tree")
        assert not perms.can_bash("rm file.txt")


class TestIgnorePatterns:
    """Tests for ignore patterns."""

    def test_builtin_patterns_exist(self):
        """Test that builtin patterns are defined."""
        assert len(BUILTIN_DENY_PATTERNS) > 0
        assert ".env" in BUILTIN_DENY_PATTERNS
        assert "**/*.key" in BUILTIN_DENY_PATTERNS

    def test_env_files_denied(self):
        """Test that .env files are denied."""
        ignore = IgnorePatterns()
        assert ignore.is_denied(".env")
        assert ignore.is_denied(".env.local")
        assert ignore.is_denied("config/.env")

    def test_key_files_denied(self):
        """Test that key files are denied."""
        ignore = IgnorePatterns()
        assert ignore.is_denied("secrets/api.key")
        assert ignore.is_denied("ssh/id_rsa.pem")

    def test_node_modules_denied(self):
        """Test that node_modules is denied."""
        ignore = IgnorePatterns()
        assert ignore.is_denied("node_modules/package/file.js")
        assert ignore.is_denied("project/node_modules/dep/index.js")

    def test_regular_files_allowed(self):
        """Test that regular files are not denied."""
        ignore = IgnorePatterns()
        assert not ignore.is_denied("Blogs/post.md")
        assert not ignore.is_denied("Daily/journals/2024-01-01.md")
        assert not ignore.is_denied("README.md")


class TestPermissionChecker:
    """Tests for PermissionChecker."""

    def test_deny_list_takes_precedence(self, trust_mode_session, vault_path):
        """Test that deny list blocks access even in trust mode."""
        checker = PermissionChecker(trust_mode_session, vault_path)

        # Trust mode allows regular files
        allowed, reason = checker.can_read("Blogs/post.md")
        assert allowed

        # But deny list still blocks sensitive files
        allowed, reason = checker.can_read(".env")
        assert not allowed
        assert "deny pattern" in reason.lower()

    def test_read_without_permission(self, basic_session, vault_path):
        """Test reading without explicit permission."""
        checker = PermissionChecker(basic_session, vault_path)

        allowed, reason = checker.can_read("Blogs/post.md")
        assert not allowed
        assert "no read permission" in reason.lower()

    def test_read_with_permission(self, session_with_read_permission, vault_path):
        """Test reading with granted permission."""
        checker = PermissionChecker(session_with_read_permission, vault_path)

        allowed, reason = checker.can_read("Blogs/post.md")
        assert allowed

        # But still denied for paths without permission
        allowed, reason = checker.can_read("Daily/journals/2024-01-01.md")
        assert not allowed

    def test_write_to_artifacts(self, basic_session, vault_path):
        """Test writing to artifacts folder (default allowed)."""
        checker = PermissionChecker(basic_session, vault_path)

        allowed, reason = checker.can_write("Chat/artifacts/output.txt")
        assert allowed

    def test_dangerous_commands_blocked(self, trust_mode_session, vault_path):
        """Test that dangerous commands are blocked even in trust mode."""
        checker = PermissionChecker(trust_mode_session, vault_path)

        dangerous_commands = [
            "sudo rm -rf /",
            "rm -rf /",
            "rm -rf ~",
            ":(){:|:&};:",  # Fork bomb
        ]

        for cmd in dangerous_commands:
            allowed, reason = checker.can_bash(cmd)
            assert not allowed, f"Command should be blocked: {cmd}"

    def test_suggested_grants(self, basic_session, vault_path):
        """Test that suggested grants are generated correctly."""
        checker = PermissionChecker(basic_session, vault_path)

        suggestions = checker.get_suggested_grant("Blogs/drafts/new-post.md")

        assert len(suggestions) >= 3
        assert suggestions[0]["scope"] == "file"
        assert "new-post.md" in suggestions[0]["label"]

    def test_absolute_path_conversion(self, basic_session, vault_path):
        """Test that absolute paths are converted to relative."""
        vault_path.mkdir(parents=True, exist_ok=True)
        checker = PermissionChecker(basic_session, vault_path)

        # Create a session with permission
        perms = SessionPermissions(read=["Blogs/**/*"])
        session = basic_session.with_permissions(perms)
        checker = PermissionChecker(session, vault_path)

        # Absolute path should be converted and matched
        abs_path = str(vault_path / "Blogs" / "post.md")
        allowed, reason = checker.can_read(abs_path)
        assert allowed
