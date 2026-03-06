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


# ---------------------------------------------------------------------------
# Schema v2: rename tables to new ontology (Projects / Chats / Exchange / Note)
# ---------------------------------------------------------------------------


async def migrate_schema_v2(graph) -> bool:
    """
    One-time migration renaming tables to match the v2 ontology:
      Parachute_Session    → Chat  (container_env_id → project_id)
      Parachute_ContainerEnv → Project     (+ core_memory field added)
      Chat_Session         → dropped       (Chat is authoritative)
      Chat_Exchange        → Exchange
      Journal_Entry        → Note          (+ note_type, aliases, status, created_by)
      Day                  → dropped       (query by date field directly)

    Runs once, detected by presence of old table names.
    Returns True if migration ran.
    """
    old_cols = await graph.get_table_columns("Parachute_Session")
    if not old_cols:
        return False  # Already migrated

    logger.info("Schema v2 migration: renaming tables to new ontology ...")

    # 1. Migrate Parachute_ContainerEnv → Project
    env_cols = await graph.get_table_columns("Parachute_ContainerEnv")
    if env_cols:
        env_rows = await graph.execute_cypher(
            "MATCH (e:Parachute_ContainerEnv) RETURN e"
        )
        for row in env_rows:
            try:
                async with graph.write_lock:
                    await graph._execute(
                        "MERGE (p:Project {slug: $slug}) "
                        "ON CREATE SET p.display_name = $display_name, "
                        "p.core_memory = $core_memory, p.created_at = $created_at",
                        {
                            "slug": row["slug"],
                            "display_name": row.get("display_name", ""),
                            "core_memory": None,
                            "created_at": row.get("created_at", ""),
                        },
                    )
            except Exception as e:
                logger.warning(f"  Project migration failed for {row.get('slug')}: {e}")
        async with graph.write_lock:
            await graph._execute("MATCH (e:Parachute_ContainerEnv) DETACH DELETE e")
        try:
            await graph._execute("DROP TABLE Parachute_ContainerEnv")
        except Exception:
            pass
        logger.info(f"  Migrated {len(env_rows)} Project nodes")

    # 2. Migrate Parachute_Session → Chat
    session_rows = await graph.execute_cypher(
        "MATCH (s:Parachute_Session) RETURN s"
    )
    for row in session_rows:
        try:
            async with graph.write_lock:
                await graph._execute(
                """
                MERGE (c:Chat {session_id: $session_id})
                ON CREATE SET
                    c.title = $title,
                    c.module = $module,
                    c.source = $source,
                    c.working_directory = $working_directory,
                    c.model = $model,
                    c.message_count = $message_count,
                    c.archived = $archived,
                    c.created_at = $created_at,
                    c.last_accessed = $last_accessed,
                    c.continued_from = $continued_from,
                    c.agent_type = $agent_type,
                    c.trust_level = $trust_level,
                    c.mode = $mode,
                    c.linked_bot_platform = $linked_bot_platform,
                    c.linked_bot_chat_id = $linked_bot_chat_id,
                    c.linked_bot_chat_type = $linked_bot_chat_type,
                    c.parent_session_id = $parent_session_id,
                    c.created_by = $created_by,
                    c.summary = $summary,
                    c.bridge_session_id = $bridge_session_id,
                    c.bridge_context_log = $bridge_context_log,
                    c.project_id = $project_id,
                    c.metadata_json = $metadata_json,
                    c.tags_json = $tags_json,
                    c.contexts_json = $contexts_json
                """,
                {
                    "session_id": row["session_id"],
                    "title": row.get("title"),
                    "module": row.get("module", "chat"),
                    "source": row.get("source", "parachute"),
                    "working_directory": row.get("working_directory"),
                    "model": row.get("model"),
                    "message_count": row.get("message_count", 0) or 0,
                    "archived": bool(row.get("archived", False)),
                    "created_at": row.get("created_at", ""),
                    "last_accessed": row.get("last_accessed", ""),
                    "continued_from": row.get("continued_from"),
                    "agent_type": row.get("agent_type"),
                    "trust_level": row.get("trust_level"),
                    "mode": row.get("mode"),
                    "linked_bot_platform": row.get("linked_bot_platform"),
                    "linked_bot_chat_id": row.get("linked_bot_chat_id"),
                    "linked_bot_chat_type": row.get("linked_bot_chat_type"),
                    "parent_session_id": row.get("parent_session_id"),
                    "created_by": row.get("created_by") or "user",
                    "summary": row.get("summary"),
                    "bridge_session_id": row.get("bridge_session_id"),
                    "bridge_context_log": row.get("bridge_context_log"),
                    # container_env_id → project_id
                    "project_id": row.get("container_env_id"),
                    "metadata_json": row.get("metadata_json"),
                    "tags_json": row.get("tags_json") or "[]",
                    "contexts_json": row.get("contexts_json") or "[]",
                },
            )
        except Exception as e:
            logger.warning(f"  Chat migration failed for {row.get('session_id')}: {e}")

    async with graph.write_lock:
        await graph._execute("MATCH (s:Parachute_Session) DETACH DELETE s")
    # Drop old HAS_EXCHANGE rel table (Chat_Session→Chat_Exchange) before dropping node table
    old_has_exchange = await graph.get_table_columns("HAS_EXCHANGE")
    if old_has_exchange:
        try:
            await graph._execute("DROP TABLE HAS_EXCHANGE")
        except Exception:
            pass
    try:
        await graph._execute("DROP TABLE Parachute_Session")
    except Exception:
        pass
    logger.info(f"  Migrated {len(session_rows)} Chat nodes")

    # 3. Migrate Chat_Exchange → Exchange
    exchange_cols = await graph.get_table_columns("Chat_Exchange")
    if exchange_cols:
        # Create Exchange table and HAS_EXCHANGE rel NOW — modules haven't loaded yet
        await graph.ensure_node_table(
            "Exchange",
            {
                "exchange_id": "STRING",
                "session_id": "STRING",
                "exchange_number": "STRING",
                "description": "STRING",
                "user_message": "STRING",
                "ai_response": "STRING",
                "context": "STRING",
                "session_title": "STRING",
                "tools_used": "STRING",
                "created_at": "STRING",
            },
            primary_key="exchange_id",
        )
        await graph.ensure_rel_table("HAS_EXCHANGE", "Chat", "Exchange")

        exchange_rows = await graph.execute_cypher(
            "MATCH (e:Chat_Exchange) RETURN e"
        )
        for row in exchange_rows:
            try:
                async with graph.write_lock:
                    await graph._execute(
                        """
                        MERGE (e:Exchange {exchange_id: $exchange_id})
                        ON CREATE SET
                            e.session_id = $session_id,
                            e.exchange_number = $exchange_number,
                            e.description = $description,
                            e.user_message = $user_message,
                            e.ai_response = $ai_response,
                            e.context = $context,
                            e.session_title = $session_title,
                            e.tools_used = $tools_used,
                            e.created_at = $created_at
                        """,
                        {
                            "exchange_id": row["exchange_id"],
                            "session_id": row.get("session_id"),
                            "exchange_number": row.get("exchange_number"),
                            "description": row.get("description"),
                            "user_message": row.get("user_message"),
                            "ai_response": row.get("ai_response"),
                            "context": row.get("context"),
                            "session_title": row.get("session_title"),
                            "tools_used": row.get("tools_used"),
                            "created_at": row.get("created_at", ""),
                        },
                    )
            except Exception as e:
                logger.warning(f"  Exchange migration failed for {row.get('exchange_id')}: {e}")

        # Recreate HAS_EXCHANGE rels (Chat → Exchange)
        try:
            async with graph.write_lock:
                await graph._execute(
                    "MATCH (c:Chat), (e:Exchange) "
                    "WHERE c.session_id = e.session_id "
                    "MERGE (c)-[:HAS_EXCHANGE]->(e)"
                )
        except Exception as e:
            logger.warning(f"  HAS_EXCHANGE rel recreation failed: {e}")

        async with graph.write_lock:
            await graph._execute("MATCH (e:Chat_Exchange) DETACH DELETE e")
        try:
            await graph._execute("DROP TABLE Chat_Exchange")
        except Exception:
            pass
        # Drop old Chat_Session shadow table
        chat_session_cols = await graph.get_table_columns("Chat_Session")
        if chat_session_cols:
            async with graph.write_lock:
                await graph._execute("MATCH (s:Chat_Session) DETACH DELETE s")
            try:
                await graph._execute("DROP TABLE Chat_Session")
            except Exception:
                pass
        logger.info(f"  Migrated {len(exchange_rows)} Exchange nodes")

    # 4. Migrate Journal_Entry → Note
    journal_cols = await graph.get_table_columns("Journal_Entry")
    if journal_cols:
        journal_rows = await graph.execute_cypher(
            "MATCH (e:Journal_Entry) RETURN e"
        )
        for row in journal_rows:
            try:
                async with graph.write_lock:
                    await graph._execute(
                        """
                        MERGE (n:Note {entry_id: $entry_id})
                        ON CREATE SET
                            n.note_type = $note_type,
                            n.date = $date,
                            n.content = $content,
                            n.snippet = $snippet,
                            n.title = $title,
                            n.entry_type = $entry_type,
                            n.audio_path = $audio_path,
                            n.aliases = $aliases,
                            n.status = $status,
                            n.created_by = $created_by,
                            n.brain_links_json = $brain_links_json,
                            n.metadata_json = $metadata_json,
                            n.created_at = $created_at
                        """,
                        {
                            "entry_id": row["entry_id"],
                            "note_type": row.get("entry_type") or "journal",
                            "date": row.get("date"),
                            "content": row.get("content"),
                            "snippet": row.get("snippet"),
                            "title": row.get("title"),
                            "entry_type": row.get("entry_type"),
                            "audio_path": row.get("audio_path"),
                            "aliases": "[]",
                            "status": "active",
                            "created_by": "user",
                            "brain_links_json": row.get("brain_links_json"),
                            "metadata_json": row.get("metadata_json"),
                            "created_at": row.get("created_at", ""),
                        },
                    )
            except Exception as e:
                logger.warning(f"  Note migration failed for {row.get('entry_id')}: {e}")

        # Drop rel tables before node tables (Kuzu requirement)
        for rel_table in ("HAS_ENTRY", "HAS_CARD"):
            if await graph.get_table_columns(rel_table):
                try:
                    await graph._execute(f"DROP TABLE {rel_table}")
                except Exception:
                    pass

        async with graph.write_lock:
            await graph._execute("MATCH (e:Journal_Entry) DETACH DELETE e")
        try:
            await graph._execute("DROP TABLE Journal_Entry")
        except Exception:
            pass

        # Drop Day nodes and rel tables (no longer needed)
        day_cols = await graph.get_table_columns("Day")
        if day_cols:
            async with graph.write_lock:
                await graph._execute("MATCH (d:Day) DETACH DELETE d")
            try:
                await graph._execute("DROP TABLE Day")
            except Exception:
                pass

        logger.info(f"  Migrated {len(journal_rows)} Note nodes")

    logger.info("Schema v2 migration complete.")
    return True
