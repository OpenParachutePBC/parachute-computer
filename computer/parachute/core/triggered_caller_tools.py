"""
Note-scoped tools for triggered Callers.

These tools operate on a single Note (bound to a specific entry_id at creation time).
Used by event-driven Callers that process individual notes after lifecycle events
like transcription completion or entry creation.

Distinct from the day-scoped tools in daily_agent_tools.py which operate across
a day's entries and produce Cards.
"""

import json
import logging
from typing import Any

from claude_agent_sdk import tool, create_sdk_mcp_server, SdkMcpTool

logger = logging.getLogger(__name__)


def create_triggered_caller_tools(
    graph: Any,
    entry_id: str,
    allowed_tools: list[str],
    caller_name: str = "triggered-caller",
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create note-scoped tools for a triggered Caller.

    Each tool is pre-bound to the specific entry_id via closure. The Caller
    only gets tools listed in `allowed_tools` — a cleanup Caller with
    ["read_entry", "update_entry_content"] literally cannot modify tags or metadata.

    Args:
        graph: GraphDB instance
        entry_id: The Note entry_id this Caller is operating on
        allowed_tools: Which tools to include (from the Caller's tools config)
        caller_name: Name of the Caller (for logging and MCP server naming)

    Returns:
        Tuple of (list of SdkMcpTool instances, server config dict)
    """

    all_tools: list[SdkMcpTool] = []

    @tool(
        "read_entry",
        "Read the note that triggered this Caller. Returns the note's content, "
        "metadata, tags, and type.",
        {},
    )
    async def read_entry(args: dict[str, Any]) -> dict[str, Any]:
        """Read the triggering Note from the graph."""
        if graph is None:
            return {
                "content": [{"type": "text", "text": "Error: graph unavailable"}],
                "is_error": True,
            }

        try:
            rows = await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $entry_id}) RETURN e",
                {"entry_id": entry_id},
            )
            if not rows:
                return {
                    "content": [{"type": "text", "text": f"Error: no entry found with id {entry_id}"}],
                    "is_error": True,
                }

            row = rows[0]
            content = row.get("content", "")
            entry_type = row.get("entry_type") or "text"
            title = row.get("title") or ""
            date = row.get("date") or ""

            # Parse metadata from JSON blob
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
                meta_display = {k: v for k, v in meta.items()
                                if k not in ("transcription_raw",)}
                result_text += f"\n\n## Metadata\n\n```json\n{json.dumps(meta_display, indent=2)}\n```"

            return {
                "content": [{"type": "text", "text": result_text}],
            }

        except Exception as e:
            logger.error(f"read_entry failed for {entry_id}: {e}")
            return {
                "content": [{"type": "text", "text": f"Error reading entry: {e}"}],
                "is_error": True,
            }

    @tool(
        "update_entry_content",
        "Replace the note's content with cleaned or processed text.",
        {"content": str},
    )
    async def update_entry_content(args: dict[str, Any]) -> dict[str, Any]:
        """Replace the Note's content."""
        new_content = args.get("content", "").strip()

        if not new_content:
            return {
                "content": [{"type": "text", "text": "Error: content is required"}],
                "is_error": True,
            }

        if graph is None:
            return {
                "content": [{"type": "text", "text": "Error: graph unavailable"}],
                "is_error": True,
            }

        try:
            async with graph.write_lock:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) RETURN e.entry_id AS eid",
                    {"entry_id": entry_id},
                )
                if not rows:
                    return {
                        "content": [{"type": "text", "text": f"Error: no entry found with id {entry_id}"}],
                        "is_error": True,
                    }

                await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) SET e.content = $content",
                    {"entry_id": entry_id, "content": new_content},
                )

            logger.info(f"Triggered caller '{caller_name}' updated content of {entry_id}")
            return {
                "content": [{"type": "text", "text": f"Successfully updated content of entry {entry_id}"}],
            }

        except Exception as e:
            logger.error(f"update_entry_content failed for {entry_id}: {e}")
            return {
                "content": [{"type": "text", "text": f"Error updating entry: {e}"}],
                "is_error": True,
            }

    @tool(
        "update_entry_tags",
        "Set tags on the note. Pass a list of tag strings.",
        {"tags": list},
    )
    async def update_entry_tags(args: dict[str, Any]) -> dict[str, Any]:
        """Set the Note's tags via metadata_json."""
        tags = args.get("tags", [])
        if not isinstance(tags, list):
            return {
                "content": [{"type": "text", "text": "Error: tags must be a list of strings"}],
                "is_error": True,
            }

        if graph is None:
            return {
                "content": [{"type": "text", "text": "Error: graph unavailable"}],
                "is_error": True,
            }

        try:
            # Read-modify-write metadata_json
            async with graph.write_lock:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) RETURN e.metadata_json AS meta",
                    {"entry_id": entry_id},
                )
                if not rows:
                    return {
                        "content": [{"type": "text", "text": f"Error: no entry found with id {entry_id}"}],
                        "is_error": True,
                    }

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

            logger.info(f"Triggered caller '{caller_name}' set tags on {entry_id}: {tags}")
            return {
                "content": [{"type": "text", "text": f"Successfully set tags on entry {entry_id}: {tags}"}],
            }

        except Exception as e:
            logger.error(f"update_entry_tags failed for {entry_id}: {e}")
            return {
                "content": [{"type": "text", "text": f"Error updating tags: {e}"}],
                "is_error": True,
            }

    @tool(
        "update_entry_metadata",
        "Update a metadata field on the note.",
        {"key": str, "value": str},
    )
    async def update_entry_metadata(args: dict[str, Any]) -> dict[str, Any]:
        """Set a metadata field on the Note."""
        key = args.get("key", "").strip()
        value = args.get("value", "")

        if not key:
            return {
                "content": [{"type": "text", "text": "Error: key is required"}],
                "is_error": True,
            }

        # Protect internal fields from LLM mutation
        protected = {"transcription_status", "cleanup_status", "transcription_raw"}
        if key in protected:
            return {
                "content": [{"type": "text", "text": f"Error: '{key}' is a protected field"}],
                "is_error": True,
            }

        if graph is None:
            return {
                "content": [{"type": "text", "text": "Error: graph unavailable"}],
                "is_error": True,
            }

        try:
            async with graph.write_lock:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) RETURN e.metadata_json AS meta",
                    {"entry_id": entry_id},
                )
                if not rows:
                    return {
                        "content": [{"type": "text", "text": f"Error: no entry found with id {entry_id}"}],
                        "is_error": True,
                    }

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

            logger.info(f"Triggered caller '{caller_name}' set metadata {key}={value!r} on {entry_id}")
            return {
                "content": [{"type": "text", "text": f"Successfully set {key}={value!r} on entry {entry_id}"}],
            }

        except Exception as e:
            logger.error(f"update_entry_metadata failed for {entry_id}: {e}")
            return {
                "content": [{"type": "text", "text": f"Error updating metadata: {e}"}],
                "is_error": True,
            }

    # Map tool names to tool instances
    tool_map = {
        "read_entry": read_entry,
        "update_entry_content": update_entry_content,
        "update_entry_tags": update_entry_tags,
        "update_entry_metadata": update_entry_metadata,
    }

    # Only include tools the Caller is allowed to use
    for name in allowed_tools:
        if name in tool_map:
            all_tools.append(tool_map[name])

    if not all_tools:
        logger.warning(
            f"Triggered caller '{caller_name}' has no matching note-scoped tools "
            f"(requested: {allowed_tools})"
        )

    # Create the MCP server config
    server_config = create_sdk_mcp_server(
        name=f"triggered_{caller_name}",
        version="1.0.0",
        tools=all_tools,
    )

    return all_tools, server_config
