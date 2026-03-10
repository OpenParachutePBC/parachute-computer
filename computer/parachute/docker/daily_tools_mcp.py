#!/usr/bin/env python3
"""
Container-side MCP server for daily agent tools.

Runs inside the Docker sandbox as a stdio MCP process. Provides the same
tools that daily agents use (read_journal, read_chat_log, write_output, etc.)
but backed by HTTP calls to the host Parachute server rather than direct
graph access.

Environment variables:
    PARACHUTE_CALLER_NAME   - Agent name (e.g. "reflection")
    PARACHUTE_HOST_URL      - Host server URL (default: http://host.docker.internal:3333)

Usage (by the Claude SDK inside the container):
    Configured as an MCP server in the capabilities JSON:
    {
        "command": "python",
        "args": ["/workspace/daily_tools_mcp.py"],
        "env": {
            "PARACHUTE_CALLER_NAME": "reflection",
            "PARACHUTE_HOST_URL": "http://host.docker.internal:3333"
        }
    }
"""

import json
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

# MCP protocol constants
JSONRPC_VERSION = "2.0"

AGENT_NAME = os.environ.get("PARACHUTE_CALLER_NAME", "unknown")
HOST_URL = os.environ.get("PARACHUTE_HOST_URL", "http://host.docker.internal:3333")

# Tools provided by this MCP server
TOOLS = [
    {
        "name": "read_journal",
        "description": "Read journal entries for a specific date. Returns the full content of thatday's journal.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {
                    "type": "string",
                    "description": "Date in YYYY-MM-DD format",
                }
            },
            "required": ["date"],
        },
    },
    {
        "name": "read_chat_log",
        "description": "Read AI chat logs for a specific date. Shows what conversations happened with AI assistants that day.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {
                    "type": "string",
                    "description": "Date in YYYY-MM-DD format",
                }
            },
            "required": ["date"],
        },
    },
    {
        "name": "read_recent_journals",
        "description": "Read journal entries from the past N days for context. Useful for noticing patterns across days.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "days": {
                    "type": "integer",
                    "description": "Number of days to look back (default: 7, max: 30)",
                }
            },
        },
    },
    {
        "name": "read_recent_sessions",
        "description": "Read recent AI chat sessions for context. Returns summaries of recent conversations.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "days": {
                    "type": "integer",
                    "description": "Number of days to look back (default: 7, max: 30)",
                }
            },
        },
    },
    {
        "name": "write_output",
        "description": "Write the agent's output. Saves as a Card in the graph.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {
                    "type": "string",
                    "description": "Date in YYYY-MM-DD format for the card",
                },
                "content": {
                    "type": "string",
                    "description": "Markdown content for the card",
                },
            },
            "required": ["date", "content"],
        },
    },
]


def _http_get(path: str, params: dict | None = None) -> dict | str:
    """Make an HTTP GET request to the host server using urllib (no deps)."""
    import urllib.request
    import urllib.parse
    import urllib.error

    url = f"{HOST_URL}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.reason}"}
    except Exception as e:
        return {"error": str(e)}


def _http_post(path: str, body: dict) -> dict:
    """Make an HTTP POST request to the host server using urllib (no deps)."""
    import urllib.request
    import urllib.error

    url = f"{HOST_URL}{path}"
    data = json.dumps(body).encode()
    try:
        req = urllib.request.Request(url, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode() if e.fp else ""
        return {"error": f"HTTP {e.code}: {body_text or e.reason}"}
    except Exception as e:
        return {"error": str(e)}


def handle_read_journal(args: dict) -> list[dict]:
    """Read journal entries for a date from the host API."""
    date_str = args.get("date", "").strip()
    if not date_str:
        return [{"type": "text", "text": "Error: date is required (YYYY-MM-DD format)"}]

    result = _http_get("/api/daily/entries", {"date": date_str})
    if isinstance(result, dict) and "error" in result:
        return [{"type": "text", "text": f"Error reading journal: {result['error']}"}]

    entries = result.get("entries", [])
    if not entries:
        return [{"type": "text", "text": f"No journal found for {date_str}"}]

    entries_text = "\n\n---\n\n".join(
        e.get("content", "") for e in entries if e.get("content")
    )
    return [{"type": "text", "text": f"# Journal for {date_str}\n\n{entries_text}"}]


def handle_read_chat_log(args: dict) -> list[dict]:
    """Read chat logs for a date from the mounted vault."""
    date_str = args.get("date", "").strip()
    if not date_str:
        return [{"type": "text", "text": "Error: date is required (YYYY-MM-DD format)"}]

    # Read from mounted vault path inside container
    chat_log_file = Path("/home/sandbox/Parachute/Daily/chat-log") / f"{date_str}.md"
    if not chat_log_file.exists():
        return [{"type": "text", "text": f"No chat log found for {date_str}"}]

    try:
        content = chat_log_file.read_text(encoding="utf-8")
        if len(content) > 10000:
            content = content[:10000] + "\n\n...(truncated - chat log was very long)"
        return [{"type": "text", "text": f"# Chat Log for {date_str}\n\n{content}"}]
    except Exception as e:
        return [{"type": "text", "text": f"Error reading chat log: {e}"}]


def handle_read_recent_journals(args: dict) -> list[dict]:
    """Read recent journal entries from the host API."""
    days_back = min(int(args.get("days", 7)), 30)
    today = datetime.now().date()
    journals_found = []

    for i in range(1, days_back + 1):
        date = today - timedelta(days=i)
        date_str = date.strftime("%Y-%m-%d")

        result = _http_get("/api/daily/entries", {"date": date_str})
        if isinstance(result, dict) and "error" not in result:
            entries = result.get("entries", [])
            if entries:
                content = "\n\n".join(
                    e.get("content", "") for e in entries if e.get("content")
                )
                if len(content) > 5000:
                    content = content[:5000] + "\n\n...(truncated)"
                journals_found.append(f"## {date_str}\n\n{content}")

    if not journals_found:
        return [{"type": "text", "text": f"No journals found in the past {days_back} days"}]

    return [{"type": "text", "text": f"# Recent Journals ({len(journals_found)} days)\n\n" + "\n\n---\n\n".join(journals_found)}]


def handle_read_recent_sessions(args: dict) -> list[dict]:
    """Read recent chat sessions from the mounted vault."""
    days_back = min(int(args.get("days", 7)), 30)
    today = datetime.now().date()
    chat_log_dir = Path("/home/sandbox/Parachute/Daily/chat-log")
    logs_found = []

    for i in range(1, days_back + 1):
        date = today - timedelta(days=i)
        date_str = date.strftime("%Y-%m-%d")
        log_file = chat_log_dir / f"{date_str}.md"

        if log_file.exists():
            try:
                content = log_file.read_text(encoding="utf-8")
                if len(content) > 3000:
                    content = content[:3000] + "\n\n...(truncated)"
                logs_found.append(f"## {date_str}\n\n{content}")
            except Exception:
                continue

    if not logs_found:
        return [{"type": "text", "text": f"No chat logs found in the past {days_back} days"}]

    return [{"type": "text", "text": f"# Recent Chat Sessions ({len(logs_found)} days)\n\n" + "\n\n---\n\n".join(logs_found)}]


def handle_write_output(args: dict) -> list[dict]:
    """Write the agent's output as a Card via the host API."""
    date_str = args.get("date", "").strip()
    content = args.get("content", "").strip()

    if not date_str:
        return [{"type": "text", "text": "Error: date is required"}]
    if not content:
        return [{"type": "text", "text": "Error: content is required"}]

    result = _http_post("/api/daily/cards/write", {
        "agent_name": AGENT_NAME,
        "date": date_str,
        "content": content,
    })

    if "error" in result:
        return [{"type": "text", "text": f"Error writing output: {result['error']}"}]

    card_id = result.get("card_id", f"{AGENT_NAME}:{date_str}")
    return [{"type": "text", "text": f"Successfully wrote output to graph (card_id: {card_id})"}]


# Tool handler dispatch
TOOL_HANDLERS = {
    "read_journal": handle_read_journal,
    "read_chat_log": handle_read_chat_log,
    "read_recent_journals": handle_read_recent_journals,
    "read_recent_sessions": handle_read_recent_sessions,
    "write_output": handle_write_output,
}


# ── MCP stdio protocol ─────────────────────────────────────────────────────

def send_response(id, result):
    """Send a JSON-RPC response."""
    msg = {"jsonrpc": JSONRPC_VERSION, "id": id, "result": result}
    out = json.dumps(msg)
    sys.stdout.write(f"Content-Length: {len(out)}\r\n\r\n{out}")
    sys.stdout.flush()


def send_error(id, code, message):
    """Send a JSON-RPC error response."""
    msg = {
        "jsonrpc": JSONRPC_VERSION,
        "id": id,
        "error": {"code": code, "message": message},
    }
    out = json.dumps(msg)
    sys.stdout.write(f"Content-Length: {len(out)}\r\n\r\n{out}")
    sys.stdout.flush()


def read_message() -> dict | None:
    """Read a JSON-RPC message from stdin using the LSP framing protocol."""
    # Read headers
    content_length = 0
    while True:
        line = sys.stdin.readline()
        if not line:
            return None  # EOF
        line = line.strip()
        if not line:
            break  # End of headers
        if line.lower().startswith("content-length:"):
            content_length = int(line.split(":", 1)[1].strip())

    if content_length == 0:
        return None

    # Read body
    body = sys.stdin.read(content_length)
    if not body:
        return None
    return json.loads(body)


def handle_request(msg: dict):
    """Handle a single JSON-RPC request."""
    method = msg.get("method", "")
    id = msg.get("id")
    params = msg.get("params", {})

    if method == "initialize":
        send_response(id, {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {
                "name": f"daily-tools-{AGENT_NAME}",
                "version": "1.0.0",
            },
        })

    elif method == "notifications/initialized":
        pass  # No response needed for notifications

    elif method == "tools/list":
        send_response(id, {"tools": TOOLS})

    elif method == "tools/call":
        tool_name = params.get("name", "")
        tool_args = params.get("arguments", {})
        handler = TOOL_HANDLERS.get(tool_name)
        if handler:
            try:
                content = handler(tool_args)
                send_response(id, {"content": content})
            except Exception as e:
                send_response(id, {
                    "content": [{"type": "text", "text": f"Error: {e}"}],
                    "isError": True,
                })
        else:
            send_error(id, -32601, f"Unknown tool: {tool_name}")

    elif id is not None:
        send_error(id, -32601, f"Method not found: {method}")


def main():
    """Run the MCP stdio server loop."""
    while True:
        msg = read_message()
        if msg is None:
            break
        handle_request(msg)


if __name__ == "__main__":
    main()
