"""
SSE event models for streaming chat responses.

These match the event types from the Node.js server for compatibility.
"""

from typing import Any, Literal, Optional, Union

from pydantic import BaseModel, Field


class SessionEvent(BaseModel):
    """Session information event - sent at start of stream."""

    type: Literal["session"] = "session"
    session_id: Optional[str] = Field(alias="sessionId")
    working_directory: Optional[str] = Field(alias="workingDirectory", default=None)
    resume_info: dict[str, Any] = Field(alias="resumeInfo")

    model_config = {"populate_by_name": True}


class ModelEvent(BaseModel):
    """Model information event - sent when model is determined."""

    type: Literal["model"] = "model"
    model: str


class InitEvent(BaseModel):
    """Initialization event - sent when SDK is ready."""

    type: Literal["init"] = "init"
    tools: list[str] = Field(default_factory=list)
    permission_mode: Optional[str] = Field(alias="permissionMode", default=None)

    model_config = {"populate_by_name": True}


class TextEvent(BaseModel):
    """Text output event - streaming text from assistant."""

    type: Literal["text"] = "text"
    content: str
    delta: str = ""


class ThinkingEvent(BaseModel):
    """Thinking/chain-of-thought event."""

    type: Literal["thinking"] = "thinking"
    content: str


class ToolUseEvent(BaseModel):
    """Tool use event - assistant is using a tool."""

    type: Literal["tool_use"] = "tool_use"
    tool: dict[str, Any]


class ToolResultEvent(BaseModel):
    """Tool result event - result from tool execution."""

    type: Literal["tool_result"] = "tool_result"
    tool_use_id: str = Field(alias="toolUseId")
    content: str
    is_error: bool = Field(alias="isError", default=False)

    model_config = {"populate_by_name": True}


class DoneEvent(BaseModel):
    """Completion event - stream finished successfully."""

    type: Literal["done"] = "done"
    response: str
    session_id: str = Field(alias="sessionId")
    working_directory: Optional[str] = Field(alias="workingDirectory", default=None)
    message_count: int = Field(alias="messageCount")
    model: Optional[str] = None
    duration_ms: int = Field(alias="durationMs")
    spawned: list[str] = Field(default_factory=list)
    tool_calls: Optional[list[dict[str, Any]]] = Field(alias="toolCalls", default=None)
    permission_denials: Optional[list[dict[str, Any]]] = Field(
        alias="permissionDenials", default=None
    )
    session_resume: Optional[dict[str, Any]] = Field(alias="sessionResume", default=None)

    model_config = {"populate_by_name": True}


class AbortedEvent(BaseModel):
    """Abort event - stream was cancelled by user."""

    type: Literal["aborted"] = "aborted"
    message: str
    session_id: Optional[str] = Field(alias="sessionId", default=None)
    partial_response: Optional[str] = Field(alias="partialResponse", default=None)

    model_config = {"populate_by_name": True}


class SessionUnavailableEvent(BaseModel):
    """Session unavailable event - SDK session not found."""

    type: Literal["session_unavailable"] = "session_unavailable"
    reason: str
    session_id: str = Field(alias="sessionId")
    has_markdown_history: bool = Field(alias="hasMarkdownHistory")
    message_count: int = Field(alias="messageCount")
    message: str

    model_config = {"populate_by_name": True}


class ErrorEvent(BaseModel):
    """Error event - something went wrong."""

    type: Literal["error"] = "error"
    error: str
    session_id: Optional[str] = Field(alias="sessionId", default=None)

    model_config = {"populate_by_name": True}


class PermissionRequestEvent(BaseModel):
    """Permission request event - agent needs user approval for an operation."""

    type: Literal["permission_request"] = "permission_request"
    id: str
    tool_name: str = Field(alias="toolName")
    agent_name: str = Field(alias="agentName")
    timestamp: int

    # For write tools
    file_path: Optional[str] = Field(alias="filePath", default=None)
    allowed_patterns: list[str] = Field(alias="allowedPatterns", default_factory=list)

    # For MCP tools
    mcp_server: Optional[str] = Field(alias="mcpServer", default=None)
    mcp_tool: Optional[str] = Field(alias="mcpTool", default=None)

    # Tool input for context
    input_data: Optional[dict[str, Any]] = Field(alias="input", default=None)

    model_config = {"populate_by_name": True}


# Union type for all SSE events
SSEEvent = Union[
    SessionEvent,
    ModelEvent,
    InitEvent,
    TextEvent,
    ThinkingEvent,
    ToolUseEvent,
    ToolResultEvent,
    DoneEvent,
    AbortedEvent,
    SessionUnavailableEvent,
    ErrorEvent,
    PermissionRequestEvent,
]
