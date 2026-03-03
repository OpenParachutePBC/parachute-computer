"""
One-time migration from ~/Parachute/ vault to ~/.parachute/.

Called on first boot when the old vault exists but the new parachute_dir doesn't.
Uses Python's built-in sqlite3 (not aiosqlite) to read the legacy sessions.db.
"""

import json
import logging
import shutil
import sqlite3
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# File migration helpers
# ---------------------------------------------------------------------------


def _copy_if_exists(src: Path, dst: Path, chmod: Optional[int] = None) -> bool:
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
        logger.info(f"  Migrated config.yaml (vault_path key removed)")
        return True
    except Exception as e:
        logger.warning(f"  Failed to migrate config.yaml: {e}")
        return False


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
        logger.info(f"  Copied graph DB")

    # 3. JSONL transcripts
    old_sessions_dir = old_vault / ".claude"
    new_sessions_dir = parachute_dir / "sessions"
    if old_sessions_dir.exists():
        shutil.copytree(old_sessions_dir, new_sessions_dir, dirs_exist_ok=True)
        logger.info(f"  Copied SDK JSONL transcripts")

    # 4. Modules
    _copy_dir_if_exists(old_vault / ".modules", parachute_dir / "modules")

    # 5. Skills
    _copy_dir_if_exists(old_vault / ".skills", parachute_dir / "skills")

    # 6. MCP config
    _copy_if_exists(old_vault / ".mcp.json", parachute_dir / "mcp.json")

    logger.info(
        "Migration complete. ~/Parachute/ preserved — safe to archive or delete manually."
    )
    return True


# ---------------------------------------------------------------------------
# SQLite → Kuzu session migration
# ---------------------------------------------------------------------------


async def migrate_sqlite_to_graph(old_db_path: Path, session_store) -> int:
    """
    Read sessions from legacy SQLite sessions.db and import into GraphSessionStore.

    Uses Python's built-in sqlite3 (synchronous) since this runs once at startup.
    Returns the number of sessions migrated.
    """
    if not old_db_path.exists():
        return 0

    logger.info(f"Migrating SQLite sessions from {old_db_path} ...")
    count = 0
    skipped = 0

    try:
        conn = sqlite3.connect(str(old_db_path))
        conn.row_factory = sqlite3.Row

        # Check if the sessions table exists
        cursor = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'"
        )
        if not cursor.fetchone():
            logger.info("  No sessions table found — nothing to migrate")
            conn.close()
            return 0

        rows = conn.execute("SELECT * FROM sessions").fetchall()

        from parachute.models.session import Session, SessionSource

        for row in rows:
            try:
                row_dict = dict(row)
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

                from parachute.models.session import SessionCreate
                from datetime import datetime, timezone

                def _parse_dt(val) -> datetime:
                    if not val:
                        return datetime.now(timezone.utc)
                    if isinstance(val, (int, float)):
                        return datetime.fromtimestamp(val, tz=timezone.utc)
                    try:
                        return datetime.fromisoformat(str(val).replace("Z", "+00:00"))
                    except Exception:
                        return datetime.now(timezone.utc)

                session = Session(
                    id=session_id,
                    title=row_dict.get("title") or "Migrated Session",
                    module=row_dict.get("module") or "chat",
                    source=source,
                    working_directory=row_dict.get("working_directory"),
                    created_at=_parse_dt(row_dict.get("created_at")),
                    last_accessed=_parse_dt(row_dict.get("last_accessed") or row_dict.get("updated_at")),
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
        try:
            tags_rows = conn.execute("SELECT * FROM session_tags").fetchall()
            for row in tags_rows:
                row_dict = dict(row)
                sid = row_dict.get("session_id")
                tag = row_dict.get("tag")
                if sid and tag:
                    try:
                        await session_store.add_tag(sid, tag)
                    except Exception:
                        pass
            logger.info(f"  Migrated {len(tags_rows)} tags")
        except sqlite3.OperationalError:
            pass  # No tags table

        conn.close()

    except Exception as e:
        logger.error(f"SQLite migration failed: {e}", exc_info=True)
        return count

    logger.info(f"Migrated {count} sessions from SQLite to Kuzu ({skipped} skipped)")
    return count
