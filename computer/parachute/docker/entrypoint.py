"""
Sandbox entrypoint for Parachute Docker containers.

Reads a JSON message from stdin, calls the Claude Agent SDK,
and writes JSONL events to stdout matching the orchestrator's event format.

SDK event types:
  SystemMessage(subtype, data)  — init event with session_id, tools, model
  AssistantMessage(content, model, error)  — content is list of TextBlock/ToolUseBlock objects
  ResultMessage(result, session_id, ...)  — final result text
"""

import asyncio
import json
import os
import re
import sys


def emit(event: dict):
    """Write a JSON event line to stdout."""
    print(json.dumps(event, default=str), flush=True)


def _patch_sdk_parse_message() -> None:
    """Patch the SDK's parse_message to handle unknown event types gracefully.

    The CLI emits event types (e.g. rate_limit_event) that the SDK's parser
    doesn't recognise, causing MessageParseError. This kills the async generator
    and drops all subsequent events (tool results, final text, etc.).
    """
    try:
        from claude_agent_sdk._internal import client as _sdk_client
        from claude_agent_sdk._internal.message_parser import parse_message as _original

        _original_ref = _original

        def _safe_parse(data):
            try:
                return _original_ref(data)
            except Exception:
                return data  # Return raw dict for unknown types

        _sdk_client.parse_message = _safe_parse
    except Exception:
        pass  # SDK not installed or structure changed — non-fatal


_patch_sdk_parse_message()


async def run_query_and_emit(message: str, options) -> str | None:
    """Run SDK query, emit JSONL events to stdout. Returns captured session ID."""
    from claude_agent_sdk import query

    current_text = ""
    captured_session_id = None
    captured_model = None

    async for event in query(prompt=message, options=options):
        # Raw dicts come from patched parse_message (unknown event types)
        if isinstance(event, dict):
            continue  # Skip unknown events (rate_limit_event, etc.)

        event_type = type(event).__name__

        if event_type == "SystemMessage":
            # Extract session_id from init data
            data = getattr(event, "data", {}) or {}
            if isinstance(data, dict) and data.get("session_id"):
                captured_session_id = data["session_id"]
                emit({"type": "session", "sessionId": captured_session_id})

        elif event_type == "AssistantMessage":
            # Capture model
            model = getattr(event, "model", None)
            if model and not captured_model:
                captured_model = model
                emit({"type": "model", "model": captured_model})

            # Process content blocks — SDK objects don't have a reliable .type;
            # detect block kind by checking for characteristic attributes.
            content = getattr(event, "content", []) or []
            for block in content:
                if hasattr(block, "thinking"):
                    thinking_text = getattr(block, "thinking", "")
                    if thinking_text:
                        emit({"type": "thinking", "content": thinking_text})

                elif hasattr(block, "name") and hasattr(block, "input"):
                    # Tool use block
                    tool_call = {
                        "id": getattr(block, "id", ""),
                        "name": getattr(block, "name", ""),
                        "input": getattr(block, "input", {}),
                    }
                    emit({"type": "tool_use", "tool": tool_call})
                    # Reset text tracking — new text block follows tool results
                    current_text = ""

                elif hasattr(block, "text"):
                    new_text = getattr(block, "text", "")
                    if new_text and new_text != current_text:
                        delta = new_text[len(current_text):]
                        emit({"type": "text", "content": new_text, "delta": delta})
                        current_text = new_text

            # Check for error
            error = getattr(event, "error", None)
            if error:
                emit({"type": "error", "error": str(error)})

        elif event_type == "UserMessage":
            # Tool results come back as ToolResultBlock objects
            msg_content = getattr(event, "content", []) or []
            for block in (msg_content if isinstance(msg_content, list) else []):
                if hasattr(block, "tool_use_id"):
                    emit({
                        "type": "tool_result",
                        "toolUseId": getattr(block, "tool_use_id", ""),
                        "content": str(getattr(block, "content", "")),
                        "isError": getattr(block, "is_error", False),
                    })

        elif event_type == "ResultMessage":
            # Final result text
            result_text = getattr(event, "result", "") or ""
            if result_text and result_text != current_text:
                delta = result_text[len(current_text):]
                emit({"type": "text", "content": result_text, "delta": delta})
                current_text = result_text
            sid = getattr(event, "session_id", None)
            if sid:
                captured_session_id = sid

        # Silently ignore other SDK event types (RateLimitEvent, UsageEvent, etc.)

    return captured_session_id


async def run():
    """Run Claude SDK query inside the sandbox container."""
    # Read input message from stdin
    try:
        raw = sys.stdin.readline()
        if not raw.strip():
            emit({"type": "error", "error": "No input received on stdin"})
            sys.exit(1)
        request = json.loads(raw)
        message = request.get("message", "")
        if not message:
            emit({"type": "error", "error": "Empty message in request"})
            sys.exit(1)
    except json.JSONDecodeError as e:
        emit({"type": "error", "error": f"Invalid JSON input: {e}"})
        sys.exit(1)

    # Get environment configuration
    session_id = os.environ.get("PARACHUTE_SESSION_ID", "")

    # Validate session_id is safe (alphanumeric + hyphens only — no path traversal)
    if session_id and not re.match(r'^[a-zA-Z0-9_-]+$', session_id):
        emit({"type": "error", "error": f"Invalid PARACHUTE_SESSION_ID format"})
        sys.exit(1)

    # Create per-session scratch directory under /scratch (tmpfs)
    # Gives agent an isolated writable workspace without polluting /tmp
    scratch_dir = None
    if session_id and os.path.isdir("/scratch"):
        scratch_dir = f"/scratch/{session_id}"
        os.makedirs(scratch_dir, exist_ok=True)

    # Token: prefer stdin payload (persistent mode), fall back to env var (ephemeral mode)
    oauth_token = request.get("claude_token") or os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")

    # Set working directory: prefer explicit PARACHUTE_CWD, else session scratch dir
    cwd = os.environ.get("PARACHUTE_CWD")
    if cwd:
        if os.path.isdir(cwd):
            os.chdir(cwd)
        else:
            emit({"type": "warning", "message": f"PARACHUTE_CWD={cwd} does not exist in container, staying at {os.getcwd()}"})
    elif scratch_dir:
        os.chdir(scratch_dir)

    if not oauth_token:
        emit({"type": "error", "error": "CLAUDE_CODE_OAUTH_TOKEN not set"})
        sys.exit(1)

    # Capabilities: prefer stdin payload (persistent mode),
    # fall back to mounted file (ephemeral mode)
    capabilities = request.get("capabilities") or {}
    if not capabilities:
        caps_path = "/tmp/capabilities.json"
        if os.path.exists(caps_path):
            try:
                with open(caps_path) as f:
                    capabilities = json.load(f)
            except (json.JSONDecodeError, OSError) as e:
                emit({"type": "warning", "message": f"Failed to load capabilities: {e}"})

    try:
        from claude_agent_sdk import ClaudeAgentOptions

        # Use the resolved CWD (either PARACHUTE_CWD or process default)
        effective_cwd = os.getcwd()

        # Note: No setting_sources — Parachute explicitly constructs all parameters.
        # The host passes system prompt, capabilities, model, etc. via mounted files
        # and environment variables. No SDK auto-discovery.
        options_kwargs: dict = {
            "permission_mode": "bypassPermissions",
            "env": {"CLAUDE_CODE_OAUTH_TOKEN": oauth_token},
            "cwd": effective_cwd,
        }

        # System prompt: prefer stdin payload (persistent mode),
        # fall back to mounted file (ephemeral mode)
        system_prompt = request.get("system_prompt") or ""
        if not system_prompt:
            prompt_path = "/tmp/system_prompt.txt"
            if os.path.exists(prompt_path):
                try:
                    with open(prompt_path) as f:
                        system_prompt = f.read().strip()
                except OSError as e:
                    emit({"type": "warning", "message": f"Failed to load system prompt: {e}"})
        if system_prompt:
            # Use Claude Code preset with appended content
            options_kwargs["system_prompt"] = {
                "type": "preset",
                "preset": "claude_code",
                "append": system_prompt,
            }

        # Pass capabilities to SDK if available
        if capabilities.get("mcp_servers"):
            options_kwargs["mcp_servers"] = capabilities["mcp_servers"]
        if capabilities.get("agents"):
            options_kwargs["agents"] = capabilities["agents"]

        # Convert plugin_dirs to SDK plugins format
        if capabilities.get("plugin_dirs"):
            options_kwargs["plugins"] = [
                {"type": "local", "path": str(d)} for d in capabilities["plugin_dirs"]
            ]

        # Pass model if configured
        parachute_model = os.environ.get("PARACHUTE_MODEL")
        if parachute_model:
            options_kwargs["model"] = parachute_model

        # Resume from prior transcript if requested by orchestrator
        resume_id = request.get("resume_session_id")
        if resume_id and re.match(r'^[a-zA-Z0-9_-]+$', resume_id):
            options_kwargs["resume"] = resume_id
        elif resume_id:
            emit({"type": "warning", "message": f"Invalid resume_session_id format, ignoring"})
            resume_id = None

        # Tell SDK to use our session ID so transcript filenames match our DB.
        # Skip when resuming — CLI rejects --session-id + --resume without --fork-session,
        # and --resume already implies the session ID from the transcript filename.
        if session_id and not resume_id:
            options_kwargs.setdefault("extra_args", {})["session-id"] = session_id

        options = ClaudeAgentOptions(**options_kwargs)

        try:
            captured_session_id = await run_query_and_emit(message, options)
            emit({"type": "done", "sessionId": captured_session_id or ""})
        except Exception as e:
            if resume_id:
                # Resume failed — emit structured event so orchestrator can retry
                # with history injection instead of dropping to zero context
                emit({"type": "resume_failed", "error": str(e), "session_id": resume_id})
                emit({"type": "done", "sessionId": session_id or ""})
                sys.exit(0)  # Clean exit — orchestrator handles retry
            else:
                raise

    except ImportError:
        emit({"type": "error", "error": "claude-agent-sdk not installed in sandbox"})
        sys.exit(1)
    except Exception as e:
        # Extract stderr from ProcessError if available
        stderr_info = ""
        if hasattr(e, "stderr") and e.stderr:
            stderr_info = f" | stderr: {e.stderr}"
        elif hasattr(e, "__cause__") and e.__cause__:
            stderr_info = f" | cause: {e.__cause__}"
        emit({"type": "error", "error": f"Sandbox SDK error: {e}{stderr_info}"})
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(run())
