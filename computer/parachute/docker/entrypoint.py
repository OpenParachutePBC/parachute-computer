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


async def _keep_stdin_open(message: str, done_event: asyncio.Event):
    """Yield a user message then block until done_event is set.

    The SDK's query() with a string prompt calls end_input() immediately,
    closing stdin.  The CLI subprocess needs stdin open for its internal tool
    execution loop (reading permission responses, processing tool results).
    Without this wrapper, the CLI crashes with exit code 1 on any turn that
    involves tool use — including session resume.

    Mirrors the _string_to_async_iterable() pattern from claude_sdk.py.
    """
    yield {
        "type": "user",
        "message": {
            "role": "user",
            "content": message,
        }
    }
    await done_event.wait()


async def run_query_and_emit(message: str, options, done_event: asyncio.Event) -> str | None:
    """Run SDK query, emit JSONL events to stdout. Returns captured session ID."""
    from claude_agent_sdk import query

    current_text = ""
    captured_session_id = None
    captured_model = None

    prompt_iterable = _keep_stdin_open(message, done_event)

    async for event in query(prompt=prompt_iterable, options=options):
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
            # Signal the stdin wrapper to close — CLI is done with this turn
            done_event.set()

        # Silently ignore other SDK event types (RateLimitEvent, UsageEvent, etc.)

    # Ensure stdin closes even if ResultMessage was not received
    done_event.set()
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

    # Add parachute-tools paths to environment so installed packages are usable
    # bin/ → PATH (CLI tools), python/ → PYTHONPATH (pip --target installs)
    _tools_bin = "/opt/parachute-tools/bin"
    _tools_python = "/opt/parachute-tools/python"
    _path = os.environ.get("PATH", "")
    if _tools_bin not in _path:
        os.environ["PATH"] = f"{_tools_bin}:{_path}"
    _pythonpath = os.environ.get("PYTHONPATH", "")
    if _tools_python not in _pythonpath:
        os.environ["PYTHONPATH"] = f"{_tools_python}:{_pythonpath}"

    # Token: prefer stdin payload (persistent mode), fall back to env var (ephemeral mode)
    oauth_token = request.get("claude_token") or os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")

    # Broker secret: prefer stdin payload (persistent mode avoids docker exec -e exposure),
    # fall back to env var (ephemeral mode uses --env-file which is safe)
    broker_secret = request.get("broker_secret") or os.environ.get("BROKER_SECRET", "")
    if broker_secret:
        os.environ["BROKER_SECRET"] = broker_secret

    # Apply injected credentials to environment before SDK initialisation.
    # Values come from vault/.parachute/credentials.yaml (server-side) and are
    # forwarded via the stdin JSON payload — never via --env-file or -e flags.
    # Defense-in-depth: maintain a local denylist here even though the server
    # already filters via _BLOCKED_ENV_VARS — a compromised server plugin should
    # not be able to smuggle interpreter-control variables into the container.
    _ENTRYPOINT_BLOCKED = frozenset({
        "CLAUDE_CODE_OAUTH_TOKEN", "PATH", "LD_PRELOAD", "LD_LIBRARY_PATH",
        "HOME", "USER", "SHELL", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONINSPECT",
        "PYTHONASYNCIODEBUG", "PYTHONMALLOC", "PYTHONFAULTHANDLER", "NODE_OPTIONS",
    })
    for key, value in request.get("credentials", {}).items():
        if (
            key
            and isinstance(value, str)
            and key not in _ENTRYPOINT_BLOCKED
            and re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', key)  # valid env var name
        ):
            os.environ[key] = value

    # Set working directory: prefer explicit PARACHUTE_CWD, else container home
    cwd = os.environ.get("PARACHUTE_CWD")
    if cwd:
        if os.path.isdir(cwd):
            os.chdir(cwd)
        else:
            emit({"type": "warning", "message": f"PARACHUTE_CWD={cwd} does not exist in container, staying at {os.getcwd()}"})
    elif os.path.isdir("/home/sandbox"):
        os.chdir("/home/sandbox")

    # Prevent the CLI from detecting a "nested session" and refusing to start.
    # Each docker exec is an independent process — CLAUDECODE should never be set,
    # but clear it defensively (mirrors claude_sdk.py's direct path).
    os.environ.pop("CLAUDECODE", None)

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

        # setting_sources=["project"] enables CWD-aware discovery of .claude/ settings
        # (commands, custom agents, hooks) walking up from the working directory.
        # Consistent with direct sessions. Scoped to mounted paths only — the vault
        # is not fully mounted in sandboxed sessions, so no vault-wide leakage.
        options_kwargs: dict = {
            "permission_mode": "bypassPermissions",
            "env": {"CLAUDE_CODE_OAUTH_TOKEN": oauth_token, "CLAUDECODE": ""},
            "cwd": effective_cwd,
            "setting_sources": ["project"],
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
            # Check whether to use the Claude Code preset.
            # Agents opt out (use_preset=False via stdin JSON payload) so they
            # get only their personality prompt without Claude Code noise
            # (git, Bash, file editing, etc.).
            # Chat sessions keep the preset (default) for full tool guidance.
            if request.get("use_preset", True):
                options_kwargs["system_prompt"] = {
                    "type": "preset",
                    "preset": "claude_code",
                    "append": system_prompt,
                }
            else:
                options_kwargs["system_prompt"] = system_prompt

        # Tool filtering: control which built-in CLI tools are available.
        # Without this, sandbox sessions get the full Claude Code tool set
        # (including AskUserQuestion, EnterPlanMode, etc.) which are not
        # appropriate for non-interactive container execution.
        # Persistent mode: tools come via stdin payload.
        # Ephemeral mode: tools come via capabilities JSON.
        tools = request.get("tools") or capabilities.get("tools")
        if tools:
            options_kwargs["tools"] = tools
        disallowed_tools = request.get("disallowed_tools") or capabilities.get("disallowed_tools")
        if disallowed_tools:
            options_kwargs["disallowed_tools"] = disallowed_tools

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

        # Pass --session-id only if it's a valid UUID (CLI requires UUID format).
        # Non-UUID session IDs (e.g. slug-format "agent-daily-reflection") are used
        # only for container identification, not transcript naming.
        # Skip when resuming — CLI rejects --session-id + --resume.
        # Also skip when fresh_session is set (retry after resume failure) — the
        # CLI would reject a --session-id that already has a transcript.
        fresh_session = request.get("fresh_session", False)
        if session_id and not resume_id and not fresh_session and re.match(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
            session_id, re.IGNORECASE,
        ):
            options_kwargs.setdefault("extra_args", {})["session-id"] = session_id

        options = ClaudeAgentOptions(**options_kwargs)
        done_event = asyncio.Event()

        try:
            captured_session_id = await run_query_and_emit(message, options, done_event)
            emit({"type": "done", "sessionId": captured_session_id or ""})
        except Exception as e:
            if resume_id:
                # Resume failed — emit structured event so orchestrator can retry
                # with history injection instead of dropping to zero context.
                # Extract real error from ProcessError if available.
                if hasattr(e, "stderr") and e.stderr:
                    resume_error = e.stderr.strip()
                else:
                    resume_error = str(e)
                emit({
                    "type": "resume_failed",
                    "error": resume_error,
                    "session_id": resume_id,
                })
                emit({"type": "done", "sessionId": session_id or ""})
                sys.exit(0)  # Clean exit — orchestrator handles retry
            else:
                raise

    except ImportError:
        emit({"type": "error", "error": "claude-agent-sdk not installed in sandbox"})
        sys.exit(1)
    except Exception as e:
        # Extract the actual CLI error from the SDK's ProcessError wrapper.
        # The ProcessError.stderr field contains the real error message
        # (e.g. "Invalid session ID") — surface it instead of the generic wrapper.
        if hasattr(e, "stderr") and e.stderr:
            error_detail = e.stderr.strip()
        elif hasattr(e, "returncode") and hasattr(e, "stdout"):
            # ProcessError with returncode but no stderr — include exit code
            error_detail = f"CLI exited {e.returncode}: {e}"
        elif hasattr(e, "__cause__") and e.__cause__:
            error_detail = f"{e} (cause: {e.__cause__})"
        else:
            error_detail = str(e)
        emit({"type": "error", "error": error_detail})
        # Also write to stderr so the orchestrator's _stream_process can
        # capture it when the process exit code is non-zero
        print(f"ENTRYPOINT_ERROR: {error_detail}", file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(run())
