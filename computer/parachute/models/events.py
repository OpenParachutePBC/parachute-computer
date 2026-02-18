"""
SSE event models for streaming chat responses.

These match the event types from the Node.js server for compatibility.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any, Literal, Optional, Union

from pydantic import BaseModel, Field

from parachute.lib.typed_errors import ErrorCode, RecoveryAction

if TYPE_CHECKING:
    from parachute.lib.typed_errors import TypedError


class SessionEvent(BaseModel):
    """Session information event - sent at start of stream."""

    type: Literal["session"] = "session"
    session_id: Optional[str] = Field(alias="sessionId")
    working_directory: Optional[str] = Field(alias="workingDirectory", default=None)
    resume_info: dict[str, Any] = Field(alias="resumeInfo")
    trust_level: Optional[str] = Field(alias="trustLevel", default=None)

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


class TypedErrorEvent(BaseModel):
    """Typed error event - structured error with recovery actions.

    This provides richer error information than ErrorEvent, including:
    - Error code for programmatic handling
    - User-friendly title and message
    - Suggested recovery actions with keyboard shortcuts
    - Retry capability information
    """

    type: Literal["typed_error"] = "typed_error"
    code: ErrorCode = Field(description="Error code for programmatic handling")
    title: str = Field(description="User-friendly error title")
    message: str = Field(description="Detailed error message")
    actions: list[RecoveryAction] = Field(
        default_factory=list, description="Suggested recovery actions"
    )
    can_retry: bool = Field(
        alias="canRetry", default=False, description="Whether retry is possible"
    )
    retry_delay_ms: Optional[int] = Field(
        alias="retryDelayMs", default=None, description="Suggested retry delay in ms"
    )
    original_error: Optional[str] = Field(
        alias="originalError", default=None, description="Original error for debugging"
    )
    session_id: Optional[str] = Field(alias="sessionId", default=None)

    model_config = {"populate_by_name": True}

    @classmethod
    def from_typed_error(
        cls, error: TypedError, session_id: str | None = None
    ) -> TypedErrorEvent:
        """Create from a TypedError, avoiding brittle field-by-field copying."""
        return cls(
            code=error.code,
            title=error.title,
            message=error.message,
            actions=error.actions,
            can_retry=error.can_retry,
            retry_delay_ms=error.retry_delay_ms,
            original_error=error.original_error,
            session_id=session_id,
        )


class WarningEvent(BaseModel):
    """Warning event — non-fatal issue, stream continues.

    Unlike TypedErrorEvent, warnings do not terminate the stream.
    Existing clients that don't handle 'warning' will safely ignore it.
    """

    type: Literal["warning"] = "warning"
    code: ErrorCode = Field(description="Warning code for programmatic handling")
    title: str = Field(description="User-friendly warning title")
    message: str = Field(description="Detailed warning message")
    details: Optional[list[str]] = Field(
        default=None, description="List of specific issues (e.g., per-MCP failures)"
    )
    session_id: Optional[str] = Field(alias="sessionId", default=None)

    model_config = {"populate_by_name": True}


class UserMessageEvent(BaseModel):
    """User message event - sent at start of stream so clients can display immediately.

    This is emitted by the server before the SDK starts processing, ensuring
    the user's message is visible even if the client rejoins mid-stream
    (since the SDK doesn't write user messages to JSONL until response completes).
    """

    type: Literal["user_message"] = "user_message"
    content: str = Field(description="The user's message text")

    model_config = {"populate_by_name": True}


class PromptMetadataEvent(BaseModel):
    """Prompt composition metadata - sent after session event for transparency."""

    type: Literal["prompt_metadata"] = "prompt_metadata"

    # Prompt source info
    prompt_source: str = Field(
        alias="promptSource",
        description="Source of base prompt: 'default', 'module', 'agent', 'custom'",
    )
    prompt_source_path: Optional[str] = Field(
        alias="promptSourcePath",
        default=None,
        description="Path to prompt file if from module/agent (e.g., 'Chat/CLAUDE.md')",
    )

    # Context files info
    context_files: list[str] = Field(
        alias="contextFiles",
        default_factory=list,
        description="List of context files loaded",
    )
    context_tokens: int = Field(
        alias="contextTokens",
        default=0,
        description="Estimated tokens from context files",
    )
    context_truncated: bool = Field(
        alias="contextTruncated",
        default=False,
        description="Whether context was truncated due to token limit",
    )

    # Agent info
    agent_name: Optional[str] = Field(
        alias="agentName",
        default=None,
        description="Name of agent being used",
    )
    available_agents: list[str] = Field(
        alias="availableAgents",
        default_factory=list,
        description="List of specialized agents available",
    )

    # Capability info (populated after workspace filtering)
    available_skills: list[str] = Field(
        alias="availableSkills",
        default_factory=list,
        description="List of skills available for this session",
    )
    available_mcps: list[str] = Field(
        alias="availableMcps",
        default_factory=list,
        description="List of MCP servers available for this session",
    )

    # Token estimates
    base_prompt_tokens: int = Field(
        alias="basePromptTokens",
        default=0,
        description="Estimated tokens in base prompt",
    )
    total_prompt_tokens: int = Field(
        alias="totalPromptTokens",
        default=0,
        description="Total estimated tokens in system prompt",
    )

    # Trust mode
    trust_mode: bool = Field(
        alias="trustMode",
        default=True,
        description="Whether trust mode is enabled for this session",
    )

    # Working directory CLAUDE.md
    working_directory_claude_md: Optional[str] = Field(
        alias="workingDirectoryClaudeMd",
        default=None,
        description="Path to CLAUDE.md in working directory (if found)",
    )

    model_config = {"populate_by_name": True}


class PermissionRequestEvent(BaseModel):
    """Permission request event - agent needs user approval for an operation."""

    type: Literal["permission_request"] = "permission_request"
    id: str
    tool_name: str = Field(alias="toolName")
    agent_name: str = Field(alias="agentName")
    timestamp: int
    permission_type: str = Field(alias="permissionType", default="write")  # read, write, bash

    # For file tools
    file_path: Optional[str] = Field(alias="filePath", default=None)
    allowed_patterns: list[str] = Field(alias="allowedPatterns", default_factory=list)

    # Suggested grant options
    suggested_grants: list[dict[str, str]] = Field(alias="suggestedGrants", default_factory=list)

    # For MCP tools
    mcp_server: Optional[str] = Field(alias="mcpServer", default=None)
    mcp_tool: Optional[str] = Field(alias="mcpTool", default=None)

    # Tool input for context
    input_data: Optional[dict[str, Any]] = Field(alias="input", default=None)

    model_config = {"populate_by_name": True}


class PermissionDeniedEvent(BaseModel):
    """Permission denied event - operation was denied (by user or policy)."""

    type: Literal["permission_denied"] = "permission_denied"
    request_id: Optional[str] = Field(alias="requestId", default=None)
    tool_name: str = Field(alias="toolName")
    reason: str
    file_path: Optional[str] = Field(alias="filePath", default=None)

    model_config = {"populate_by_name": True}


class UserQuestionEvent(BaseModel):
    """User question event - Claude is asking the user a question (AskUserQuestion tool)."""

    type: Literal["user_question"] = "user_question"
    request_id: str = Field(alias="requestId")
    session_id: str = Field(alias="sessionId")
    questions: list[dict[str, Any]]

    model_config = {"populate_by_name": True}


# Union type for all SSE events
SSEEvent = Union[
    SessionEvent,
    ModelEvent,
    InitEvent,
    PromptMetadataEvent,
    TextEvent,
    ThinkingEvent,
    ToolUseEvent,
    ToolResultEvent,
    DoneEvent,
    AbortedEvent,
    SessionUnavailableEvent,
    ErrorEvent,
    TypedErrorEvent,
    WarningEvent,
    UserMessageEvent,
    PermissionRequestEvent,
    UserQuestionEvent,
    PermissionDeniedEvent,
]
