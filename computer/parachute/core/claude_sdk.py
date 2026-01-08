"""
Claude SDK wrapper for async streaming.

Wraps the claude-code-sdk to provide async generators for streaming responses.
"""

import asyncio
import logging
import os
from pathlib import Path
from typing import Any, AsyncGenerator, Awaitable, Callable, Optional

logger = logging.getLogger(__name__)

# Ensure Claude CLI is in PATH before SDK is imported
# The SDK looks for 'claude' binary at import time
_claude_paths = [
    os.path.expanduser("~/.claude/local"),  # Claude Code local install
    "/opt/homebrew/bin",  # macOS Homebrew
    os.path.expanduser("~/node_modules/.bin"),  # Local npm
]
_current_path = os.environ.get("PATH", "")
for _p in _claude_paths:
    if _p not in _current_path:
        _current_path = f"{_p}:{_current_path}"
os.environ["PATH"] = _current_path


def get_sdk_env() -> dict[str, str]:
    """
    Get environment variables for SDK subprocess.

    Ensures PATH includes common node and Claude installation locations.
    """
    env = dict(os.environ)
    path = env.get("PATH", "")

    # Add common paths for Claude Code CLI and Node.js
    paths_to_add = [
        os.path.expanduser("~/.claude/local"),  # Claude Code local install
        "/opt/homebrew/bin",  # macOS Homebrew
        os.path.expanduser("~/node_modules/.bin"),  # Local npm
    ]

    for p in paths_to_add:
        if p not in path:
            path = f"{p}:{path}"

    env["PATH"] = path
    return env


# Type alias for permission callback
CanUseToolCallback = Optional[
    Callable[[str, dict[str, Any], Any], Awaitable[Any]]
]


async def query_streaming(
    prompt: str,
    system_prompt: Optional[str] = None,
    cwd: Optional[Path] = None,
    resume: Optional[str] = None,
    tools: Optional[list[str]] = None,
    mcp_servers: Optional[dict[str, Any]] = None,
    permission_mode: str = "default",
    can_use_tool: CanUseToolCallback = None,
    plugin_dirs: Optional[list[Path]] = None,
    agents: Optional[dict[str, Any]] = None,
) -> AsyncGenerator[dict[str, Any], None]:
    """
    Run a Claude SDK query with streaming response.

    Args:
        prompt: User message
        system_prompt: System prompt
        cwd: Working directory
        resume: Session ID to resume
        tools: List of allowed tools
        mcp_servers: MCP server configurations
        permission_mode: Permission mode for tools
        can_use_tool: Optional callback for permission checking
        plugin_dirs: List of plugin directories to load (for skills)
        agents: Dict of agent definitions for subagents

    Yields:
        SDK events as dictionaries
    """
    try:
        # Import the SDK
        from claude_code_sdk import query as sdk_query, ClaudeCodeOptions
        try:
            from claude_code_sdk import ClaudeSDKError
        except ImportError:
            ClaudeSDKError = Exception  # Fallback if not available

        # Build options - using dataclass style
        options_kwargs: dict[str, Any] = {
            "env": get_sdk_env(),
        }

        if system_prompt:
            options_kwargs["system_prompt"] = system_prompt

        if cwd:
            options_kwargs["cwd"] = cwd

        if permission_mode:
            # Validate permission_mode
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

        # Plugin directories for skills - need subprocess for proper --plugin-dir support
        # The SDK's extra_args doesn't handle repeatable flags well
        if plugin_dirs:
            logger.debug(f"Plugin dirs requested, using subprocess for proper --plugin-dir support")
            async for event in _query_subprocess(
                prompt=prompt,
                system_prompt=system_prompt,
                cwd=cwd,
                resume=resume,
                tools=tools,
                mcp_servers=mcp_servers,
                plugin_dirs=plugin_dirs,
                agents=agents,
            ):
                yield event
            return

        # Agents definition (passed as JSON via --agents flag)
        if agents:
            import json
            options_kwargs["extra_args"] = options_kwargs.get("extra_args", {})
            options_kwargs["extra_args"]["--agents"] = json.dumps(agents)

        options = ClaudeCodeOptions(**options_kwargs)

        # Run query and stream events
        try:
            async for event in sdk_query(prompt=prompt, options=options):
                # Convert SDK message types to dicts
                yield _event_to_dict(event)
        except ClaudeSDKError as e:
            logger.error(f"Claude SDK error: {e}")
            yield {"type": "error", "error": str(e)}
        except Exception as e:
            # Catch any other SDK runtime errors
            error_msg = str(e)
            logger.error(f"SDK query error: {error_msg}")
            yield {"type": "error", "error": error_msg}

    except ImportError as e:
        # SDK not installed - use subprocess fallback
        logger.warning(f"claude-code-sdk import failed ({e}), using subprocess fallback")
        async for event in _query_subprocess(
            prompt=prompt,
            system_prompt=system_prompt,
            cwd=cwd,
            resume=resume,
            tools=tools,
            mcp_servers=mcp_servers,
        ):
            yield event


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


async def _query_subprocess(
    prompt: str,
    system_prompt: Optional[str] = None,
    cwd: Optional[Path] = None,
    resume: Optional[str] = None,
    tools: Optional[list[str]] = None,
    mcp_servers: Optional[dict[str, Any]] = None,
    plugin_dirs: Optional[list[Path]] = None,
    agents: Optional[dict[str, Any]] = None,
) -> AsyncGenerator[dict[str, Any], None]:
    """
    Fallback: Run Claude via CLI subprocess.

    This is less efficient but works without the SDK package installed.
    Also used when plugin_dirs are specified since SDK doesn't handle
    repeatable --plugin-dir flags well.
    """
    import json

    # Build CLI command
    # -p (print mode) and --verbose are required for --output-format=stream-json
    cmd = ["claude", "-p", "--verbose", "--output-format", "stream-json"]

    if system_prompt:
        cmd.extend(["--system-prompt", system_prompt])

    if resume:
        cmd.extend(["--resume", resume])

    if tools:
        cmd.extend(["--allowedTools", ",".join(tools)])

    # Plugin directories (repeatable flag)
    if plugin_dirs:
        for pd in plugin_dirs:
            cmd.extend(["--plugin-dir", str(pd)])

    # Agents definition as JSON
    if agents:
        cmd.extend(["--agents", json.dumps(agents)])

    # Add the prompt as the final positional argument
    cmd.append(prompt)

    env = get_sdk_env()
    if cwd:
        env["PWD"] = str(cwd)

    # Log full command for debugging (truncate prompt)
    cmd_display = cmd.copy()
    if len(cmd_display) > 0 and len(cmd_display[-1]) > 100:
        cmd_display[-1] = cmd_display[-1][:100] + "..."
    logger.info(f"Running Claude CLI: {' '.join(cmd_display)}")

    try:
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(cwd) if cwd else None,
            env=env,
        )

        # Read stdout line by line
        while True:
            if process.stdout is None:
                break

            line = await process.stdout.readline()
            if not line:
                break

            line = line.decode("utf-8").strip()
            if not line:
                continue

            try:
                event = json.loads(line)
                # Normalize camelCase to snake_case for session_id
                if "sessionId" in event:
                    event["session_id"] = event["sessionId"]
                yield event
            except json.JSONDecodeError:
                logger.debug(f"Non-JSON line from Claude: {line[:100]}")

        # Wait for process to complete
        await process.wait()

        if process.returncode != 0:
            stderr = ""
            if process.stderr:
                stderr = (await process.stderr.read()).decode("utf-8")
            logger.error(f"Claude CLI error: {stderr}")
            yield {"type": "error", "error": stderr or "Claude CLI failed"}

    except FileNotFoundError:
        logger.error("Claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code")
        yield {"type": "error", "error": "Claude CLI not installed"}


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
