"""
API request models.
"""

from typing import Any, Optional

from pydantic import BaseModel, Field


class Attachment(BaseModel):
    """File attachment for chat messages."""

    id: str = Field(description="Unique ID for the attachment")
    fileName: str = Field(alias="fileName", description="Original file name")
    filePath: str = Field(alias="filePath", description="File path")
    mimeType: str = Field(alias="mimeType", description="MIME type")
    sizeBytes: int = Field(alias="sizeBytes", description="Size in bytes")
    type: str = Field(description="Attachment type (image, pdf, text, code)")
    base64Data: Optional[str] = Field(alias="base64Data", default=None, description="Base64 encoded data")

    model_config = {"populate_by_name": True}


class ChatRequest(BaseModel):
    """Request body for POST /api/chat."""

    message: str = Field(description="User message (required)")
    session_id: Optional[str] = Field(
        alias="sessionId",
        default=None,
        description="SDK session ID to resume",
    )
    module: str = Field(default="chat", description="Module (chat, daily, build)")
    system_prompt: Optional[str] = Field(
        alias="systemPrompt",
        default=None,
        description="Override system prompt",
    )
    working_directory: Optional[str] = Field(
        alias="workingDirectory",
        default=None,
        description="Working directory for file operations",
    )
    initial_context: Optional[str] = Field(
        alias="initialContext",
        default=None,
        description="Initial context for new sessions",
    )
    prior_conversation: Optional[str] = Field(
        alias="priorConversation",
        default=None,
        description="Prior conversation for continuation",
    )
    continued_from: Optional[str] = Field(
        alias="continuedFrom",
        default=None,
        description="Session ID this continues from",
    )
    contexts: Optional[list[str]] = Field(
        default=None,
        description="Context files to load",
    )
    recovery_mode: Optional[str] = Field(
        alias="recoveryMode",
        default=None,
        description="Recovery mode: 'inject_context' or 'fresh_start'",
    )
    attachments: Optional[list[Attachment]] = Field(
        default=None,
        description="File attachments (images, PDFs, text files)",
    )

    # Legacy fields for compatibility
    agent_path: Optional[str] = Field(alias="agentPath", default=None)

    model_config = {"populate_by_name": True}


class ModulePromptUpdate(BaseModel):
    """Request body for PUT /api/modules/:mod/prompt."""

    content: Optional[str] = Field(default=None, description="New prompt content")
    reset: bool = Field(default=False, description="Reset to default prompt")


class McpServerCreate(BaseModel):
    """Request body for POST /api/mcps."""

    name: str = Field(description="Server name")
    config: dict[str, Any] = Field(description="Server configuration")


class SkillCreate(BaseModel):
    """Request body for POST /api/skills."""

    name: str = Field(description="Skill name")
    description: Optional[str] = None
    content: Optional[str] = None
    allowed_tools: Optional[list[str]] = Field(alias="allowedTools", default=None)

    model_config = {"populate_by_name": True}


class SymlinkCreate(BaseModel):
    """Request body for POST /api/symlink."""

    target: str = Field(description="Absolute path to link target")
    link: str = Field(description="Relative path for the symlink in vault")


class FileWrite(BaseModel):
    """Request body for PUT /api/write."""

    path: str = Field(description="Relative path in vault")
    content: str = Field(description="File content")
