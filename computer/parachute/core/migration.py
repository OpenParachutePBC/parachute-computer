"""
One-time migration from ~/Parachute/ vault to ~/.parachute/.

Called on first boot when the old vault exists but the new parachute_dir doesn't.
Uses Python's built-in sqlite3 (not aiosqlite) to read the legacy sessions.db.
"""

import asyncio
import json
import logging
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _parse_dt(val: Any) -> datetime:
    """Parse a datetime value from SQLite."""
    if not val:
        return datetime.now(timezone.utc)
    if isinstance(val, (int, float)):
        return datetime.fromtimestamp(val, tz=timezone.utc)
    try:
        return datetime.fromisoformat(str(val).replace("Z", "+00:00"))
    except Exception:
        return datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# File migration helpers (synchronous — called via asyncio.to_thread)
# ---------------------------------------------------------------------------


def _copy_if_exists(src: Path, dst: Path, chmod: int | None = None) -> bool:
    """Copy a file if it exists. Returns True if copied."""
    if not src.exists():
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if chmod is not None:
        dst.chmod(chmod)
    logger.info(f"  Copied {src.name} → {dst}")
    return True


def _copy_dir_if_exists(src: Path, dst: Path) -> bool:
    """Copy a directory tree if it exists. Returns True if copied."""
    if not src.exists():
        return False
    shutil.copytree(src, dst, dirs_exist_ok=True)
    logger.info(f"  Copied dir {src.name}/ → {dst}")
    return True


def _migrate_config(src: Path, dst: Path) -> bool:
    """Copy config YAML, stripping the legacy vault_path key."""
    if not src.exists():
        return False
    import yaml

    try:
        with open(src) as f:
            data = yaml.safe_load(f) or {}
        data.pop("vault_path", None)  # Remove legacy key
        dst.parent.mkdir(parents=True, exist_ok=True)
        with open(dst, "w") as f:
            yaml.safe_dump(data, f)
        logger.info("  Migrated config.yaml (vault_path key removed)")
        return True
    except Exception as e:
        logger.warning(f"  Failed to migrate config.yaml: {e}")
        return False


def _do_file_migration(old_parachute: Path, old_vault: Path, parachute_dir: Path) -> None:
    """Synchronous file copy work — run via asyncio.to_thread to avoid blocking."""
    parachute_dir.mkdir(parents=True, exist_ok=True)

    # 1. Config files
    _migrate_config(old_parachute / "config.yaml", parachute_dir / "config.yaml")
    _copy_if_exists(old_parachute / ".token", parachute_dir / ".token", chmod=0o600)
    _copy_if_exists(old_parachute / "module_hashes.json", parachute_dir / "module_hashes.json")
    _copy_dir_if_exists(old_parachute / "plugin-manifests", parachute_dir / "plugin-manifests")
    _copy_dir_if_exists(old_parachute / "logs", parachute_dir / "logs")

    # 2. Graph DB (Kuzu / LadybugDB)
    old_graph = old_vault / ".brain" / "brain.lbug"
    new_graph = parachute_dir / "graph" / "parachute.kz"
    if old_graph.exists():
        new_graph.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(old_graph, new_graph)
        _copy_if_exists(old_graph.parent / "brain.lbug.wal", new_graph.parent / "parachute.kz.wal")
        logger.info("  Copied graph DB")

    # 3. JSONL transcripts
    old_sessions_dir = old_vault / ".claude"
    new_sessions_dir = parachute_dir / "sessions"
    if old_sessions_dir.exists():
        shutil.copytree(old_sessions_dir, new_sessions_dir, dirs_exist_ok=True)
        logger.info("  Copied SDK JSONL transcripts")

    # 4. Modules
    _copy_dir_if_exists(old_vault / ".modules", parachute_dir / "modules")

    # 5. Skills
    _copy_dir_if_exists(old_vault / ".skills", parachute_dir / "skills")

    # 6. MCP config
    _copy_if_exists(old_vault / ".mcp.json", parachute_dir / "mcp.json")


# ---------------------------------------------------------------------------
# Top-level migration
# ---------------------------------------------------------------------------


async def migrate_if_needed(parachute_dir: Path) -> bool:
    """
    Run one-time migration from ~/Parachute/ if ~/.parachute/ doesn't exist.

    Returns True if migration ran, False if skipped (already migrated or no old vault).
    """
    old_vault = Path.home() / "Parachute"
    old_parachute = old_vault / ".parachute"

    if parachute_dir.exists():
        return False  # Already set up
    if not old_parachute.exists():
        return False  # No legacy vault to migrate

    logger.info("Migrating from ~/Parachute/ to ~/.parachute/ ...")
    await asyncio.to_thread(_do_file_migration, old_parachute, old_vault, parachute_dir)
    logger.info(
        "Migration complete. ~/Parachute/ preserved — safe to archive or delete manually."
    )
    return True


# ---------------------------------------------------------------------------
# SQLite → Kuzu session migration
# ---------------------------------------------------------------------------


def _read_sqlite_data(old_db_path: Path) -> tuple[list[dict], list[dict]]:
    """
    Read all sessions and tags from the legacy SQLite DB.

    Returns (session_rows, tag_rows) as plain dicts. Synchronous — call via
    asyncio.to_thread() to avoid blocking the event loop.
    """
    with sqlite3.connect(str(old_db_path)) as conn:
        conn.row_factory = sqlite3.Row

        cursor = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'"
        )
        if not cursor.fetchone():
            return [], []

        session_rows = [dict(r) for r in conn.execute("SELECT * FROM sessions").fetchall()]

        try:
            tag_rows = [dict(r) for r in conn.execute("SELECT * FROM session_tags").fetchall()]
        except sqlite3.OperationalError:
            tag_rows = []

    return session_rows, tag_rows


async def migrate_sqlite_to_graph(old_db_path: Path, session_store) -> int:
    """
    Read sessions from legacy SQLite sessions.db and import into GraphSessionStore.

    Returns the number of sessions migrated.
    """
    if not old_db_path.exists():
        return 0

    logger.info(f"Migrating SQLite sessions from {old_db_path} ...")
    count = 0
    skipped = 0

    try:
        session_rows, tag_rows = await asyncio.to_thread(_read_sqlite_data, old_db_path)
    except Exception as e:
        logger.error(f"SQLite migration failed to read data: {e}", exc_info=True)
        return 0

    if not session_rows:
        logger.info("  No sessions table found — nothing to migrate")
        return 0

    from parachute.models.session import Session, SessionCreate, SessionSource

    for row_dict in session_rows:
        try:
            session_id = row_dict.get("id") or row_dict.get("session_id")
            if not session_id:
                skipped += 1
                continue

            # Check if already exists
            existing = await session_store.get_session(session_id)
            if existing:
                skipped += 1
                continue

            # Parse metadata JSON
            metadata = row_dict.get("metadata")
            if isinstance(metadata, str):
                try:
                    metadata = json.loads(metadata)
                except Exception:
                    metadata = {}
            elif not isinstance(metadata, dict):
                metadata = {}

            # Parse source
            source_str = row_dict.get("source", "parachute")
            try:
                source = SessionSource(source_str)
            except ValueError:
                source = SessionSource.PARACHUTE

            session = Session(
                id=session_id,
                title=row_dict.get("title") or "Migrated Session",
                module=row_dict.get("module") or "chat",
                source=source,
                working_directory=row_dict.get("working_directory"),
                created_at=_parse_dt(row_dict.get("created_at")),
                last_accessed=_parse_dt(
                    row_dict.get("last_accessed") or row_dict.get("updated_at")
                ),
                message_count=int(row_dict.get("message_count") or 0),
                archived=bool(row_dict.get("archived") or False),
                metadata=metadata,
                summary=row_dict.get("summary"),
                trust_level=row_dict.get("trust_level"),
            )

            await session_store.create_session(session)
            count += 1

        except Exception as e:
            logger.warning(f"  Failed to migrate session {row_dict.get('id', '?')}: {e}")
            skipped += 1

    # Migrate tags
    tag_count = 0
    for row_dict in tag_rows:
        sid = row_dict.get("session_id")
        tag = row_dict.get("tag")
        if sid and tag:
            try:
                await session_store.add_tag(sid, tag)
                tag_count += 1
            except Exception:
                pass
    if tag_count:
        logger.info(f"  Migrated {tag_count} tags")

    logger.info(f"Migrated {count} sessions from SQLite to Kuzu ({skipped} skipped)")
    return count
