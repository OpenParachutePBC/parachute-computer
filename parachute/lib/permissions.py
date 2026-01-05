"""
Permission checking utilities.

Provides centralized permission checking that combines:
- Session-specific permissions (from metadata)
- Global deny patterns (from .parachuteignore)
- Built-in security rules
"""

import logging
from pathlib import Path
from typing import Optional

from parachute.lib.ignore_patterns import get_ignore_patterns
from parachute.models.session import Session, SessionPermissions

logger = logging.getLogger(__name__)


class PermissionChecker:
    """
    Checks permissions for file and tool operations.

    Combines session-specific grants with global deny patterns.
    The deny list always takes precedence over grants.
    """

    def __init__(
        self,
        session: Session,
        vault_path: Path,
    ):
        """
        Initialize permission checker.

        Args:
            session: The session with permissions in metadata
            vault_path: Path to the vault root for path normalization
        """
        self.session = session
        self.vault_path = vault_path
        self.permissions = session.permissions
        self.ignore = get_ignore_patterns()

    def can_read(self, path: str) -> tuple[bool, Optional[str]]:
        """
        Check if reading the given path is allowed.

        Args:
            path: Absolute or relative path to check

        Returns:
            Tuple of (allowed, reason). If not allowed, reason explains why.
        """
        relative_path = self._to_relative_path(path)

        # Check deny list first (always enforced)
        if self.ignore.is_denied(relative_path):
            return False, f"Path matches deny pattern: {relative_path}"

        # Check session permissions
        if self.permissions.can_read(relative_path):
            return True, None

        return False, f"No read permission for: {relative_path}"

    def can_write(self, path: str) -> tuple[bool, Optional[str]]:
        """
        Check if writing to the given path is allowed.

        Args:
            path: Absolute or relative path to check

        Returns:
            Tuple of (allowed, reason). If not allowed, reason explains why.
        """
        relative_path = self._to_relative_path(path)

        # Check deny list first (always enforced)
        if self.ignore.is_denied(relative_path):
            return False, f"Path matches deny pattern: {relative_path}"

        # Check session permissions
        if self.permissions.can_write(relative_path):
            return True, None

        return False, f"No write permission for: {relative_path}"

    def can_bash(self, command: str) -> tuple[bool, Optional[str]]:
        """
        Check if running the given bash command is allowed.

        Args:
            command: The full bash command string

        Returns:
            Tuple of (allowed, reason). If not allowed, reason explains why.
        """
        # Extract base command
        base_cmd = command.strip().split()[0] if command.strip() else ""

        # Check for dangerous commands (always blocked)
        dangerous = self._is_dangerous_command(command)
        if dangerous:
            return False, dangerous

        # Check session permissions
        if self.permissions.can_bash(command):
            return True, None

        return False, f"Bash command not allowed: {base_cmd}"

    def _to_relative_path(self, path: str) -> str:
        """Convert an absolute path to a vault-relative path."""
        try:
            abs_path = Path(path).resolve()
            if abs_path.is_relative_to(self.vault_path):
                return str(abs_path.relative_to(self.vault_path))
            # Path is outside vault - return as-is
            return path
        except (ValueError, OSError):
            return path

    def _is_dangerous_command(self, command: str) -> Optional[str]:
        """
        Check if a command is inherently dangerous.

        Returns the reason if dangerous, None if OK.
        """
        cmd_lower = command.lower().strip()

        # Commands that are always blocked
        blocked_commands = [
            ("sudo", "sudo commands are not allowed"),
            ("rm -rf /", "Cannot delete root filesystem"),
            ("rm -rf ~", "Cannot delete home directory"),
            ("rm -rf /*", "Cannot delete root filesystem"),
            (":(){:|:&};:", "Fork bomb detected"),
            ("mkfs", "Cannot format filesystems"),
            ("dd if=", "Direct disk access not allowed"),
            ("> /dev/", "Cannot write to device files"),
            ("chmod -R 777 /", "Cannot change permissions on root"),
        ]

        for pattern, reason in blocked_commands:
            if pattern in cmd_lower:
                return reason

        # Check for command substitution that might bypass checks
        if "$(" in command or "`" in command:
            # Only warn, don't block entirely - let session permissions decide
            logger.warning(f"Command contains substitution: {command[:50]}...")

        return None

    def get_suggested_grant(
        self, path: str, for_write: bool = False
    ) -> list[dict[str, str]]:
        """
        Get suggested permission grants for a path.

        Returns a list of grant options from most specific to most broad.
        """
        relative_path = self._to_relative_path(path)
        parts = Path(relative_path).parts

        suggestions = []

        # Option 1: Just this file
        suggestions.append({
            "scope": "file",
            "pattern": relative_path,
            "label": f"This file only ({Path(relative_path).name})",
        })

        # Option 2: This folder
        if len(parts) > 1:
            folder = str(Path(*parts[:-1]))
            suggestions.append({
                "scope": "folder",
                "pattern": f"{folder}/*",
                "label": f"{folder}/ folder",
            })

        # Option 3: This folder recursively
        if len(parts) > 1:
            folder = str(Path(*parts[:-1]))
            suggestions.append({
                "scope": "recursive",
                "pattern": f"{folder}/**/*",
                "label": f"{folder}/ and subfolders",
            })

        # Option 4: Root folder (if nested)
        if len(parts) > 2:
            root_folder = parts[0]
            suggestions.append({
                "scope": "root",
                "pattern": f"{root_folder}/**/*",
                "label": f"All of {root_folder}/",
            })

        # Option 5: Full vault access
        suggestions.append({
            "scope": "vault",
            "pattern": "**/*",
            "label": "Full vault access",
        })

        return suggestions


def check_read_permission(
    session: Session, path: str, vault_path: Path
) -> tuple[bool, Optional[str]]:
    """Convenience function to check read permission."""
    checker = PermissionChecker(session, vault_path)
    return checker.can_read(path)


def check_write_permission(
    session: Session, path: str, vault_path: Path
) -> tuple[bool, Optional[str]]:
    """Convenience function to check write permission."""
    checker = PermissionChecker(session, vault_path)
    return checker.can_write(path)


def check_bash_permission(
    session: Session, command: str, vault_path: Path
) -> tuple[bool, Optional[str]]:
    """Convenience function to check bash permission."""
    checker = PermissionChecker(session, vault_path)
    return checker.can_bash(command)
