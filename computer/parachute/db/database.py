"""
SQLite database for session management.

Provides async database operations using aiosqlite.
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional, Union

import aiosqlite

from parachute.models.session import PairingRequest, Session, SessionCreate, SessionSource, SessionUpdate

logger = logging.getLogger(__name__)


SCHEMA_SQL = """
-- Sessions table
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    title TEXT,
    module TEXT NOT NULL DEFAULT 'chat',
    source TEXT NOT NULL DEFAULT 'parachute',
    working_directory TEXT,
    vault_root TEXT,  -- Root path of vault when session was created (for cross-machine portability)
    model TEXT,
    message_count INTEGER DEFAULT 0,
    archived INTEGER DEFAULT 0,
    created_at TEXT NOT NULL,
    last_accessed TEXT NOT NULL,
    continued_from TEXT,
    agent_type TEXT,  -- Agent type/name (e.g., 'vault-agent', 'orchestrator', 'summarizer')
    metadata TEXT
);

-- Session indexes
CREATE INDEX IF NOT EXISTS idx_sessions_module ON sessions(module);
CREATE INDEX IF NOT EXISTS idx_sessions_archived ON sessions(archived);
CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
CREATE INDEX IF NOT EXISTS idx_sessions_last_accessed ON sessions(last_accessed DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_created_at ON sessions(created_at DESC);
-- Note: idx_sessions_agent_type is created in migrations to handle existing DBs

-- Session tags for filtered search
CREATE TABLE IF NOT EXISTS session_tags (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    tag TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (session_id, tag)
);

CREATE INDEX IF NOT EXISTS idx_session_tags_tag ON session_tags(tag);

-- Content chunks for RAG search (sessions, journals, etc.)
CREATE TABLE IF NOT EXISTS chunks (
    id TEXT PRIMARY KEY,
    content_id TEXT NOT NULL,
    content_type TEXT NOT NULL,
    field TEXT NOT NULL DEFAULT 'content',
    chunk_index INTEGER NOT NULL,
    chunk_text TEXT NOT NULL,
    embedding BLOB,
    created_at TEXT NOT NULL,
    UNIQUE(content_id, field, chunk_index)
);

CREATE INDEX IF NOT EXISTS idx_chunks_content_id ON chunks(content_id);
CREATE INDEX IF NOT EXISTS idx_chunks_content_type ON chunks(content_type);

-- Index manifest for tracking what's been indexed
CREATE TABLE IF NOT EXISTS index_manifest (
    content_id TEXT PRIMARY KEY,
    content_type TEXT NOT NULL,
    content_hash TEXT,
    title TEXT,
    indexed_at TEXT NOT NULL,
    chunk_count INTEGER NOT NULL,
    source_path TEXT,
    metadata TEXT
);

CREATE INDEX IF NOT EXISTS idx_manifest_type ON index_manifest(content_type);
CREATE INDEX IF NOT EXISTS idx_manifest_indexed ON index_manifest(indexed_at DESC);

-- Key-value metadata store
CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TEXT NOT NULL
);

-- Session context folders (folder-based context system)
-- Each row is a folder path that provides context for a session
-- The full parent chain is computed at runtime
CREATE TABLE IF NOT EXISTS session_contexts (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    folder_path TEXT NOT NULL,  -- Relative to vault (e.g., "Projects/parachute")
    added_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (session_id, folder_path)
);

CREATE INDEX IF NOT EXISTS idx_session_contexts_session ON session_contexts(session_id);
CREATE INDEX IF NOT EXISTS idx_session_contexts_folder ON session_contexts(folder_path);

-- Pairing requests (bot connector user approval flow)
CREATE TABLE IF NOT EXISTS pairing_requests (
    id TEXT PRIMARY KEY,
    platform TEXT NOT NULL,
    platform_user_id TEXT NOT NULL,
    platform_user_display TEXT,
    platform_chat_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    approved_trust_level TEXT,
    created_at TEXT NOT NULL,
    resolved_at TEXT,
    resolved_by TEXT,
    UNIQUE(platform, platform_user_id, status)
);

CREATE INDEX IF NOT EXISTS idx_pairing_requests_status ON pairing_requests(status);
CREATE INDEX IF NOT EXISTS idx_pairing_requests_platform ON pairing_requests(platform, platform_user_id);

-- Schema version tracking
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

-- Insert schema version 10 (current schema)
INSERT OR IGNORE INTO schema_version (version, applied_at)
VALUES (10, datetime('now'));
"""


class Database:
    """Async SQLite database for session management."""

    def __init__(self, db_path: Path):
        """Initialize database with path."""
        self.db_path = db_path
        self._connection: Optional[aiosqlite.Connection] = None

    async def connect(self) -> None:
        """Connect to database and initialize schema."""
        # Ensure parent directory exists
        self.db_path.parent.mkdir(parents=True, exist_ok=True)

        self._connection = await aiosqlite.connect(self.db_path)
        self._connection.row_factory = aiosqlite.Row

        # Initialize schema
        await self._connection.executescript(SCHEMA_SQL)
        await self._connection.commit()

        # Run migrations for existing databases
        await self._run_migrations()

        logger.info(f"Database connected: {self.db_path}")

    async def _run_migrations(self) -> None:
        """Run any needed migrations for existing databases."""
        # Migration: Add vault_root column to sessions if missing (v9)
        try:
            async with self._connection.execute(
                "SELECT vault_root FROM sessions LIMIT 1"
            ):
                pass  # Column exists
        except Exception:
            # Column doesn't exist, add it
            await self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN vault_root TEXT"
            )
            await self._connection.commit()
            logger.info("Added vault_root column to sessions")

        # Migration: Add agent_type column to sessions if missing (v10)
        try:
            async with self._connection.execute(
                "SELECT agent_type FROM sessions LIMIT 1"
            ):
                pass  # Column exists
        except Exception:
            # Column doesn't exist, add it
            await self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN agent_type TEXT"
            )
            # Add index for agent_type lookups
            await self._connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_sessions_agent_type ON sessions(agent_type)"
            )
            await self._connection.commit()
            logger.info("Added agent_type column to sessions")

        # Migration: Add trust_level and linked_bot columns (v11)
        try:
            async with self._connection.execute(
                "SELECT trust_level FROM sessions LIMIT 1"
            ):
                pass  # Column exists
        except Exception:
            await self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN trust_level TEXT DEFAULT 'full'"
            )
            await self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN linked_bot_platform TEXT"
            )
            await self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN linked_bot_chat_id TEXT"
            )
            await self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN linked_bot_chat_type TEXT"
            )
            await self._connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_sessions_trust_level ON sessions(trust_level)"
            )
            await self._connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_sessions_linked_bot ON sessions(linked_bot_platform, linked_bot_chat_id)"
            )
            await self._connection.commit()
            logger.info("Added trust_level and linked_bot columns to sessions (v11)")

        # Migration: Add pairing_requests table (v12)
        try:
            async with self._connection.execute(
                "SELECT id FROM pairing_requests LIMIT 1"
            ):
                pass  # Table exists
        except Exception:
            await self._connection.executescript("""
                CREATE TABLE IF NOT EXISTS pairing_requests (
                    id TEXT PRIMARY KEY,
                    platform TEXT NOT NULL,
                    platform_user_id TEXT NOT NULL,
                    platform_user_display TEXT,
                    platform_chat_id TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    approved_trust_level TEXT,
                    created_at TEXT NOT NULL,
                    resolved_at TEXT,
                    resolved_by TEXT,
                    UNIQUE(platform, platform_user_id, status)
                );
                CREATE INDEX IF NOT EXISTS idx_pairing_requests_status ON pairing_requests(status);
                CREATE INDEX IF NOT EXISTS idx_pairing_requests_platform ON pairing_requests(platform, platform_user_id);
            """)
            await self._connection.commit()
            logger.info("Added pairing_requests table (v12)")

        # Migration: Add workspace_id column to sessions (v13)
        try:
            async with self._connection.execute(
                "SELECT workspace_id FROM sessions LIMIT 1"
            ):
                pass  # Column exists
        except Exception:
            await self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN workspace_id TEXT"
            )
            await self._connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_sessions_workspace_id ON sessions(workspace_id)"
            )
            await self._connection.commit()
            logger.info("Added workspace_id column to sessions (v13)")

        # Migration: Trust model simplification (v14)
        # Map old 3-tier trust levels to binary: full/vault → trusted, sandboxed → untrusted
        async with self._connection.execute(
            "SELECT version FROM schema_version WHERE version = 14"
        ) as cursor:
            row = await cursor.fetchone()
        if not row:
            await self._connection.execute(
                "UPDATE sessions SET trust_level = 'trusted' WHERE trust_level IN ('full', 'vault')"
            )
            await self._connection.execute(
                "UPDATE sessions SET trust_level = 'untrusted' WHERE trust_level = 'sandboxed'"
            )
            # Also update pairing_requests
            await self._connection.execute(
                "UPDATE pairing_requests SET approved_trust_level = 'trusted' "
                "WHERE approved_trust_level IN ('full', 'vault')"
            )
            await self._connection.execute(
                "UPDATE pairing_requests SET approved_trust_level = 'untrusted' "
                "WHERE approved_trust_level = 'sandboxed'"
            )
            await self._connection.execute(
                "INSERT OR IGNORE INTO schema_version (version, applied_at) VALUES (14, datetime('now'))"
            )
            await self._connection.commit()
            logger.info("Migrated trust levels: full/vault → trusted, sandboxed → untrusted (v14)")

        # Migration: Unify working_directory paths to /vault/... format (v15)
        # Convert relative paths (e.g., "Projects/foo") to absolute ("/vault/Projects/foo")
        async with self._connection.execute(
            "SELECT version FROM schema_version WHERE version = 15"
        ) as cursor:
            row = await cursor.fetchone()
        if not row:
            await self._connection.execute("""
                UPDATE sessions
                SET working_directory = '/vault/' || working_directory
                WHERE working_directory IS NOT NULL
                  AND working_directory != ''
                  AND working_directory NOT LIKE '/vault/%'
                  AND working_directory NOT LIKE '/%'
            """)
            await self._connection.execute(
                "INSERT OR IGNORE INTO schema_version (version, applied_at) VALUES (15, datetime('now'))"
            )
            await self._connection.commit()
            logger.info("Migrated working_directory paths to /vault/... format (v15)")

        # Migration: Trust level rename (v16)
        # Rename trusted → direct, untrusted → sandboxed
        # Also mark v14 as applied to prevent it from un-renaming our data.
        async with self._connection.execute(
            "SELECT version FROM schema_version WHERE version = 16"
        ) as cursor:
            row = await cursor.fetchone()
        if not row:
            await self._connection.execute(
                "UPDATE sessions SET trust_level = 'direct' WHERE trust_level = 'trusted'"
            )
            await self._connection.execute(
                "UPDATE sessions SET trust_level = 'sandboxed' WHERE trust_level = 'untrusted'"
            )
            await self._connection.execute(
                "UPDATE pairing_requests SET approved_trust_level = 'direct' "
                "WHERE approved_trust_level = 'trusted'"
            )
            await self._connection.execute(
                "UPDATE pairing_requests SET approved_trust_level = 'sandboxed' "
                "WHERE approved_trust_level = 'untrusted'"
            )
            # Prevent v14 from running on a fresh DB that never had old trust levels
            await self._connection.execute(
                "INSERT OR IGNORE INTO schema_version (version, applied_at) VALUES (14, datetime('now'))"
            )
            await self._connection.execute(
                "INSERT OR IGNORE INTO schema_version (version, applied_at) VALUES (16, datetime('now'))"
            )
            await self._connection.commit()
            logger.info("Migrated trust levels: trusted → direct, untrusted → sandboxed (v16)")

        # Migration: Add parent_session_id and created_by for multi-agent (v17)
        async with self._connection.execute(
            "SELECT version FROM schema_version WHERE version = 17"
        ) as cursor:
            row = await cursor.fetchone()
        if not row:
            try:
                async with self._connection.execute(
                    "SELECT parent_session_id FROM sessions LIMIT 1"
                ):
                    pass  # Column exists
            except Exception:
                await self._connection.execute(
                    "ALTER TABLE sessions ADD COLUMN parent_session_id TEXT"
                )
                logger.info("Added parent_session_id column to sessions")

            try:
                async with self._connection.execute(
                    "SELECT created_by FROM sessions LIMIT 1"
                ):
                    pass  # Column exists
            except Exception:
                await self._connection.execute(
                    "ALTER TABLE sessions ADD COLUMN created_by TEXT DEFAULT 'user'"
                )
                logger.info("Added created_by column to sessions")

            # Add indexes for multi-agent queries
            await self._connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_sessions_parent_session ON sessions(parent_session_id)"
            )
            # Composite index for efficient spawn limit and rate limiting queries
            await self._connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_sessions_parent_active ON sessions(parent_session_id, archived)"
            )
            await self._connection.execute(
                "INSERT OR IGNORE INTO schema_version (version, applied_at) VALUES (17, datetime('now'))"
            )
            await self._connection.commit()
            logger.info("Added multi-agent session fields (v17)")

    async def close(self) -> None:
        """Close database connection."""
        if self._connection:
            await self._connection.close()
            self._connection = None
            logger.info("Database connection closed")

    @property
    def connection(self) -> aiosqlite.Connection:
        """Get active connection, raising if not connected."""
        if not self._connection:
            raise RuntimeError("Database not connected")
        return self._connection

    # =========================================================================
    # Session CRUD
    # =========================================================================

    async def create_session(self, session: Union[Session, SessionCreate]) -> Session:
        """Create a new session.

        Accepts either a full Session or SessionCreate. When a full Session is
        provided (e.g., from imports), uses the provided timestamps. Otherwise,
        uses the current time.
        """
        now = datetime.now(timezone.utc)
        metadata_json = json.dumps(session.metadata) if session.metadata else None

        # Use provided timestamps if available (for imports), otherwise use now
        if isinstance(session, Session):
            created_at = session.created_at.isoformat()
            last_accessed = session.last_accessed.isoformat()
            message_count = session.message_count
            archived = 1 if session.archived else 0
        else:
            created_at = now.isoformat()
            last_accessed = now.isoformat()
            message_count = 0
            archived = 0

        # Get optional fields (may be None)
        agent_type = getattr(session, 'agent_type', None)
        trust_level = getattr(session, 'trust_level', None)
        linked_bot_platform = getattr(session, 'linked_bot_platform', None)
        linked_bot_chat_id = getattr(session, 'linked_bot_chat_id', None)
        linked_bot_chat_type = getattr(session, 'linked_bot_chat_type', None)
        workspace_id = getattr(session, 'workspace_id', None)
        parent_session_id = getattr(session, 'parent_session_id', None)
        created_by = getattr(session, 'created_by', 'user')

        await self.connection.execute(
            """
            INSERT INTO sessions (
                id, title, module, source, working_directory, vault_root, model,
                message_count, archived, created_at, last_accessed,
                continued_from, agent_type, trust_level,
                linked_bot_platform, linked_bot_chat_id, linked_bot_chat_type,
                workspace_id, parent_session_id, created_by, metadata
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                session.id,
                session.title,
                session.module,
                session.source.value,
                session.working_directory,
                session.vault_root,
                session.model,
                message_count,
                archived,
                created_at,
                last_accessed,
                session.continued_from,
                agent_type,
                trust_level,
                linked_bot_platform,
                linked_bot_chat_id,
                linked_bot_chat_type,
                workspace_id,
                parent_session_id,
                created_by,
                metadata_json,
            ),
        )
        await self.connection.commit()

        return await self.get_session(session.id)  # type: ignore

    async def get_session(self, session_id: str) -> Optional[Session]:
        """Get a session by ID."""
        async with self.connection.execute(
            "SELECT * FROM sessions WHERE id = ?", (session_id,)
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                return self._row_to_session(row)
            return None

    async def update_session(
        self, session_id: str, update: SessionUpdate
    ) -> Optional[Session]:
        """Update a session."""
        updates = []
        params = []

        if update.title is not None:
            updates.append("title = ?")
            params.append(update.title)

        if update.archived is not None:
            updates.append("archived = ?")
            params.append(1 if update.archived else 0)

        if update.message_count is not None:
            updates.append("message_count = ?")
            params.append(update.message_count)

        if update.model is not None:
            updates.append("model = ?")
            params.append(update.model)

        if update.metadata is not None:
            updates.append("metadata = ?")
            params.append(json.dumps(update.metadata))

        if update.agent_type is not None:
            updates.append("agent_type = ?")
            params.append(update.agent_type)

        if update.trust_level is not None:
            updates.append("trust_level = ?")
            params.append(update.trust_level)

        if update.working_directory is not None:
            updates.append("working_directory = ?")
            params.append(update.working_directory)

        if update.workspace_id is not None:
            updates.append("workspace_id = ?")
            params.append(update.workspace_id)

        if not updates:
            return await self.get_session(session_id)

        # Always update last_accessed
        updates.append("last_accessed = ?")
        params.append(datetime.now(timezone.utc).isoformat())
        params.append(session_id)

        await self.connection.execute(
            f"UPDATE sessions SET {', '.join(updates)} WHERE id = ?",
            params,
        )
        await self.connection.commit()

        return await self.get_session(session_id)

    async def delete_session(self, session_id: str) -> bool:
        """Delete a session."""
        cursor = await self.connection.execute(
            "DELETE FROM sessions WHERE id = ?", (session_id,)
        )
        await self.connection.commit()
        return cursor.rowcount > 0

    async def list_sessions(
        self,
        module: Optional[str] = None,
        archived: Optional[bool] = None,
        agent_type: Optional[str] = None,
        search: Optional[str] = None,
        workspace_id: Optional[str] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[Session]:
        """List sessions with optional filtering."""
        query = "SELECT * FROM sessions WHERE 1=1"
        params: list[Any] = []

        if module:
            query += " AND module = ?"
            params.append(module)

        if archived is not None:
            query += " AND archived = ?"
            params.append(1 if archived else 0)

        if agent_type:
            query += " AND agent_type = ?"
            params.append(agent_type)

        if search:
            query += " AND title LIKE ?"
            params.append(f"%{search}%")

        if workspace_id is not None:
            query += " AND workspace_id = ?"
            params.append(workspace_id)

        query += " ORDER BY last_accessed DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])

        async with self.connection.execute(query, params) as cursor:
            rows = await cursor.fetchall()
            return [self._row_to_session(row) for row in rows]

    async def archive_session(self, session_id: str) -> Optional[Session]:
        """Archive a session."""
        return await self.update_session(session_id, SessionUpdate(archived=True))

    async def unarchive_session(self, session_id: str) -> Optional[Session]:
        """Unarchive a session."""
        return await self.update_session(session_id, SessionUpdate(archived=False))

    async def touch_session(self, session_id: str) -> None:
        """Update last_accessed timestamp."""
        await self.connection.execute(
            "UPDATE sessions SET last_accessed = ? WHERE id = ?",
            (datetime.now(timezone.utc).isoformat(), session_id),
        )
        await self.connection.commit()

    async def increment_message_count(
        self, session_id: str, increment: int = 1
    ) -> None:
        """Increment the message count for a session."""
        await self.connection.execute(
            "UPDATE sessions SET message_count = message_count + ?, last_accessed = ? WHERE id = ?",
            (increment, datetime.now(timezone.utc).isoformat(), session_id),
        )
        await self.connection.commit()

    async def get_session_count(
        self, module: Optional[str] = None, archived: Optional[bool] = None
    ) -> int:
        """Get count of sessions."""
        query = "SELECT COUNT(*) FROM sessions WHERE 1=1"
        params: list[Any] = []

        if module:
            query += " AND module = ?"
            params.append(module)

        if archived is not None:
            query += " AND archived = ?"
            params.append(1 if archived else 0)

        async with self.connection.execute(query, params) as cursor:
            row = await cursor.fetchone()
            return row[0] if row else 0

    async def cleanup_old_sessions(self, days: int = 30) -> int:
        """Delete archived sessions older than specified days."""
        # Use SQL datetime functions for cutoff calculation
        cursor = await self.connection.execute(
            """
            DELETE FROM sessions
            WHERE archived = 1
            AND datetime(last_accessed) < datetime('now', ?)
            """,
            (f"-{days} days",),
        )
        await self.connection.commit()
        return cursor.rowcount

    # =========================================================================
    # Session Tags
    # =========================================================================

    async def add_tag(self, session_id: str, tag: str) -> None:
        """Add a tag to a session."""
        now = datetime.now(timezone.utc).isoformat()
        await self.connection.execute(
            "INSERT OR IGNORE INTO session_tags (session_id, tag, created_at) VALUES (?, ?, ?)",
            (session_id, tag.lower().strip(), now),
        )
        await self.connection.commit()

    async def remove_tag(self, session_id: str, tag: str) -> None:
        """Remove a tag from a session."""
        await self.connection.execute(
            "DELETE FROM session_tags WHERE session_id = ? AND tag = ?",
            (session_id, tag.lower().strip()),
        )
        await self.connection.commit()

    async def get_session_tags(self, session_id: str) -> list[str]:
        """Get all tags for a session."""
        async with self.connection.execute(
            "SELECT tag FROM session_tags WHERE session_id = ? ORDER BY tag",
            (session_id,),
        ) as cursor:
            rows = await cursor.fetchall()
            return [row["tag"] for row in rows]

    async def get_sessions_by_tag(
        self, tag: str, limit: int = 100
    ) -> list[Session]:
        """Get all sessions with a specific tag."""
        async with self.connection.execute(
            """
            SELECT s.* FROM sessions s
            JOIN session_tags t ON s.id = t.session_id
            WHERE t.tag = ?
            ORDER BY s.last_accessed DESC
            LIMIT ?
            """,
            (tag.lower().strip(), limit),
        ) as cursor:
            rows = await cursor.fetchall()
            return [self._row_to_session(row) for row in rows]

    async def list_all_tags(self) -> list[tuple[str, int]]:
        """List all tags with their usage counts."""
        async with self.connection.execute(
            """
            SELECT tag, COUNT(*) as count
            FROM session_tags
            GROUP BY tag
            ORDER BY count DESC, tag ASC
            """
        ) as cursor:
            rows = await cursor.fetchall()
            return [(row["tag"], row["count"]) for row in rows]

    # =========================================================================
    # Session Context Folders
    # =========================================================================

    async def set_session_contexts(
        self, session_id: str, folder_paths: list[str]
    ) -> None:
        """
        Set the context folders for a session (replaces existing).

        Args:
            session_id: The session ID
            folder_paths: List of folder paths relative to vault
        """
        now = datetime.now(timezone.utc).isoformat()

        # Delete existing contexts
        await self.connection.execute(
            "DELETE FROM session_contexts WHERE session_id = ?",
            (session_id,),
        )

        # Insert new contexts
        for folder_path in folder_paths:
            await self.connection.execute(
                "INSERT INTO session_contexts (session_id, folder_path, added_at) VALUES (?, ?, ?)",
                (session_id, folder_path, now),
            )

        await self.connection.commit()

    async def add_session_context(self, session_id: str, folder_path: str) -> None:
        """Add a context folder to a session."""
        now = datetime.now(timezone.utc).isoformat()
        await self.connection.execute(
            "INSERT OR IGNORE INTO session_contexts (session_id, folder_path, added_at) VALUES (?, ?, ?)",
            (session_id, folder_path, now),
        )
        await self.connection.commit()

    async def remove_session_context(self, session_id: str, folder_path: str) -> None:
        """Remove a context folder from a session."""
        await self.connection.execute(
            "DELETE FROM session_contexts WHERE session_id = ? AND folder_path = ?",
            (session_id, folder_path),
        )
        await self.connection.commit()

    async def get_session_contexts(self, session_id: str) -> list[str]:
        """Get all context folder paths for a session."""
        async with self.connection.execute(
            "SELECT folder_path FROM session_contexts WHERE session_id = ? ORDER BY folder_path",
            (session_id,),
        ) as cursor:
            rows = await cursor.fetchall()
            return [row["folder_path"] for row in rows]

    async def get_sessions_by_context(
        self, folder_path: str, limit: int = 100
    ) -> list[Session]:
        """Get all sessions using a specific context folder."""
        async with self.connection.execute(
            """
            SELECT s.* FROM sessions s
            JOIN session_contexts sc ON s.id = sc.session_id
            WHERE sc.folder_path = ?
            ORDER BY s.last_accessed DESC
            LIMIT ?
            """,
            (folder_path, limit),
        ) as cursor:
            rows = await cursor.fetchall()
            return [self._row_to_session(row) for row in rows]

    async def get_session_by_bot_link(
        self, platform: str, chat_id: str
    ) -> Optional[Session]:
        """Get the most recent active session linked to a bot chat."""
        async with self.connection.execute(
            """
            SELECT * FROM sessions
            WHERE linked_bot_platform = ? AND linked_bot_chat_id = ?
                AND archived = 0
            ORDER BY last_accessed DESC
            LIMIT 1
            """,
            (platform, chat_id),
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                return self._row_to_session(row)
        return None

    # =========================================================================
    # Multi-Agent Session Helpers
    # =========================================================================

    async def count_children(self, parent_session_id: str) -> int:
        """Count active (non-archived) child sessions for rate limiting."""
        async with self.connection.execute(
            """
            SELECT COUNT(*) FROM sessions
            WHERE parent_session_id = ? AND archived = 0
            """,
            (parent_session_id,),
        ) as cursor:
            row = await cursor.fetchone()
            return row[0] if row else 0

    async def get_last_child_created(
        self, parent_session_id: str
    ) -> Optional[datetime]:
        """Get timestamp of most recent child session for rate limiting."""
        async with self.connection.execute(
            """
            SELECT created_at FROM sessions
            WHERE parent_session_id = ?
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (parent_session_id,),
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                return datetime.fromisoformat(row["created_at"])
            return None

    # =========================================================================
    # Pairing Requests
    # =========================================================================

    async def create_pairing_request(
        self,
        id: str,
        platform: str,
        platform_user_id: str,
        platform_chat_id: str,
        platform_user_display: Optional[str] = None,
    ) -> PairingRequest:
        """Create a new pairing request from an unknown bot user."""
        now = datetime.now(timezone.utc).isoformat()
        await self.connection.execute(
            """
            INSERT OR REPLACE INTO pairing_requests
            (id, platform, platform_user_id, platform_user_display, platform_chat_id, status, created_at)
            VALUES (?, ?, ?, ?, ?, 'pending', ?)
            """,
            (id, platform, platform_user_id, platform_user_display, platform_chat_id, now),
        )
        await self.connection.commit()
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
        async with self.connection.execute(
            "SELECT * FROM pairing_requests WHERE status = 'pending' ORDER BY created_at DESC"
        ) as cursor:
            rows = await cursor.fetchall()
            return [self._row_to_pairing_request(row) for row in rows]

    async def get_pending_pairing_count(self) -> int:
        """Get count of pending pairing requests."""
        async with self.connection.execute(
            "SELECT COUNT(*) FROM pairing_requests WHERE status = 'pending'"
        ) as cursor:
            row = await cursor.fetchone()
            return row[0] if row else 0

    async def get_pairing_request(self, request_id: str) -> Optional[PairingRequest]:
        """Get a pairing request by ID."""
        async with self.connection.execute(
            "SELECT * FROM pairing_requests WHERE id = ?", (request_id,)
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                return self._row_to_pairing_request(row)
            return None

    async def get_pairing_request_for_user(
        self, platform: str, user_id: str
    ) -> Optional[PairingRequest]:
        """Get the most recent pairing request for a platform user."""
        async with self.connection.execute(
            """
            SELECT * FROM pairing_requests
            WHERE platform = ? AND platform_user_id = ?
            ORDER BY created_at DESC LIMIT 1
            """,
            (platform, user_id),
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                return self._row_to_pairing_request(row)
            return None

    async def resolve_pairing_request(
        self,
        request_id: str,
        approved: bool,
        trust_level: Optional[str] = None,
        resolved_by: Optional[str] = "owner",
    ) -> Optional[PairingRequest]:
        """Resolve a pairing request (approve or deny)."""
        now = datetime.now(timezone.utc).isoformat()
        status = "approved" if approved else "denied"
        await self.connection.execute(
            """
            UPDATE pairing_requests
            SET status = ?, approved_trust_level = ?, resolved_at = ?, resolved_by = ?
            WHERE id = ?
            """,
            (status, trust_level if approved else None, now, resolved_by, request_id),
        )
        await self.connection.commit()
        return await self.get_pairing_request(request_id)

    def _row_to_pairing_request(self, row: aiosqlite.Row) -> PairingRequest:
        """Convert a database row to a PairingRequest model."""
        return PairingRequest(
            id=row["id"],
            platform=row["platform"],
            platform_user_id=row["platform_user_id"],
            platform_user_display=row["platform_user_display"],
            platform_chat_id=row["platform_chat_id"],
            status=row["status"],
            approved_trust_level=row["approved_trust_level"],
            created_at=datetime.fromisoformat(row["created_at"]),
            resolved_at=datetime.fromisoformat(row["resolved_at"]) if row["resolved_at"] else None,
            resolved_by=row["resolved_by"],
        )

    # =========================================================================
    # Session Config Update
    # =========================================================================

    async def update_session_config(
        self, session_id: str, **kwargs: Any
    ) -> None:
        """Update session config fields (trust_level, module, etc.)."""
        set_clauses = []
        values: list[Any] = []
        for key, value in kwargs.items():
            if key in ("trust_level", "module", "workspace_id"):
                set_clauses.append(f"{key} = ?")
                values.append(value)
        if set_clauses:
            set_clauses.append("last_accessed = ?")
            values.append(datetime.now(timezone.utc).isoformat())
            values.append(session_id)
            sql = f"UPDATE sessions SET {', '.join(set_clauses)} WHERE id = ?"
            await self.connection.execute(sql, values)
            await self.connection.commit()

    # =========================================================================
    # Chunks (RAG Index)
    # =========================================================================

    async def upsert_chunk(
        self,
        content_id: str,
        content_type: str,
        field: str,
        chunk_index: int,
        chunk_text: str,
        embedding: Optional[bytes] = None,
    ) -> str:
        """Insert or update a chunk."""
        chunk_id = f"chunk:{content_id}:{field}:{chunk_index}"
        now = datetime.now(timezone.utc).isoformat()

        await self.connection.execute(
            """
            INSERT OR REPLACE INTO chunks
            (id, content_id, content_type, field, chunk_index, chunk_text, embedding, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (chunk_id, content_id, content_type, field, chunk_index, chunk_text, embedding, now),
        )
        await self.connection.commit()
        return chunk_id

    async def get_chunks_for_content(
        self, content_id: str, field: Optional[str] = None
    ) -> list[dict[str, Any]]:
        """Get all chunks for a content item."""
        if field:
            query = "SELECT * FROM chunks WHERE content_id = ? AND field = ? ORDER BY chunk_index"
            params = (content_id, field)
        else:
            query = "SELECT * FROM chunks WHERE content_id = ? ORDER BY field, chunk_index"
            params = (content_id,)

        async with self.connection.execute(query, params) as cursor:
            rows = await cursor.fetchall()
            return [dict(row) for row in rows]

    async def delete_chunks_for_content(self, content_id: str) -> int:
        """Delete all chunks for a content item."""
        cursor = await self.connection.execute(
            "DELETE FROM chunks WHERE content_id = ?", (content_id,)
        )
        await self.connection.commit()
        return cursor.rowcount

    async def search_chunks(
        self,
        content_type: Optional[str] = None,
        tags: Optional[list[str]] = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        """
        Search chunks with optional filtering.

        For vector similarity search, the caller should:
        1. Get chunks with embeddings
        2. Compute similarity in Python (or use sqlite-vec extension)
        """
        if tags:
            # Join with session_tags for tag filtering
            query = """
                SELECT DISTINCT c.* FROM chunks c
                JOIN session_tags t ON c.content_id = t.session_id
                WHERE t.tag IN ({})
            """.format(",".join("?" * len(tags)))
            params: list[Any] = [tag.lower().strip() for tag in tags]

            if content_type:
                query += " AND c.content_type = ?"
                params.append(content_type)

            query += " ORDER BY c.created_at DESC LIMIT ?"
            params.append(limit)
        else:
            query = "SELECT * FROM chunks WHERE 1=1"
            params = []

            if content_type:
                query += " AND content_type = ?"
                params.append(content_type)

            query += " ORDER BY created_at DESC LIMIT ?"
            params.append(limit)

        async with self.connection.execute(query, params) as cursor:
            rows = await cursor.fetchall()
            return [dict(row) for row in rows]

    # =========================================================================
    # Index Manifest
    # =========================================================================

    async def upsert_manifest(
        self,
        content_id: str,
        content_type: str,
        chunk_count: int,
        content_hash: Optional[str] = None,
        title: Optional[str] = None,
        source_path: Optional[str] = None,
        metadata: Optional[dict] = None,
    ) -> None:
        """Insert or update an index manifest entry."""
        now = datetime.now(timezone.utc).isoformat()
        metadata_json = json.dumps(metadata) if metadata else None

        await self.connection.execute(
            """
            INSERT OR REPLACE INTO index_manifest
            (content_id, content_type, content_hash, title, indexed_at, chunk_count, source_path, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (content_id, content_type, content_hash, title, now, chunk_count, source_path, metadata_json),
        )
        await self.connection.commit()

    async def get_manifest(self, content_id: str) -> Optional[dict[str, Any]]:
        """Get manifest entry for a content item."""
        async with self.connection.execute(
            "SELECT * FROM index_manifest WHERE content_id = ?", (content_id,)
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                result = dict(row)
                if result.get("metadata"):
                    try:
                        result["metadata"] = json.loads(result["metadata"])
                    except json.JSONDecodeError:
                        pass
                return result
            return None

    async def delete_manifest(self, content_id: str) -> bool:
        """Delete manifest entry and associated chunks."""
        await self.delete_chunks_for_content(content_id)
        cursor = await self.connection.execute(
            "DELETE FROM index_manifest WHERE content_id = ?", (content_id,)
        )
        await self.connection.commit()
        return cursor.rowcount > 0

    async def list_indexed_content(
        self, content_type: Optional[str] = None, limit: int = 100
    ) -> list[dict[str, Any]]:
        """List all indexed content."""
        if content_type:
            query = "SELECT * FROM index_manifest WHERE content_type = ? ORDER BY indexed_at DESC LIMIT ?"
            params = (content_type, limit)
        else:
            query = "SELECT * FROM index_manifest ORDER BY indexed_at DESC LIMIT ?"
            params = (limit,)

        async with self.connection.execute(query, params) as cursor:
            rows = await cursor.fetchall()
            return [dict(row) for row in rows]

    # =========================================================================
    # Metadata (Key-Value Store)
    # =========================================================================

    async def set_metadata(self, key: str, value: str) -> None:
        """Set a metadata value."""
        now = datetime.now(timezone.utc).isoformat()
        await self.connection.execute(
            "INSERT OR REPLACE INTO metadata (key, value, updated_at) VALUES (?, ?, ?)",
            (key, value, now),
        )
        await self.connection.commit()

    async def get_metadata(self, key: str) -> Optional[str]:
        """Get a metadata value."""
        async with self.connection.execute(
            "SELECT value FROM metadata WHERE key = ?", (key,)
        ) as cursor:
            row = await cursor.fetchone()
            return row["value"] if row else None

    async def delete_metadata(self, key: str) -> bool:
        """Delete a metadata entry."""
        cursor = await self.connection.execute(
            "DELETE FROM metadata WHERE key = ?", (key,)
        )
        await self.connection.commit()
        return cursor.rowcount > 0

    # =========================================================================
    # Helpers
    # =========================================================================

    def _row_to_session(self, row: aiosqlite.Row) -> Session:
        """Convert a database row to a Session model."""
        metadata = None
        if row["metadata"]:
            try:
                metadata = json.loads(row["metadata"])
            except json.JSONDecodeError:
                pass

        keys = row.keys()
        return Session(
            id=row["id"],
            title=row["title"],
            module=row["module"],
            source=SessionSource(row["source"]),
            working_directory=row["working_directory"],
            vault_root=row["vault_root"] if "vault_root" in keys else None,
            model=row["model"],
            message_count=row["message_count"],
            archived=bool(row["archived"]),
            created_at=datetime.fromisoformat(row["created_at"]),
            last_accessed=datetime.fromisoformat(row["last_accessed"]),
            continued_from=row["continued_from"],
            agent_type=row["agent_type"] if "agent_type" in keys else None,
            trust_level=row["trust_level"] if "trust_level" in keys else None,
            linked_bot_platform=row["linked_bot_platform"] if "linked_bot_platform" in keys else None,
            linked_bot_chat_id=row["linked_bot_chat_id"] if "linked_bot_chat_id" in keys else None,
            linked_bot_chat_type=row["linked_bot_chat_type"] if "linked_bot_chat_type" in keys else None,
            workspace_id=row["workspace_id"] if "workspace_id" in keys else None,
            parent_session_id=row["parent_session_id"] if "parent_session_id" in keys else None,
            created_by=row["created_by"] if "created_by" in keys else "user",
            metadata=metadata,
        )


# Global database instance
_database: Optional[Database] = None


async def get_database() -> Database:
    """Get the global database instance."""
    global _database
    if _database is None:
        raise RuntimeError("Database not initialized. Call init_database() first.")
    return _database


async def init_database(db_path: Path) -> Database:
    """Initialize the global database instance."""
    global _database
    _database = Database(db_path)
    await _database.connect()
    return _database


async def close_database() -> None:
    """Close the global database instance."""
    global _database
    if _database:
        await _database.close()
        _database = None
