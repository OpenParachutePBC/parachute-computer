"""
Daily module — Journal entries with Kuzu graph as primary storage.

Provides CRUD operations for daily journal entries stored as nodes in the
shared Kuzu graph database. Audio and image files live on the server filesystem;
only metadata and content are stored in the graph.

Entry IDs are timestamp strings: "YYYY-MM-DD-HH-MM-SS-ffffff" (with microseconds)

Storage layout:
  ~/.parachute/graph/            ← Kuzu database (primary store, all modules share)
  ~/.parachute/daily/assets/     ← Audio/image files uploaded to server (absolute paths in graph)
"""

import asyncio
import json
import logging
import os
import re
import shutil
import tempfile
import uuid
from datetime import date as _date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Literal, Optional

from fastapi import APIRouter, Query, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel, field_validator

# Audio/image assets directory — fixed, not user-configurable
ASSETS_DIR = Path.home() / ".parachute" / "daily" / "assets"

# Append-only JSONL redo log for crash recovery (rolled to 90 days)
REDO_LOG_PATH = Path.home() / ".parachute" / "daily" / "entries.jsonl"

logger = logging.getLogger(__name__)


def _append_redo_log(
    entry_id: str,
    date: str,
    content: str,
    created_at: str,
    title: str,
    entry_type: str,
    audio_path: str,
    extra_meta: dict | None,
) -> None:
    """Append entry to JSONL redo log. Filesystem-only, never raises."""
    record = {
        "entry_id": entry_id,
        "date": date,
        "content": content,
        "created_at": created_at,
        "title": title,
        "entry_type": entry_type,
        "audio_path": audio_path,
        "extra_meta": extra_meta or {},
    }
    try:
        REDO_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with REDO_LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:
        logger.warning(f"Daily: redo log append failed: {e}")


def _trim_redo_log() -> list[dict]:
    """Remove entries older than 90 days and return the kept records.

    Uses an atomic write-to-temp + os.replace so a crash mid-trim cannot
    truncate the log. Never raises — returns an empty list on any error.
    """
    if not REDO_LOG_PATH.exists():
        return []
    cutoff = (datetime.now(timezone.utc) - timedelta(days=90)).strftime("%Y-%m-%d")
    try:
        kept_lines: list[str] = []
        kept_records: list[dict] = []
        for line in REDO_LOG_PATH.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
                if rec.get("date", "") >= cutoff:
                    kept_lines.append(line)
                    kept_records.append(rec)
            except json.JSONDecodeError:
                logger.warning(f"Daily: redo log corrupt line skipped: {line[:80]!r}")
        fd, tmp_path = tempfile.mkstemp(dir=REDO_LOG_PATH.parent, suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("\n".join(kept_lines) + ("\n" if kept_lines else ""))
            os.replace(tmp_path, REDO_LOG_PATH)
        except Exception:
            os.unlink(tmp_path)
            raise
        return kept_records
    except Exception as e:
        logger.warning(f"Daily: redo log trim failed: {e}")
        return []


class CreateEntryRequest(BaseModel):
    content: str
    metadata: Optional[dict] = None


class UpdateEntryRequest(BaseModel):
    content: Optional[str] = None
    metadata: Optional[dict] = None  # merged (not replaced) into existing metadata


class FlexibleImportRequest(BaseModel):
    source_dir: str
    format: Literal["parachute", "obsidian", "logseq", "plain"] = "parachute"
    dry_run: bool = False
    date_from: Optional[str] = None  # YYYY-MM-DD inclusive filter
    date_to: Optional[str] = None    # YYYY-MM-DD inclusive filter

    @field_validator("date_from", "date_to", mode="before")
    @classmethod
    def validate_date(cls, v: str | None) -> str | None:
        if v is None:
            return v
        try:
            datetime.strptime(v, "%Y-%m-%d")
        except ValueError:
            raise ValueError("must be YYYY-MM-DD")
        return v


class DailyModule:
    """Daily module for journal entry management. Kuzu graph is primary storage."""

    name = "daily"
    provides = []

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path

    async def on_load(self) -> None:
        """Register Daily schema in shared graph."""
        from parachute.core.interfaces import get_registry
        graph = get_registry().get("BrainDB")
        if graph is None:
            logger.warning("Daily: BrainDB not in registry — module will not function")
            return

        # Ensure schema tables exist
        await graph.ensure_node_table(
            "Note",
            {
                "entry_id": "STRING",
                "note_type": "STRING",   # "journal", "meeting", "reference", etc.
                "date": "STRING",
                "content": "STRING",
                "snippet": "STRING",
                "created_at": "STRING",
                "title": "STRING",
                "entry_type": "STRING",  # kept for audio-type compat ("text", "audio")
                "audio_path": "STRING",
                "aliases": "STRING",     # JSON array
                "status": "STRING",      # "active", "archived", etc.
                "created_by": "STRING",  # "user", "agent", "import"
                "metadata_json": "STRING",
                "brain_links_json": "STRING",
            },
            primary_key="entry_id",
        )
        await graph.ensure_node_table(
            "Card",
            {
                "card_id": "STRING",       # PK: "{agent_name}:{date}" — idempotent MERGE
                "agent_name": "STRING",
                "display_name": "STRING",
                "content": "STRING",       # markdown body
                "generated_at": "STRING",  # ISO timestamp
                "status": "STRING",        # "running" | "done" | "failed"
                "date": "STRING",          # YYYY-MM-DD (the day this card is for)
            },
            primary_key="card_id",
        )
        # No Day table or HAS_ENTRY/HAS_CARD rels — query Note/Card by date field directly
        await graph.ensure_node_table(
            "Caller",
            {
                "name": "STRING",           # PK: agent name, e.g. "reflection"
                "display_name": "STRING",
                "description": "STRING",
                "system_prompt": "STRING",  # full markdown body
                "tools": "STRING",          # JSON array string
                "model": "STRING",
                "schedule_enabled": "STRING",  # "true" / "false"
                "schedule_time": "STRING",  # "HH:MM"
                "enabled": "STRING",        # "true" / "false"
                "trust_level": "STRING",    # "sandboxed" (default) | "direct"
                "created_at": "STRING",
                "updated_at": "STRING",
                # Runtime state (previously in DailyAgentState JSON files)
                "sdk_session_id": "STRING",      # Claude SDK session ID for resume
                "last_run_at": "STRING",         # ISO timestamp of last completed run
                "last_processed_date": "STRING", # YYYY-MM-DD of last processed journal date
                "run_count": "INT64",            # Total number of completed runs
            },
            primary_key="name",
        )

        # Add new columns to existing databases (idempotent schema migration)
        await self._ensure_new_columns(graph)

        # Migrate relative audio paths to absolute (one-time, idempotent)
        await self._migrate_audio_paths_to_absolute(graph)

        # Trim redo log (90-day rolling), then replay any entries missing from graph
        redo_records = _trim_redo_log()
        await self._recover_from_redo_log(graph, redo_records)

        logger.info("Daily: graph schema ready (Kuzu primary storage)")

    async def _ensure_new_columns(self, graph) -> None:
        """Add columns introduced in the Kuzu-primary migration to existing databases."""
        existing = await graph.get_table_columns("Note")
        new_cols = {
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
        missing = {col: typ for col, typ in new_cols.items() if col not in existing}
        if missing:
            async with graph.write_lock:
                for col, typ in missing.items():
                    await graph.execute_cypher(
                        f"ALTER TABLE Note ADD {col} {typ} DEFAULT NULL"
                    )
                    logger.info(f"Daily: added column Note.{col}")

        # Caller table migrations
        try:
            caller_cols = await graph.get_table_columns("Caller")
            caller_new = {
                "trust_level": ("STRING", "'sandboxed'"),
                "sdk_session_id": ("STRING", "''"),
                "last_run_at": ("STRING", "''"),
                "last_processed_date": ("STRING", "''"),
                "run_count": ("INT64", "0"),
            }
            for col, (typ, default) in caller_new.items():
                if col not in caller_cols:
                    async with graph.write_lock:
                        await graph.execute_cypher(
                            f"ALTER TABLE Caller ADD {col} {typ} DEFAULT {default}"
                        )
                        logger.info(f"Daily: added column Caller.{col}")
        except Exception:
            pass  # Caller table may not exist yet on first run

    async def _migrate_audio_paths_to_absolute(self, graph) -> None:
        """One-time: convert relative audio_path values in graph to absolute.

        Already-absolute paths (starting with '/') are skipped. Tries known
        legacy roots in order; logs entries where no file is found.
        """
        rows = await graph.execute_cypher(
            "MATCH (e:Note) "
            "WHERE e.audio_path IS NOT NULL AND e.audio_path <> '' "
            "AND NOT e.audio_path STARTS WITH '/' "
            "RETURN e.entry_id AS entry_id, e.audio_path AS audio_path"
        )
        if not rows:
            return

        legacy_roots = [
            Path.home() / "Parachute" / "Daily",
            Path.home() / "Daily",
            ASSETS_DIR.parent,  # ~/.parachute/daily
        ]

        migrated = 0
        missing = 0
        for row in rows:
            eid = row["entry_id"]
            rel_path = row["audio_path"]
            resolved = None
            for root in legacy_roots:
                candidate = root / rel_path
                if candidate.exists():
                    resolved = str(candidate)
                    break
            if resolved:
                async with graph.write_lock:
                    await graph.execute_cypher(
                        "MATCH (e:Note {entry_id: $id}) SET e.audio_path = $path",
                        {"id": eid, "path": resolved},
                    )
                migrated += 1
            else:
                logger.debug(f"Daily: audio not found for entry {eid!r}: {rel_path!r}")
                missing += 1

        if migrated or missing:
            logger.info(
                f"Daily: migrated {migrated} audio paths to absolute "
                f"({missing} not found on disk)"
            )

    async def _recover_from_redo_log(self, graph, records: list[dict]) -> None:
        """Replay any redo log entries that are missing from the graph.

        Accepts the records already parsed by _trim_redo_log (no second file read).
        Runs on every startup — safe because _write_to_graph uses MERGE (idempotent).
        Normally a no-op. Activates after WAL corruption or abrupt power loss.

        Note: entries are appended to the redo log *after* a successful graph write,
        so this log recovers WAL-loss scenarios (existing WAL discarded on startup),
        not mid-write crashes.
        """
        if not records:
            return

        # Check each entry individually with parameterized queries (no string interpolation)
        existing_ids: set[str] = set()
        try:
            for rec in records:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) RETURN e.entry_id AS entry_id",
                    {"entry_id": rec["entry_id"]},
                )
                if rows:
                    existing_ids.add(rec["entry_id"])
        except Exception as e:
            logger.warning(f"Daily: redo log recovery query failed: {e}")
            return

        missing_records = [r for r in records if r["entry_id"] not in existing_ids]
        if not missing_records:
            return

        logger.warning(
            f"Daily: redo log recovery — replaying {len(missing_records)} "
            f"entries missing from graph (likely WAL loss)"
        )
        recovered = 0
        for rec in missing_records:
            try:
                await self._write_to_graph(
                    graph,
                    entry_id=rec["entry_id"],
                    date=rec["date"],
                    content=rec["content"],
                    created_at=rec["created_at"],
                    title=rec.get("title", ""),
                    entry_type=rec.get("entry_type", "text"),
                    audio_path=rec.get("audio_path", ""),
                    extra_meta=rec.get("extra_meta"),
                )
                recovered += 1
            except Exception as e:
                logger.warning(f"Daily: redo log recovery failed for {rec['entry_id']!r}: {e}")
        logger.warning(
            f"Daily: redo log recovery complete — {recovered}/{len(missing_records)} entries recovered"
        )

    @staticmethod
    def _sanitize_fm_value(v: Any) -> Any:
        """Convert PyYAML-parsed date/datetime objects to ISO strings."""
        if isinstance(v, (_date, datetime)):
            return v.isoformat()
        return v

    def _parse_md_file(self, md_file: Path) -> list[dict]:
        """
        Parse a journal markdown file into a list of entry dicts.

        Handles three formats that evolved over time:
          1. Plain markdown (pre-Dec 2025): no frontmatter, single block
             → one entry, entry_id = file stem
          2. Frontmatter + plain sections (Dec 15 2025 style): ``assets:`` key,
             sections separated by ``\\n---\\n`` but no ``# para:`` headers
             → one entry per section, first gets stem as ID, rest get stem-N
          3. Frontmatter + entries map + para headers (Dec 20 2025+):
             ``entries:`` map keyed by para_id, sections start with
             ``# para:{id} {time}``
             → one entry per section, entry_id = para_id, audio_path from map

        Each returned dict has keys matching _write_to_graph kwargs:
        entry_id, date, content, created_at, title, entry_type, audio_path,
        brain_links, extra_meta.
        """
        raw = md_file.read_text(encoding="utf-8", errors="replace")
        file_stem = md_file.stem
        file_date = file_stem[:10]

        meta: dict = {}
        content_block = raw
        if raw.startswith("---\n"):
            try:
                import frontmatter as fm
                post = fm.loads(raw)
                meta = {k: self._sanitize_fm_value(v) for k, v in post.metadata.items()}
                content_block = post.content or ""
            except ImportError:
                pass

        date_raw = meta.get("date", "")
        date = str(date_raw)[:10] if date_raw else file_date

        # entries: map from frontmatter — keyed by para_id
        entries_fm: dict = meta.get("entries") or {}

        # Split on bare --- lines (section separators used in these journals).
        # python-frontmatter strips the trailing newline, so the last separator
        # may be "\n---" with no following newline — use (?:\n|$) to handle both.
        sections = [s.strip() for s in re.split(r'\n---(?:\n|$)', content_block) if s.strip()]
        if not sections:
            return []

        # Detect # para:{id} {time} section headers
        para_re = re.compile(r'^#\s+para:([^\s]+)(?:\s+(\d{1,2}:\d{2}))?')

        result = []
        for i, section in enumerate(sections):
            m = para_re.match(section)
            if m:
                para_id = m.group(1)
                time_str = m.group(2)
                section_content = section[m.end():].strip()

                fm_entry: dict = entries_fm.get(para_id) or {}
                entry_type = fm_entry.get("type", "text") or "text"
                audio_path = fm_entry.get("audio", "") or ""
                duration = fm_entry.get("duration")

                # "created" in YAML can be parsed as sexagesimal int by PyYAML
                created_raw = fm_entry.get("created", time_str or "")
                if isinstance(created_raw, int):
                    created_time = f"{created_raw // 60:02d}:{created_raw % 60:02d}"
                elif created_raw:
                    created_time = str(created_raw).strip()
                else:
                    created_time = time_str or "00:00"

                entry_id = para_id
                title = created_time  # e.g. "10:13" — shown in UI header
            else:
                # No para header: generate IDs from stem
                entry_id = file_stem if i == 0 else f"{file_stem}-{i}"
                section_content = section
                entry_type = "text"
                audio_path = ""
                duration = None
                created_time = "00:00"
                title = ""

            t = created_time.strip()
            if len(t) == 5:   # HH:MM
                created_at = f"{date}T{t}:00+00:00"
            elif t:
                created_at = f"{date}T{t}+00:00"
            else:
                created_at = f"{date}T00:00:00+00:00"

            extra_meta: dict = {}
            if duration is not None:
                extra_meta["duration_seconds"] = int(duration)

            result.append({
                "entry_id": entry_id,
                "date": date,
                "content": section_content,
                "created_at": created_at,
                "title": title,
                "entry_type": entry_type,
                "audio_path": audio_path,
                "brain_links": [],
                "extra_meta": extra_meta,
            })

        return result

    # ── Graph helpers ─────────────────────────────────────────────────────────

    def _get_graph(self):
        """Return BrainDB from registry, or None if unavailable."""
        from parachute.core.interfaces import get_registry
        return get_registry().get("BrainDB")

    async def _write_to_graph(
        self,
        graph,
        *,
        entry_id: str,
        date: str,
        content: str,
        created_at: str,
        title: str = "",
        entry_type: str = "text",
        audio_path: str = "",
        extra_meta: dict | None = None,
    ) -> None:
        """Write (MERGE) a Note node. Date-based grouping via note.date field (no Day node)."""
        snippet = content[:200]
        brain_links_json = json.dumps([])
        metadata_json = json.dumps(extra_meta or {})

        async with graph.write_lock:
            # MERGE Note — ON CREATE SET protects original timestamp
            await graph.execute_cypher(
                "MERGE (e:Note {entry_id: $entry_id}) "
                "ON CREATE SET e.created_at = $created_at, "
                "    e.note_type = $note_type, e.aliases = $aliases, "
                "    e.status = $status, e.created_by = $created_by "
                "SET e.date = $date, e.content = $content, e.snippet = $snippet, "
                "    e.title = $title, e.entry_type = $entry_type, "
                "    e.audio_path = $audio_path, "
                "    e.metadata_json = $metadata_json, "
                "    e.brain_links_json = $brain_links_json",
                {
                    "entry_id": entry_id,
                    "date": date,
                    "content": content,
                    "snippet": snippet,
                    "created_at": created_at,
                    "title": title,
                    "entry_type": entry_type,
                    "audio_path": audio_path,
                    "note_type": "journal",
                    "aliases": "[]",
                    "status": "active",
                    "created_by": "user",
                    "metadata_json": metadata_json,
                    "brain_links_json": brain_links_json,
                },
            )

    def _row_to_entry(self, row: dict) -> dict:
        """Convert a Kuzu Note node dict to the API response shape."""
        entry_id = row.get("entry_id", "")
        content = row.get("content", "")
        title = row.get("title") or ""
        entry_type = row.get("entry_type") or "text"
        audio_path = row.get("audio_path") or ""

        # Reconstruct metadata dict — Flutter reads: type, title, audio_path, image_path, duration_seconds
        meta: dict[str, Any] = {
            "entry_id": entry_id,
            "created_at": row.get("created_at", ""),
            "title": title,
            "type": entry_type,
            "audio_path": audio_path,
        }

        # Merge extra fields from JSON blob (image_path, duration_seconds, etc.)
        metadata_json = row.get("metadata_json") or ""
        if metadata_json:
            try:
                meta.update(json.loads(metadata_json))
            except (json.JSONDecodeError, TypeError):
                pass

        # Brain links
        brain_links_json = row.get("brain_links_json") or ""
        brain_links: list = []
        if brain_links_json:
            try:
                brain_links = json.loads(brain_links_json)
            except (json.JSONDecodeError, TypeError):
                pass

        return {
            "id": entry_id,
            "created_at": row.get("created_at", ""),
            "content": content,
            "snippet": row.get("snippet") or content[:200],
            "metadata": meta,
            "brain_links": brain_links,
        }

    # ── CRUD ──────────────────────────────────────────────────────────────────

    async def create_entry(self, content: str, metadata: dict[str, Any] | None = None) -> dict:
        """Create a new daily entry in the graph. Returns {id, created_at}."""
        graph = self._get_graph()
        if graph is None:
            raise RuntimeError("BrainDB unavailable — cannot create entry")

        now = datetime.now(timezone.utc)
        entry_id = now.strftime("%Y-%m-%d-%H-%M-%S-%f")
        # Use local wall-clock date so entries group under the day the user
        # experienced them (e.g. 8pm local = next UTC day in US timezones).
        date = datetime.now().strftime("%Y-%m-%d")
        created_at = now.isoformat()

        meta = metadata or {}
        title = meta.get("title", "")
        entry_type = meta.get("type", "text")
        audio_path = meta.get("audio_path", "") or ""

        # Extra metadata (image_path, duration_seconds, etc.)
        known = {"title", "type", "audio_path"}
        extra_meta = {k: v for k, v in meta.items() if k not in known}

        await self._write_to_graph(
            graph,
            entry_id=entry_id,
            date=date,
            content=content,
            created_at=created_at,
            title=title,
            entry_type=entry_type,
            audio_path=audio_path,
            extra_meta=extra_meta,
        )
        _append_redo_log(entry_id, date, content, created_at, title, entry_type, audio_path, extra_meta)

        logger.info(f"Daily: created entry {entry_id}")
        return {
            "id": entry_id,
            "created_at": created_at,
        }

    async def update_entry(
        self, entry_id: str, content: str | None = None, metadata: dict | None = None
    ) -> Optional[dict]:
        """
        Update content and/or metadata of an existing entry.

        Returns the updated entry dict, or None if the entry does not exist.
        Raises on graph errors so the route can return 500 (not 404).
        """
        graph = self._get_graph()
        if graph is None:
            raise RuntimeError("BrainDB unavailable — cannot update entry")

        # Check existence
        rows = await graph.execute_cypher(
            "MATCH (e:Note {entry_id: $entry_id}) RETURN e",
            {"entry_id": entry_id},
        )
        if not rows:
            return None  # 404

        row = rows[0]

        # Merge updates
        new_content = content if content is not None else (row.get("content") or "")
        new_snippet = new_content[:200]

        # Merge metadata fields
        if metadata:
            if "title" in metadata:
                row["title"] = metadata["title"]
            if "type" in metadata:
                row["entry_type"] = metadata["type"]
            if "audio_path" in metadata:
                row["audio_path"] = metadata["audio_path"]

            # Merge remaining fields into metadata_json blob
            known = {"title", "type", "audio_path"}
            extra_updates = {k: v for k, v in metadata.items() if k not in known}
            if extra_updates:
                existing_blob = row.get("metadata_json") or ""
                try:
                    existing_extra = json.loads(existing_blob) if existing_blob else {}
                except (json.JSONDecodeError, TypeError):
                    existing_extra = {}
                existing_extra.update(extra_updates)
                row["metadata_json"] = json.dumps(existing_extra)

        async with graph.write_lock:
            await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $entry_id}) "
                "SET e.content = $content, e.snippet = $snippet, "
                "    e.title = $title, e.entry_type = $entry_type, "
                "    e.audio_path = $audio_path, e.metadata_json = $metadata_json",
                {
                    "entry_id": entry_id,
                    "content": new_content,
                    "snippet": new_snippet,
                    "title": row.get("title") or "",
                    "entry_type": row.get("entry_type") or "text",
                    "audio_path": row.get("audio_path") or "",
                    "metadata_json": row.get("metadata_json") or "{}",
                },
            )

        logger.info(f"Daily: updated entry {entry_id}")
        row["content"] = new_content
        row["snippet"] = new_snippet
        return self._row_to_entry(row)

    async def delete_entry(self, entry_id: str) -> bool:
        """Delete an entry node and all its edges. Returns True on success (including 404)."""
        graph = self._get_graph()
        if graph is None:
            raise RuntimeError("BrainDB unavailable — cannot delete entry")

        rows = await graph.execute_cypher(
            "MATCH (e:Note {entry_id: $entry_id}) RETURN e.entry_id AS entry_id",
            {"entry_id": entry_id},
        )
        if not rows:
            return True  # already gone — idempotent

        try:
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) DETACH DELETE e",
                    {"entry_id": entry_id},
                )
            logger.info(f"Daily: deleted entry {entry_id}")
            return True
        except Exception as e:
            logger.error(f"Daily: delete failed for {entry_id}: {e}")
            return False

    async def list_entries(self, limit: int = 20, offset: int = 0, date: str | None = None) -> list[dict]:
        """List entries, optionally filtered by date (YYYY-MM-DD). Newest first."""
        graph = self._get_graph()
        if graph is None:
            return []

        if date:
            rows = await graph.execute_cypher(
                "MATCH (e:Note) WHERE e.date = $date "
                "RETURN e ORDER BY e.created_at ASC",
                {"date": date},
            )
        else:
            rows = await graph.execute_cypher(
                "MATCH (e:Note) RETURN e ORDER BY e.created_at DESC"
            )

        return [self._row_to_entry(r) for r in rows[offset: offset + limit]]

    async def get_entry(self, entry_id: str) -> Optional[dict]:
        """Get a specific entry by ID."""
        graph = self._get_graph()
        if graph is None:
            return None

        rows = await graph.execute_cypher(
            "MATCH (e:Note {entry_id: $entry_id}) RETURN e",
            {"entry_id": entry_id},
        )
        if not rows:
            return None
        return self._row_to_entry(rows[0])

    async def search_entries(self, query: str, limit: int = 30) -> list[dict]:
        """Keyword search across content and title of all entries. Returns results with snippet and match_count."""
        if not query.strip():
            return []

        query_lower = query.lower()
        query_terms = [t for t in query_lower.split() if len(t) > 1]
        if not query_terms:
            return []

        graph = self._get_graph()
        if graph is None:
            return []

        all_rows = await graph.execute_cypher(
            "MATCH (e:Note) RETURN e ORDER BY e.created_at DESC"
        )

        results = []
        for row in all_rows:
            content = row.get("content") or ""
            title = row.get("title") or ""
            content_lower = content.lower()
            title_lower = title.lower()
            match_count = sum(
                content_lower.count(term) + title_lower.count(term)
                for term in query_terms
            )
            if match_count == 0:
                continue
            snippet = self._extract_snippet(content, content_lower, query_terms)
            entry = self._row_to_entry(row)
            entry["snippet"] = snippet
            entry["match_count"] = match_count
            results.append(entry)

        results.sort(key=lambda r: (r["match_count"], r.get("created_at", "")), reverse=True)
        return results[:limit]

    def _extract_snippet(self, content: str, content_lower: str, query_terms: list[str]) -> str:
        """Extract a ~210-char context window around the first match."""
        first_pos = len(content)
        for term in query_terms:
            pos = content_lower.find(term)
            if pos != -1 and pos < first_pos:
                first_pos = pos

        if first_pos >= len(content):
            return content[:200]

        context = 80
        start = max(0, first_pos - context)
        end = min(len(content), first_pos + context + 50)
        snippet = content[start:end].replace("\n", " ")
        snippet = re.sub(r"\s+", " ", snippet).strip()
        if start > 0:
            snippet = f"...{snippet}"
        if end < len(content):
            snippet = f"{snippet}..."
        return snippet

    # ── Flexible Importers ────────────────────────────────────────────────────

    def _parse_file(self, md_file: Path, fmt: str) -> list[dict]:
        """Dispatch to format-specific parser."""
        if fmt == "parachute":
            return self._parse_md_file(md_file)
        elif fmt == "obsidian":
            return self._parse_obsidian(md_file)
        elif fmt == "logseq":
            return self._parse_logseq(md_file)
        else:  # plain
            return self._parse_plain(md_file)

    def _parse_obsidian(self, md_file: Path) -> list[dict]:
        """
        Obsidian daily note parser.

        Splits on bare `---` HR or `## ` H2 headings.
        Uses frontmatter `date:` or filename stem for date.
        """
        raw = md_file.read_text(encoding="utf-8", errors="replace")
        file_stem = md_file.stem
        file_date = file_stem[:10] if len(file_stem) >= 10 else ""

        meta: dict = {}
        content_block = raw
        if raw.startswith("---\n"):
            try:
                import frontmatter as fm
                post = fm.loads(raw)
                meta = {k: self._sanitize_fm_value(v) for k, v in post.metadata.items()}
                content_block = post.content or ""
            except ImportError:
                pass

        date_raw = meta.get("date", "")
        date = str(date_raw)[:10] if date_raw else file_date

        # Split on HR (---) or H2 headings
        sections = [s.strip() for s in re.split(r'\n---(?:\n|$)|\n(?=## )', content_block) if s.strip()]
        if not sections:
            return []

        result = []
        for i, section in enumerate(sections):
            entry_id = file_stem if i == 0 else f"{file_stem}-{i}"
            # Use H2 heading as title if present
            title_match = re.match(r'^## (.+)', section)
            title = title_match.group(1).strip() if title_match else ""
            content = section[title_match.end():].strip() if title_match else section
            result.append({
                "entry_id": entry_id,
                "date": date,
                "content": content,
                "created_at": f"{date}T00:00:00+00:00",
                "title": title,
                "entry_type": "text",
                "audio_path": "",
                "brain_links": [],
                "extra_meta": {},
            })
        return result

    def _parse_logseq(self, md_file: Path) -> list[dict]:
        """
        Logseq daily note parser.

        Splits on top-level `- ` bullets (not indented). Each bullet = one entry.
        Date from filename stem (YYYY-MM-DD).
        """
        raw = md_file.read_text(encoding="utf-8", errors="replace")
        file_stem = md_file.stem
        file_date = file_stem[:10] if len(file_stem) >= 10 else ""

        # Collect top-level bullet blocks
        blocks: list[str] = []
        current: list[str] = []
        for line in raw.splitlines():
            if line.startswith("- "):
                if current:
                    blocks.append("\n".join(current))
                current = [line[2:]]  # strip leading "- "
            elif current and (line.startswith("  ") or line == ""):
                current.append(line.strip())
            else:
                # Not a top-level bullet — skip (page properties, etc.)
                pass

        if current:
            blocks.append("\n".join(current))

        result = []
        for i, block in enumerate(blocks):
            content = block.strip()
            if not content:
                continue
            entry_id = f"{file_stem}-{i}"
            result.append({
                "entry_id": entry_id,
                "date": file_date,
                "content": content,
                "created_at": f"{file_date}T00:00:00+00:00",
                "title": "",
                "entry_type": "text",
                "audio_path": "",
                "brain_links": [],
                "extra_meta": {},
            })
        return result

    def _parse_plain(self, md_file: Path) -> list[dict]:
        """Plain text parser — whole file = one entry. Date from filename."""
        raw = md_file.read_text(encoding="utf-8", errors="replace").strip()
        if not raw:
            return []
        file_stem = md_file.stem
        file_date = file_stem[:10] if len(file_stem) >= 10 else ""
        return [{
            "entry_id": file_stem,
            "date": file_date,
            "content": raw,
            "created_at": f"{file_date}T00:00:00+00:00",
            "title": "",
            "entry_type": "text",
            "audio_path": "",
            "brain_links": [],
            "extra_meta": {},
        }]

    async def _flexible_import(
        self,
        graph,
        source_dir: Path,
        fmt: str,
        dry_run: bool,
        date_from: str | None,
        date_to: str | None,
    ) -> dict:
        """Parse files from source_dir using fmt, optionally write to graph."""
        date_pattern = re.compile(r'^\d{4}-\d{2}-\d{2}')

        md_files = await asyncio.to_thread(
            lambda: sorted(f for f in source_dir.glob("*.md") if date_pattern.match(f.stem))
        )
        files_found = len(md_files)

        rows = await graph.execute_cypher(
            "MATCH (e:Note) RETURN e.entry_id AS entry_id"
        )
        existing_ids = {r["entry_id"] for r in rows}

        all_entries: list[dict] = []
        for md_file in md_files:
            try:
                entries = await asyncio.to_thread(self._parse_file, md_file, fmt)
            except Exception as e:
                logger.warning(f"Daily flexible import: parse failed for {md_file.name}: {e}")
                continue

            for entry in entries:
                # Apply date filters (date_from/date_to are validated YYYY-MM-DD strings)
                entry_date = entry.get("date", "")
                if not entry_date:
                    continue
                if date_from and entry_date < date_from:
                    continue
                if date_to and entry_date > date_to:
                    continue
                all_entries.append(entry)

        already_imported = sum(1 for e in all_entries if e["entry_id"] in existing_ids)
        to_import = [e for e in all_entries if e["entry_id"] not in existing_ids]

        sample = [
            {"id": e["entry_id"], "date": e["date"], "snippet": e["content"][:100]}
            for e in all_entries[:3]
        ]

        if dry_run:
            return {
                "dry_run": True,
                "files_found": files_found,
                "entries_parsed": len(all_entries),
                "already_imported": already_imported,
                "to_import": len(to_import),
                "sample": sample,
            }

        imported = 0
        for entry in to_import:
            try:
                await self._write_to_graph(graph, **entry)
                imported += 1
            except Exception as e:
                logger.error(f"Daily flexible import: write failed for {entry['entry_id']!r}: {e}")

        return {
            "dry_run": False,
            "files_found": files_found,
            "entries_parsed": len(all_entries),
            "already_imported": already_imported,
            "to_import": len(to_import),
            "sample": sample,
            "imported": imported,
        }

    # ── Routes ────────────────────────────────────────────────────────────────

    def get_router(self) -> APIRouter:
        """Return API routes for the daily module."""
        router = APIRouter(tags=["daily"])

        @router.post("/entries", status_code=201)
        async def create_entry(body: CreateEntryRequest):
            """Create a new daily journal entry."""
            result = await self.create_entry(body.content, body.metadata)
            return result

        @router.get("/entries")
        async def list_entries(
            limit: int = Query(20, ge=1, le=100),
            offset: int = Query(0, ge=0),
            date: str | None = Query(None, description="Filter by date (YYYY-MM-DD)"),
        ):
            """List daily journal entries, optionally filtered by date."""
            entries = await self.list_entries(limit=limit, offset=offset, date=date)
            return {"entries": entries, "count": len(entries), "offset": offset}

        @router.get("/entries/search")
        async def search_entries(
            q: str = Query(..., description="Keyword search query"),
            limit: int = Query(30, ge=1, le=100),
        ):
            """Search entries by keyword across content and title."""
            results = await self.search_entries(q, limit=limit)
            return {"results": results, "query": q, "count": len(results)}

        @router.get("/entries/{entry_id}")
        async def get_entry(entry_id: str):
            """Get a specific daily entry."""
            entry = await self.get_entry(entry_id)
            if not entry:
                return JSONResponse(
                    status_code=404,
                    content={"error": "Entry not found", "id": entry_id},
                )
            return entry

        @router.patch("/entries/{entry_id}")
        async def update_entry(entry_id: str, body: UpdateEntryRequest):
            """Update content and/or metadata of an existing entry."""
            entry = await self.update_entry(entry_id, content=body.content, metadata=body.metadata)
            if entry is None:
                return JSONResponse(
                    status_code=404,
                    content={"error": "Entry not found", "id": entry_id},
                )
            return entry

        @router.delete("/entries/{entry_id}", status_code=204)
        async def delete_entry(entry_id: str):
            """Delete an entry and its graph edges."""
            ok = await self.delete_entry(entry_id)
            if not ok:
                return JSONResponse(status_code=500, content={"error": "Delete failed"})
            return Response(status_code=204)

        # ── Import ────────────────────────────────────────────────────────────

        @router.delete("/import/all", status_code=200)
        async def clear_all_entries():
            """Delete ALL Note nodes from the graph.

            Safe to call before a fresh re-import. Does NOT touch any markdown files.
            """
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(
                    status_code=503,
                    content={"error": "BrainDB not available"},
                )
            rows = await graph.execute_cypher(
                "MATCH (e:Note) RETURN count(e) AS n"
            )
            entry_count = rows[0]["n"] if rows else 0
            async with graph.write_lock:
                await graph.execute_cypher("MATCH (e:Note) DETACH DELETE e")
            logger.info(f"Daily: cleared {entry_count} Note nodes")
            return {
                "deleted_entries": entry_count,
                "message": f"Cleared {entry_count} entries. Markdown files are untouched.",
            }

        # ── Assets ───────────────────────────────────────────────────────────

        @router.post("/assets/upload", status_code=201)
        async def upload_asset(file: UploadFile, date: str | None = None):
            """Receive an audio/image file and save it to ~/.parachute/daily/assets/{date}/."""
            date_str = date or datetime.now(timezone.utc).strftime("%Y-%m-%d")

            # Validate date param to prevent path traversal
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_str):
                return JSONResponse(status_code=400, content={"error": "invalid date parameter"})
            assets_root = ASSETS_DIR.resolve()
            dest_dir = (assets_root / date_str).resolve()
            if not dest_dir.is_relative_to(assets_root):
                return JSONResponse(status_code=400, content={"error": "invalid date parameter"})

            # Strip directory components from filename to prevent traversal
            bare_name = Path(file.filename).name if file.filename else "upload"
            safe_name = f"{uuid.uuid4().hex[:8]}_{bare_name}"
            dest_path = dest_dir / safe_name

            contents = await file.read()
            await asyncio.to_thread(dest_dir.mkdir, parents=True, exist_ok=True)
            await asyncio.to_thread(dest_path.write_bytes, contents)

            logger.info(f"Daily: saved uploaded asset to {dest_path}")
            return {"path": str(dest_path), "filename": safe_name}

        @router.get("/assets/{path:path}")
        async def serve_asset(path: str):
            """Stream an audio/image file. Path is relative to ASSETS_DIR."""
            assets_root = ASSETS_DIR.resolve()
            full_path = (assets_root / path).resolve()
            if not full_path.is_relative_to(assets_root):
                return JSONResponse(status_code=403, content={"error": "forbidden"})
            if not full_path.exists():
                return JSONResponse(status_code=404, content={"error": "not found"})
            return FileResponse(full_path)

        @router.post("/import/flexible")
        async def flexible_import(body: FlexibleImportRequest):
            """Format-aware journal importer. Accepts Parachute, Obsidian, Logseq, or plain files."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})

            source = Path(body.source_dir).expanduser()
            if not source.is_dir():
                return JSONResponse(
                    status_code=400,
                    content={"error": f"source_dir not found: {body.source_dir}"},
                )

            result = await self._flexible_import(
                graph,
                source_dir=source,
                fmt=body.format,
                dry_run=body.dry_run,
                date_from=body.date_from,
                date_to=body.date_to,
            )
            return result

        @router.get("/cards")
        @router.get("/agent-cards")  # backward-compat alias
        async def list_cards(date: str | None = Query(None)):
            """Fetch all Card nodes, optionally filtered by date."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            if date:
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
                    return JSONResponse(status_code=400, content={"error": "invalid date"})
                rows = await graph.execute_cypher(
                    "MATCH (c:Card) WHERE c.date = $date RETURN c ORDER BY c.generated_at ASC",
                    {"date": date},
                )
            else:
                rows = await graph.execute_cypher(
                    "MATCH (c:Card) RETURN c ORDER BY c.generated_at DESC"
                )
            return {"cards": rows, "count": len(rows)}

        @router.get("/cards/{agent_name}")
        @router.get("/agent-cards/{agent_name}")  # backward-compat alias
        async def get_card(agent_name: str, date: str | None = Query(None)):
            """Get a specific agent's card, optionally filtered to a specific date."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            if date:
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
                    return JSONResponse(status_code=400, content={"error": "invalid date"})
                rows = await graph.execute_cypher(
                    "MATCH (c:Card) WHERE c.agent_name = $name AND c.date = $date RETURN c",
                    {"name": agent_name, "date": date},
                )
            else:
                rows = await graph.execute_cypher(
                    "MATCH (c:Card) WHERE c.agent_name = $name "
                    "RETURN c ORDER BY c.generated_at DESC",
                    {"name": agent_name},
                )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "not found"})
            return rows[0] if date else {"cards": rows, "count": len(rows)}

        @router.post("/cards/{agent_name}/run", status_code=202)
        @router.post("/agent-cards/{agent_name}/run", status_code=202)  # backward-compat alias
        async def run_card(
            agent_name: str,
            date: str | None = Query(None),
            force: bool = Query(False),
        ):
            """Trigger an agent run for a date (async — returns 202 immediately)."""
            from parachute.core.daily_agent import run_daily_agent
            asyncio.create_task(
                run_daily_agent(self.vault_path, agent_name, date=date, force=force)
            )
            return {"status": "started", "agent": agent_name, "date": date}

        @router.post("/cards/write", status_code=201)
        async def write_card(body: dict):
            """Write a Card to the graph (used by container-side daily tools MCP).

            Body: { agent_name, date, content, display_name? }
            """
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            agent_name = body.get("agent_name", "").strip()
            date_str = body.get("date", "").strip()
            content = body.get("content", "").strip()
            if not agent_name or not date_str or not content:
                return JSONResponse(
                    status_code=400,
                    content={"error": "agent_name, date, and content are required"},
                )
            if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,63}", agent_name):
                return JSONResponse(status_code=400, content={"error": "invalid agent_name format"})
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_str):
                return JSONResponse(status_code=400, content={"error": "invalid date format"})
            # Verify agent_name corresponds to a known Caller
            caller_rows = await graph.execute_cypher(
                "MATCH (c:Caller {name: $name}) RETURN c.name",
                {"name": agent_name},
            )
            if not caller_rows:
                return JSONResponse(status_code=403, content={"error": "unknown caller"})
            card_id = f"{agent_name}:{date_str}"
            display_name = body.get("display_name") or agent_name.replace("-", " ").title()
            generated_at = datetime.now(timezone.utc).isoformat()
            await graph.execute_cypher(
                "MERGE (c:Card {card_id: $card_id}) "
                "SET c.agent_name = $agent_name, "
                "    c.display_name = $display_name, "
                "    c.content = $content, "
                "    c.generated_at = $generated_at, "
                "    c.status = 'done', "
                "    c.date = $date",
                {
                    "card_id": card_id,
                    "agent_name": agent_name,
                    "display_name": display_name,
                    "content": content,
                    "generated_at": generated_at,
                    "date": date_str,
                },
            )
            return {"card_id": card_id, "status": "done", "date": date_str}

        # ── Callers (agent definitions) ──────────────────────────────────────

        @router.get("/callers")
        @router.get("/agents")  # backward-compat alias
        async def list_callers():
            """List all Caller nodes from the graph."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (c:Caller) RETURN c ORDER BY c.name"
            )
            return {"callers": rows, "count": len(rows)}

        @router.get("/callers/{name}")
        async def get_caller(name: str):
            """Get a specific Caller node."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (c:Caller {name: $name}) RETURN c",
                {"name": name},
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "not found"})
            return rows[0]

        @router.post("/callers", status_code=201)
        async def create_caller(body: dict):
            """Create or update a Caller node (MERGE on name)."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            name = body.get("name", "").strip()
            if not name:
                return JSONResponse(status_code=400, content={"error": "name required"})
            now = datetime.now(timezone.utc).isoformat()
            trust_level = body.get("trust_level", "sandboxed")
            if trust_level not in ("sandboxed", "direct"):
                trust_level = "sandboxed"
            await graph.execute_cypher(
                "MERGE (c:Caller {name: $name}) "
                "SET c.display_name = $display_name, c.description = $description, "
                "    c.system_prompt = $system_prompt, c.tools = $tools, "
                "    c.model = $model, c.schedule_enabled = $schedule_enabled, "
                "    c.schedule_time = $schedule_time, c.enabled = $enabled, "
                "    c.trust_level = $trust_level, "
                "    c.updated_at = $now",
                {
                    "name": name,
                    "display_name": body.get("display_name") or name.replace("-", " ").title(),
                    "description": body.get("description") or "",
                    "system_prompt": body.get("system_prompt") or "",
                    "tools": json.dumps(body.get("tools") or ["read_journal", "read_chat_log", "read_recent_journals"]),
                    "model": body.get("model") or "",
                    "schedule_enabled": "true" if body.get("schedule_enabled", True) else "false",
                    "schedule_time": body.get("schedule_time") or "3:00",
                    "enabled": "true" if body.get("enabled", True) else "false",
                    "trust_level": trust_level,
                    "now": now,
                },
            )
            rows = await graph.execute_cypher(
                "MATCH (c:Caller {name: $name}) RETURN c", {"name": name}
            )
            return rows[0] if rows else {"name": name}

        @router.put("/callers/{name}")
        async def update_caller(name: str, body: dict):
            """Update fields on an existing Caller node."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            now = datetime.now(timezone.utc).isoformat()
            # Fetch existing
            rows = await graph.execute_cypher(
                "MATCH (c:Caller {name: $name}) RETURN c", {"name": name}
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "not found"})
            existing = rows[0]
            trust_level = body.get("trust_level", existing.get("trust_level") or "sandboxed")
            if trust_level not in ("sandboxed", "direct"):
                trust_level = "sandboxed"
            await graph.execute_cypher(
                "MATCH (c:Caller {name: $name}) "
                "SET c.display_name = $display_name, c.description = $description, "
                "    c.system_prompt = $system_prompt, c.tools = $tools, "
                "    c.model = $model, c.schedule_enabled = $schedule_enabled, "
                "    c.schedule_time = $schedule_time, c.enabled = $enabled, "
                "    c.trust_level = $trust_level, "
                "    c.updated_at = $now",
                {
                    "name": name,
                    "display_name": body.get("display_name", existing.get("display_name") or name),
                    "description": body.get("description", existing.get("description") or ""),
                    "system_prompt": body.get("system_prompt", existing.get("system_prompt") or ""),
                    "tools": json.dumps(body.get("tools")) if "tools" in body else existing.get("tools") or "[]",
                    "model": body.get("model", existing.get("model") or ""),
                    "schedule_enabled": "true" if body.get("schedule_enabled", existing.get("schedule_enabled") == "true") else "false",
                    "schedule_time": body.get("schedule_time", existing.get("schedule_time") or "3:00"),
                    "enabled": "true" if body.get("enabled", existing.get("enabled") == "true") else "false",
                    "trust_level": trust_level,
                    "now": now,
                },
            )
            rows = await graph.execute_cypher(
                "MATCH (c:Caller {name: $name}) RETURN c", {"name": name}
            )
            return rows[0] if rows else {"name": name}

        @router.post("/callers/{name}/reset", status_code=200)
        async def reset_caller(name: str):
            """Reset a Caller's session state so its next run starts fresh."""
            # Validate name to prevent path traversal
            if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,63}", name):
                return JSONResponse(status_code=400, content={"error": "invalid caller name format"})
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            # Verify Caller exists
            rows = await graph.execute_cypher(
                "MATCH (c:Caller {name: $name}) RETURN c", {"name": name}
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "not found"})
            # Clear the agent's SDK session so next run starts fresh
            await graph.execute_cypher(
                "MATCH (c:Caller {name: $name}) SET c.sdk_session_id = ''",
                {"name": name},
            )
            return {"status": "reset", "agent": name}

        @router.delete("/callers/{name}", status_code=204)
        async def delete_caller(name: str):
            """Delete a Caller node."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            await graph.execute_cypher(
                "MATCH (c:Caller {name: $name}) DELETE c", {"name": name}
            )
            return Response(status_code=204)

        return router
