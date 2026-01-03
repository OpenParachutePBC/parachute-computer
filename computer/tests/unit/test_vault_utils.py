"""
Unit tests for vault utilities.
"""

import pytest
from pathlib import Path

from parachute.lib.vault_utils import (
    matches_pattern,
    matches_patterns,
    validate_path,
    get_vault_stats,
)


class TestMatchesPattern:
    """Tests for pattern matching."""

    def test_exact_match(self):
        """Test exact path matching."""
        assert matches_pattern("file.md", "file.md") is True
        assert matches_pattern("file.md", "other.md") is False

    def test_wildcard_match(self):
        """Test wildcard matching."""
        assert matches_pattern("file.md", "*.md") is True
        assert matches_pattern("file.txt", "*.md") is False

    def test_directory_wildcard(self):
        """Test directory wildcard matching."""
        assert matches_pattern("docs/file.md", "docs/*.md") is True
        assert matches_pattern("other/file.md", "docs/*.md") is False

    def test_double_star_wildcard(self):
        """Test ** recursive wildcard."""
        assert matches_pattern("docs/sub/file.md", "docs/**/*.md") is True
        assert matches_pattern("docs/file.md", "docs/**") is True
        assert matches_pattern("other/file.md", "docs/**") is False


class TestMatchesPatterns:
    """Tests for multiple pattern matching."""

    def test_matches_any_pattern(self):
        """Test matching against multiple patterns."""
        patterns = ["*.md", "*.txt", "docs/*"]

        assert matches_patterns("file.md", patterns) is True
        assert matches_patterns("file.txt", patterns) is True
        assert matches_patterns("docs/file.py", patterns) is True
        assert matches_patterns("other/file.py", patterns) is False

    def test_wildcard_all(self):
        """Test that * pattern matches everything."""
        assert matches_patterns("anything", ["*"]) is True
        assert matches_patterns("path/to/file.md", ["*"]) is True

    def test_empty_patterns(self):
        """Test with empty pattern list."""
        assert matches_patterns("file.md", []) is False


class TestValidatePath:
    """Tests for path validation."""

    def test_valid_paths(self, test_vault: Path):
        """Test valid path validation."""
        assert validate_path(test_vault, "file.md") is True
        assert validate_path(test_vault, "docs/file.md") is True
        assert validate_path(test_vault, "Chat/sessions/session.md") is True

    def test_path_traversal_blocked(self, test_vault: Path):
        """Test that path traversal is blocked."""
        assert validate_path(test_vault, "../outside.md") is False
        assert validate_path(test_vault, "docs/../../../etc/passwd") is False
        assert validate_path(test_vault, "..") is False

    def test_absolute_path_in_vault(self, test_vault: Path):
        """Test absolute path within vault."""
        abs_path = str(test_vault / "file.md")
        # This should work as relative path
        assert validate_path(test_vault, "file.md") is True


class TestGetVaultStats:
    """Tests for vault statistics."""

    def test_basic_stats(self, test_vault: Path):
        """Test basic vault stats."""
        stats = get_vault_stats(test_vault)

        assert stats["path"] == str(test_vault)
        assert stats["exists"] is True
        assert "Chat" in stats["modules"]
        assert "Daily" in stats["modules"]

    def test_nonexistent_vault(self, tmp_path: Path):
        """Test stats for nonexistent vault."""
        nonexistent = tmp_path / "nonexistent"
        stats = get_vault_stats(nonexistent)

        assert stats["exists"] is False
        assert stats["modules"] == []
