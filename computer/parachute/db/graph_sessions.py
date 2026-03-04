"""
GraphSessionStore — Kuzu-backed session metadata store.

Replaces database.py (SQLite/aiosqlite). All session metadata is stored in
the shared Kuzu graph database alongside Brain, Chat, and Daily data.

Schema:
  - Parachute_Session: core session metadata
  - Parachute_ContainerEnv: named container environments
  - Parachute_PairingRequest: bot pairing requests
  - Parachute_KV: key-value metadata store

Tags and context folders are stored as JSON arrays on the session node
(simpler than separate rel tables for a personal-scale tool).
"""

import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Optional, Union

from parachute.db.graph import GraphService
from parachute.models.session import (
    ContainerEnv,
    PairingRequest,
    Session,
    SessionCreate,
    SessionSource,
    SessionUpdate,
)

logger = logging.getLogger(__name__)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()



class GraphSessionStore:
    """
    Kuzu-backed session metadata store.

    Drop-in replacement for Database (SQLite/aiosqlite). Uses GraphService for
    all Kuzu access. The GraphService write_lock serializes writes.
    """

    def __init__(self, graph: GraphService):
        self.graph = graph

    # ── Schema ────────────────────────────────────────────────────────────────

    async def ensure_schema(self) -> None:
        """Create node tables if they don't exist. Idempotent."""
        await self.graph.ensure_node_table(
            "Parachute_Session",
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
                "linked_bot_platform": "STRING",
                "linked_bot_chat_id": "STRING",
                "linked_bot_chat_type": "STRING",
                "parent_session_id": "STRING",
                "created_by": "STRING",
                "summary": "STRING",
                "bridge_session_id": "STRING",
                "bridge_context_log": "STRING",
                "container_env_id": "STRING",
                "metadata_json": "STRING",
                "tags_json": "STRING",
                "contexts_json": "STRING",
            },
            primary_key="session_id",
        )
        await self.graph.ensure_node_table(
            "Parachute_ContainerEnv",
            {
                "slug": "STRING",
                "display_name": "STRING",
                "created_at": "STRING",
            },
            primary_key="slug",
        )
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
        logger.info("GraphSessionStore: schema ready")

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
            "linked_bot_platform": getattr(session, "linked_bot_platform", None),
            "linked_bot_chat_id": getattr(session, "linked_bot_chat_id", None),
            "linked_bot_chat_type": getattr(session, "linked_bot_chat_type", None),
            "parent_session_id": getattr(session, "parent_session_id", None),
            "created_by": getattr(session, "created_by", "user") or "user",
            "summary": getattr(session, "summary", None),
            "bridge_session_id": getattr(session, "bridge_session_id", None),
            "bridge_context_log": getattr(session, "bridge_context_log", None),
            "container_env_id": getattr(session, "container_env_id", None),
            "metadata_json": metadata_json,
            "tags_json": "[]",
            "contexts_json": "[]",
        }

        async with self.graph.write_lock:
            await self.graph._execute(
                """
                CREATE (:Parachute_Session {
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
                    linked_bot_platform: $linked_bot_platform,
                    linked_bot_chat_id: $linked_bot_chat_id,
                    linked_bot_chat_type: $linked_bot_chat_type,
                    parent_session_id: $parent_session_id,
                    created_by: $created_by,
                    summary: $summary,
                    bridge_session_id: $bridge_session_id,
                    bridge_context_log: $bridge_context_log,
                    container_env_id: $container_env_id,
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
            "MATCH (s:Parachute_Session {session_id: $session_id}) RETURN s",
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

        if update.working_directory is not None:
            set_parts.append("s.working_directory = $working_directory")
            params["working_directory"] = update.working_directory

        if update.bridge_session_id is not None:
            set_parts.append("s.bridge_session_id = $bridge_session_id")
            params["bridge_session_id"] = update.bridge_session_id

        if update.bridge_context_log is not None:
            set_parts.append("s.bridge_context_log = $bridge_context_log")
            params["bridge_context_log"] = update.bridge_context_log

        if update.container_env_id is not None:
            set_parts.append("s.container_env_id = $container_env_id")
            params["container_env_id"] = update.container_env_id

        if not set_parts:
            return await self.get_session(session_id)

        set_parts.append("s.last_accessed = $last_accessed")
        params["last_accessed"] = _now()

        async with self.graph.write_lock:
            await self.graph._execute(
                f"MATCH (s:Parachute_Session {{session_id: $session_id}}) "
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
                "MATCH (s:Parachute_Session {session_id: $session_id}) DETACH DELETE s",
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
            f"MATCH (s:Parachute_Session) {where_clause} "
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
                "MATCH (s:Parachute_Session {session_id: $session_id}) "
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
                "MATCH (s:Parachute_Session {session_id: $session_id}) RETURN s.message_count",
                {"session_id": session_id},
            )
            if not rows:
                return
            current = rows[0].get("s.message_count", 0) or 0
            new_count = current + increment
            await self.graph._execute(
                "MATCH (s:Parachute_Session {session_id: $session_id}) "
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
            f"MATCH (s:Parachute_Session) {where_clause} RETURN count(s) AS cnt",
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
                    f"MATCH (s:Parachute_Session {{session_id: $session_id}}) "
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
                    f"MATCH (s:Parachute_Session {{session_id: $session_id}}) "
                    f"SET {', '.join(set_parts)}",
                    params,
                )

    # ── Session Tags ──────────────────────────────────────────────────────────

    async def add_tag(self, session_id: str, tag: str) -> None:
        """Add a tag to a session."""
        tag = tag.lower().strip()
        rows = await self.graph.execute_cypher(
            "MATCH (s:Parachute_Session {session_id: $session_id}) RETURN s.tags_json",
            {"session_id": session_id},
        )
        if not rows:
            return
        tags: list[str] = json.loads(rows[0].get("s.tags_json") or "[]")
        if tag not in tags:
            tags.append(tag)
            async with self.graph.write_lock:
                await self.graph._execute(
                    "MATCH (s:Parachute_Session {session_id: $session_id}) "
                    "SET s.tags_json = $tags_json",
                    {"session_id": session_id, "tags_json": json.dumps(tags)},
                )

    async def remove_tag(self, session_id: str, tag: str) -> None:
        """Remove a tag from a session."""
        tag = tag.lower().strip()
        rows = await self.graph.execute_cypher(
            "MATCH (s:Parachute_Session {session_id: $session_id}) RETURN s.tags_json",
            {"session_id": session_id},
        )
        if not rows:
            return
        tags: list[str] = json.loads(rows[0].get("s.tags_json") or "[]")
        tags = [t for t in tags if t != tag]
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (s:Parachute_Session {session_id: $session_id}) "
                "SET s.tags_json = $tags_json",
                {"session_id": session_id, "tags_json": json.dumps(tags)},
            )

    async def get_session_tags(self, session_id: str) -> list[str]:
        """Get all tags for a session."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Parachute_Session {session_id: $session_id}) RETURN s.tags_json",
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
            "MATCH (s:Parachute_Session) RETURN s ORDER BY s.last_accessed DESC"
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
            "MATCH (s:Parachute_Session) RETURN s.tags_json"
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
                "MATCH (s:Parachute_Session {session_id: $session_id}) "
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
            "MATCH (s:Parachute_Session {session_id: $session_id}) RETURN s.contexts_json",
            {"session_id": session_id},
        )
        if not rows:
            return
        contexts: list[str] = json.loads(rows[0].get("s.contexts_json") or "[]")
        if folder_path not in contexts:
            contexts.append(folder_path)
            async with self.graph.write_lock:
                await self.graph._execute(
                    "MATCH (s:Parachute_Session {session_id: $session_id}) "
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
            "MATCH (s:Parachute_Session {session_id: $session_id}) RETURN s.contexts_json",
            {"session_id": session_id},
        )
        if not rows:
            return
        contexts: list[str] = json.loads(rows[0].get("s.contexts_json") or "[]")
        contexts = [c for c in contexts if c != folder_path]
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (s:Parachute_Session {session_id: $session_id}) "
                "SET s.contexts_json = $contexts_json",
                {
                    "session_id": session_id,
                    "contexts_json": json.dumps(contexts),
                },
            )

    async def get_session_contexts(self, session_id: str) -> list[str]:
        """Get all context folder paths for a session."""
        rows = await self.graph.execute_cypher(
            "MATCH (s:Parachute_Session {session_id: $session_id}) RETURN s.contexts_json",
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
            "MATCH (s:Parachute_Session) RETURN s ORDER BY s.last_accessed DESC"
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
            "MATCH (s:Parachute_Session) "
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
            "MATCH (s:Parachute_Session) "
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
            "MATCH (s:Parachute_Session) "
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

    # ── Container Envs ────────────────────────────────────────────────────────

    async def create_container_env(
        self, slug: str, display_name: str
    ) -> ContainerEnv:
        """Create a named container environment."""
        now = _now()
        async with self.graph.write_lock:
            await self.graph._execute(
                "CREATE (:Parachute_ContainerEnv {slug: $slug, display_name: $display_name, created_at: $created_at})",
                {"slug": slug, "display_name": display_name, "created_at": now},
            )
        return ContainerEnv(
            slug=slug,
            display_name=display_name,
            created_at=datetime.fromisoformat(now),
        )

    async def get_container_env(self, slug: str) -> Optional[ContainerEnv]:
        """Get a named container environment by slug."""
        rows = await self.graph.execute_cypher(
            "MATCH (e:Parachute_ContainerEnv {slug: $slug}) RETURN e",
            {"slug": slug},
        )
        if rows:
            return self._node_to_container_env(rows[0])
        return None

    async def list_container_envs(self) -> list[ContainerEnv]:
        """List all named container environments."""
        rows = await self.graph.execute_cypher(
            "MATCH (e:Parachute_ContainerEnv) RETURN e ORDER BY e.created_at DESC"
        )
        return [self._node_to_container_env(r) for r in rows]

    async def delete_container_env(self, slug: str) -> bool:
        """Delete a container env, nullifying sessions that reference it."""
        # Nullify container_env_id on referencing sessions
        async with self.graph.write_lock:
            await self.graph._execute(
                "MATCH (s:Parachute_Session {container_env_id: $slug}) "
                "SET s.container_env_id = null",
                {"slug": slug},
            )
            result = await self.graph.execute_cypher(
                "MATCH (e:Parachute_ContainerEnv {slug: $slug}) RETURN count(e) AS cnt",
                {"slug": slug},
            )
            count = result[0]["cnt"] if result else 0
            if count == 0:
                return False
            await self.graph._execute(
                "MATCH (e:Parachute_ContainerEnv {slug: $slug}) DETACH DELETE e",
                {"slug": slug},
            )
        return True

    async def delete_container_env_if_unreferenced(self, slug: str) -> bool:
        """Delete a container env only if no sessions reference it."""
        async with self.graph.write_lock:
            # Check if any sessions reference this env
            sessions = await self.graph.execute_cypher(
                "MATCH (s:Parachute_Session {container_env_id: $slug}) RETURN count(s) AS cnt",
                {"slug": slug},
            )
            if sessions and sessions[0]["cnt"] > 0:
                return False
            env = await self.graph.execute_cypher(
                "MATCH (e:Parachute_ContainerEnv {slug: $slug}) RETURN count(e) AS cnt",
                {"slug": slug},
            )
            if not env or env[0]["cnt"] == 0:
                return False
            await self.graph._execute(
                "MATCH (e:Parachute_ContainerEnv {slug: $slug}) DETACH DELETE e",
                {"slug": slug},
            )
        return True

    async def list_orphan_container_env_slugs(
        self, min_age_minutes: int = 5
    ) -> list[str]:
        """Return slugs of container envs safe to prune."""
        cutoff = (
            datetime.now(timezone.utc) - timedelta(minutes=min_age_minutes)
        ).isoformat()

        all_envs = await self.graph.execute_cypher(
            "MATCH (e:Parachute_ContainerEnv) WHERE e.created_at < $cutoff RETURN e.slug",
            {"cutoff": cutoff},
        )

        orphans = []
        for row in all_envs:
            slug = row.get("e.slug")
            if not slug:
                continue
            # Check if any session with message_count > 0 references this env
            sessions = await self.graph.execute_cypher(
                "MATCH (s:Parachute_Session {container_env_id: $slug}) "
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
            linked_bot_platform=row.get("linked_bot_platform"),
            linked_bot_chat_id=row.get("linked_bot_chat_id"),
            linked_bot_chat_type=row.get("linked_bot_chat_type"),
            parent_session_id=row.get("parent_session_id"),
            created_by=row.get("created_by") or "user",
            summary=row.get("summary"),
            bridge_session_id=row.get("bridge_session_id"),
            bridge_context_log=row.get("bridge_context_log"),
            container_env_id=row.get("container_env_id"),
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

    def _node_to_container_env(self, row: dict[str, Any]) -> ContainerEnv:
        """Convert a Kuzu node dict to a ContainerEnv model."""
        return ContainerEnv(
            slug=row["slug"],
            display_name=row["display_name"],
            created_at=datetime.fromisoformat(row["created_at"]),
        )
