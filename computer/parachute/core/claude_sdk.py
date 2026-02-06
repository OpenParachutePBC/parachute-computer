"""
Claude SDK wrapper for async streaming.

Wraps the claude-agent-sdk to provide async generators for streaming responses.
The SDK bundles the Claude CLI, so no separate installation is required.

Authentication:
    Uses CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`) passed as an
    environment variable to the SDK subprocess. No HOME override needed.
"""

import asyncio
import logging
from pathlib import Path
from typing import Any, AsyncGenerator, Awaitable, Callable, Optional

logger = logging.getLogger(__name__)


class QueryInterrupt:
    """Handle for interrupting a running query."""

    def __init__(self) -> None:
        self._interrupted = False
        self._event = asyncio.Event()

    def interrupt(self) -> None:
        """Signal the query to stop."""
        self._interrupted = True
        self._event.set()

    @property
    def is_interrupted(self) -> bool:
        """Check if interrupt was requested."""
        return self._interrupted

    async def wait(self) -> None:
        """Wait for interrupt signal."""
        await self._event.wait()


# Type alias for permission callback
CanUseToolCallback = Optional[
    Callable[[str, dict[str, Any], Any], Awaitable[Any]]
]


async def _string_to_async_iterable(s: str) -> AsyncGenerator[dict[str, Any], None]:
    """Convert a string to an async iterable that yields a user message."""
    yield {
        "type": "user",
        "message": {
            "role": "user",
            "content": s,
        }
    }


async def query_streaming(
    prompt: str,
    system_prompt: Optional[str] = None,
    system_prompt_append: Optional[str] = None,
    use_claude_code_preset: bool = True,
    setting_sources: Optional[list[str]] = None,
    cwd: Optional[Path] = None,
    resume: Optional[str] = None,
    tools: Optional[list[str]] = None,
    mcp_servers: Optional[dict[str, Any]] = None,
    permission_mode: str = "default",
    can_use_tool: CanUseToolCallback = None,
    plugin_dirs: Optional[list[Path]] = None,
    agents: Optional[dict[str, Any]] = None,
    claude_token: Optional[str] = None,
) -> AsyncGenerator[dict[str, Any], None]:
    """
    Run a Claude SDK query with streaming response.

    Args:
        prompt: User message
        system_prompt: Full custom system prompt (overrides preset if provided)
        system_prompt_append: Text to append to Claude Code preset (ignored if system_prompt is set)
        use_claude_code_preset: If True (default), use Claude Code's system prompt as base
        setting_sources: List of setting sources to load CLAUDE.md from ("user", "project", "local")
                        Defaults to ["project"] to enable CLAUDE.md hierarchy loading
        cwd: Working directory - CLAUDE.md files are discovered from here upward
        resume: Session ID to resume
        tools: List of allowed tools
        mcp_servers: MCP server configurations
        permission_mode: Permission mode for tools
        can_use_tool: Optional callback for permission checking
        plugin_dirs: List of plugin directories to load (for skills)
        agents: Dict of agent definitions for subagents
        claude_token: OAuth token from `claude setup-token` (CLAUDE_CODE_OAUTH_TOKEN)

    Yields:
        SDK events as dictionaries

    Note:
        When setting_sources includes "project", Claude SDK loads CLAUDE.md files from
        the directory hierarchy, walking up from cwd to root. This enables hierarchical context:
        ~/Parachute/CLAUDE.md → ~/Parachute/projects/foo/CLAUDE.md → etc.
    """
    # Import the SDK
    from claude_agent_sdk import query as sdk_query, ClaudeAgentOptions, ClaudeSDKError

    # Build options
    options_kwargs: dict[str, Any] = {}

    # Configure system prompt
    # Priority: explicit system_prompt > preset with append > preset only
    if system_prompt:
        # Full custom system prompt overrides everything
        options_kwargs["system_prompt"] = system_prompt
    elif use_claude_code_preset:
        # Use Claude Code's system prompt as base
        if system_prompt_append:
            options_kwargs["system_prompt"] = {
                "type": "preset",
                "preset": "claude_code",
                "append": system_prompt_append,
            }
        else:
            options_kwargs["system_prompt"] = {
                "type": "preset",
                "preset": "claude_code",
            }

    # Configure setting sources for CLAUDE.md loading
    if setting_sources:
        options_kwargs["setting_sources"] = setting_sources

    if cwd:
        options_kwargs["cwd"] = cwd

    if permission_mode:
        valid_modes = ["default", "acceptEdits", "plan", "bypassPermissions"]
        if permission_mode in valid_modes:
            options_kwargs["permission_mode"] = permission_mode  # type: ignore

    if tools:
        options_kwargs["allowed_tools"] = tools

    if resume:
        options_kwargs["resume"] = resume

    if mcp_servers:
        options_kwargs["mcp_servers"] = mcp_servers

    if can_use_tool:
        options_kwargs["can_use_tool"] = can_use_tool

    # Agents - SDK supports this natively
    if agents:
        options_kwargs["agents"] = agents

    # Plugins - SDK supports this natively
    if plugin_dirs:
        # SDK expects plugins as list of SdkPluginConfig: {"type": "local", "path": "..."}
        options_kwargs["plugins"] = [{"type": "local", "path": str(pd)} for pd in plugin_dirs]

    # Pass OAuth token as env var to the SDK subprocess
    if claude_token:
        options_kwargs["env"] = {"CLAUDE_CODE_OAUTH_TOKEN": claude_token}

    options = ClaudeAgentOptions(**options_kwargs)

    # Run query and stream events
    # When using can_use_tool callback, SDK requires prompt as AsyncIterable
    try:
        effective_prompt: Any = prompt
        if can_use_tool:
            effective_prompt = _string_to_async_iterable(prompt)

        async for event in sdk_query(prompt=effective_prompt, options=options):
            yield _event_to_dict(event)
    except ClaudeSDKError as e:
        logger.error(f"Claude SDK error: {e}")
        yield {"type": "error", "error": str(e)}
    except Exception as e:
        error_msg = str(e)
        logger.error(f"SDK query error: {error_msg}")
        yield {"type": "error", "error": error_msg}


def _event_to_dict(event: Any) -> dict[str, Any]:
    """Convert SDK event types to plain dictionaries."""
    event_dict: dict[str, Any] = {}

    # Get the type name from the class
    type_name = type(event).__name__.lower()

    # Map SDK type names to our event types
    if "user" in type_name:
        event_dict["type"] = "user"
    elif "assistant" in type_name:
        event_dict["type"] = "assistant"
    elif "system" in type_name:
        event_dict["type"] = "system"
    elif "result" in type_name:
        event_dict["type"] = "result"
    elif "stream" in type_name:
        event_dict["type"] = "stream"
    else:
        event_dict["type"] = type_name

    # Handle SystemMessage - has data attribute with all info
    if hasattr(event, "data") and isinstance(event.data, dict):
        data = event.data
        if data.get("session_id"):
            event_dict["session_id"] = data["session_id"]
        if data.get("tools"):
            event_dict["tools"] = data["tools"]
        if data.get("model"):
            event_dict["model"] = data["model"]
        if data.get("permissionMode"):
            event_dict["permissionMode"] = data["permissionMode"]

    # Handle AssistantMessage - has content and model directly
    if hasattr(event, "content"):
        content = event.content
        # Convert content blocks to dicts
        content_list = []
        for block in content:
            if hasattr(block, "text"):
                content_list.append({"type": "text", "text": block.text})
            elif hasattr(block, "thinking"):
                content_list.append({"type": "thinking", "thinking": block.thinking})
            elif hasattr(block, "name"):
                # Tool use block
                content_list.append({
                    "type": "tool_use",
                    "id": getattr(block, "id", None),
                    "name": block.name,
                    "input": getattr(block, "input", {}),
                })
            elif hasattr(block, "__dict__"):
                content_list.append(_object_to_dict(block))
            else:
                content_list.append(str(block))

        # Structure as message for orchestrator compatibility
        event_dict["message"] = {
            "content": content_list,
            "model": getattr(event, "model", None),
        }

    # Handle ResultMessage - has session_id, result directly
    if hasattr(event, "session_id"):
        event_dict["session_id"] = event.session_id

    if hasattr(event, "result"):
        event_dict["result"] = event.result

    if hasattr(event, "subtype"):
        event_dict["subtype"] = event.subtype

    if hasattr(event, "model") and "message" not in event_dict:
        event_dict["model"] = event.model

    return event_dict


def _object_to_dict(obj: Any) -> dict[str, Any]:
    """Recursively convert an object to a dictionary."""
    if hasattr(obj, "model_dump"):
        return obj.model_dump()

    result = {}
    for key, value in vars(obj).items():
        if key.startswith("_"):
            continue
        if hasattr(value, "__dict__"):
            result[key] = _object_to_dict(value)
        elif isinstance(value, list):
            result[key] = [
                _object_to_dict(item) if hasattr(item, "__dict__") else item
                for item in value
            ]
        else:
            result[key] = value
    return result
