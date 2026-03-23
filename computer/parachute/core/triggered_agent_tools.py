"""
Note-scoped agent tools.

Tools that operate on a single Note, bound to a specific entry_id via closure.
Used by event-driven Agents that process individual notes after lifecycle events
like transcription completion or entry creation.

Each factory creates a single SDK tool. Tool implementations register into
the shared TOOL_FACTORIES registry in agent_tools.py.
"""

import json
import logging
from pathlib import Path
from typing import Any

from claude_agent_sdk import tool, create_sdk_mcp_server, SdkMcpTool

logger = logging.getLogger(__name__)


# ── Individual tool factories ─────────────────────────────────────────────────


def _make_read_this_note(graph: Any, scope: dict, agent_name: str, vault_path: Path) -> SdkMcpTool:
    """Read the specific note this agent is processing."""
    entry_id = scope["entry_id"]

    @tool(
        "read_this_note",
        "Read the note that triggered this Agent. Returns the note's content, "
        "metadata, tags, and type.",
        {},
    )
    async def read_this_note(args: dict[str, Any]) -> dict[str, Any]:
        if graph is None:
            return {"content": [{"type": "text", "text": "Error: graph unavailable"}], "is_error": True}

        try:
            rows = await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $entry_id}) RETURN e",
                {"entry_id": entry_id},
            )
            if not rows:
                return {"content": [{"type": "text", "text": f"Error: no entry found with id {entry_id}"}], "is_error": True}

            row = rows[0]
            content = row.get("content", "")
            entry_type = row.get("entry_type") or "text"
            title = row.get("title") or ""
            date = row.get("date") or ""

            meta = {}
            metadata_json = row.get("metadata_json") or ""
            if metadata_json:
                try:
                    meta = json.loads(metadata_json)
                except (json.JSONDecodeError, TypeError):
                    pass

            result_text = (
                f"# Entry: {entry_id}\n\n"
                f"**Type**: {entry_type}\n"
                f"**Date**: {date}\n"
                f"**Title**: {title or '(none)'}\n\n"
                f"## Content\n\n{content}"
            )

            if meta:
                meta_display = {k: v for k, v in meta.items() if k not in ("transcription_raw",)}
                result_text += f"\n\n## Metadata\n\n```json\n{json.dumps(meta_display, indent=2)}\n```"

            return {"content": [{"type": "text", "text": result_text}]}

        except Exception as e:
            logger.error(f"read_this_note failed for {entry_id}: {e}")
            return {"content": [{"type": "text", "text": f"Error reading entry: {e}"}], "is_error": True}

    return read_this_note


def _make_update_this_note(graph: Any, scope: dict, agent_name: str, vault_path: Path) -> SdkMcpTool:
    """Replace the note's content with cleaned or processed text."""
    entry_id = scope["entry_id"]

    @tool(
        "update_this_note",
        "Replace the note's content with cleaned or processed text.",
        {"content": str},
    )
    async def update_this_note(args: dict[str, Any]) -> dict[str, Any]:
        new_content = args.get("content", "").strip()
        if not new_content:
            return {"content": [{"type": "text", "text": "Error: content is required"}], "is_error": True}
        if graph is None:
            return {"content": [{"type": "text", "text": "Error: graph unavailable"}], "is_error": True}

        try:
            async with graph.write_lock:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) RETURN e.entry_id AS eid",
                    {"entry_id": entry_id},
                )
                if not rows:
                    return {"content": [{"type": "text", "text": f"Error: no entry found with id {entry_id}"}], "is_error": True}

                await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) SET e.content = $content",
                    {"entry_id": entry_id, "content": new_content},
                )

            logger.info(f"Agent '{agent_name}' updated content of {entry_id}")
            return {"content": [{"type": "text", "text": f"Successfully updated content of entry {entry_id}"}]}

        except Exception as e:
            logger.error(f"update_this_note failed for {entry_id}: {e}")
            return {"content": [{"type": "text", "text": f"Error updating entry: {e}"}], "is_error": True}

    return update_this_note


def _make_update_note_tags(graph: Any, scope: dict, agent_name: str, vault_path: Path) -> SdkMcpTool:
    """Set tags on the note."""
    entry_id = scope["entry_id"]

    @tool(
        "update_note_tags",
        "Set tags on the note. Pass a list of tag strings.",
        {"tags": list},
    )
    async def update_note_tags(args: dict[str, Any]) -> dict[str, Any]:
        tags = args.get("tags", [])
        if not isinstance(tags, list):
            return {"content": [{"type": "text", "text": "Error: tags must be a list of strings"}], "is_error": True}
        if graph is None:
            return {"content": [{"type": "text", "text": "Error: graph unavailable"}], "is_error": True}

        try:
            async with graph.write_lock:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) RETURN e.metadata_json AS meta",
                    {"entry_id": entry_id},
                )
                if not rows:
                    return {"content": [{"type": "text", "text": f"Error: no entry found with id {entry_id}"}], "is_error": True}

                meta = {}
                blob = rows[0].get("meta") or ""
                if blob:
                    try:
                        meta = json.loads(blob)
                    except (json.JSONDecodeError, TypeError):
                        pass

                meta["tags"] = [str(t) for t in tags]
                await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) SET e.metadata_json = $meta",
                    {"entry_id": entry_id, "meta": json.dumps(meta)},
                )

            logger.info(f"Agent '{agent_name}' set tags on {entry_id}: {tags}")
            return {"content": [{"type": "text", "text": f"Successfully set tags on entry {entry_id}: {tags}"}]}

        except Exception as e:
            logger.error(f"update_note_tags failed for {entry_id}: {e}")
            return {"content": [{"type": "text", "text": f"Error updating tags: {e}"}], "is_error": True}

    return update_note_tags


def _make_update_note_metadata(graph: Any, scope: dict, agent_name: str, vault_path: Path) -> SdkMcpTool:
    """Update a metadata field on the note."""
    entry_id = scope["entry_id"]

    @tool(
        "update_note_metadata",
        "Update a metadata field on the note.",
        {"key": str, "value": str},
    )
    async def update_note_metadata(args: dict[str, Any]) -> dict[str, Any]:
        key = args.get("key", "").strip()
        value = args.get("value", "")
        if not key:
            return {"content": [{"type": "text", "text": "Error: key is required"}], "is_error": True}

        protected = {"transcription_status", "cleanup_status", "transcription_raw"}
        if key in protected:
            return {"content": [{"type": "text", "text": f"Error: '{key}' is a protected field"}], "is_error": True}
        if graph is None:
            return {"content": [{"type": "text", "text": "Error: graph unavailable"}], "is_error": True}

        try:
            async with graph.write_lock:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) RETURN e.metadata_json AS meta",
                    {"entry_id": entry_id},
                )
                if not rows:
                    return {"content": [{"type": "text", "text": f"Error: no entry found with id {entry_id}"}], "is_error": True}

                meta = {}
                blob = rows[0].get("meta") or ""
                if blob:
                    try:
                        meta = json.loads(blob)
                    except (json.JSONDecodeError, TypeError):
                        pass

                meta[key] = value
                await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) SET e.metadata_json = $meta",
                    {"entry_id": entry_id, "meta": json.dumps(meta)},
                )

            logger.info(f"Agent '{agent_name}' set metadata {key}={value!r} on {entry_id}")
            return {"content": [{"type": "text", "text": f"Successfully set {key}={value!r} on entry {entry_id}"}]}

        except Exception as e:
            logger.error(f"update_note_metadata failed for {entry_id}: {e}")
            return {"content": [{"type": "text", "text": f"Error updating metadata: {e}"}], "is_error": True}

    return update_note_metadata


# ── Register into shared registry ─────────────────────────────────────────────

from parachute.core.agent_tools import TOOL_FACTORIES  # noqa: E402

TOOL_FACTORIES["read_this_note"] = (_make_read_this_note, frozenset({"entry_id"}))
TOOL_FACTORIES["update_this_note"] = (_make_update_this_note, frozenset({"entry_id"}))
TOOL_FACTORIES["update_note_tags"] = (_make_update_note_tags, frozenset({"entry_id"}))
TOOL_FACTORIES["update_note_metadata"] = (_make_update_note_metadata, frozenset({"entry_id"}))

# Legacy aliases — old tool names still work
TOOL_FACTORIES["read_entry"] = TOOL_FACTORIES["read_this_note"]
TOOL_FACTORIES["update_entry_content"] = TOOL_FACTORIES["update_this_note"]
TOOL_FACTORIES["update_entry_tags"] = TOOL_FACTORIES["update_note_tags"]
TOOL_FACTORIES["update_entry_metadata"] = TOOL_FACTORIES["update_note_metadata"]


# ── Backwards-compatible monolithic creator ───────────────────────────────────


def create_triggered_agent_tools(
    graph: Any,
    entry_id: str,
    allowed_tools: list[str],
    agent_name: str = "triggered-agent",
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create note-scoped tools for a triggered Agent (backwards-compatible).

    Delegates to bind_tools() with a note scope.
    Kept for callers that haven't migrated to the unified runner yet.
    """
    from parachute.core.agent_tools import bind_tools

    scope = {"entry_id": entry_id}

    return bind_tools(
        tool_names=allowed_tools,
        scope=scope,
        graph=graph,
        agent_name=agent_name,
        vault_path=Path.home(),  # Note tools don't use vault_path
    )
