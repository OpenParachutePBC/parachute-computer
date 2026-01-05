"""
Ignore patterns for file access control.

Loads patterns from .parachuteignore files and provides matching utilities.
These patterns are ALWAYS enforced, even in trust mode.
"""

import fnmatch
import logging
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# Built-in patterns that are always denied (security-critical)
BUILTIN_DENY_PATTERNS = [
    # Secrets and credentials
    ".env",
    ".env.*",
    "*.env",
    "**/credentials/**",
    "**/secrets/**",
    "**/*.key",
    "**/*.pem",
    "**/*.p12",
    "**/*.pfx",
    "**/id_rsa",
    "**/id_rsa.*",
    "**/id_ed25519",
    "**/id_ed25519.*",
    "**/.ssh/**",

    # API keys and tokens
    "**/api_key*",
    "**/apikey*",
    "**/*_token*",
    "**/*_secret*",

    # Git internals (allow .git status checks but not internal files)
    ".git/objects/**",
    ".git/refs/**",
    ".git/hooks/**",

    # Package manager internals
    "**/node_modules/**",
    "**/.venv/**",
    "**/venv/**",
    "**/__pycache__/**",
    "**/.pytest_cache/**",

    # Parachute internals (protect database and system files)
    ".parachute/**",
    "**/parachute.db",
    "**/parachute.db-*",
]


class IgnorePatterns:
    """
    Manages ignore patterns for file access control.

    Combines built-in security patterns with user-defined patterns
    from .parachuteignore files.
    """

    def __init__(self, vault_path: Optional[Path] = None):
        """
        Initialize with optional vault path.

        Args:
            vault_path: Path to the vault root. If provided, loads
                       .parachuteignore from the vault.
        """
        self.vault_path = vault_path
        self.patterns: list[str] = list(BUILTIN_DENY_PATTERNS)
        self._loaded = False

        if vault_path:
            self._load_ignore_file(vault_path / ".parachuteignore")

    def _load_ignore_file(self, path: Path) -> None:
        """Load patterns from a .parachuteignore file."""
        if not path.exists():
            logger.debug(f"No .parachuteignore found at {path}")
            return

        try:
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    # Skip empty lines and comments
                    if not line or line.startswith("#"):
                        continue
                    self.patterns.append(line)

            logger.info(f"Loaded {len(self.patterns)} ignore patterns from {path}")
            self._loaded = True

        except Exception as e:
            logger.error(f"Error loading .parachuteignore: {e}")

    def is_denied(self, path: str) -> bool:
        """
        Check if a path matches any deny pattern.

        Args:
            path: Path to check (relative to vault root)

        Returns:
            True if the path should be denied access
        """
        # Normalize the path - remove leading ./ but preserve dotfiles
        normalized = path
        if normalized.startswith("./"):
            normalized = normalized[2:]
        elif normalized.startswith("/"):
            normalized = normalized[1:]

        for pattern in self.patterns:
            if self._matches_pattern(normalized, pattern):
                return True

        return False

    def _matches_pattern(self, path: str, pattern: str) -> bool:
        """
        Check if a path matches a single pattern.

        Supports:
        - Exact matches (.env, README.md)
        - Simple glob patterns (*.txt, file.*)
        - Directory patterns (dir/**)
        - Recursive patterns (**/name, **/dir/**)
        """
        # Exact match (no wildcards)
        if "*" not in pattern and "?" not in pattern:
            # Check exact match
            if path == pattern:
                return True
            # Check if pattern matches basename
            if Path(path).name == pattern:
                return True
            # Check if pattern matches any path component
            if pattern in path.split("/"):
                return True
            return False

        # Handle ** patterns (recursive matching)
        if "**" in pattern:
            # Handle patterns like "**/dirname/**" (matches anything containing dirname as a component)
            # This is common for patterns like "**/node_modules/**"
            if pattern.startswith("**/") and pattern.endswith("/**"):
                # Extract the middle part
                middle = pattern[3:-3]  # Remove **/ and /**
                if "/" not in middle:
                    # Simple directory name - check if it's a path component
                    if middle in path.split("/"):
                        return True

            # Split pattern at first **
            parts = pattern.split("**", 1)
            if len(parts) == 2:
                prefix, suffix = parts
                prefix = prefix.rstrip("/")
                suffix = suffix.lstrip("/")

                # Handle remaining ** in suffix
                if "**" in suffix:
                    # Pattern like "**/dir/**" - already handled above
                    pass

                # Pattern like "**/name" - matches name anywhere
                elif not prefix and suffix and "/" not in suffix:
                    if fnmatch.fnmatch(Path(path).name, suffix):
                        return True
                    # Also match if the suffix pattern matches any component
                    for part in path.split("/"):
                        if fnmatch.fnmatch(part, suffix):
                            return True

                # Pattern like "dir/**/*" - matches anything under dir
                elif prefix and (suffix == "*" or suffix == "/*" or not suffix):
                    if path.startswith(prefix + "/") or path == prefix:
                        return True

                # General case: prefix/**/suffix
                elif prefix and suffix:
                    if path.startswith(prefix + "/") or path.startswith(prefix):
                        remaining = path[len(prefix):].lstrip("/")
                        if fnmatch.fnmatch(remaining, suffix) or fnmatch.fnmatch(remaining, "*/" + suffix):
                            return True

                # Pattern like "**/suffix" with suffix containing /
                elif not prefix and suffix:
                    # Match against the full path
                    if fnmatch.fnmatch(path, "*" + suffix):
                        return True
                    if path.endswith(suffix.lstrip("/")):
                        return True

            return False

        # Standard fnmatch for simple patterns
        if fnmatch.fnmatch(path, pattern):
            return True

        # Also check the basename for patterns like "*.key"
        if fnmatch.fnmatch(Path(path).name, pattern):
            return True

        return False

    def get_all_patterns(self) -> list[str]:
        """Get all active deny patterns."""
        return list(self.patterns)

    def add_pattern(self, pattern: str) -> None:
        """Add a pattern to the deny list."""
        if pattern not in self.patterns:
            self.patterns.append(pattern)

    def remove_pattern(self, pattern: str) -> bool:
        """
        Remove a pattern from the deny list.

        Note: Cannot remove built-in patterns.
        """
        if pattern in BUILTIN_DENY_PATTERNS:
            logger.warning(f"Cannot remove built-in pattern: {pattern}")
            return False

        if pattern in self.patterns:
            self.patterns.remove(pattern)
            return True

        return False


# Global instance (initialized when server starts)
_ignore_patterns: Optional[IgnorePatterns] = None


def get_ignore_patterns() -> IgnorePatterns:
    """Get the global ignore patterns instance."""
    global _ignore_patterns
    if _ignore_patterns is None:
        _ignore_patterns = IgnorePatterns()
    return _ignore_patterns


def init_ignore_patterns(vault_path: Path) -> IgnorePatterns:
    """Initialize the global ignore patterns instance."""
    global _ignore_patterns
    _ignore_patterns = IgnorePatterns(vault_path)
    return _ignore_patterns
