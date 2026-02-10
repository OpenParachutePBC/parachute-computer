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
import sys


def emit(event: dict):
    """Write a JSON event line to stdout."""
    print(json.dumps(event, default=str), flush=True)


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
    oauth_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")

    # Set working directory if provided
    cwd = os.environ.get("PARACHUTE_CWD")
    if cwd:
        if os.path.isdir(cwd):
            os.chdir(cwd)
        else:
            emit({"type": "warning", "message": f"PARACHUTE_CWD={cwd} does not exist in container, staying at {os.getcwd()}"})

    if not oauth_token:
        emit({"type": "error", "error": "CLAUDE_CODE_OAUTH_TOKEN not set"})
        sys.exit(1)

    # Load capabilities config if mounted by the host
    capabilities = {}
    caps_path = "/tmp/capabilities.json"
    if os.path.exists(caps_path):
        try:
            with open(caps_path) as f:
                capabilities = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            emit({"type": "warning", "message": f"Failed to load capabilities: {e}"})

    try:
        from claude_agent_sdk import query, ClaudeAgentOptions

        # Use the resolved CWD (either PARACHUTE_CWD or process default)
        effective_cwd = os.getcwd()

        options_kwargs = {
            "permission_mode": "bypassPermissions",
            "env": {"CLAUDE_CODE_OAUTH_TOKEN": oauth_token},
            "cwd": effective_cwd,
        }

        # Pass capabilities to SDK if available
        if capabilities.get("mcp_servers"):
            options_kwargs["mcp_servers"] = capabilities["mcp_servers"]
        if capabilities.get("agents"):
            options_kwargs["agents"] = capabilities["agents"]

        # plugin_dirs may not be supported by all SDK versions — probe first
        if capabilities.get("plugin_dirs"):
            import inspect
            sig = inspect.signature(ClaudeAgentOptions.__init__)
            if "plugin_dirs" in sig.parameters:
                from pathlib import Path
                options_kwargs["plugin_dirs"] = [Path(d) for d in capabilities["plugin_dirs"]]
            else:
                emit({"type": "warning", "message": "SDK does not support plugin_dirs, skipping"})

        # Pass model if configured
        parachute_model = os.environ.get("PARACHUTE_MODEL")
        if parachute_model:
            options_kwargs["model"] = parachute_model

        # Note: We intentionally do NOT use "resume" here. The container has no
        # access to SDK session transcripts (stored in host's .claude/ directory),
        # so --resume would always fail. Each sandbox invocation is a fresh query.
        # The session_id is used only for tracking/logging purposes.

        options = ClaudeAgentOptions(**options_kwargs)

        current_text = ""
        captured_session_id = None
        captured_model = None

        async for event in query(prompt=message, options=options):
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

                # Process content blocks — these are objects with .type and .text attrs
                content = getattr(event, "content", []) or []
                for block in content:
                    block_type = getattr(block, "type", None)
                    if block_type == "text":
                        new_text = getattr(block, "text", "")
                        if new_text and new_text != current_text:
                            delta = new_text[len(current_text):]
                            emit({"type": "text", "content": new_text, "delta": delta})
                            current_text = new_text

                # Check for error
                error = getattr(event, "error", None)
                if error:
                    emit({"type": "error", "error": str(error)})

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

        # Emit completion
        emit({"type": "done", "sessionId": captured_session_id})

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
