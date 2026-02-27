"""
Claude SDK wrapper for async streaming.

Wraps the claude-agent-sdk to provide async generators for streaming responses.
The SDK bundles the Claude CLI, so no separate installation is required.

Authentication:
    Uses CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`) passed as an
    environment variable to the SDK subprocess. No HOME override needed.
"""

import asyncio
import contextlib
import logging
from pathlib import Path
from typing import Any, AsyncGenerator, Awaitable, Callable, Optional

logger = logging.getLogger(__name__)


def _patch_sdk_parse_message() -> None:
    """Patch the SDK's parse_message to handle unknown event types gracefully.

    The CLI emits event types (e.g. rate_limit_event) that the SDK's parser
    doesn't recognise, causing MessageParseError. This kills the async generator
    and drops all subsequent events (tool results, final text, etc.).

    The patch catches the error and returns the raw dict instead, which
    _event_to_dict handles via isinstance(event, dict).
    """
    try:
        from claude_agent_sdk._internal import client as _sdk_client
        from claude_agent_sdk._internal.message_parser import parse_message as _original

        _original_ref = _original  # capture in closure

        def _safe_parse(data: dict[str, Any]) -> Any:
            try:
                return _original_ref(data)
            except Exception:
                logger.debug(f"SDK parse_message: passing through raw event type={data.get('type')}")
                return data  # Return raw dict — _event_to_dict handles this

        _sdk_client.parse_message = _safe_parse  # type: ignore[attr-defined]
        logger.debug("Patched SDK parse_message for unknown event types")
    except Exception as e:
        logger.warning(f"Could not patch SDK parse_message: {e}")


_patch_sdk_parse_message()


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


async def _string_to_async_iterable(
    s: str,
    done_event: asyncio.Event | None = None,
    message_queue: asyncio.Queue[str] | None = None,
) -> AsyncGenerator[dict[str, Any], None]:
    """Convert a string to an async iterable that yields a user message.

    When done_event is provided, the generator stays alive after yielding the
    message (blocking on the event).  This keeps stdin open so the SDK can send
    control-protocol responses (e.g. can_use_tool permission decisions) back to
    the CLI subprocess.  Without this, stream_input() closes stdin as soon as
    the iterable is exhausted, which breaks bidirectional communication.

    When message_queue is provided, the generator also monitors the queue for
    additional user messages to inject mid-stream. Uses asyncio.wait() for
    zero-latency response to either new messages or stream completion.
    """
    yield {
        "type": "user",
        "message": {
            "role": "user",
            "content": s,
        }
    }
    if done_event is None:
        return

    if message_queue is None:
        await done_event.wait()
        return

    # Use asyncio.wait() to respond immediately to either a new message
    # or the done_event, avoiding polling latency.
    done_task = asyncio.create_task(done_event.wait())
    try:
        while not done_event.is_set():
            get_task = asyncio.create_task(message_queue.get())
            done_set, _ = await asyncio.wait(
                {done_task, get_task},
                return_when=asyncio.FIRST_COMPLETED,
            )
            if get_task in done_set:
                msg = get_task.result()
                yield {"type": "user", "message": {"role": "user", "content": msg}}
            else:
                get_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await get_task
                break

        # Drain any messages queued right as done_event fired
        while not message_queue.empty():
            try:
                msg = message_queue.get_nowait()
                yield {"type": "user", "message": {"role": "user", "content": msg}}
            except asyncio.QueueEmpty:
                break
    finally:
        done_task.cancel()


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
    model: Optional[str] = None,
    message_queue: asyncio.Queue[str] | None = None,
) -> AsyncGenerator[dict[str, Any], None]:
    """
    Run a Claude SDK query with streaming response.

    Args:
        prompt: User message
        system_prompt: Full custom system prompt (overrides preset if provided)
        system_prompt_append: Text to append to Claude Code preset (ignored if system_prompt is set)
        use_claude_code_preset: If True (default), use Claude Code's system prompt as base
        setting_sources: List of setting sources for SDK config loading.
                        Pass ["project"] to enable project-level .claude/ discovery.
        cwd: Working directory for the agent session
        resume: Session ID to resume
        tools: List of allowed tools
        mcp_servers: MCP server configurations
        permission_mode: Permission mode for tools
        can_use_tool: Optional callback for permission checking
        plugin_dirs: List of plugin directories to load (for skills)
        agents: Dict of agent definitions for subagents
        claude_token: OAuth token from `claude setup-token` (CLAUDE_CODE_OAUTH_TOKEN)
        message_queue: Queue for injecting user messages mid-stream

    Yields:
        SDK events as dictionaries

    Note:
        Parachute passes setting_sources=["project"] for project-level discovery
        (CLAUDE.md, .claude/ commands/skills/agents). Vault-level CLAUDE.md is
        appended separately via system_prompt_append.
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

    # Model override
    if model:
        options_kwargs["model"] = model

    # Build env vars for the SDK subprocess.
    # Inherit the full process environment so the CLI (and any MCP server
    # subprocesses it spawns) get PATH, HOME, PYTHONPATH, etc.
    # Then override/add the specific vars we need.
    import os
    sdk_env: dict[str, str] = dict(os.environ)
    # Clear CLAUDECODE to prevent "nested session" detection when the server
    # itself runs inside Claude Code (e.g. during development).
    sdk_env["CLAUDECODE"] = ""
    if claude_token:
        sdk_env["CLAUDE_CODE_OAUTH_TOKEN"] = claude_token
    # Strip ANTHROPIC_API_KEY so it never leaks into the Claude CLI subprocess.
    # Brain module stores its key in vault config.yaml (brain.anthropic_api_key)
    # and passes it directly to Graphiti. If ANTHROPIC_API_KEY were present here,
    # the CLI would use it for all inference, bypassing the OAuth subscription.
    sdk_env.pop("ANTHROPIC_API_KEY", None)
    options_kwargs["env"] = sdk_env

    # Capture CLI stderr for debugging tool execution issues
    def _stderr_callback(line: str) -> None:
        logger.debug(f"CLI stderr: {line.rstrip()}")
    options_kwargs["stderr"] = _stderr_callback

    options = ClaudeAgentOptions(**options_kwargs)

    # Run query and stream events
    # When using can_use_tool callback, SDK requires prompt as AsyncIterable.
    # We also need to keep the iterable alive (stdin open) so the SDK can
    # send control-protocol responses back to the CLI subprocess.
    #
    # Lifecycle: the iterable blocks on done_event after yielding the user
    # message.  We set done_event when we see the "result" event (conversation
    # turn complete).  This lets stream_input() call end_input() → stdin
    # closes → CLI exits → stdout closes → receive_messages() finishes.
    #
    # When message_queue is provided, the iterable also monitors it for
    # injected user messages (mid-stream messaging).
    done_event: Optional[asyncio.Event] = None
    try:
        effective_prompt: Any = prompt
        # Always use AsyncIterable to keep stdin open for the CLI subprocess.
        # When prompt is passed as a string, the SDK calls end_input() immediately
        # which closes stdin — preventing the CLI's internal tool execution loop
        # from completing. The AsyncIterable wrapper keeps stdin alive until we
        # see the "result" event (done_event), allowing multi-turn tool use.
        done_event = asyncio.Event()
        effective_prompt = _string_to_async_iterable(prompt, done_event, message_queue)

        # The SDK's parse_message is patched (above) to return raw dicts
        # for unknown event types instead of raising MessageParseError.
        # This keeps the generator alive through rate_limit_event etc.
        async for event in sdk_query(prompt=effective_prompt, options=options):
            event_dict = _event_to_dict(event)
            # Signal the iterable to finish once the turn is complete so
            # stream_input can close stdin and the CLI process can exit.
            if done_event is not None and event_dict.get("type") == "result":
                done_event.set()
            yield event_dict
    except ClaudeSDKError as e:
        logger.error(f"Claude SDK error: {e}", exc_info=True)
        yield {"type": "error", "error": str(e)}
    except Exception as e:
        error_msg = str(e)
        logger.error(f"SDK query error: {error_msg}", exc_info=True)
        yield {"type": "error", "error": error_msg}
    finally:
        # Safety net: always release the iterable on exit
        if done_event is not None:
            done_event.set()


def _event_to_dict(event: Any) -> dict[str, Any]:
    """Convert SDK event types to plain dictionaries."""
    # Raw dicts come from the patched parse_message (unknown event types)
    if isinstance(event, dict):
        return event

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
