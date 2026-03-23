"""
Bridge agent utilities — tool call summarization for Message nodes.

The bridge agent's observe/enrich functions have been removed. Message nodes
are now written directly by the orchestrator (see write_turn_messages in
BrainChatStore). A future process-chat agent will handle enrichment.

This module retains the tool call summarization helpers used by the
orchestrator when writing machine Message nodes.
"""

import logging

logger = logging.getLogger(__name__)


def summarize_tool_calls(tool_calls: list[dict]) -> str:
    """Build a readable summary of tool calls made during an exchange."""
    if not tool_calls:
        return ""
    parts = []
    for tc in tool_calls:
        name = tc.get("name", "unknown")
        if "__" in name:
            name = name.rsplit("__", 1)[-1]
        inp = tc.get("input") or {}
        preview = _pick_preview(name, inp)
        parts.append(f"{name}({preview})" if preview else name)
    return ", ".join(parts)


def _pick_preview(tool_name: str, inp: dict) -> str:
    """Return a short preview string for a tool call input."""
    if not inp:
        return ""
    if tool_name in ("Read", "read"):
        return _short_path(inp.get("file_path", ""))
    if tool_name in ("Write", "write", "Edit", "edit", "MultiEdit"):
        return _short_path(inp.get("file_path", ""))
    if tool_name in ("Bash", "bash"):
        cmd = inp.get("command", "")
        return cmd[:50] if cmd else ""
    if tool_name in ("Glob", "glob"):
        return inp.get("pattern", "")[:40]
    if tool_name in ("Grep", "grep"):
        return inp.get("pattern", "")[:40]
    if tool_name in ("WebFetch", "web_fetch"):
        return inp.get("url", "")[:50]
    for v in inp.values():
        if isinstance(v, str) and v:
            return v[:40]
    return ""


def _short_path(path: str) -> str:
    """Return just the last two path components."""
    if not path:
        return ""
    parts = path.replace("\\", "/").rstrip("/").split("/")
    return "/".join(parts[-2:]) if len(parts) > 1 else parts[-1]
