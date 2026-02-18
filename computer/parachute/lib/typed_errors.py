"""
Typed errors for better error handling and user-friendly messages.

Inspired by craft-agents-oss, these error types map error patterns to
actionable error information that can be displayed to users.
"""

from enum import Enum
from typing import Any, Literal, Optional

from pydantic import BaseModel, Field


class ErrorCode(str, Enum):
    """Error codes for programmatic handling."""

    # Authentication errors
    INVALID_API_KEY = "invalid_api_key"
    INVALID_CREDENTIALS = "invalid_credentials"
    EXPIRED_TOKEN = "expired_token"

    # Billing errors
    BILLING_ERROR = "billing_error"

    # Rate limiting
    RATE_LIMITED = "rate_limited"

    # Service errors
    SERVICE_ERROR = "service_error"
    SERVICE_UNAVAILABLE = "service_unavailable"
    CONTEXT_EXCEEDED = "context_exceeded"

    # Network errors
    NETWORK_ERROR = "network_error"

    # MCP errors
    MCP_CONNECTION_FAILED = "mcp_connection_failed"
    MCP_LOAD_FAILED = "mcp_load_failed"
    MCP_TOOL_ERROR = "mcp_tool_error"

    # Attachment errors
    ATTACHMENT_SAVE_FAILED = "attachment_save_failed"

    # Tool errors
    TOOL_EXECUTION_FAILED = "tool_execution_failed"

    # Transcription errors
    TRANSCRIPTION_FAILED = "transcription_failed"

    # Session errors
    SESSION_NOT_FOUND = "session_not_found"
    SESSION_UNAVAILABLE = "session_unavailable"

    # Generic
    UNKNOWN_ERROR = "unknown_error"


class RecoveryAction(BaseModel):
    """A suggested recovery action for an error."""

    key: str = Field(description="Keyboard shortcut (single letter)")
    label: str = Field(description="Description of the action")
    action: Literal["retry", "settings", "reauth", "dismiss", "new_session"] = Field(
        description="Action type for handling"
    )


class TypedError(BaseModel):
    """A structured error with user-friendly info and recovery suggestions."""

    code: ErrorCode = Field(description="Error code for programmatic handling")
    title: str = Field(description="User-friendly title")
    message: str = Field(description="Detailed message explaining what went wrong")
    actions: list[RecoveryAction] = Field(
        default_factory=list, description="Suggested recovery actions"
    )
    can_retry: bool = Field(
        alias="canRetry", default=False, description="Whether auto-retry is possible"
    )
    retry_delay_ms: Optional[int] = Field(
        alias="retryDelayMs", default=None, description="Retry delay in ms"
    )
    original_error: Optional[str] = Field(
        alias="originalError", default=None, description="Original error message"
    )
    details: Optional[list[str]] = Field(
        default=None, description="Diagnostic details for debugging"
    )

    model_config = {"populate_by_name": True}


# Error definitions with user-friendly messages and recovery actions
ERROR_DEFINITIONS: dict[ErrorCode, dict[str, Any]] = {
    ErrorCode.INVALID_API_KEY: {
        "title": "Invalid API Key",
        "message": "Your Anthropic API key was rejected. It may be invalid or expired.",
        "actions": [
            RecoveryAction(key="s", label="Check settings", action="settings"),
        ],
        "can_retry": False,
    },
    ErrorCode.INVALID_CREDENTIALS: {
        "title": "Invalid Credentials",
        "message": "Your API key or authentication is missing or invalid.",
        "actions": [
            RecoveryAction(key="s", label="Update credentials", action="settings"),
        ],
        "can_retry": False,
    },
    ErrorCode.EXPIRED_TOKEN: {
        "title": "Session Expired",
        "message": "Your authentication session has expired.",
        "actions": [
            RecoveryAction(key="r", label="Re-authenticate", action="reauth"),
            RecoveryAction(key="s", label="Check settings", action="settings"),
        ],
        "can_retry": False,
    },
    ErrorCode.BILLING_ERROR: {
        "title": "Payment Required",
        "message": "Your account has a billing issue. Check your Anthropic account status.",
        "actions": [
            RecoveryAction(key="s", label="Check settings", action="settings"),
        ],
        "can_retry": False,
    },
    ErrorCode.RATE_LIMITED: {
        "title": "Rate Limited",
        "message": "Too many requests. Please wait a moment.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
        ],
        "can_retry": True,
        "retry_delay_ms": 5000,
    },
    ErrorCode.SERVICE_ERROR: {
        "title": "Service Error",
        "message": "The AI service is temporarily unavailable.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
        ],
        "can_retry": True,
        "retry_delay_ms": 2000,
    },
    ErrorCode.SERVICE_UNAVAILABLE: {
        "title": "Service Unavailable",
        "message": "The AI service is experiencing issues. Try again in a moment.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
        ],
        "can_retry": True,
        "retry_delay_ms": 2000,
    },
    ErrorCode.CONTEXT_EXCEEDED: {
        "title": "Context Limit Exceeded",
        "message": "The conversation is too long. Try starting a new session or summarizing.",
        "actions": [
            RecoveryAction(key="n", label="New session", action="new_session"),
        ],
        "can_retry": False,
    },
    ErrorCode.NETWORK_ERROR: {
        "title": "Connection Error",
        "message": "Could not connect to the server. Check your internet connection.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
        ],
        "can_retry": True,
        "retry_delay_ms": 1000,
    },
    ErrorCode.MCP_CONNECTION_FAILED: {
        "title": "MCP Connection Failed",
        "message": "Cannot connect to the MCP server. Check your configuration.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
            RecoveryAction(key="s", label="Check settings", action="settings"),
        ],
        "can_retry": True,
        "retry_delay_ms": 2000,
    },
    ErrorCode.MCP_LOAD_FAILED: {
        "title": "MCP Tools Unavailable",
        "message": "MCP servers failed to load. Chat will continue without MCP tools.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
        ],
        "can_retry": True,
        "retry_delay_ms": 2000,
    },
    ErrorCode.MCP_TOOL_ERROR: {
        "title": "Tool Error",
        "message": "An MCP tool failed to execute.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
        ],
        "can_retry": True,
    },
    ErrorCode.ATTACHMENT_SAVE_FAILED: {
        "title": "Attachment Failed",
        "message": "One or more attachments could not be saved.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
            RecoveryAction(key="d", label="Dismiss", action="dismiss"),
        ],
        "can_retry": True,
    },
    ErrorCode.TOOL_EXECUTION_FAILED: {
        "title": "Tool Failed",
        "message": "A tool failed to execute properly.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
        ],
        "can_retry": True,
    },
    ErrorCode.TRANSCRIPTION_FAILED: {
        "title": "Transcription Failed",
        "message": "Could not transcribe the audio. Try recording again.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
            RecoveryAction(key="d", label="Dismiss", action="dismiss"),
        ],
        "can_retry": True,
    },
    ErrorCode.SESSION_NOT_FOUND: {
        "title": "Session Not Found",
        "message": "The requested session could not be found.",
        "actions": [
            RecoveryAction(key="n", label="New session", action="new_session"),
        ],
        "can_retry": False,
    },
    ErrorCode.SESSION_UNAVAILABLE: {
        "title": "Session Unavailable",
        "message": "The session data is not available. You may need to start a new conversation.",
        "actions": [
            RecoveryAction(key="n", label="New session", action="new_session"),
            RecoveryAction(key="r", label="Retry", action="retry"),
        ],
        "can_retry": True,
    },
    ErrorCode.UNKNOWN_ERROR: {
        "title": "Error",
        "message": "An unexpected error occurred.",
        "actions": [
            RecoveryAction(key="r", label="Retry", action="retry"),
        ],
        "can_retry": True,
    },
}


def parse_error(error: Exception | str) -> TypedError:
    """
    Parse an error and return a typed error with user-friendly info.

    Args:
        error: The error to parse (Exception or string)

    Returns:
        TypedError with appropriate code, message, and recovery actions
    """
    if isinstance(error, Exception):
        error_message = str(error)
        original_error = f"{type(error).__name__}: {error_message}"
    else:
        error_message = str(error)
        original_error = error_message

    lower_message = error_message.lower()

    # Detect error type from message/status
    code = ErrorCode.UNKNOWN_ERROR

    # Check for specific HTTP status codes or patterns
    if "402" in lower_message or "payment required" in lower_message:
        code = ErrorCode.BILLING_ERROR
    elif any(
        x in lower_message
        for x in ["401", "unauthorized", "invalid api key", "invalid x-api-key", "authentication failed"]
    ):
        if any(x in lower_message for x in ["oauth", "token", "session", "expired"]):
            code = ErrorCode.EXPIRED_TOKEN
        else:
            code = ErrorCode.INVALID_API_KEY
    elif any(x in lower_message for x in ["429", "rate limit", "too many requests"]):
        code = ErrorCode.RATE_LIMITED
    elif any(
        x in lower_message
        for x in ["500", "502", "503", "504", "internal server error", "service unavailable"]
    ):
        code = ErrorCode.SERVICE_ERROR
    elif any(
        x in lower_message
        for x in ["network", "econnrefused", "enotfound", "fetch failed", "connection refused", "timeout"]
    ):
        code = ErrorCode.NETWORK_ERROR
    elif "context" in lower_message and any(x in lower_message for x in ["exceed", "limit", "too long"]):
        code = ErrorCode.CONTEXT_EXCEEDED
    elif "mcp" in lower_message:
        if any(x in lower_message for x in ["connect", "unreachable", "refused"]):
            code = ErrorCode.MCP_CONNECTION_FAILED
        else:
            code = ErrorCode.MCP_TOOL_ERROR
    elif any(x in lower_message for x in ["transcri", "audio", "speech"]):
        code = ErrorCode.TRANSCRIPTION_FAILED
    elif "session" in lower_message and any(x in lower_message for x in ["not found", "unavailable", "missing"]):
        if "not found" in lower_message:
            code = ErrorCode.SESSION_NOT_FOUND
        else:
            code = ErrorCode.SESSION_UNAVAILABLE
    elif any(x in lower_message for x in ["tool", "execution", "failed"]):
        code = ErrorCode.TOOL_EXECUTION_FAILED

    # Build typed error from definition
    definition = ERROR_DEFINITIONS[code]

    return TypedError(
        code=code,
        title=definition["title"],
        message=definition["message"],
        actions=definition["actions"],
        can_retry=definition.get("can_retry", False),
        retry_delay_ms=definition.get("retry_delay_ms"),
        original_error=original_error,
    )


def is_billing_error(error: TypedError) -> bool:
    """Check if an error is a billing/auth error that blocks usage."""
    return error.code in [
        ErrorCode.BILLING_ERROR,
        ErrorCode.INVALID_API_KEY,
        ErrorCode.EXPIRED_TOKEN,
    ]


def can_auto_retry(error: TypedError) -> bool:
    """Check if an error can be automatically retried."""
    return error.can_retry and error.retry_delay_ms is not None
