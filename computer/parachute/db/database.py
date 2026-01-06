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

from parachute.models.session import Session, SessionCreate, SessionSource, SessionUpdate

logger = logging.getLogger(__name__)


SCHEMA_SQL = """
-- Sessions table
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    title TEXT,
    module TEXT NOT NULL DEFAULT 'chat',
    source TEXT NOT NULL DEFAULT 'parachute',
    working_directory TEXT,
    model TEXT,
    message_count INTEGER DEFAULT 0,
    archived INTEGER DEFAULT 0,
    created_at TEXT NOT NULL,
    last_accessed TEXT NOT NULL,
    continued_from TEXT,
    metadata TEXT
);

-- Session indexes
CREATE INDEX IF NOT EXISTS idx_sessions_module ON sessions(module);
CREATE INDEX IF NOT EXISTS idx_sessions_archived ON sessions(archived);
CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
CREATE INDEX IF NOT EXISTS idx_sessions_last_accessed ON sessions(last_accessed DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_created_at ON sessions(created_at DESC);

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

-- Curator sessions (companion agents that curate chat sessions)
CREATE TABLE IF NOT EXISTS curator_sessions (
    id TEXT PRIMARY KEY,
    parent_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    sdk_session_id TEXT,
    last_run_at TEXT,
    last_message_index INTEGER DEFAULT 0,
    context_files TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_curator_sessions_parent ON curator_sessions(parent_session_id);

-- Curator task queue (one runs at a time to avoid conflicts)
CREATE TABLE IF NOT EXISTS curator_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_session_id TEXT NOT NULL,
    curator_session_id TEXT REFERENCES curator_sessions(id),
    trigger_type TEXT NOT NULL,
    message_count INTEGER,
    queued_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    started_at TEXT,
    completed_at TEXT,
    status TEXT DEFAULT 'pending',
    result TEXT,
    error TEXT
);

CREATE INDEX IF NOT EXISTS idx_curator_queue_status ON curator_queue(status);
CREATE INDEX IF NOT EXISTS idx_curator_queue_parent ON curator_queue(parent_session_id);

-- OAuth tokens for MCP servers (remote servers with OAuth auth)
CREATE TABLE IF NOT EXISTS mcp_oauth_tokens (
    server_name TEXT PRIMARY KEY,
    access_token TEXT NOT NULL,
    refresh_token TEXT,
    token_type TEXT DEFAULT 'Bearer',
    expires_at TEXT,
    scopes TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Schema version tracking
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

-- Insert schema version 4 (MCP OAuth support)
INSERT OR IGNORE INTO schema_version (version, applied_at)
VALUES (4, datetime('now'));
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

        logger.info(f"Database connected: {self.db_path}")

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

        await self.connection.execute(
            """
            INSERT INTO sessions (
                id, title, module, source, working_directory, model,
                message_count, archived, created_at, last_accessed,
                continued_from, metadata
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                session.id,
                session.title,
                session.module,
                session.source.value,
                session.working_directory,
                session.model,
                message_count,
                archived,
                created_at,
                last_accessed,
                session.continued_from,
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
    # MCP OAuth Tokens
    # =========================================================================

    async def store_oauth_token(
        self,
        server_name: str,
        access_token: str,
        refresh_token: Optional[str] = None,
        token_type: str = "Bearer",
        expires_at: Optional[datetime] = None,
        scopes: Optional[list[str]] = None,
    ) -> None:
        """Store or update an OAuth token for an MCP server."""
        now = datetime.now(timezone.utc).isoformat()
        expires_at_str = expires_at.isoformat() if expires_at else None
        scopes_str = ",".join(scopes) if scopes else None

        await self.connection.execute(
            """
            INSERT OR REPLACE INTO mcp_oauth_tokens
            (server_name, access_token, refresh_token, token_type, expires_at, scopes, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, COALESCE(
                (SELECT created_at FROM mcp_oauth_tokens WHERE server_name = ?),
                ?
            ), ?)
            """,
            (
                server_name,
                access_token,
                refresh_token,
                token_type,
                expires_at_str,
                scopes_str,
                server_name,
                now,
                now,
            ),
        )
        await self.connection.commit()

    async def get_oauth_token(self, server_name: str) -> Optional[dict[str, Any]]:
        """Get OAuth token for an MCP server."""
        async with self.connection.execute(
            "SELECT * FROM mcp_oauth_tokens WHERE server_name = ?",
            (server_name,),
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                result = dict(row)
                # Parse expires_at back to datetime
                if result.get("expires_at"):
                    try:
                        result["expires_at"] = datetime.fromisoformat(result["expires_at"])
                    except ValueError:
                        result["expires_at"] = None
                # Parse scopes back to list
                if result.get("scopes"):
                    result["scopes"] = result["scopes"].split(",")
                else:
                    result["scopes"] = []
                return result
            return None

    async def delete_oauth_token(self, server_name: str) -> bool:
        """Delete OAuth token for an MCP server (logout)."""
        cursor = await self.connection.execute(
            "DELETE FROM mcp_oauth_tokens WHERE server_name = ?",
            (server_name,),
        )
        await self.connection.commit()
        return cursor.rowcount > 0

    async def is_token_expired(self, server_name: str) -> bool:
        """Check if an OAuth token is expired."""
        token = await self.get_oauth_token(server_name)
        if not token:
            return True
        expires_at = token.get("expires_at")
        if not expires_at:
            return False  # No expiry means it doesn't expire
        return datetime.now(timezone.utc) >= expires_at

    async def list_oauth_tokens(self) -> list[dict[str, Any]]:
        """List all stored OAuth tokens (without exposing actual tokens)."""
        async with self.connection.execute(
            """
            SELECT server_name, token_type, expires_at, scopes, created_at, updated_at
            FROM mcp_oauth_tokens
            ORDER BY updated_at DESC
            """
        ) as cursor:
            rows = await cursor.fetchall()
            result = []
            for row in rows:
                token_info = dict(row)
                if token_info.get("expires_at"):
                    try:
                        token_info["expires_at"] = datetime.fromisoformat(token_info["expires_at"])
                    except ValueError:
                        token_info["expires_at"] = None
                if token_info.get("scopes"):
                    token_info["scopes"] = token_info["scopes"].split(",")
                else:
                    token_info["scopes"] = []
                result.append(token_info)
            return result

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

        return Session(
            id=row["id"],
            title=row["title"],
            module=row["module"],
            source=SessionSource(row["source"]),
            working_directory=row["working_directory"],
            model=row["model"],
            message_count=row["message_count"],
            archived=bool(row["archived"]),
            created_at=datetime.fromisoformat(row["created_at"]),
            last_accessed=datetime.fromisoformat(row["last_accessed"]),
            continued_from=row["continued_from"],
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
