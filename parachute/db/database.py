"""
SQLite database for session management.

Provides async database operations using aiosqlite.
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

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

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_sessions_module ON sessions(module);
CREATE INDEX IF NOT EXISTS idx_sessions_archived ON sessions(archived);
CREATE INDEX IF NOT EXISTS idx_sessions_last_accessed ON sessions(last_accessed DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_created_at ON sessions(created_at DESC);

-- Schema version tracking
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

-- Insert initial version if not exists
INSERT OR IGNORE INTO schema_version (version, applied_at)
VALUES (1, datetime('now'));
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

    async def create_session(self, session: SessionCreate) -> Session:
        """Create a new session."""
        now = datetime.now(timezone.utc).isoformat()
        metadata_json = json.dumps(session.metadata) if session.metadata else None

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
                0,  # message_count starts at 0
                0,  # not archived
                now,
                now,
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
