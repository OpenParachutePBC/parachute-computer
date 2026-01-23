"""
Session data models.

Sessions are stored in SQLite with SDK JSONL files as the source of truth for messages.
"""

from datetime import datetime
from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, Field


class SessionPermissions(BaseModel):
    """
    Permissions granted for a session.

    Controls what file operations and tools the agent can use.
    Stored in session metadata and checked at runtime.
    """

    # File access patterns (glob-style, relative to vault)
    read: list[str] = Field(
        default_factory=list,
        description="Glob patterns for allowed read paths (e.g., 'Blogs/**/*')",
    )
    write: list[str] = Field(
        default_factory=lambda: ["Chat/artifacts/*"],
        description="Glob patterns for allowed write paths",
    )

    # Bash command access
    bash: list[str] | bool = Field(
        default_factory=lambda: ["ls", "pwd", "tree"],
        description="Allowed bash commands, or True for all, or False for none",
    )

    # Trust mode bypasses all permission checks (except deny list)
    # Default to True so existing sessions continue to work without prompts
    trust_mode: bool = Field(
        default=True,
        alias="trustMode",
        serialization_alias="trustMode",
        description="If true, skip all permission prompts",
    )

    model_config = {"populate_by_name": True}

    def can_read(self, path: str) -> bool:
        """Check if reading the given path is allowed."""
        if self.trust_mode:
            return True
        return self._matches_any_pattern(path, self.read)

    def can_write(self, path: str) -> bool:
        """Check if writing to the given path is allowed."""
        if self.trust_mode:
            return True
        return self._matches_any_pattern(path, self.write)

    def can_bash(self, command: str) -> bool:
        """Check if running the given bash command is allowed."""
        if self.trust_mode:
            return True
        if isinstance(self.bash, bool):
            return self.bash
        # Extract base command (first word)
        base_cmd = command.strip().split()[0] if command.strip() else ""
        return base_cmd in self.bash

    def _matches_any_pattern(self, path: str, patterns: list[str]) -> bool:
        """Check if path matches any of the glob patterns."""
        import fnmatch
        # Normalize path (remove leading ./ or /)
        normalized = path.lstrip("./")
        for pattern in patterns:
            if fnmatch.fnmatch(normalized, pattern):
                return True
            # Also check if the pattern matches a parent directory
            # e.g., pattern "Blogs/**/*" should match "Blogs/post.md"
            if "**" in pattern:
                # Convert ** to regex-style matching
                base = pattern.split("**")[0].rstrip("/")
                if normalized.startswith(base):
                    return True
        return False


class SessionSource(str, Enum):
    """Source of the session."""

    PARACHUTE = "parachute"
    CLAUDE_CODE = "claude-code"
    CLAUDE_WEB = "claude"  # Imported from Claude.ai web app
    CHATGPT = "chatgpt"  # Imported from ChatGPT


class Session(BaseModel):
    """A chat session."""

    id: str = Field(description="SDK session ID (UUID)")
    title: Optional[str] = Field(default=None, description="Session title")
    module: str = Field(default="chat", description="Module (chat, daily, build)")
    source: SessionSource = Field(
        default=SessionSource.PARACHUTE, description="Session source"
    )
    working_directory: Optional[str] = Field(
        default=None,
        alias="workingDirectory",
        serialization_alias="workingDirectory",
        description="Working directory for file operations",
    )
    vault_root: Optional[str] = Field(
        default=None,
        alias="vaultRoot",
        serialization_alias="vaultRoot",
        description="Root path of vault when session was created (for cross-machine portability)",
    )
    model: Optional[str] = Field(default=None, description="Model used")
    message_count: int = Field(
        default=0,
        alias="messageCount",
        serialization_alias="messageCount",
        description="Number of messages",
    )
    archived: bool = Field(default=False, description="Whether session is archived")
    created_at: datetime = Field(
        alias="createdAt",
        serialization_alias="createdAt",
        description="Creation timestamp",
    )
    last_accessed: datetime = Field(
        alias="lastAccessed",
        serialization_alias="lastAccessed",
        description="Last access timestamp",
    )
    continued_from: Optional[str] = Field(
        default=None,
        alias="continuedFrom",
        serialization_alias="continuedFrom",
        description="Parent session ID if continued",
    )
    metadata: Optional[dict[str, Any]] = Field(
        default=None, description="Additional metadata"
    )

    model_config = {"from_attributes": True, "populate_by_name": True}

    @property
    def permissions(self) -> SessionPermissions:
        """Get session permissions from metadata."""
        if self.metadata and "permissions" in self.metadata:
            return SessionPermissions(**self.metadata["permissions"])
        return SessionPermissions()

    def with_permissions(self, permissions: SessionPermissions) -> "Session":
        """Return a copy of the session with updated permissions."""
        new_metadata = dict(self.metadata) if self.metadata else {}
        new_metadata["permissions"] = permissions.model_dump(by_alias=True)
        return self.model_copy(update={"metadata": new_metadata})


class SessionCreate(BaseModel):
    """Data for creating a new session."""

    id: str = Field(description="SDK session ID")
    title: Optional[str] = None
    module: str = "chat"
    source: SessionSource = SessionSource.PARACHUTE
    working_directory: Optional[str] = None
    vault_root: Optional[str] = None
    model: Optional[str] = None
    continued_from: Optional[str] = None
    metadata: Optional[dict[str, Any]] = None


class SessionUpdate(BaseModel):
    """Data for updating a session."""

    title: Optional[str] = None
    archived: Optional[bool] = None
    message_count: Optional[int] = None
    model: Optional[str] = None
    metadata: Optional[dict[str, Any]] = None


class SessionWithMessages(Session):
    """Session with message history loaded from SDK JSONL."""

    messages: list[dict[str, Any]] = Field(
        default_factory=list, description="Message history"
    )


class ResumeInfo(BaseModel):
    """Information about how a session was resumed."""

    method: str = Field(description="Resume method: 'sdk_resume', 'new', 'context_injection'")
    is_new_session: bool = Field(description="Whether this is a new session")
    previous_message_count: int = Field(
        default=0, description="Messages from previous session"
    )
    sdk_session_available: bool = Field(
        default=True, description="Whether SDK session was found"
    )
