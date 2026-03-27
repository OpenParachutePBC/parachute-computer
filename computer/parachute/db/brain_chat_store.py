"""
BrainChatStore — Kuzu-backed chat metadata store.

Replaces database.py (SQLite/aiosqlite). All chat metadata is stored in
the shared Kuzu graph database alongside Brain, Chat, and Daily data.

Schema:
  - Chat: core session metadata
  - Container: container environments
  - Parachute_PairingRequest: bot pairing requests
  - Parachute_KV: key-value metadata store

Tags are graph-native: Tag nodes with TAGGED_WITH edges to any entity type.
Context folders are stored as JSON arrays on the session node.
"""

import json
import logging
import re
from datetime import datetime, timedelta, timezone
from typing import Any, Optional, TypedDict, Union

from parachute.db.brain import BrainService
from parachute.models.session import (
    Container,
    PairingRequest,
    Session,
    SessionCreate,
    SessionSource,
    SessionUpdate,
)

logger = logging.getLogger(__name__)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# ── Agent templates ──────────────────────────────────────────────────────────
# Built-in agent definitions seeded on startup.  Also returned by the daily
# module's GET /agents/templates endpoint.


class AgentTemplateDict(TypedDict, total=False):
    name: str
    display_name: str
    description: str
    system_prompt: str
    tools: list[str]
    schedule_time: str
    trust_level: str
    trigger_event: str
    trigger_filter: str
    memory_mode: str
    template_version: str


PROCESS_NOTE_SYSTEM_PROMPT = (
    "You are a post-processing assistant for journal entries.\n\n"
    "## Your Job\n\n"
    "Read the entry with `read_this_note`. If it came from a voice recording, "
    "clean up the transcript and save it with `update_this_note`. "
    "If the entry was typed (not voice), do nothing — just return.\n\n"
    "## Transcription Cleanup Rules\n\n"
    "- Remove filler words: \"um\", \"uh\", \"like\", \"you know\", \"I mean\", \"so\", \"right\"\n"
    "- Fix grammar and sentence structure\n"
    "- Add proper punctuation (periods, commas, question marks)\n"
    "- Create paragraph breaks at natural topic transitions\n"
    "- Very light restructuring for readability — combine fragments, smooth transitions\n"
    "- Preserve the speaker's voice, tone, and meaning exactly\n"
    "- Do NOT summarize, add commentary, or change the substance\n"
    "- Do NOT add headers, bullet points, or other structural formatting "
    "unless the speaker clearly intended a list\n"
    "- Output ONLY the cleaned text — no preamble, no explanation"
)

# Backwards compat alias
POST_PROCESS_SYSTEM_PROMPT = PROCESS_NOTE_SYSTEM_PROMPT

PROCESS_DAY_SYSTEM_PROMPT = (
    "You are a thoughtful, perceptive reflection partner for {user_name}.\n\n"
    "## Your Role\n\n"
    "Review yesterday's activity — journal entries, chat conversations, and "
    "recent reflections — then write a short, meaningful reflection that helps "
    "them see their day clearly.\n\n"
    "## Guidelines\n\n"
    "- **Be genuine, not performative.** No empty affirmations. Reflect what "
    "you actually notice.\n"
    "- **Make connections.** Link yesterday's activity to patterns from recent days "
    "when relevant.\n"
    "- **Keep it concise.** 3-5 paragraphs. Quality over quantity.\n"
    "- **Match their energy.** If the day was hard, acknowledge it honestly. "
    "If it was good, celebrate without overdoing it.\n"
    "- **One insight, well-developed** is better than five shallow observations.\n"
    "- Write in second person (\"you\") — this is for them.\n\n"
    "## Process\n\n"
    "1. Read the day's chat sessions with `read_days_chats` — see what conversations happened\n"
    "2. For each substantive session, call `summarize_chat` to get a focused summary of what happened that day\n"
    "3. Read journal entries with `read_days_notes`\n"
    "4. Read recent reflection cards with `read_recent_cards` (type \"reflection\", last 7 days) for continuity\n"
    "5. Write your reflection using `write_card` with card_type \"reflection\"\n\n"
    "## User Context\n\n"
    "{user_context}"
)


# ── Tool templates ────────────────────────────────────────────────────────
# Built-in Tool definitions seeded on startup.  Tool is the universal
# primitive — everything callable is a Tool node in the graph.  The `mode`
# field discriminates: "function", "transform", "agent", "mcp".


class ToolTemplateDict(TypedDict, total=False):
    name: str
    display_name: str
    description: str
    mode: str  # "function" | "transform" | "agent" | "mcp"
    scope_keys: list[str]
    # mode=query
    query: str
    write_query: str
    # mode=transform
    transform_prompt: str
    transform_model: str
    # mode=agent
    system_prompt: str
    model: str
    memory_mode: str
    trust_level: str
    container_slug: str
    # metadata
    template_version: str
    # child tools (names) — becomes CAN_CALL edges
    can_call: list[str]


class TriggerTemplateDict(TypedDict, total=False):
    name: str
    type: str  # "schedule" | "event"
    schedule_time: str
    event: str
    event_filter: str
    scope: dict[str, str]
    enabled: str
    template_version: str
    # target tool (name) — becomes INVOKES edge
    invokes: str


TOOL_TEMPLATES: list[ToolTemplateDict] = [
    # ── Day-scoped query tools ────────────────────────────────────────────
    {
        "name": "read-days-notes",
        "display_name": "Today's Notes",
        "description": "Read all notes for a specific date. Returns the full content of that day's entries.",
        "mode": "function",
        "scope_keys": ["date"],
        "template_version": "2026-03-26",
    },
    {
        "name": "read-days-chats",
        "display_name": "Today's Chats",
        "description": "List chat sessions active on a specific date. Returns session IDs, titles, message counts, and time ranges.",
        "mode": "function",
        "scope_keys": ["date"],
        "template_version": "2026-03-26",
    },
    {
        "name": "read-recent-journals",
        "display_name": "Recent Journals",
        "description": "Read journal entries from the past N days for context. Useful for noticing patterns across days.",
        "mode": "function",
        "scope_keys": [],
        "template_version": "2026-03-26",
    },
    {
        "name": "read-recent-sessions",
        "display_name": "Recent Sessions",
        "description": "Read recent AI chat sessions for context. Returns summaries of recent conversations.",
        "mode": "function",
        "scope_keys": [],
        "template_version": "2026-03-26",
    },
    {
        "name": "read-recent-cards",
        "display_name": "Recent Cards",
        "description": "Read cards from recent days. Filter by card_type (e.g. 'reflection') to see past outputs.",
        "mode": "function",
        "scope_keys": [],
        "template_version": "2026-03-26",
    },
    {
        "name": "write-card",
        "display_name": "Write Card",
        "description": "Write the agent's output. Saves as a Card in the graph.",
        "mode": "function",
        "scope_keys": [],
        "template_version": "2026-03-26",
    },
    # ── Note-scoped query tools ───────────────────────────────────────────
    {
        "name": "read-this-note",
        "display_name": "Read This Note",
        "description": "Read the note that triggered this agent. Returns the note's content, metadata, tags, and type.",
        "mode": "function",
        "scope_keys": ["entry_id"],
        "template_version": "2026-03-26",
    },
    {
        "name": "update-this-note",
        "display_name": "Update This Note",
        "description": "Replace the note's content with cleaned or processed text.",
        "mode": "function",
        "scope_keys": ["entry_id"],
        "template_version": "2026-03-26",
    },
    {
        "name": "update-note-tags",
        "display_name": "Update Note Tags",
        "description": "Set tags on the note. Pass a list of tag strings.",
        "mode": "function",
        "scope_keys": ["entry_id"],
        "template_version": "2026-03-26",
    },
    {
        "name": "update-note-metadata",
        "display_name": "Update Note Metadata",
        "description": "Update a metadata field on the note.",
        "mode": "function",
        "scope_keys": ["entry_id"],
        "template_version": "2026-03-26",
    },
    # ── Transform tools ───────────────────────────────────────────────────
    {
        "name": "summarize-chat",
        "display_name": "Summarize Chat",
        "description": "Summarize a chat session's activity for a specific date. Spawns a fast sub-agent to read the full transcript and return a focused summary.",
        "mode": "transform",
        "scope_keys": ["date"],
        "transform_model": "haiku",
        "template_version": "2026-03-26",
    },
    {
        "name": "process-note",
        "display_name": "Process Note",
        "description": "Runs after voice transcription completes. Cleans up filler words, fixes grammar, adds punctuation.",
        "mode": "agent",
        "scope_keys": ["entry_id"],
        "system_prompt": PROCESS_NOTE_SYSTEM_PROMPT,
        "trust_level": "direct",
        "memory_mode": "fresh",
        "can_call": ["read-this-note", "update-this-note"],
        "template_version": "2026-03-26",
    },
    # ── Agent tools ───────────────────────────────────────────────────────
    {
        "name": "process-day",
        "display_name": "Daily Reflection",
        "description": "Reviews your journal entries and chat sessions, then offers a thoughtful daily reflection",
        "mode": "agent",
        "scope_keys": ["date"],
        "system_prompt": PROCESS_DAY_SYSTEM_PROMPT,
        "trust_level": "sandboxed",
        "memory_mode": "persistent",
        "can_call": [
            "read-days-notes",
            "read-days-chats",
            "summarize-chat",
            "read-recent-cards",
            "write-card",
        ],
        "template_version": "2026-03-26",
    },
]

TRIGGER_TEMPLATES: list[TriggerTemplateDict] = [
    {
        "name": "nightly-reflection",
        "type": "schedule",
        "schedule_time": "4:00",
        "scope": {"date": "yesterday"},
        "enabled": "true",
        "invokes": "process-day",
        "template_version": "2026-03-26",
    },
    {
        "name": "on-transcription",
        "type": "event",
        "event": "note.transcription_complete",
        "enabled": "true",
        "invokes": "process-note",
        "template_version": "2026-03-26",
    },
]


# ── Derive AGENT_TEMPLATES from TOOL_TEMPLATES ──────────────────────────
# TOOL_TEMPLATES is the source of truth.  AGENT_TEMPLATES is derived for
# backward compatibility with the old Agent seeding/execution path.
# Remove this once Phase 2 execution rewire is complete.

# Kebab → underscore for tool names (old factories use underscores)
_TOOL_NAME_ALIASES: dict[str, str] = {
    "read-days-notes": "read_days_notes",
    "read-days-chats": "read_days_chats",
    "summarize-chat": "summarize_chat",
    "read-recent-journals": "read_recent_journals",
    "read-recent-sessions": "read_recent_sessions",
    "read-recent-cards": "read_recent_cards",
    "write-card": "write_card",
    "read-this-note": "read_this_note",
    "update-this-note": "update_this_note",
    "update-note-tags": "update_note_tags",
    "update-note-metadata": "update_note_metadata",
}

# Build a trigger lookup: tool_name → trigger template
_TRIGGER_BY_TOOL: dict[str, TriggerTemplateDict] = {
    t["invokes"]: t for t in TRIGGER_TEMPLATES if "invokes" in t
}


def _tool_to_agent_template(tool: ToolTemplateDict) -> AgentTemplateDict:
    """Derive a legacy Agent template from a Tool template + its Trigger."""
    trigger = _TRIGGER_BY_TOOL.get(tool["name"])
    # Convert can_call kebab names → underscore names for TOOL_FACTORIES
    can_call = tool.get("can_call", [])
    tools_underscore = [_TOOL_NAME_ALIASES.get(n, n.replace("-", "_")) for n in can_call]

    result: AgentTemplateDict = {
        "name": tool["name"],
        "display_name": tool.get("display_name", ""),
        "description": tool.get("description", ""),
        "system_prompt": tool.get("system_prompt", ""),
        "tools": tools_underscore,
        "trust_level": tool.get("trust_level", "sandboxed"),
        "memory_mode": tool.get("memory_mode", "persistent"),
        "template_version": tool.get("template_version", ""),
    }
    if trigger:
        if trigger.get("type") == "schedule":
            result["schedule_time"] = trigger.get("schedule_time", "")
        elif trigger.get("type") == "event":
            result["trigger_event"] = trigger.get("event", "")
            result["trigger_filter"] = trigger.get("event_filter", "")
    return result


# Only agent-mode and transform-mode tools (with system_prompt) become Agents
AGENT_TEMPLATES: list[AgentTemplateDict] = [
    _tool_to_agent_template(t)
    for t in TOOL_TEMPLATES
    if t.get("mode") in ("agent", "transform") and t.get("system_prompt")
]


class BrainChatStore:
    """
    Kuzu-backed chat metadata store.

    Drop-in replacement for Database (SQLite/aiosqlite). Uses BrainService for
    all Kuzu access. The BrainService write_lock serializes writes.
    """

    # Mapping from API entity_type string to (graph table name, primary key column)
    TAG_ENTITY_TYPES: dict[str, tuple[str, str]] = {
        "chat": ("Chat", "session_id"),
        "note": ("Note", "entry_id"),
        "card": ("Card", "card_id"),
        "entity": ("Brain_Entity", "name"),
        "agent": ("Agent", "name"),
        "tool": ("Tool", "name"),
    }

    def __init__(self, graph: BrainService):
        self.graph = graph

    # ── Schema ────────────────────────────────────────────────────────────────

    async def ensure_schema(self) -> None:
        """Create node tables if they don't exist. Idempotent."""
        await self.graph.ensure_node_table(
            "Chat",
            {
                "session_id": "STRING",
                "title": "STRING",
                "module": "STRING",
                "source": "STRING",
                "working_directory": "STRING",
                "model": "STRING",
                "message_count": "INT64",
                "archived": "BOOLEAN",
                "created_at": "STRING",
                "last_accessed": "STRING",
                "continued_from": "STRING",
                "agent_type": "STRING",
                "trust_level": "STRING",
                "mode": "STRING",
                "linked_bot_platform": "STRING",
                "linked_bot_chat_id": "STRING",
                "linked_bot_chat_type": "STRING",
                "parent_session_id": "STRING",
                "created_by": "STRING",
                "summary": "STRING",
                "summary_updated_at": "STRING",
                "bridge_session_id": "STRING",
                "bridge_context_log": "STRING",
                "container_id": "STRING",
                "metadata_json": "STRING",
                "tags_json": "STRING",
                "contexts_json": "STRING",
            },
            primary_key="session_id",
        )
        await self.graph.ensure_node_table(
            "Container",
            {
                "slug": "STRING",
                "display_name": "STRING",
                "core_memory": "STRING",
                "is_workspace": "BOOLEAN",
                "credential_grants_json": "STRING",
                "created_at": "STRING",
            },
            primary_key="slug",
        )
        # Migrations for existing tables
        async with self.graph.write_lock:
            # Rename project_id → container_id (from the container rename PR #265)
            chat_cols = await self.graph.get_table_columns("Chat")
            if "project_id" in chat_cols and "container_id" not in chat_cols:
                await self.graph.execute_cypher(
                    "ALTER TABLE Chat RENAME project_id TO container_id"
                )
                logger.info("Renamed Chat.project_id → container_id")

            # Add is_workspace column to Container table
            container_cols = await self.graph.get_table_columns("Container")
            if "is_workspace" not in container_cols:
                await self.graph.execute_cypher(
                    "ALTER TABLE Container ADD is_workspace BOOLEAN DEFAULT false"
                )
                logger.info("Added is_workspace column to Container table")
        await self.graph.ensure_node_table(
            "Parachute_PairingRequest",
            {
                "request_id": "STRING",
                "platform": "STRING",
                "platform_user_id": "STRING",
                "platform_user_display": "STRING",
                "platform_chat_id": "STRING",
                "status": "STRING",
                "approved_trust_level": "STRING",
                "created_at": "STRING",
                "resolved_at": "STRING",
                "resolved_by": "STRING",
            },
            primary_key="request_id",
        )
        # ── Shared schema tables ─────────────────────────────────────────────
        # All node/rel tables are registered here so they exist at startup
        # regardless of which modules are loaded.  Modules are views (route
        # providers) — not data owners.

        await self.graph.ensure_node_table(
            "Note",
            {
                "entry_id": "STRING",
                "note_type": "STRING",
                "date": "STRING",
                "content": "STRING",
                "snippet": "STRING",
                "created_at": "STRING",
                "title": "STRING",
                "entry_type": "STRING",
                "audio_path": "STRING",
                "aliases": "STRING",
                "status": "STRING",
                "created_by": "STRING",
                "metadata_json": "STRING",
                "brain_links_json": "STRING",
                "updated_at": "STRING",
            },
            primary_key="entry_id",
        )
        await self.graph.ensure_node_table(
            "Card",
            {
                "card_id": "STRING",
                "agent_name": "STRING",
                "card_type": "STRING",
                "display_name": "STRING",
                "content": "STRING",
                "generated_at": "STRING",
                "status": "STRING",
                "date": "STRING",
                "read_at": "STRING",
            },
            primary_key="card_id",
        )
        await self.graph.ensure_node_table(
            "Agent",
            {
                "name": "STRING",
                "display_name": "STRING",
                "description": "STRING",
                "system_prompt": "STRING",
                "tools": "STRING",
                "model": "STRING",
                "schedule_enabled": "STRING",
                "schedule_time": "STRING",
                "enabled": "STRING",
                "trust_level": "STRING",
                "created_at": "STRING",
                "updated_at": "STRING",
                "sdk_session_id": "STRING",
                "last_run_at": "STRING",
                "last_processed_date": "STRING",
                "run_count": "INT64",
                "memory_mode": "STRING",
                # Columns added post-launch (migrations keep old DBs in sync):
                "trigger_event": "STRING",
                "trigger_filter": "STRING",
                "template_version": "STRING",
                "user_modified": "STRING",
                "container_slug": "STRING",
            },
            primary_key="name",
        )
        await self.graph.ensure_node_table(
            "AgentRun",
            {
                "run_id": "STRING",
                "agent_name": "STRING",
                "display_name": "STRING",
                "entry_id": "STRING",
                "date": "STRING",
                "trigger": "STRING",
                "status": "STRING",
                "error": "STRING",
                "container_slug": "STRING",
                "card_id": "STRING",
                "started_at": "STRING",
                "completed_at": "STRING",
                "duration_seconds": "DOUBLE",
                "ran_at": "STRING",
                "session_id": "STRING",
                "scope": "STRING",
            },
            primary_key="run_id",
        )
        await self.graph.ensure_node_table(
            "Message",
            {
                "message_id": "STRING",
                "session_id": "STRING",
                "role": "STRING",           # "human" | "machine"
                "content": "STRING",
                "status": "STRING",         # "complete" | "interrupted" | "error" | "pending"
                "sequence": "INT64",
                "tools_used": "STRING",     # JSON: tool names + param keys (machine only)
                "thinking": "STRING",       # thinking blocks (machine only, null for sandboxed)
                "description": "STRING",    # search-optimized summary (set by enrichment)
                "context": "STRING",        # session state snapshot (set by enrichment)
                "created_at": "STRING",
                "updated_at": "STRING",
                "metadata_json": "STRING",
            },
            primary_key="message_id",
        )
        await self.graph.ensure_rel_table("HAS_MESSAGE", "Chat", "Message")

        # ── Tool / Trigger / ToolRun (universal primitive) ────────────────────
        await self.graph.ensure_node_table(
            "Tool",
            {
                "name": "STRING",            # PK: "read-days-notes", "process-day"
                "display_name": "STRING",
                "description": "STRING",
                "mode": "STRING",            # "function" | "transform" | "agent" | "mcp"
                "scope_keys": "STRING",      # JSON array: ["date"], ["entry_id"]
                "input_schema": "STRING",    # JSON schema for parameters

                # mode=query
                "query": "STRING",           # Cypher template

                # mode=transform
                "transform_prompt": "STRING",
                "transform_model": "STRING",
                "write_query": "STRING",

                # mode=agent
                "system_prompt": "STRING",
                "model": "STRING",
                "memory_mode": "STRING",     # "persistent" | "fresh"
                "trust_level": "STRING",     # "direct" | "sandboxed"
                "container_slug": "STRING",

                # mode=mcp
                "server_name": "STRING",

                # metadata
                "builtin": "STRING",         # "true" | "false"
                "enabled": "STRING",
                "template_version": "STRING",
                "user_modified": "STRING",
                "created_at": "STRING",
                "updated_at": "STRING",
            },
            primary_key="name",
        )
        await self.graph.ensure_node_table(
            "Trigger",
            {
                "name": "STRING",            # PK: "nightly-reflection"
                "type": "STRING",            # "schedule" | "event"
                "schedule_time": "STRING",   # "4:00"
                "event": "STRING",           # "note.transcription_complete"
                "event_filter": "STRING",    # JSON
                "scope": "STRING",           # JSON: default scope
                "enabled": "STRING",
                "template_version": "STRING",
                "user_modified": "STRING",
                "created_at": "STRING",
                "updated_at": "STRING",
            },
            primary_key="name",
        )
        await self.graph.ensure_node_table(
            "ToolRun",
            {
                "run_id": "STRING",
                "tool_name": "STRING",
                "display_name": "STRING",
                "trigger_name": "STRING",    # or "manual"
                "status": "STRING",
                "started_at": "STRING",
                "completed_at": "STRING",
                "duration_seconds": "DOUBLE",
                "session_id": "STRING",
                "scope": "STRING",           # JSON
                "card_id": "STRING",
                "error": "STRING",
                "container_slug": "STRING",
                "date": "STRING",
                "entry_id": "STRING",
                "created_at": "STRING",
            },
            primary_key="run_id",
        )
        # Relationships
        await self.graph.ensure_rel_table("CAN_CALL", "Tool", "Tool")
        await self.graph.ensure_rel_table("INVOKES", "Trigger", "Tool")

        # ── Brain entities (open ontology — created here so Tag edges work) ───
        await self.graph.ensure_node_table(
            "Brain_Entity",
            {
                "name": "STRING",
                "entity_type": "STRING",
                "description": "STRING",
                "created_at": "STRING",
                "updated_at": "STRING",
            },
            primary_key="name",
        )

        # ── Tags ──────────────────────────────────────────────────────────────
        await self.graph.ensure_node_table(
            "Tag",
            {
                "name": "STRING",
                "description": "STRING",
                "created_at": "STRING",
            },
            primary_key="name",
        )
        await self._ensure_tagged_with_rel_table()

        # ── Column migrations ────────────────────────────────────────────────
        await self._ensure_column_migrations()

        # ── Tag migration (JSON arrays → graph edges) ────────────────────────
        await self._migrate_tags_to_graph()

        logger.info("BrainChatStore: schema ready")

    async def _ensure_tagged_with_rel_table(self) -> None:
        """Create the TAGGED_WITH relationship table with multiple source types.

        Kuzu 0.8.0+ supports multiple FROM/TO pairs in a single rel table.
        Falls back to separate per-type tables if multi-source DDL fails.
        """
        source_tables = ["Chat", "Note", "Card", "Brain_Entity", "Agent"]
        try:
            from_clauses = ", ".join(f"FROM {t} TO Tag" for t in source_tables)
            ddl = (
                f"CREATE REL TABLE IF NOT EXISTS TAGGED_WITH "
                f"({from_clauses}, tagged_at STRING, tagged_by STRING)"
            )
            async with self.graph.write_lock:
                await self.graph._execute(ddl)
            logger.debug("BrainChatStore: ensured TAGGED_WITH rel table (multi-source)")
        except Exception as e:
            logger.warning(f"Multi-source TAGGED_WITH failed ({e}), falling back to per-type tables")
            for table in source_tables:
                try:
                    await self.graph.ensure_rel_table(
                        f"{table}_TAGGED_WITH", table, "Tag",
                        {"tagged_at": "STRING", "tagged_by": "STRING"},
                    )
                except Exception as e2:
                    # Brain_Entity may not exist yet — that's fine
                    logger.debug(f"Skipped {table}_TAGGED_WITH: {e2}")

    async def _migrate_tags_to_graph(self) -> None:
        """Migrate tags from JSON arrays to graph edges. Idempotent.

        Reads Chat.tags_json and Note.metadata_json['tags'], creates Tag
        nodes and TAGGED_WITH edges, then clears the JSON fields.
        """
        migrated = 0

        # ── Chat tags_json → TAGGED_WITH edges ───────────────────────────
        try:
            rows = await self.graph.execute_cypher(
                "MATCH (s:Chat) WHERE s.tags_json IS NOT NULL AND s.tags_json <> '' "
                "AND s.tags_json <> '[]' RETURN s.session_id AS sid, s.tags_json AS tj"
            )
            for row in rows:
                sid = row.get("sid", "")
                tags_raw = row.get("tj", "[]")
                try:
                    tags = json.loads(tags_raw)
                except (json.JSONDecodeError, TypeError):
                    continue
                if not isinstance(tags, list) or not tags:
                    continue
                for tag in tags:
                    if not isinstance(tag, str) or not tag.strip():
                        continue
                    tag = tag.lower().strip()
                    try:
                        await self.add_tag("chat", sid, tag, tagged_by="migration")
                        migrated += 1
                    except (ValueError, Exception) as e:
                        logger.debug(f"Tag migration skip {tag!r} on {sid}: {e}")
                # Clear the JSON field after migrating
                async with self.graph.write_lock:
                    await self.graph._execute(
                        "MATCH (s:Chat {session_id: $sid}) SET s.tags_json = '[]'",
                        {"sid": sid},
                    )
        except Exception as e:
            logger.warning(f"Chat tag migration error: {e}")

        # ── Note metadata_json.tags → TAGGED_WITH edges ──────────────────
        try:
            rows = await self.graph.execute_cypher(
                "MATCH (n:Note) WHERE n.metadata_json IS NOT NULL AND n.metadata_json <> '' "
                "RETURN n.entry_id AS eid, n.metadata_json AS mj"
            )
            for row in rows:
                eid = row.get("eid", "")
                mj_raw = row.get("mj", "")
                try:
                    meta = json.loads(mj_raw)
                except (json.JSONDecodeError, TypeError):
                    continue
                if not isinstance(meta, dict):
                    continue
                tags = meta.get("tags")
                if not isinstance(tags, list) or not tags:
                    continue
                for tag in tags:
                    if not isinstance(tag, str) or not tag.strip():
                        continue
                    tag = tag.lower().strip()
                    try:
                        await self.add_tag("note", eid, tag, tagged_by="migration")
                        migrated += 1
                    except (ValueError, Exception) as e:
                        logger.debug(f"Tag migration skip {tag!r} on {eid}: {e}")
                # Remove tags from metadata_json
                del meta["tags"]
                async with self.graph.write_lock:
                    await self.graph._execute(
                        "MATCH (n:Note {entry_id: $eid}) SET n.metadata_json = $mj",
                        {"eid": eid, "mj": json.dumps(meta)},
                    )
        except Exception as e:
            logger.warning(f"Note tag migration error: {e}")

        if migrated:
            logger.info(f"BrainChatStore: migrated {migrated} tag(s) to graph edges")

    async def _ensure_column_migrations(self) -> None:
        """Add columns introduced after initial table creation.

        Idempotent — checks existing columns before ALTERing.  Moved from
        the daily module so migrations run at startup regardless of which
        modules are loaded.
        """
        # ── Note migrations ──
        note_cols = await self.graph.get_table_columns("Note")
        note_new = {
            "title": "STRING",
            "entry_type": "STRING",
            "audio_path": "STRING",
            "note_type": "STRING",
            "aliases": "STRING",
            "status": "STRING",
            "created_by": "STRING",
            "metadata_json": "STRING",
            "brain_links_json": "STRING",
        }
        note_missing = {c: t for c, t in note_new.items() if c not in note_cols}
        if note_missing:
            async with self.graph.write_lock:
                for col, typ in note_missing.items():
                    await self.graph.execute_cypher(
                        f"ALTER TABLE Note ADD {col} {typ} DEFAULT NULL"
                    )
                    logger.info(f"Schema migration: added Note.{col}")

        # ── Agent migrations ──
        try:
            agent_cols = await self.graph.get_table_columns("Agent")
        except Exception as e:
            logger.warning(f"Schema migration: could not inspect Agent columns: {e}")
            agent_cols = {}

        agent_new = {
            "trust_level": ("STRING", "'sandboxed'"),
            "sdk_session_id": ("STRING", "''"),
            "last_run_at": ("STRING", "''"),
            "last_processed_date": ("STRING", "''"),
            "run_count": ("INT64", "0"),
            "trigger_event": ("STRING", "''"),
            "trigger_filter": ("STRING", "'{}'"),
            "memory_mode": ("STRING", "'persistent'"),
            "template_version": ("STRING", "''"),
            "user_modified": ("STRING", "''"),
            "container_slug": ("STRING", "''"),
        }
        agent_missing = {c: v for c, v in agent_new.items() if c not in agent_cols}
        if agent_missing:
            async with self.graph.write_lock:
                for col, (typ, default) in agent_missing.items():
                    await self.graph.execute_cypher(
                        f"ALTER TABLE Agent ADD {col} {typ} DEFAULT {default}"
                    )
                    logger.info(f"Schema migration: added Agent.{col}")

        # ── AgentRun migrations ──
        try:
            run_cols = await self.graph.get_table_columns("AgentRun")
        except Exception as e:
            logger.warning(f"Schema migration: could not inspect AgentRun columns: {e}")
            run_cols = {}

        run_new = {
            "date": ("STRING", "''"),
            "trigger": ("STRING", "''"),
            "error": ("STRING", "''"),
            "container_slug": ("STRING", "''"),
            "card_id": ("STRING", "''"),
            "started_at": ("STRING", "''"),
            "completed_at": ("STRING", "''"),
            "duration_seconds": ("DOUBLE", "0.0"),
            "scope": ("STRING", "'{}'"),
        }
        run_missing = {c: v for c, v in run_new.items() if c not in run_cols}
        if run_missing:
            async with self.graph.write_lock:
                for col, (typ, default) in run_missing.items():
                    await self.graph.execute_cypher(
                        f"ALTER TABLE AgentRun ADD {col} {typ} DEFAULT {default}"
                    )
                    logger.info(f"Schema migration: added AgentRun.{col}")

    # ── Message writes ─────────────────────────────────────────────────────

    async def write_turn_messages(
        self,
        session_id: str,
        human_content: str,
        machine_content: str,
        tools_used: str,
        thinking: str | None,
        status: str,
        message_count: int,
        session_meta: dict[str, Any] | None = None,
    ) -> tuple[str, str]:
        """Write human + machine Message nodes for a completed turn.

        Args:
            session_id: Parachute session ID (grouping key).
            human_content: Full text the user sent.
            machine_content: All text blocks from the AI (mid-stream included).
            tools_used: Tool summary string (from summarize_tool_calls).
            thinking: Concatenated thinking blocks (None for sandboxed).
            status: "complete" | "interrupted" | "error".
            message_count: Session message_count *before* this turn's increment.
            session_meta: If provided, lazy-creates the Chat node on first write.

        Returns:
            Tuple of (human_message_id, machine_message_id).
        """
        now = datetime.now(timezone.utc).isoformat()
        human_seq = message_count + 1
        machine_seq = message_count + 2
        sid_prefix = session_id[:8] if len(session_id) >= 8 else session_id
        human_id = f"{sid_prefix}:msg:{human_seq}"
        machine_id = f"{sid_prefix}:msg:{machine_seq}"

        async with self.graph.write_lock:
            # 1. Lazy-upsert Chat node on first message
            if session_meta:
                await self.graph.execute_cypher(
                    "MERGE (s:Chat {session_id: $session_id}) "
                    "ON CREATE SET s.title = $title, s.module = $module, "
                    "s.source = $source, s.agent_type = $agent_type, "
                    "s.created_at = $created_at",
                    {
                        "session_id": session_id,
                        "title": session_meta.get("title") or "",
                        "module": session_meta.get("module") or "chat",
                        "source": session_meta.get("source") or "parachute",
                        "agent_type": session_meta.get("agent_type") or "",
                        "created_at": session_meta.get("created_at") or now,
                    },
                )

            # 2. Write human Message
            await self.graph.execute_cypher(
                "MERGE (m:Message {message_id: $message_id}) "
                "ON CREATE SET m.created_at = $created_at "
                "SET m.session_id = $session_id, "
                "m.role = $role, m.content = $content, "
                "m.status = $status, m.sequence = $sequence, "
                "m.updated_at = $updated_at",
                {
                    "message_id": human_id,
                    "session_id": session_id,
                    "role": "human",
                    "content": human_content,
                    "status": "complete",
                    "sequence": human_seq,
                    "created_at": now,
                    "updated_at": now,
                },
            )

            # 3. Write machine Message
            await self.graph.execute_cypher(
                "MERGE (m:Message {message_id: $message_id}) "
                "ON CREATE SET m.created_at = $created_at "
                "SET m.session_id = $session_id, "
                "m.role = $role, m.content = $content, "
                "m.status = $status, m.sequence = $sequence, "
                "m.tools_used = $tools_used, m.thinking = $thinking, "
                "m.updated_at = $updated_at",
                {
                    "message_id": machine_id,
                    "session_id": session_id,
                    "role": "machine",
                    "content": machine_content,
                    "status": status,
                    "sequence": machine_seq,
                    "tools_used": tools_used,
                    "thinking": thinking or "",
                    "created_at": now,
                    "updated_at": now,
                },
            )

            # 4. Create HAS_MESSAGE relationships
            for mid in (human_id, machine_id):
                try:
                    await self.graph.execute_cypher(
                        "MATCH (s:Chat {session_id: $sid}), "
                        "(m:Message {message_id: $mid}) "
                        "MERGE (s)-[:HAS_MESSAGE]->(m)",
                        {"sid": session_id, "mid": mid},
                    )
                except Exception as e:
                    logger.debug(f"HAS_MESSAGE edge skipped for {mid}: {e}")

        logger.debug(
            f"Wrote messages {human_id}, {machine_id} "
            f"(status={status}) for session {session_id[:8]}"
        )
        return human_id, machine_id

    async def seed_builtin_agents(self) -> None:
        """Seed or update built-in Agents from AGENT_TEMPLATES.

        Version-aware:
        - New agent → CREATE with template_version, user_modified="false"
        - Pre-versioned (template_version == "") → stamp version, mark modified
        - Modified by user → skip, log "update available"
        - Unmodified + older version → auto-update config fields
        - Already current → skip

        Also cleans up renamed/retired agents.
        """
        now = _now()

        # Rename old agent names → new names (one-time migration)
        renames = {
            "daily-reflection": "process-day",
            "post-process": "process-note",
        }
        for old_name, new_name in renames.items():
            try:
                rows = await self.graph.execute_cypher(
                    "MATCH (a:Agent {name: $name}) "
                    "RETURN a.user_modified AS um",
                    {"name": old_name},
                )
                if rows:
                    um = (rows[0].get("um") or "").strip()
                    if um == "true":
                        logger.info(
                            f"Agent '{old_name}' user-modified — keeping as-is. "
                            f"New template '{new_name}' will be seeded separately."
                        )
                    else:
                        # Not customized — rename the node
                        async with self.graph.write_lock:
                            await self.graph.execute_cypher(
                                "MATCH (a:Agent {name: $old}) SET a.name = $new",
                                {"old": old_name, "new": new_name},
                            )
                        logger.info(f"Renamed agent '{old_name}' → '{new_name}'")
                        # Also update any AgentRun references
                        try:
                            async with self.graph.write_lock:
                                await self.graph.execute_cypher(
                                    "MATCH (r:AgentRun {agent_name: $old}) "
                                    "SET r.agent_name = $new",
                                    {"old": old_name, "new": new_name},
                                )
                        except Exception:
                            pass  # Non-critical
            except Exception as e:
                logger.warning(f"Failed to check rename for '{old_name}': {e}")

        for tpl in AGENT_TEMPLATES:
            name = tpl["name"]
            tpl_version = tpl.get("template_version", "")

            is_triggered = bool(tpl.get("trigger_event", ""))
            seed_data = {
                "name": name,
                "display_name": tpl.get("display_name", name.replace("-", " ").title()),
                "description": tpl.get("description", ""),
                "system_prompt": tpl.get("system_prompt", ""),
                "tools": json.dumps(tpl.get("tools", [])),
                "schedule_enabled": "false" if is_triggered else "true",
                "schedule_time": tpl.get("schedule_time", ""),
                "enabled": "true",
                "trust_level": tpl.get("trust_level", "sandboxed"),
                "trigger_event": tpl.get("trigger_event", ""),
                "trigger_filter": tpl.get("trigger_filter", "{}"),
                "memory_mode": tpl.get("memory_mode", "persistent"),
                "template_version": tpl_version,
                "user_modified": "false",
            }

            rows = await self.graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) "
                "RETURN a.template_version AS tv, a.user_modified AS um",
                {"name": name},
            )

            if not rows:
                try:
                    async with self.graph.write_lock:
                        await self.graph.execute_cypher(
                            "CREATE (a:Agent {"
                            "  name: $name,"
                            "  display_name: $display_name,"
                            "  description: $description,"
                            "  system_prompt: $system_prompt,"
                            "  tools: $tools,"
                            "  schedule_enabled: $schedule_enabled,"
                            "  schedule_time: $schedule_time,"
                            "  enabled: $enabled,"
                            "  trust_level: $trust_level,"
                            "  trigger_event: $trigger_event,"
                            "  trigger_filter: $trigger_filter,"
                            "  memory_mode: $memory_mode,"
                            "  template_version: $template_version,"
                            "  user_modified: $user_modified,"
                            "  created_at: $now,"
                            "  updated_at: $now"
                            "})",
                            {**seed_data, "now": now},
                        )
                    logger.info(f"Seeded built-in Agent '{name}' (v{tpl_version})")
                except Exception as e:
                    logger.warning(f"Failed to seed Agent '{name}': {e}")
                continue

            existing_tv = (rows[0].get("tv") or "").strip()
            existing_um = (rows[0].get("um") or "").strip()

            if not existing_tv:
                try:
                    async with self.graph.write_lock:
                        await self.graph.execute_cypher(
                            "MATCH (a:Agent {name: $name}) "
                            "SET a.template_version = $tv, a.user_modified = 'true'",
                            {"name": name, "tv": tpl_version},
                        )
                    logger.info(
                        f"Stamped pre-versioned Agent '{name}' "
                        f"with v{tpl_version}, marked user_modified=true"
                    )
                except Exception as e:
                    logger.warning(f"Failed to stamp Agent '{name}': {e}")
            elif existing_um == "true":
                if existing_tv < tpl_version:
                    logger.info(
                        f"Update available for '{name}' "
                        f"(v{existing_tv} → v{tpl_version}) but user customized, skipping"
                    )
            elif existing_tv < tpl_version:
                try:
                    async with self.graph.write_lock:
                        await self.graph.execute_cypher(
                            "MATCH (a:Agent {name: $name}) "
                            "SET a.display_name = $display_name,"
                            "    a.description = $description,"
                            "    a.system_prompt = $system_prompt,"
                            "    a.tools = $tools,"
                            "    a.schedule_time = $schedule_time,"
                            "    a.trust_level = $trust_level,"
                            "    a.trigger_event = $trigger_event,"
                            "    a.trigger_filter = $trigger_filter,"
                            "    a.memory_mode = $memory_mode,"
                            "    a.template_version = $template_version,"
                            "    a.updated_at = $now",
                            {**seed_data, "now": now},
                        )
                    logger.info(
                        f"Updated builtin Agent '{name}' "
                        f"from v{existing_tv} to v{tpl_version}"
                    )
                except Exception as e:
                    logger.warning(f"Failed to update Agent '{name}': {e}")

        # Clean up renamed/retired agents
        # Note: daily-reflection and post-process are handled by rename logic above,
        # so only delete them if the rename already happened (node doesn't exist)
        for old_name in ["transcription-cleanup"]:
            try:
                rows = await self.graph.execute_cypher(
                    "MATCH (a:Agent {name: $name}) RETURN a.name",
                    {"name": old_name},
                )
                if rows:
                    async with self.graph.write_lock:
                        await self.graph.execute_cypher(
                            "MATCH (a:Agent {name: $name}) DELETE a",
                            {"name": old_name},
                        )
                    logger.info(f"Removed retired Agent '{old_name}'")
                    try:
                        run_rows = await self.graph.execute_cypher(
                            "MATCH (r:AgentRun {agent_name: $name}) RETURN r.run_id",
                            {"name": old_name},
                        )
                        if run_rows:
                            async with self.graph.write_lock:
                                await self.graph.execute_cypher(
                                    "MATCH (r:AgentRun {agent_name: $name}) DELETE r",
                                    {"name": old_name},
                                )
                            logger.info(
                                f"Removed {len(run_rows)} orphaned AgentRun(s) for '{old_name}'"
                            )
                    except Exception:
                        pass
            except Exception:
                pass

    # ── Tool / Trigger seeding ───────────────────────────────────────────────

    async def seed_builtin_tools(self) -> None:
        """Seed or update built-in Tools from TOOL_TEMPLATES.

        Version-aware (same pattern as seed_builtin_agents):
        - New tool → CREATE with template_version, user_modified="false"
        - Pre-versioned (template_version == "") → stamp version, mark modified
        - Modified by user → skip, log "update available"
        - Unmodified + older version → auto-update config fields
        - Already current → skip

        Also seeds CAN_CALL edges for tools with child tools.
        """
        now = _now()

        for tpl in TOOL_TEMPLATES:
            name = tpl["name"]
            tpl_version = tpl.get("template_version", "")

            seed_data = {
                "name": name,
                "display_name": tpl.get("display_name", name.replace("-", " ").title()),
                "description": tpl.get("description", ""),
                "mode": tpl.get("mode", "function"),
                "scope_keys": json.dumps(tpl.get("scope_keys", [])),
                "input_schema": "",
                "query": tpl.get("query", ""),
                "transform_prompt": tpl.get("transform_prompt", ""),
                "transform_model": tpl.get("transform_model", ""),
                "write_query": tpl.get("write_query", ""),
                "system_prompt": tpl.get("system_prompt", ""),
                "model": tpl.get("model", ""),
                "memory_mode": tpl.get("memory_mode", ""),
                "trust_level": tpl.get("trust_level", ""),
                "container_slug": tpl.get("container_slug", ""),
                "server_name": tpl.get("server_name", ""),
                "builtin": "true",
                "enabled": "true",
                "template_version": tpl_version,
                "user_modified": "false",
            }

            rows = await self.graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) "
                "RETURN t.template_version AS tv, t.user_modified AS um",
                {"name": name},
            )

            if not rows:
                # New tool — create it
                try:
                    async with self.graph.write_lock:
                        await self.graph.execute_cypher(
                            "CREATE (t:Tool {"
                            "  name: $name,"
                            "  display_name: $display_name,"
                            "  description: $description,"
                            "  mode: $mode,"
                            "  scope_keys: $scope_keys,"
                            "  input_schema: $input_schema,"
                            "  query: $query,"
                            "  transform_prompt: $transform_prompt,"
                            "  transform_model: $transform_model,"
                            "  write_query: $write_query,"
                            "  system_prompt: $system_prompt,"
                            "  model: $model,"
                            "  memory_mode: $memory_mode,"
                            "  trust_level: $trust_level,"
                            "  container_slug: $container_slug,"
                            "  server_name: $server_name,"
                            "  builtin: $builtin,"
                            "  enabled: $enabled,"
                            "  template_version: $template_version,"
                            "  user_modified: $user_modified,"
                            "  created_at: $now,"
                            "  updated_at: $now"
                            "})",
                            {**seed_data, "now": now},
                        )
                    logger.info(f"Seeded built-in Tool '{name}' (v{tpl_version})")
                except Exception as e:
                    logger.warning(f"Failed to seed Tool '{name}': {e}")
                    continue
            else:
                existing_tv = (rows[0].get("tv") or "").strip()
                existing_um = (rows[0].get("um") or "").strip()

                if not existing_tv:
                    # Pre-versioned — stamp and mark as user-modified
                    try:
                        async with self.graph.write_lock:
                            await self.graph.execute_cypher(
                                "MATCH (t:Tool {name: $name}) "
                                "SET t.template_version = $tv, t.user_modified = 'true'",
                                {"name": name, "tv": tpl_version},
                            )
                        logger.info(
                            f"Stamped pre-versioned Tool '{name}' "
                            f"with v{tpl_version}, marked user_modified=true"
                        )
                    except Exception as e:
                        logger.warning(f"Failed to stamp Tool '{name}': {e}")
                elif existing_um == "true":
                    if existing_tv < tpl_version:
                        logger.info(
                            f"Update available for Tool '{name}' "
                            f"(v{existing_tv} → v{tpl_version}) but user customized, skipping"
                        )
                elif existing_tv < tpl_version:
                    # Auto-update unmodified tool
                    try:
                        async with self.graph.write_lock:
                            await self.graph.execute_cypher(
                                "MATCH (t:Tool {name: $name}) "
                                "SET t.display_name = $display_name,"
                                "    t.description = $description,"
                                "    t.mode = $mode,"
                                "    t.scope_keys = $scope_keys,"
                                "    t.query = $query,"
                                "    t.transform_prompt = $transform_prompt,"
                                "    t.transform_model = $transform_model,"
                                "    t.write_query = $write_query,"
                                "    t.system_prompt = $system_prompt,"
                                "    t.model = $model,"
                                "    t.memory_mode = $memory_mode,"
                                "    t.trust_level = $trust_level,"
                                "    t.container_slug = $container_slug,"
                                "    t.server_name = $server_name,"
                                "    t.template_version = $template_version,"
                                "    t.updated_at = $now",
                                {**seed_data, "now": now},
                            )
                        logger.info(
                            f"Updated builtin Tool '{name}' "
                            f"from v{existing_tv} to v{tpl_version}"
                        )
                    except Exception as e:
                        logger.warning(f"Failed to update Tool '{name}': {e}")

            # Seed CAN_CALL edges
            can_call = tpl.get("can_call", [])
            if can_call:
                for child_name in can_call:
                    try:
                        async with self.graph.write_lock:
                            # MERGE to avoid duplicates
                            await self.graph.execute_cypher(
                                "MATCH (parent:Tool {name: $parent}), "
                                "(child:Tool {name: $child}) "
                                "MERGE (parent)-[:CAN_CALL]->(child)",
                                {"parent": name, "child": child_name},
                            )
                    except Exception as e:
                        # Child may not exist yet if seeded out of order —
                        # will be created on next pass
                        logger.debug(
                            f"CAN_CALL edge {name} → {child_name} deferred: {e}"
                        )

        # Second pass: create any deferred CAN_CALL edges
        for tpl in TOOL_TEMPLATES:
            name = tpl["name"]
            can_call = tpl.get("can_call", [])
            if not can_call:
                continue
            for child_name in can_call:
                try:
                    async with self.graph.write_lock:
                        await self.graph.execute_cypher(
                            "MATCH (parent:Tool {name: $parent}), "
                            "(child:Tool {name: $child}) "
                            "MERGE (parent)-[:CAN_CALL]->(child)",
                            {"parent": name, "child": child_name},
                        )
                except Exception as e:
                    logger.warning(
                        f"Failed to create CAN_CALL edge {name} → {child_name}: {e}"
                    )

        logger.info(f"Tool seeding complete ({len(TOOL_TEMPLATES)} templates)")

    async def seed_builtin_triggers(self) -> None:
        """Seed or update built-in Triggers from TRIGGER_TEMPLATES.

        Version-aware (same pattern as tools). Also creates INVOKES edges.
        """
        now = _now()

        for tpl in TRIGGER_TEMPLATES:
            name = tpl["name"]
            tpl_version = tpl.get("template_version", "")
            invokes_tool = tpl.get("invokes", "")

            seed_data = {
                "name": name,
                "type": tpl.get("type", "schedule"),
                "schedule_time": tpl.get("schedule_time", ""),
                "event": tpl.get("event", ""),
                "event_filter": tpl.get("event_filter", ""),
                "scope": json.dumps(tpl.get("scope", {})),
                "enabled": tpl.get("enabled", "true"),
                "template_version": tpl_version,
                "user_modified": "false",
            }

            rows = await self.graph.execute_cypher(
                "MATCH (t:Trigger {name: $name}) "
                "RETURN t.template_version AS tv, t.user_modified AS um",
                {"name": name},
            )

            if not rows:
                try:
                    async with self.graph.write_lock:
                        await self.graph.execute_cypher(
                            "CREATE (t:Trigger {"
                            "  name: $name,"
                            "  type: $type,"
                            "  schedule_time: $schedule_time,"
                            "  event: $event,"
                            "  event_filter: $event_filter,"
                            "  scope: $scope,"
                            "  enabled: $enabled,"
                            "  template_version: $template_version,"
                            "  user_modified: $user_modified,"
                            "  created_at: $now,"
                            "  updated_at: $now"
                            "})",
                            {**seed_data, "now": now},
                        )
                    logger.info(f"Seeded built-in Trigger '{name}' (v{tpl_version})")
                except Exception as e:
                    logger.warning(f"Failed to seed Trigger '{name}': {e}")
                    continue
            else:
                existing_tv = (rows[0].get("tv") or "").strip()
                existing_um = (rows[0].get("um") or "").strip()

                if not existing_tv:
                    try:
                        async with self.graph.write_lock:
                            await self.graph.execute_cypher(
                                "MATCH (t:Trigger {name: $name}) "
                                "SET t.template_version = $tv, t.user_modified = 'true'",
                                {"name": name, "tv": tpl_version},
                            )
                        logger.info(
                            f"Stamped pre-versioned Trigger '{name}' "
                            f"with v{tpl_version}, marked user_modified=true"
                        )
                    except Exception as e:
                        logger.warning(f"Failed to stamp Trigger '{name}': {e}")
                elif existing_um == "true":
                    if existing_tv < tpl_version:
                        logger.info(
                            f"Update available for Trigger '{name}' "
                            f"(v{existing_tv} → v{tpl_version}) but user customized, skipping"
                        )
                elif existing_tv < tpl_version:
                    try:
                        async with self.graph.write_lock:
                            await self.graph.execute_cypher(
                                "MATCH (t:Trigger {name: $name}) "
                                "SET t.type = $type,"
                                "    t.schedule_time = $schedule_time,"
                                "    t.event = $event,"
                                "    t.event_filter = $event_filter,"
                                "    t.scope = $scope,"
                                "    t.enabled = $enabled,"
                                "    t.template_version = $template_version,"
                                "    t.updated_at = $now",
                                {**seed_data, "now": now},
                            )
                        logger.info(
                            f"Updated builtin Trigger '{name}' "
                            f"from v{existing_tv} to v{tpl_version}"
                        )
                    except Exception as e:
                        logger.warning(f"Failed to update Trigger '{name}': {e}")

            # Create INVOKES edge
            if invokes_tool:
                try:
                    async with self.graph.write_lock:
                        await self.graph.execute_cypher(
                            "MATCH (trigger:Trigger {name: $trigger}), "
                            "(tool:Tool {name: $tool}) "
                            "MERGE (trigger)-[:INVOKES]->(tool)",
                            {"trigger": name, "tool": invokes_tool},
                        )
                except Exception as e:
                    logger.warning(
                        f"Failed to create INVOKES edge {name} → {invokes_tool}: {e}"
                    )

        logger.info(f"Trigger seeding complete ({len(TRIGGER_TEMPLATES)} templates)")

    # ── Session CRUD ──────────────────────────────────────────────────────────

    async def create_session(
        self, session: Union[Session, SessionCreate]
    ) -> Session:
        """Create a new session."""
        now = _now()

        if isinstance(session, Session):
            created_at = session.created_at.isoformat()
            last_accessed = session.last_accessed.isoformat()
            message_count = session.message_count
            archived = session.archived
        else:
            created_at = now
            last_accessed = now
            message_count = 0
            archived = False

        metadata_json = (
            json.dumps(session.metadata) if session.metadata else None
        )

        params = {
            "session_id": session.id,
            "title": session.title,
            "module": session.module,
            "source": session.source.value if hasattr(session.source, "value") else session.source,
            "working_directory": session.working_directory,
            "model": session.model,
            "message_count": message_count,
            "archived": archived,
            "created_at": created_at,
            "last_accessed": last_accessed,
            "continued_from": getattr(session, "continued_from", None),
            "agent_type": getattr(session, "agent_type", None),
            "trust_level": getattr(session, "trust_level", None),
            "mode": getattr(session, "mode", None),
            "linked_bot_platform": getattr(session, "linked_bot_platform", None),
            "linked_bot_chat_id": getattr(session, "linked_bot_chat_id", None),
            "linked_bot_chat_type": getattr(session, "linked_bot_chat_type", None),
            "parent_session_id": getattr(session, "parent_session_id", None),
            "created_by": getattr(session, "created_by", "user") or "user",
            "summary": getattr(session, "summary", None),
            "bridge_session_id": getattr(session, "bridge_session_id", None),
            "bridge_context_log": getattr(session, "bridge_context_log", None),
            "container_id": getattr(session, "container_id", None),
            "metadata_json": metadata_json,
            "tags_json": "[]",
            "contexts_json": "[]",
        }

        async with self.graph.write_lock:
            await self.graph._execute(
                """
                CREATE (:Chat {
                    session_id: $session_id,
                    title: $title,
                    module: $module,
                    source: $source,
                    working_directory: $working_directory,
                    model: $model,
                    message_count: $message_count,
                    archived: $archived,
                    created_at: $created_at,
                    last_accessed: $last_accessed,
                    continued_from: $continued_from,
                    agent_type: $agent_type,
                    trust_level: $trust_level,
                    mode: $mode,
                    linked_bot_platform: $linked_bot_platform,
                    linked_bot_chat_id: $linked_bot_chat_id,
                    linked_bot_chat_type: $linked_bot_chat_type,
                    parent_session_id: $parent_session_id,
                    created_by: $created_by,
                    summary: $summary,
                    bridge_session_id: $bridge_session_id,
                    bridge_context_log: $bridge_context_log,
                    container_id: $container_id,
                    metadata_json: $metadata_json,
                    tags_json: $tags_json,
                    contexts_json: $contexts_json
                })
                """,
                params,
            )

        result = await self.get_session(session.id)
        if result is None:
            raise RuntimeError(f"Failed to create session {session.id}")
        return result

    async def get_session(self, session_id: str) -> Optional[Session]:
        """Get a session by ID."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat {session_id: $session_id}) RETURN s",
            {"session_id": session_id},
        )
        if rows:
            return self._node_to_session(rows[0])
        return None

    async def update_session(
        self, session_id: str, update: SessionUpdate
    ) -> Optional[Session]:
        """Update a session."""
        set_parts: list[str] = []
        params: dict[str, Any] = {"session_id": session_id}

        if update.title is not None:
            set_parts.append("s.title = $title")
            params["title"] = update.title

        if update.summary is not None:
            set_parts.append("s.summary = $summary")
            params["summary"] = update.summary

        if update.archived is not None:
            set_parts.append("s.archived = $archived")
            params["archived"] = update.archived

        if update.message_count is not None:
            set_parts.append("s.message_count = $message_count")
            params["message_count"] = update.message_count

        if update.model is not None:
            set_parts.append("s.model = $model")
            params["model"] = update.model

        if update.metadata is not None:
            set_parts.append("s.metadata_json = $metadata_json")
            params["metadata_json"] = json.dumps(update.metadata)

        if update.agent_type is not None:
            set_parts.append("s.agent_type = $agent_type")
            params["agent_type"] = update.agent_type

        if update.trust_level is not None:
            set_parts.append("s.trust_level = $trust_level")
            params["trust_level"] = update.trust_level

        if update.mode is not None:
            set_parts.append("s.mode = $mode")
            params["mode"] = update.mode

        if update.working_directory is not None:
            set_parts.append("s.working_directory = $working_directory")
            params["working_directory"] = update.working_directory

        if update.bridge_session_id is not None:
            set_parts.append("s.bridge_session_id = $bridge_session_id")
            params["bridge_session_id"] = update.bridge_session_id

        if update.bridge_context_log is not None:
            set_parts.append("s.bridge_context_log = $bridge_context_log")
            params["bridge_context_log"] = update.bridge_context_log

        if update.container_id is not None:
            set_parts.append("s.container_id = $container_id")
            params["container_id"] = update.container_id

        if not set_parts:
            return await self.get_session(session_id)

        set_parts.append("s.last_accessed = $last_accessed")
        params["last_accessed"] = _now()

        async with self.graph.write_lock:
            await self.graph._execute(
                f"MATCH (s:Chat {{session_id: $session_id}}) "
                f"SET {', '.join(set_parts)}",
                params,
            )

        return await self.get_session(session_id)

    async def delete_session(self, session_id: str) -> bool:
        """Delete a session."""
        existing = await self.get_session(session_id)
        if existing is None:
            return False
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (s:Chat {session_id: $session_id}) DETACH DELETE s",
                {"session_id": session_id},
            )
        return True

    async def list_sessions(
        self,
        module: Optional[str] = None,
        archived: Optional[bool] = None,
        agent_type: Optional[str] = None,
        search: Optional[str] = None,
        trust_level: Optional[str] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[Session]:
        """List sessions with optional filtering."""
        where_parts: list[str] = []
        params: dict[str, Any] = {}

        if module is not None:
            where_parts.append("s.module = $module")
            params["module"] = module

        if archived is not None:
            where_parts.append("s.archived = $archived")
            params["archived"] = archived

        if agent_type is not None:
            where_parts.append("s.agent_type = $agent_type")
            params["agent_type"] = agent_type

        if trust_level is not None:
            where_parts.append("s.trust_level = $trust_level")
            params["trust_level"] = trust_level

        if search is not None:
            where_parts.append("s.title CONTAINS $search")
            params["search"] = search

        limit = max(1, min(int(limit), 10000))
        offset = max(0, int(offset))
        where_clause = f"WHERE {' AND '.join(where_parts)}" if where_parts else ""
        skip_clause = f" SKIP {offset}" if offset > 0 else ""
        query = (
            f"MATCH (s:Chat) {where_clause} "
            f"RETURN s ORDER BY s.last_accessed DESC "
            f"LIMIT {limit}{skip_clause}"
        )

        rows = await self.graph.execute_cypher(query, params or None)
        return [self._node_to_session(r) for r in rows]

    async def archive_session(self, session_id: str) -> Optional[Session]:
        """Archive a session."""
        return await self.update_session(session_id, SessionUpdate(archived=True))

    async def unarchive_session(self, session_id: str) -> Optional[Session]:
        """Unarchive a session."""
        return await self.update_session(session_id, SessionUpdate(archived=False))

    async def touch_session(self, session_id: str) -> None:
        """Update last_accessed timestamp."""
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (s:Chat {session_id: $session_id}) "
                "SET s.last_accessed = $last_accessed",
                {"session_id": session_id, "last_accessed": _now()},
            )

    async def increment_message_count(
        self, session_id: str, increment: int = 1
    ) -> None:
        """Increment message count and touch last_accessed."""
        # Read and write inside the same lock to prevent concurrent-update races
        async with self.graph.write_lock:
            rows = await self.graph.execute_cypher(
                "MATCH (s:Chat {session_id: $session_id}) RETURN s.message_count",
                {"session_id": session_id},
            )
            if not rows:
                return
            current = rows[0].get("s.message_count", 0) or 0
            new_count = current + increment
            await self.graph._execute(
                "MATCH (s:Chat {session_id: $session_id}) "
                "SET s.message_count = $count, s.last_accessed = $last_accessed",
                {
                    "session_id": session_id,
                    "count": new_count,
                    "last_accessed": _now(),
                },
            )

    async def get_session_count(
        self,
        module: Optional[str] = None,
        archived: Optional[bool] = None,
    ) -> int:
        """Get count of sessions."""
        where_parts: list[str] = []
        params: dict[str, Any] = {}

        if module is not None:
            where_parts.append("s.module = $module")
            params["module"] = module

        if archived is not None:
            where_parts.append("s.archived = $archived")
            params["archived"] = archived

        where_clause = f"WHERE {' AND '.join(where_parts)}" if where_parts else ""
        rows = await self.graph.execute_cypher(
            f"MATCH (s:Chat) {where_clause} RETURN count(s) AS cnt",
            params or None,
        )
        return rows[0]["cnt"] if rows else 0

    async def patch_session_timestamps(
        self,
        session_id: str,
        created_at: Optional[str] = None,
        last_accessed: Optional[str] = None,
        message_count: Optional[int] = None,
    ) -> None:
        """Update session timestamp fields directly (for import/sync operations)."""
        set_parts: list[str] = []
        params: dict[str, Any] = {"session_id": session_id}
        if created_at is not None:
            set_parts.append("s.created_at = $created_at")
            params["created_at"] = created_at
        if last_accessed is not None:
            set_parts.append("s.last_accessed = $last_accessed")
            params["last_accessed"] = last_accessed
        if message_count is not None:
            set_parts.append("s.message_count = $message_count")
            params["message_count"] = message_count
        if set_parts:
            async with self.graph.write_lock:
                await self.graph._execute(
                    f"MATCH (s:Chat {{session_id: $session_id}}) "
                    f"SET {', '.join(set_parts)}",
                    params,
                )

    async def update_session_config(self, session_id: str, **kwargs: Any) -> None:
        """Update session config fields (trust_level, module, etc.)."""
        set_parts: list[str] = []
        params: dict[str, Any] = {"session_id": session_id}
        for key, value in kwargs.items():
            if key in ("trust_level", "module"):
                safe_key = f"cfg_{key}"
                set_parts.append(f"s.{key} = ${safe_key}")
                params[safe_key] = value
        if set_parts:
            set_parts.append("s.last_accessed = $last_accessed")
            params["last_accessed"] = _now()
            async with self.graph.write_lock:
                await self.graph._execute(
                    f"MATCH (s:Chat {{session_id: $session_id}}) "
                    f"SET {', '.join(set_parts)}",
                    params,
                )

    # ── Tags (graph-native) ─────────────────────────────────────────────────

    _TAG_VALIDATE_RE = re.compile(r"[a-z0-9](?:[a-z0-9\-]{0,46}[a-z0-9])?")
    _VALID_TAGGED_BY = {"user", "agent", "migration", "api"}

    def _resolve_entity(self, entity_type: str) -> tuple[str, str]:
        """Return (table_name, pk_column) for an entity_type string."""
        entry = self.TAG_ENTITY_TYPES.get(entity_type)
        if not entry:
            raise ValueError(f"Unknown entity type: {entity_type}")
        return entry

    async def add_tag(
        self,
        entity_type: str,
        entity_id: str,
        tag: str,
        tagged_by: str = "user",
    ) -> None:
        """Add a tag to any entity via a TAGGED_WITH graph edge."""
        tag = tag.lower().strip()
        if not tag or not self._TAG_VALIDATE_RE.fullmatch(tag):
            raise ValueError(f"Invalid tag: {tag!r}")
        if tagged_by not in self._VALID_TAGGED_BY:
            raise ValueError(f"Invalid tagged_by: {tagged_by!r}. Valid: {self._VALID_TAGGED_BY}")
        table, pk_col = self._resolve_entity(entity_type)
        now = _now()

        async with self.graph.write_lock:
            # Ensure Tag node exists
            await self.graph._execute(
                "MERGE (t:Tag {name: $tag}) "
                "ON CREATE SET t.created_at = $now, t.description = ''",
                {"tag": tag, "now": now},
            )
            # Check if edge already exists (execute_cypher returns list[dict])
            existing = await self.graph.execute_cypher(
                f"MATCH (e:{table} {{{pk_col}: $eid}})-[:TAGGED_WITH]->(t:Tag {{name: $tag}}) "
                "RETURN t.name",
                {"eid": entity_id, "tag": tag},
            )
            if not existing:
                await self.graph._execute(
                    f"MATCH (e:{table} {{{pk_col}: $eid}}), (t:Tag {{name: $tag}}) "
                    "CREATE (e)-[:TAGGED_WITH {tagged_at: $now, tagged_by: $by}]->(t)",
                    {"eid": entity_id, "tag": tag, "now": now, "by": tagged_by},
                )

    async def remove_tag(
        self, entity_type: str, entity_id: str, tag: str
    ) -> None:
        """Remove a tag edge from an entity. Cleans up orphan Tag nodes."""
        tag = tag.lower().strip()
        table, pk_col = self._resolve_entity(entity_type)

        async with self.graph.write_lock:
            await self.graph._execute(
                f"MATCH (e:{table} {{{pk_col}: $eid}})-[r:TAGGED_WITH]->(t:Tag {{name: $tag}}) "
                "DELETE r",
                {"eid": entity_id, "tag": tag},
            )
        # Clean up orphan tag (no remaining edges)
        await self._delete_orphan_tag(tag)

    async def get_entity_tags(
        self, entity_type: str, entity_id: str
    ) -> list[str]:
        """Get all tags for an entity, sorted alphabetically."""
        table, pk_col = self._resolve_entity(entity_type)
        rows = await self.graph.execute_cypher(
            f"MATCH (e:{table} {{{pk_col}: $eid}})-[:TAGGED_WITH]->(t:Tag) "
            "RETURN t.name AS name ORDER BY t.name",
            {"eid": entity_id},
        )
        return [r["name"] for r in rows]

    async def get_entities_by_tag(
        self,
        tag: str,
        entity_type: str | None = None,
        limit: int = 100,
    ) -> list[dict]:
        """Get all entities with a given tag. Optionally filter by type."""
        tag = tag.lower().strip()
        if entity_type:
            table, pk_col = self._resolve_entity(entity_type)
            rows = await self.graph.execute_cypher(
                f"MATCH (e:{table})-[r:TAGGED_WITH]->(t:Tag {{name: $tag}}) "
                f"RETURN e, r.tagged_at AS tagged_at LIMIT $limit",
                {"tag": tag, "limit": limit},
            )
            return [
                {**r, "entity_type": entity_type}
                for r in rows
            ]
        # Cross-entity: query each type and merge
        results: list[dict] = []
        for etype, (table, pk_col) in self.TAG_ENTITY_TYPES.items():
            try:
                rows = await self.graph.execute_cypher(
                    f"MATCH (e:{table})-[r:TAGGED_WITH]->(t:Tag {{name: $tag}}) "
                    f"RETURN e, r.tagged_at AS tagged_at",
                    {"tag": tag},
                )
                for r in rows:
                    results.append({**r, "entity_type": etype})
            except Exception:
                # Table may not exist yet (e.g. Brain_Entity)
                continue
            if len(results) >= limit:
                break
        return results[:limit]

    async def list_all_tags(self) -> list[dict]:
        """List all tags with usage counts, sorted by frequency."""
        rows = await self.graph.execute_cypher(
            "MATCH (t:Tag)<-[r:TAGGED_WITH]-() "
            "RETURN t.name AS name, t.description AS description, COUNT(r) AS count "
            "ORDER BY count DESC, name ASC"
        )
        return [{"tag": r["name"], "description": r.get("description", ""), "count": r["count"]} for r in rows]

    async def _delete_orphan_tag(self, tag: str) -> None:
        """Delete a Tag node if it has no remaining TAGGED_WITH edges."""
        async with self.graph.write_lock:
            rows = await self.graph.execute_cypher(
                "MATCH (t:Tag {name: $tag})<-[:TAGGED_WITH]-() RETURN COUNT(*) AS cnt",
                {"tag": tag},
            )
            if rows and rows[0].get("cnt", 0) == 0:
                await self.graph._execute(
                    "MATCH (t:Tag {name: $tag}) DETACH DELETE t",
                    {"tag": tag},
                )

    # ── Backward-compatible session tag helpers ──────────────────────────────
    # These wrap the generic tag methods for the existing Chat-specific API.

    async def add_session_tag(self, session_id: str, tag: str) -> None:
        """Add a tag to a chat session (backward compat)."""
        await self.add_tag("chat", session_id, tag)

    async def remove_session_tag(self, session_id: str, tag: str) -> None:
        """Remove a tag from a chat session (backward compat)."""
        await self.remove_tag("chat", session_id, tag)

    async def get_session_tags(self, session_id: str) -> list[str]:
        """Get tags for a chat session (backward compat)."""
        return await self.get_entity_tags("chat", session_id)

    async def get_sessions_by_tag(
        self, tag: str, limit: int = 100
    ) -> list[Session]:
        """Get sessions with a specific tag (backward compat)."""
        tag = tag.lower().strip()
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat)-[:TAGGED_WITH]->(t:Tag {name: $tag}) "
            "RETURN s ORDER BY s.last_accessed DESC LIMIT $limit",
            {"tag": tag, "limit": limit},
        )
        return [self._node_to_session(r) for r in rows]

    # ── Session Context Folders ───────────────────────────────────────────────

    async def set_session_contexts(
        self, session_id: str, folder_paths: list[str]
    ) -> None:
        """Set context folders for a session (replaces existing)."""
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (s:Chat {session_id: $session_id}) "
                "SET s.contexts_json = $contexts_json",
                {
                    "session_id": session_id,
                    "contexts_json": json.dumps(folder_paths),
                },
            )

    async def add_session_context(
        self, session_id: str, folder_path: str
    ) -> None:
        """Add a context folder to a session."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat {session_id: $session_id}) RETURN s.contexts_json",
            {"session_id": session_id},
        )
        if not rows:
            return
        contexts: list[str] = json.loads(rows[0].get("s.contexts_json") or "[]")
        if folder_path not in contexts:
            contexts.append(folder_path)
            async with self.graph.write_lock:
                await self.graph._execute(
                    "MATCH (s:Chat {session_id: $session_id}) "
                    "SET s.contexts_json = $contexts_json",
                    {
                        "session_id": session_id,
                        "contexts_json": json.dumps(contexts),
                    },
                )

    async def remove_session_context(
        self, session_id: str, folder_path: str
    ) -> None:
        """Remove a context folder from a session."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat {session_id: $session_id}) RETURN s.contexts_json",
            {"session_id": session_id},
        )
        if not rows:
            return
        contexts: list[str] = json.loads(rows[0].get("s.contexts_json") or "[]")
        contexts = [c for c in contexts if c != folder_path]
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (s:Chat {session_id: $session_id}) "
                "SET s.contexts_json = $contexts_json",
                {
                    "session_id": session_id,
                    "contexts_json": json.dumps(contexts),
                },
            )

    async def get_session_contexts(self, session_id: str) -> list[str]:
        """Get all context folder paths for a session."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat {session_id: $session_id}) RETURN s.contexts_json",
            {"session_id": session_id},
        )
        if not rows:
            return []
        return sorted(json.loads(rows[0].get("s.contexts_json") or "[]"))

    async def get_sessions_by_context(
        self, folder_path: str, limit: int = 100
    ) -> list[Session]:
        """Get all sessions using a specific context folder."""
        all_sessions = await self.graph.execute_cypher(
            "MATCH (s:Chat) RETURN s ORDER BY s.last_accessed DESC"
        )
        result = []
        for row in all_sessions:
            contexts = json.loads(row.get("contexts_json") or "[]")
            if folder_path in contexts:
                result.append(self._node_to_session(row))
                if len(result) >= limit:
                    break
        return result

    async def get_session_by_bot_link(
        self, platform: str, chat_id: str
    ) -> Optional[Session]:
        """Get the most recent active session linked to a bot chat."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat) "
            "WHERE s.linked_bot_platform = $platform "
            "  AND s.linked_bot_chat_id = $chat_id "
            "  AND s.archived = false "
            "RETURN s ORDER BY s.last_accessed DESC LIMIT 1",
            {"platform": platform, "chat_id": chat_id},
        )
        if rows:
            return self._node_to_session(rows[0])
        return None

    # ── Multi-Agent Helpers ───────────────────────────────────────────────────

    async def count_children(self, parent_session_id: str) -> int:
        """Count active (non-archived) child sessions."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat) "
            "WHERE s.parent_session_id = $parent_session_id AND s.archived = false "
            "RETURN count(s) AS cnt",
            {"parent_session_id": parent_session_id},
        )
        return rows[0]["cnt"] if rows else 0

    async def get_last_child_created(
        self, parent_session_id: str
    ) -> Optional[datetime]:
        """Get timestamp of most recent child session."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat) "
            "WHERE s.parent_session_id = $parent_session_id "
            "RETURN s.created_at ORDER BY s.created_at DESC LIMIT 1",
            {"parent_session_id": parent_session_id},
        )
        if rows:
            val = rows[0].get("s.created_at")
            if val:
                return datetime.fromisoformat(val)
        return None

    # ── Pairing Requests ──────────────────────────────────────────────────────

    async def create_pairing_request(
        self,
        id: str,
        platform: str,
        platform_user_id: str,
        platform_chat_id: str,
        platform_user_display: Optional[str] = None,
        created_at: Optional[str] = None,
    ) -> PairingRequest:
        """Create a new pairing request from an unknown bot user."""
        now = created_at or _now()
        async with self.graph.write_lock:
            await self.graph._execute(
                """
                MERGE (r:Parachute_PairingRequest {request_id: $request_id})
                SET r.platform = $platform,
                    r.platform_user_id = $platform_user_id,
                    r.platform_user_display = $platform_user_display,
                    r.platform_chat_id = $platform_chat_id,
                    r.status = 'pending',
                    r.created_at = $created_at,
                    r.approved_trust_level = null,
                    r.resolved_at = null,
                    r.resolved_by = null
                """,
                {
                    "request_id": id,
                    "platform": platform,
                    "platform_user_id": platform_user_id,
                    "platform_user_display": platform_user_display,
                    "platform_chat_id": platform_chat_id,
                    "created_at": now,
                },
            )
        return PairingRequest(
            id=id,
            platform=platform,
            platform_user_id=platform_user_id,
            platform_user_display=platform_user_display,
            platform_chat_id=platform_chat_id,
            status="pending",
            created_at=datetime.fromisoformat(now),
        )

    async def get_pending_pairing_requests(self) -> list[PairingRequest]:
        """Get all pending pairing requests."""
        rows = await self.graph.execute_cypher(
            "MATCH (r:Parachute_PairingRequest) "
            "WHERE r.status = 'pending' "
            "RETURN r ORDER BY r.created_at DESC"
        )
        return [self._node_to_pairing_request(r) for r in rows]

    async def get_pending_pairing_count(self) -> int:
        """Get count of pending pairing requests."""
        rows = await self.graph.execute_cypher(
            "MATCH (r:Parachute_PairingRequest) WHERE r.status = 'pending' RETURN count(r) AS cnt"
        )
        return rows[0]["cnt"] if rows else 0

    async def get_pairing_request(
        self, request_id: str
    ) -> Optional[PairingRequest]:
        """Get a pairing request by ID."""
        rows = await self.graph.execute_cypher(
            "MATCH (r:Parachute_PairingRequest {request_id: $request_id}) RETURN r",
            {"request_id": request_id},
        )
        if rows:
            return self._node_to_pairing_request(rows[0])
        return None

    async def get_pairing_request_for_user(
        self, platform: str, user_id: str
    ) -> Optional[PairingRequest]:
        """Get the most recent pairing request for a platform user."""
        rows = await self.graph.execute_cypher(
            "MATCH (r:Parachute_PairingRequest) "
            "WHERE r.platform = $platform AND r.platform_user_id = $user_id "
            "RETURN r ORDER BY r.created_at DESC LIMIT 1",
            {"platform": platform, "user_id": user_id},
        )
        if rows:
            return self._node_to_pairing_request(rows[0])
        return None

    async def resolve_pairing_request(
        self,
        request_id: str,
        approved: bool,
        trust_level: Optional[str] = None,
        resolved_by: Optional[str] = "owner",
    ) -> Optional[PairingRequest]:
        """Resolve a pairing request (approve or deny)."""
        now = _now()
        status = "approved" if approved else "denied"
        approved_trust_level = trust_level if approved else None
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (r:Parachute_PairingRequest {request_id: $request_id}) "
                "SET r.status = $status, "
                "    r.approved_trust_level = $approved_trust_level, "
                "    r.resolved_at = $resolved_at, "
                "    r.resolved_by = $resolved_by",
                {
                    "request_id": request_id,
                    "status": status,
                    "approved_trust_level": approved_trust_level,
                    "resolved_at": now,
                    "resolved_by": resolved_by,
                },
            )
        return await self.get_pairing_request(request_id)

    async def get_expired_pairing_requests(
        self, ttl_days: int = 7
    ) -> list[PairingRequest]:
        """Return pending requests older than ttl_days."""
        cutoff = (datetime.now(timezone.utc) - timedelta(days=ttl_days)).isoformat()
        rows = await self.graph.execute_cypher(
            "MATCH (r:Parachute_PairingRequest) "
            "WHERE r.status = 'pending' AND r.created_at < $cutoff "
            "RETURN r ORDER BY r.created_at ASC",
            {"cutoff": cutoff},
        )
        return [self._node_to_pairing_request(r) for r in rows]

    async def expire_pairing_request(self, request_id: str) -> None:
        """Mark a pending pairing request as expired."""
        now = _now()
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (r:Parachute_PairingRequest {request_id: $request_id}) "
                "WHERE r.status = 'pending' "
                "SET r.status = 'expired', r.resolved_at = $resolved_at",
                {"request_id": request_id, "resolved_at": now},
            )

    # ── Containers ─────────────────────────────────────────────────────────────

    async def create_container(
        self, slug: str, display_name: str, core_memory: Optional[str] = None,
        is_workspace: bool = False,
    ) -> Container:
        """Create a container environment."""
        now = _now()
        async with self.graph.write_lock:
            await self.graph._execute(
                "CREATE (:Container {slug: $slug, display_name: $display_name, "
                "core_memory: $core_memory, is_workspace: $is_workspace, created_at: $created_at})",
                {
                    "slug": slug, "display_name": display_name,
                    "core_memory": core_memory, "is_workspace": is_workspace,
                    "created_at": now,
                },
            )
        return Container(
            slug=slug,
            display_name=display_name,
            core_memory=core_memory,
            is_workspace=is_workspace,
            created_at=datetime.fromisoformat(now),
        )

    async def get_container(self, slug: str) -> Optional[Container]:
        """Get a container environment by slug."""
        rows = await self.graph.execute_cypher(
            "MATCH (c:Container {slug: $slug}) RETURN c",
            {"slug": slug},
        )
        if rows:
            return self._node_to_container(rows[0])
        return None

    async def list_containers(
        self, workspace_only: bool = False,
    ) -> list[Container]:
        """List container environments, optionally filtering to workspaces only."""
        if workspace_only:
            rows = await self.graph.execute_cypher(
                "MATCH (c:Container) WHERE c.is_workspace = true "
                "RETURN c ORDER BY c.created_at DESC"
            )
        else:
            rows = await self.graph.execute_cypher(
                "MATCH (c:Container) RETURN c ORDER BY c.created_at DESC"
            )
        return [self._node_to_container(r) for r in rows]

    async def update_container(
        self, slug: str, display_name: Optional[str] = None,
        core_memory: Optional[str] = None, is_workspace: Optional[bool] = None,
    ) -> Optional[Container]:
        """Update a container's display name, core memory, or workspace flag."""
        set_parts: list[str] = []
        params: dict[str, Any] = {"slug": slug}
        if display_name is not None:
            set_parts.append("c.display_name = $display_name")
            params["display_name"] = display_name
        if is_workspace is not None:
            set_parts.append("c.is_workspace = $is_workspace")
            params["is_workspace"] = is_workspace
        if core_memory is not None:
            set_parts.append("c.core_memory = $core_memory")
            params["core_memory"] = core_memory
        if not set_parts:
            return await self.get_container(slug)
        async with self.graph.write_lock:
            await self.graph._execute(
                f"MATCH (c:Container {{slug: $slug}}) SET {', '.join(set_parts)}",
                params,
            )
        return await self.get_container(slug)

    async def delete_container(self, slug: str) -> bool:
        """Delete a container, nullifying sessions that reference it."""
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (s:Chat {container_id: $slug}) "
                "SET s.container_id = null",
                {"slug": slug},
            )
            result = await self.graph.execute_cypher(
                "MATCH (c:Container {slug: $slug}) RETURN count(c) AS cnt",
                {"slug": slug},
            )
            count = result[0]["cnt"] if result else 0
            if count == 0:
                return False
            await self.graph._execute(
                "MATCH (c:Container {slug: $slug}) DETACH DELETE c",
                {"slug": slug},
            )
        return True

    async def delete_container_if_unreferenced(self, slug: str) -> bool:
        """Delete a container only if no sessions reference it."""
        async with self.graph.write_lock:
            sessions = await self.graph.execute_cypher(
                "MATCH (s:Chat {container_id: $slug}) RETURN count(s) AS cnt",
                {"slug": slug},
            )
            if sessions and sessions[0]["cnt"] > 0:
                return False
            env = await self.graph.execute_cypher(
                "MATCH (c:Container {slug: $slug}) RETURN count(c) AS cnt",
                {"slug": slug},
            )
            if not env or env[0]["cnt"] == 0:
                return False
            await self.graph._execute(
                "MATCH (c:Container {slug: $slug}) DETACH DELETE c",
                {"slug": slug},
            )
        return True

    async def list_orphan_container_slugs(
        self, min_age_minutes: int = 5
    ) -> list[str]:
        """Return slugs of containers safe to prune."""
        cutoff = (
            datetime.now(timezone.utc) - timedelta(minutes=min_age_minutes)
        ).isoformat()

        # Only consider non-workspace containers for pruning.
        # Named workspaces are durable — never auto-pruned.
        # IS NULL covers pre-migration rows where the column didn't exist yet.
        all_envs = await self.graph.execute_cypher(
            "MATCH (c:Container) WHERE c.created_at < $cutoff "
            "AND (c.is_workspace = false OR c.is_workspace IS NULL) RETURN c.slug",
            {"cutoff": cutoff},
        )

        orphans = []
        for row in all_envs:
            slug = row.get("c.slug")
            if not slug:
                continue
            sessions = await self.graph.execute_cypher(
                "MATCH (s:Chat {container_id: $slug}) "
                "WHERE s.message_count > 0 "
                "RETURN count(s) AS cnt",
                {"slug": slug},
            )
            if sessions and sessions[0]["cnt"] > 0:
                continue
            orphans.append(slug)
        return orphans

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _node_to_session(self, row: dict[str, Any]) -> Session:
        """Convert a Kuzu node dict to a Session model."""
        metadata = None
        raw_metadata = row.get("metadata_json")
        if raw_metadata:
            try:
                metadata = json.loads(raw_metadata)
            except (json.JSONDecodeError, TypeError):
                pass

        source_str = row.get("source", "parachute")
        try:
            source = SessionSource(source_str)
        except ValueError:
            source = SessionSource.PARACHUTE

        created_at_str = row.get("created_at") or _now()
        last_accessed_str = row.get("last_accessed") or created_at_str

        return Session(
            id=row["session_id"],
            title=row.get("title"),
            module=row.get("module", "chat"),
            source=source,
            working_directory=row.get("working_directory"),
            vault_root=None,
            model=row.get("model"),
            message_count=row.get("message_count", 0) or 0,
            archived=bool(row.get("archived", False)),
            created_at=datetime.fromisoformat(created_at_str),
            last_accessed=datetime.fromisoformat(last_accessed_str),
            continued_from=row.get("continued_from"),
            agent_type=row.get("agent_type"),
            trust_level=row.get("trust_level"),
            mode=row.get("mode"),
            linked_bot_platform=row.get("linked_bot_platform"),
            linked_bot_chat_id=row.get("linked_bot_chat_id"),
            linked_bot_chat_type=row.get("linked_bot_chat_type"),
            parent_session_id=row.get("parent_session_id"),
            created_by=row.get("created_by") or "user",
            summary=row.get("summary"),
            bridge_session_id=row.get("bridge_session_id"),
            bridge_context_log=row.get("bridge_context_log"),
            container_id=row.get("container_id"),
            metadata=metadata,
        )

    def _node_to_pairing_request(self, row: dict[str, Any]) -> PairingRequest:
        """Convert a Kuzu node dict to a PairingRequest model."""
        resolved_at = row.get("resolved_at")
        return PairingRequest(
            id=row["request_id"],
            platform=row["platform"],
            platform_user_id=row["platform_user_id"],
            platform_user_display=row.get("platform_user_display"),
            platform_chat_id=row["platform_chat_id"],
            status=row.get("status", "pending"),
            approved_trust_level=row.get("approved_trust_level"),
            created_at=datetime.fromisoformat(row["created_at"]),
            resolved_at=datetime.fromisoformat(resolved_at) if resolved_at else None,
            resolved_by=row.get("resolved_by"),
        )

    def _node_to_container(self, row: dict[str, Any]) -> Container:
        """Convert a Kuzu node dict to a Container model."""
        grants_json = row.get("credential_grants_json")
        grants = []
        if grants_json:
            try:
                grants = json.loads(grants_json)
            except (json.JSONDecodeError, TypeError):
                pass

        return Container(
            slug=row["slug"],
            display_name=row["display_name"],
            core_memory=row.get("core_memory"),
            is_workspace=bool(row.get("is_workspace", False)),
            credential_grants=grants,
            created_at=datetime.fromisoformat(row["created_at"]),
        )
