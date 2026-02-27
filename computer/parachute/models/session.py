"""
Session data models.

Sessions are stored in SQLite with SDK JSONL files as the source of truth for messages.
"""

from datetime import datetime
from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, Field


class TrustLevel(str, Enum):
    """Trust level for agent execution.

    Binary model: either you trust the agent (bare metal) or you don't (Docker).
    """

    DIRECT = "direct"  # Bare metal execution, bypass SDK permissions
    SANDBOXED = "sandboxed"  # Docker container, scoped mounts

    # Legacy aliases — kept so any code referencing TrustLevel.TRUSTED/UNTRUSTED
    # still works without a hard break. Will be removed in a future cleanup.
    TRUSTED = "direct"
    UNTRUSTED = "sandboxed"


class SessionPermissions(BaseModel):
    """
    Permissions granted for a session.

    Controls what file operations and tools the agent can use.
    Stored in session metadata and checked at runtime.
    """

    # Trust level (binary model)
    trust_level: TrustLevel = Field(
        default=TrustLevel.DIRECT,
        alias="trustLevel",
        serialization_alias="trustLevel",
        description="Trust level: direct (bare metal) or sandboxed (Docker)",
    )

    # File access patterns (glob-style, relative to vault)
    read: list[str] = Field(
        default_factory=list,
        description="Glob patterns for allowed read paths (e.g., 'Blogs/**/*')",
    )
    write: list[str] = Field(
        default_factory=lambda: ["Chat/artifacts/*"],
        description="Glob patterns for allowed write paths",
    )

    # Allowed vault paths for VAULT/SANDBOXED levels
    allowed_paths: list[str] = Field(
        default_factory=list,
        alias="allowedPaths",
        serialization_alias="allowedPaths",
        description="Allowed vault paths for restricted trust levels",
    )

    # Bash command access
    bash: list[str] | bool = Field(
        default_factory=lambda: ["ls", "pwd", "tree"],
        description="Allowed bash commands, or True for all, or False for none",
    )

    model_config = {"populate_by_name": True}

    def can_read(self, path: str) -> bool:
        """Check if reading the given path is allowed."""
        if self.trust_level == TrustLevel.DIRECT:
            return True
        # Sandboxed: Docker handles isolation, but check allowed_paths if set
        if self.allowed_paths:
            return self._matches_any_pattern(path, self.allowed_paths)
        return self._matches_any_pattern(path, self.read)

    def can_write(self, path: str) -> bool:
        """Check if writing to the given path is allowed."""
        if self.trust_level == TrustLevel.DIRECT:
            return True
        if self.allowed_paths:
            return self._matches_any_pattern(path, self.allowed_paths)
        return self._matches_any_pattern(path, self.write)

    def can_bash(self, command: str) -> bool:
        """Check if running the given bash command is allowed."""
        if self.trust_level == TrustLevel.DIRECT:
            return True
        # Sandboxed runs in Docker — no host bash
        return False

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
    TELEGRAM = "telegram"  # From Telegram bot connector
    DISCORD = "discord"  # From Discord bot connector
    MATRIX = "matrix"  # From Matrix bot connector


BOT_SOURCES: frozenset[SessionSource] = frozenset({
    SessionSource.TELEGRAM,
    SessionSource.DISCORD,
    SessionSource.MATRIX,
})
# Session sources that originate from external bot connectors.
# Used for two security gates:
# 1. Credential injection: bot sessions receive empty credentials (never host secrets).
# 2. Docker unavailability: bot sessions hard-fail; app sessions fall through to direct execution.


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
    agent_type: Optional[str] = Field(
        default=None,
        alias="agentType",
        serialization_alias="agentType",
        description="Agent type/name (e.g., 'vault-agent', 'orchestrator', 'summarizer')",
    )
    trust_level: Optional[str] = Field(
        default=None,
        alias="trustLevel",
        serialization_alias="trustLevel",
        description="Trust level: trusted or untrusted (NULL = trusted for backward compat)",
    )
    linked_bot_platform: Optional[str] = Field(
        default=None,
        alias="linkedBotPlatform",
        serialization_alias="linkedBotPlatform",
        description="Bot platform: telegram, discord, or NULL",
    )
    linked_bot_chat_id: Optional[str] = Field(
        default=None,
        alias="linkedBotChatId",
        serialization_alias="linkedBotChatId",
        description="Platform-specific chat ID",
    )
    linked_bot_chat_type: Optional[str] = Field(
        default=None,
        alias="linkedBotChatType",
        serialization_alias="linkedBotChatType",
        description="Chat type: dm, group, or NULL",
    )
    workspace_id: Optional[str] = Field(
        default=None,
        alias="workspaceId",
        serialization_alias="workspaceId",
        description="Workspace slug this session belongs to",
    )
    parent_session_id: Optional[str] = Field(
        default=None,
        alias="parentSessionId",
        serialization_alias="parentSessionId",
        description="Session that spawned this one (if agent-created)",
    )
    created_by: str = Field(
        default="user",
        alias="createdBy",
        serialization_alias="createdBy",
        description="Session creator: 'user' or 'agent:<session_id>'",
    )
    summary: Optional[str] = Field(
        default=None, description="AI-generated session summary"
    )
    curator_session_id: Optional[str] = Field(
        default=None,
        alias="curatorSessionId",
        serialization_alias="curatorSessionId",
        description="SDK session ID of this session's curator background agent",
    )
    bridge_context_log: Optional[str] = Field(
        default=None,
        alias="bridgeContextLog",
        serialization_alias="bridgeContextLog",
        description="JSON: list of {query, type, turn_number} — bridge agent context loaded/stored",
    )
    metadata: Optional[dict[str, Any]] = Field(
        default=None, description="Additional metadata"
    )

    model_config = {"from_attributes": True, "populate_by_name": True}

    def get_trust_level(self) -> TrustLevel:
        """Get effective trust level, defaulting to DIRECT for backward compat."""
        from parachute.core.trust import normalize_trust_level

        if self.trust_level:
            try:
                canonical = normalize_trust_level(self.trust_level)
                return TrustLevel(canonical)
            except ValueError:
                return TrustLevel.DIRECT
        return TrustLevel.DIRECT

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

    def get_agent_type(self) -> Optional[str]:
        """Get agent type, checking field first, then metadata for backwards compatibility."""
        if self.agent_type:
            return self.agent_type
        if self.metadata and "agent_type" in self.metadata:
            return self.metadata["agent_type"]
        return None


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
    agent_type: Optional[str] = None
    trust_level: Optional[str] = None
    linked_bot_platform: Optional[str] = None
    linked_bot_chat_id: Optional[str] = None
    linked_bot_chat_type: Optional[str] = None
    workspace_id: Optional[str] = None
    parent_session_id: Optional[str] = None
    created_by: str = "user"
    metadata: Optional[dict[str, Any]] = None


class SessionUpdate(BaseModel):
    """Data for updating a session."""

    title: Optional[str] = None
    summary: Optional[str] = None
    archived: Optional[bool] = None
    message_count: Optional[int] = None
    model: Optional[str] = None
    agent_type: Optional[str] = None
    metadata: Optional[dict[str, Any]] = None
    trust_level: Optional[str] = None
    working_directory: Optional[str] = None
    workspace_id: Optional[str] = None
    curator_session_id: Optional[str] = None
    bridge_context_log: Optional[str] = None


class PairingRequest(BaseModel):
    """A request from an unknown bot user to be paired/approved."""

    id: str = Field(description="Unique request ID (UUID)")
    platform: str = Field(description="Bot platform: telegram, discord")
    platform_user_id: str = Field(
        alias="platformUserId",
        serialization_alias="platformUserId",
        description="Platform-specific user ID",
    )
    platform_user_display: Optional[str] = Field(
        default=None,
        alias="platformUserDisplay",
        serialization_alias="platformUserDisplay",
        description="User display name on the platform",
    )
    platform_chat_id: str = Field(
        alias="platformChatId",
        serialization_alias="platformChatId",
        description="Platform-specific chat ID where request originated",
    )
    status: str = Field(default="pending", description="Request status: pending, approved, denied")
    approved_trust_level: Optional[str] = Field(
        default=None,
        alias="approvedTrustLevel",
        serialization_alias="approvedTrustLevel",
        description="Trust level granted on approval",
    )
    created_at: datetime = Field(
        alias="createdAt",
        serialization_alias="createdAt",
        description="When the request was created",
    )
    resolved_at: Optional[datetime] = Field(
        default=None,
        alias="resolvedAt",
        serialization_alias="resolvedAt",
        description="When the request was resolved",
    )
    resolved_by: Optional[str] = Field(
        default=None,
        alias="resolvedBy",
        serialization_alias="resolvedBy",
        description="Who resolved the request",
    )

    model_config = {"from_attributes": True, "populate_by_name": True}


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
