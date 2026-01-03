"""
Session data models.

Sessions are stored in SQLite with SDK JSONL files as the source of truth for messages.
"""

from datetime import datetime
from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, Field


class SessionSource(str, Enum):
    """Source of the session."""

    PARACHUTE = "parachute"
    CLAUDE_CODE = "claude-code"


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


class SessionCreate(BaseModel):
    """Data for creating a new session."""

    id: str = Field(description="SDK session ID")
    title: Optional[str] = None
    module: str = "chat"
    source: SessionSource = SessionSource.PARACHUTE
    working_directory: Optional[str] = None
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
