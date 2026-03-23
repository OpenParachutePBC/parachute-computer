"""
BrainChatStore — Kuzu-backed chat metadata store.

Replaces database.py (SQLite/aiosqlite). All chat metadata is stored in
the shared Kuzu graph database alongside Brain, Chat, and Daily data.

Schema:
  - Chat: core session metadata
  - Container: container environments
  - Parachute_PairingRequest: bot pairing requests
  - Parachute_KV: key-value metadata store

Tags and context folders are stored as JSON arrays on the session node
(simpler than separate rel tables for a personal-scale tool).
"""

import json
import logging
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


AGENT_TEMPLATES: list[AgentTemplateDict] = [
    {
        "name": "process-day",
        "template_version": "2026-03-23",
        "display_name": "Daily Reflection",
        "description": "Reviews your journal entries and offers a thoughtful daily reflection",
        "system_prompt": (
            "You are a thoughtful, perceptive reflection partner for {user_name}.\n\n"
            "## Your Role\n\n"
            "Read yesterday's journal entries and recent journals to understand what's on "
            "their mind. Then write a short, meaningful reflection — something that "
            "helps them see their day clearly.\n\n"
            "## Guidelines\n\n"
            "- **Be genuine, not performative.** No empty affirmations. Reflect what "
            "you actually notice.\n"
            "- **Make connections.** Link yesterday's entries to patterns from recent days "
            "when relevant.\n"
            "- **Keep it concise.** 3-5 paragraphs. Quality over quantity.\n"
            "- **Match their energy.** If the day was hard, acknowledge it honestly. "
            "If it was good, celebrate without overdoing it.\n"
            "- **One insight, well-developed** is better than five shallow observations.\n"
            "- Write in second person (\"you\") — this is for them.\n\n"
            "## Process\n\n"
            "1. Read yesterday's journal entries with `read_days_notes`\n"
            "2. Read recent journals with `read_recent_journals` for broader context\n"
            "3. Optionally read chat logs with `read_days_chats` for additional context\n"
            "4. Write your reflection using `write_card`\n\n"
            "## User Context\n\n"
            "{user_context}"
        ),
        "tools": ["read_days_notes", "read_days_chats", "read_recent_journals"],
        "schedule_time": "4:00",
        "trust_level": "sandboxed",
        "memory_mode": "persistent",
    },
    {
        "name": "process-note",
        "template_version": "2026-03-23",
        "display_name": "Process Note",
        "description": (
            "Runs after voice transcription completes. Cleans up filler "
            "words, fixes grammar, adds punctuation."
        ),
        "system_prompt": PROCESS_NOTE_SYSTEM_PROMPT,
        "tools": ["read_this_note", "update_this_note"],
        "trigger_event": "note.transcription_complete",
        "trust_level": "direct",
        "memory_mode": "fresh",
    },
]


class BrainChatStore:
    """
    Kuzu-backed chat metadata store.

    Drop-in replacement for Database (SQLite/aiosqlite). Uses BrainService for
    all Kuzu access. The BrainService write_lock serializes writes.
    """

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
                "display_name": "STRING",
                "content": "STRING",
                "generated_at": "STRING",
                "status": "STRING",
                "date": "STRING",
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

        # ── Column migrations ────────────────────────────────────────────────
        await self._ensure_column_migrations()

        logger.info("BrainChatStore: schema ready")

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

    # ── Session Tags ──────────────────────────────────────────────────────────

    async def add_tag(self, session_id: str, tag: str) -> None:
        """Add a tag to a session."""
        tag = tag.lower().strip()
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat {session_id: $session_id}) RETURN s.tags_json",
            {"session_id": session_id},
        )
        if not rows:
            return
        tags: list[str] = json.loads(rows[0].get("s.tags_json") or "[]")
        if tag not in tags:
            tags.append(tag)
            async with self.graph.write_lock:
                await self.graph._execute(
                    "MATCH (s:Chat {session_id: $session_id}) "
                    "SET s.tags_json = $tags_json",
                    {"session_id": session_id, "tags_json": json.dumps(tags)},
                )

    async def remove_tag(self, session_id: str, tag: str) -> None:
        """Remove a tag from a session."""
        tag = tag.lower().strip()
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat {session_id: $session_id}) RETURN s.tags_json",
            {"session_id": session_id},
        )
        if not rows:
            return
        tags: list[str] = json.loads(rows[0].get("s.tags_json") or "[]")
        tags = [t for t in tags if t != tag]
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (s:Chat {session_id: $session_id}) "
                "SET s.tags_json = $tags_json",
                {"session_id": session_id, "tags_json": json.dumps(tags)},
            )

    async def get_session_tags(self, session_id: str) -> list[str]:
        """Get all tags for a session."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Chat {session_id: $session_id}) RETURN s.tags_json",
            {"session_id": session_id},
        )
        if not rows:
            return []
        return sorted(json.loads(rows[0].get("s.tags_json") or "[]"))

    async def get_sessions_by_tag(
        self, tag: str, limit: int = 100
    ) -> list[Session]:
        """Get all sessions with a specific tag."""
        tag = tag.lower().strip()
        all_sessions = await self.graph.execute_cypher(
            "MATCH (s:Chat) RETURN s ORDER BY s.last_accessed DESC"
        )
        result = []
        for row in all_sessions:
            tags = json.loads(row.get("tags_json") or "[]")
            if tag in tags:
                result.append(self._node_to_session(row))
                if len(result) >= limit:
                    break
        return result

    async def list_all_tags(self) -> list[tuple[str, int]]:
        """List all tags with their usage counts."""
        all_sessions = await self.graph.execute_cypher(
            "MATCH (s:Chat) RETURN s.tags_json"
        )
        counts: dict[str, int] = {}
        for row in all_sessions:
            tags = json.loads(row.get("s.tags_json") or "[]")
            for tag in tags:
                counts[tag] = counts.get(tag, 0) + 1
        return sorted(counts.items(), key=lambda x: (-x[1], x[0]))

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
