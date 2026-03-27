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

from fastapi import APIRouter, Form, Query, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel, field_validator

# Audio/image assets directory — fixed, not user-configurable
ASSETS_DIR = Path.home() / ".parachute" / "daily" / "assets"

# Background task references — prevent GC from swallowing exceptions
_background_tasks: set[asyncio.Task] = set()


def _log_task_exception(task: asyncio.Task) -> None:
    """Done-callback for background tasks: log exceptions, then discard."""
    _background_tasks.discard(task)
    if not task.cancelled():
        exc = task.exception()
        if exc:
            logger.error("Background task failed: %s", exc, exc_info=exc)

# Upload constraints
MAX_VOICE_BYTES = 200 * 1024 * 1024  # 200 MB
ALLOWED_AUDIO_EXTENSIONS = {".wav", ".m4a", ".mp3", ".aac", ".ogg", ".webm", ".mp4"}

# Default redo log path for crash recovery (rolled to 90 days).
# DailyModule derives the actual path from its home_path at init time,
# so tests with a temp vault don't pollute the production log.
_DEFAULT_REDO_LOG_PATH = Path.home() / ".parachute" / "daily" / "entries.jsonl"

logger = logging.getLogger(__name__)

# Agent templates are defined in core (brain_chat_store.py) and imported here
# for use in GET /agents/templates and agent creation endpoints.
from parachute.db.brain_chat_store import (
    AGENT_TEMPLATES,
    AgentTemplateDict,
    POST_PROCESS_SYSTEM_PROMPT,
    TOOL_TEMPLATES,
    TRIGGER_TEMPLATES,
    ToolTemplateDict,
    TriggerTemplateDict,
)


def _find_transcript_file(
    sid: str,
    container_slug: str = "",
    parachute_dir: Optional[Path] = None,
) -> Optional[Path]:
    """Locate the JSONL transcript for an SDK session.

    Search order:
    1. Container bind-mount (if ``container_slug`` given) — sandboxed agents
       write transcripts inside ``{parachute_dir}/sandbox/envs/{slug}/home/``.
    2. Host ``~/.claude/projects/`` — direct-trust agents and interactive
       sessions.

    This mirrors ``SessionManager.find_transcript_path`` but is a pure
    filesystem helper so it can run in ``asyncio.to_thread``.
    """
    filename = f"{sid}.jsonl"
    if parachute_dir is None:
        parachute_dir = Path.home() / ".parachute"

    # 1. Container bind-mounted JSONL (sandboxed agents)
    if container_slug:
        container_projects = (
            parachute_dir / "sandbox" / "envs" / container_slug / "home"
            / ".claude" / "projects"
        )
        if container_projects.exists():
            try:
                for project_dir in container_projects.iterdir():
                    if project_dir.is_dir():
                        candidate = project_dir / filename
                        if candidate.exists():
                            return candidate
            except OSError:
                pass

    # 2. Host-side ~/.claude/projects/
    home_projects = Path.home() / ".claude" / "projects"
    if home_projects.exists():
        try:
            for project_dir in home_projects.iterdir():
                if project_dir.is_dir():
                    candidate = project_dir / filename
                    if candidate.exists():
                        return candidate
        except OSError:
            pass

    return None


def _read_transcript_file(
    sid: str,
    limit: int,
    container_slug: str = "",
    parachute_dir: Optional[Path] = None,
) -> dict:
    """Read and parse a Claude SDK JSONL transcript file (sync, for to_thread).

    Returns a dict matching the Flutter AgentTranscript shape.
    """
    session_file = _find_transcript_file(sid, container_slug, parachute_dir)

    if not session_file:
        return {"hasTranscript": False, "message": "Transcript file not found."}

    messages: list[dict] = []
    try:
        with open(session_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                etype = event.get("type")
                if etype not in ("user", "assistant"):
                    continue
                msg = event.get("message", {})
                content_raw = msg.get("content", "")

                if etype == "user":
                    if isinstance(content_raw, list):
                        content_raw = " ".join(
                            b.get("text", "") for b in content_raw if b.get("type") == "text"
                        )
                    messages.append({
                        "type": "user",
                        "timestamp": event.get("timestamp"),
                        "content": content_raw,
                    })
                elif etype == "assistant":
                    if isinstance(content_raw, str):
                        messages.append({
                            "type": "assistant",
                            "timestamp": event.get("timestamp"),
                            "content": content_raw,
                            "model": event.get("model"),
                        })
                    else:
                        text_parts = []
                        blocks = []
                        for block in content_raw:
                            bt = block.get("type", "")
                            if bt == "text":
                                text_parts.append(block.get("text", ""))
                                blocks.append({"type": "text", "text": block.get("text", "")})
                            elif bt == "tool_use":
                                blocks.append({
                                    "type": "tool_use",
                                    "name": block.get("name", ""),
                                    "input": json.dumps(block.get("input", {}), indent=2),
                                    "tool_use_id": block.get("id"),
                                })
                            elif bt == "tool_result":
                                rc = block.get("content", "")
                                if isinstance(rc, list):
                                    rc = " ".join(
                                        r.get("text", "") for r in rc if r.get("type") == "text"
                                    )
                                blocks.append({
                                    "type": "tool_result",
                                    "text": str(rc)[:500],
                                    "tool_use_id": block.get("tool_use_id"),
                                })
                        messages.append({
                            "type": "assistant",
                            "timestamp": event.get("timestamp"),
                            "content": "\n".join(text_parts),
                            "blocks": blocks or None,
                            "model": event.get("model"),
                        })
    except Exception:
        logger.warning("Failed to read agent transcript for session %s", sid, exc_info=True)
        return {"hasTranscript": False, "message": "Failed to read transcript."}

    # Return most recent messages
    if len(messages) > limit:
        messages = messages[-limit:]

    return {
        "hasTranscript": True,
        "sessionId": sid,
        "totalMessages": len(messages),
        "messages": messages,
    }


def _append_redo_log(
    redo_log_path: Path,
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
        redo_log_path.parent.mkdir(parents=True, exist_ok=True)
        with redo_log_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:
        logger.warning(f"Daily: redo log append failed: {e}")


def _trim_redo_log(redo_log_path: Path) -> list[dict]:
    """Remove entries older than 90 days and return the kept records.

    Uses an atomic write-to-temp + os.replace so a crash mid-trim cannot
    truncate the log. Never raises — returns an empty list on any error.
    """
    if not redo_log_path.exists():
        return []
    cutoff = (datetime.now(timezone.utc) - timedelta(days=90)).strftime("%Y-%m-%d")
    try:
        kept_lines: list[str] = []
        kept_records: list[dict] = []
        for line in redo_log_path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
                if rec.get("date", "") >= cutoff:
                    kept_lines.append(line)
                    kept_records.append(rec)
            except json.JSONDecodeError:
                logger.warning(f"Daily: redo log corrupt line skipped: {line[:80]!r}")
        fd, tmp_path = tempfile.mkstemp(dir=redo_log_path.parent, suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("\n".join(kept_lines) + ("\n" if kept_lines else ""))
            os.replace(tmp_path, redo_log_path)
        except Exception:
            os.unlink(tmp_path)
            raise
        return kept_records
    except Exception as e:
        logger.warning(f"Daily: redo log trim failed: {e}")
        return []


# ── Transcription status validation ─────────────────────────────────────────
VALID_TRANSCRIPTION_STATUSES = {"processing", "transcribed", "complete", "failed"}
VALID_TRANSCRIPTION_TRANSITIONS = {
    "processing": {"transcribed", "complete", "failed"},
    "transcribed": {"processing", "complete", "failed"},  # +processing for re-transcribe
    "failed": {"processing"},       # retry
    "complete": {"processing"},     # re-transcribe from finished state
}



async def _transcribe_and_cleanup(
    graph,
    entry_id: str,
    audio_path: Path,
    dispatch_event_fn=None,
) -> None:
    """Background task: transcribe audio → dispatch event for cleanup.

    If dispatch_event_fn is provided, fires 'note.transcription_complete'
    event which triggers Agents (e.g., post-process).
    Falls back to direct _cleanup_transcription() if no dispatcher.
    """
    from parachute.core.interfaces import get_registry

    ts = get_registry().get("TranscriptionService")
    if not ts:
        await _update_entry_transcription_status(
            graph, entry_id, "failed", error="Transcription service unavailable"
        )
        return

    try:
        raw_text = await ts.transcribe(audio_path)
        if not raw_text.strip():
            await _update_entry_transcription_status(
                graph, entry_id, "failed", error="No speech detected in audio"
            )
            return

        # Update entry with raw transcription + status "transcribed" (atomic)
        async with graph.write_lock:
            rows = await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $entry_id}) RETURN e.metadata_json AS meta",
                {"entry_id": entry_id},
            )
            existing_meta = {}
            if rows:
                blob = rows[0].get("meta") or ""
                try:
                    existing_meta = json.loads(blob) if blob else {}
                except (json.JSONDecodeError, TypeError):
                    existing_meta = {}

            existing_meta["transcription_status"] = "transcribed"
            existing_meta["transcription_raw"] = raw_text
            await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $entry_id}) "
                "SET e.content = $content, e.metadata_json = $meta",
                {
                    "entry_id": entry_id,
                    "content": raw_text,
                    "meta": json.dumps(existing_meta),
                },
            )

        logger.info(f"Daily: transcribed voice entry {entry_id} ({len(raw_text)} chars)")

    except Exception as e:
        logger.error(f"Daily: transcription failed for {entry_id}: {e}", exc_info=True)
        await _update_entry_transcription_status(
            graph, entry_id, "failed", error=str(e)
        )
        # Clean up orphaned audio file only if transcription itself failed
        try:
            if audio_path.exists():
                audio_path.unlink()
                logger.info(f"Daily: cleaned up audio file after failed transcription: {audio_path}")
        except OSError as cleanup_err:
            logger.warning(f"Daily: failed to clean up audio file {audio_path}: {cleanup_err}")
        return

    # Dispatch note.transcription_complete event to triggered Agents.
    # The cleanup_transcription Agent (if enabled) will handle text cleanup.
    # We pass a callback since _transcribe_and_cleanup is module-level.
    if dispatch_event_fn is not None:
        try:
            await dispatch_event_fn("note.transcription_complete", entry_id)
        except Exception as e:
            logger.error(f"Daily: event dispatch failed for {entry_id} (transcription preserved): {e}", exc_info=True)
    else:
        # Fallback: direct cleanup if no dispatch function provided
        try:
            await _cleanup_transcription(graph, entry_id, raw_text)
        except Exception as e:
            logger.error(f"Daily: cleanup failed for {entry_id} (transcription preserved): {e}", exc_info=True)


async def _cleanup_transcription(
    graph,
    entry_id: str,
    raw_text: str,
) -> None:
    """Clean up raw transcription text via a single LLM call. No tools, no sandbox."""
    from parachute.core.claude_sdk import query_streaming
    from parachute.config import settings

    claude_token = settings.claude_code_oauth_token
    if not claude_token:
        import os
        claude_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if not claude_token:
        logger.warning(f"Daily: skipping cleanup for {entry_id} — no OAuth token")
        await _update_entry_transcription_status(
            graph, entry_id, "complete", cleanup_status="skipped"
        )
        return

    try:
        # Single-turn SDK call: system prompt + raw text → cleaned text
        cleaned_text = ""
        async for event in query_streaming(
            prompt=f"Clean up this voice transcription:\n\n{raw_text}",
            system_prompt=POST_PROCESS_SYSTEM_PROMPT,
            tools=[],  # No tools — pure text transform
            permission_mode="default",
            claude_token=claude_token,
            model="haiku",
        ):
            # The result event carries the final assistant text
            if event.get("type") == "result" and "result" in event:
                cleaned_text = event["result"]
            elif event.get("type") == "assistant" and "message" in event:
                # Extract text from content blocks
                msg = event["message"]
                if isinstance(msg, dict) and "content" in msg:
                    for block in msg["content"]:
                        if isinstance(block, dict) and block.get("type") == "text":
                            cleaned_text += block.get("text", "")

        cleaned_text = cleaned_text.strip()
        if not cleaned_text:
            logger.warning(f"Daily: cleanup returned empty text for {entry_id}, keeping raw")
            await _update_entry_transcription_status(
                graph, entry_id, "complete", cleanup_status="failed"
            )
            return

        # Write cleaned text back to the entry
        async with graph.write_lock:
            await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $entry_id}) "
                "SET e.content = $content",
                {"entry_id": entry_id, "content": cleaned_text},
            )

        await _update_entry_transcription_status(
            graph, entry_id, "complete", cleanup_status="completed"
        )
        logger.info(f"Daily: cleaned up entry {entry_id} ({len(raw_text)} → {len(cleaned_text)} chars)")

    except Exception as e:
        logger.error(f"Daily: cleanup failed for {entry_id}: {e}", exc_info=True)
        # Don't mark as failed — raw transcription is still readable.
        # Mark as complete so polling resolves on the client.
        await _update_entry_transcription_status(
            graph, entry_id, "complete", cleanup_status="failed"
        )


async def _update_entry_transcription_status(
    graph,
    entry_id: str,
    status: str,
    error: str | None = None,
    cleanup_status: str | None = None,
) -> None:
    """Update an entry's transcription_status (and optionally cleanup_status) in metadata_json.

    The full read-modify-write is inside write_lock to avoid race conditions
    with concurrent PATCH requests on the same entry.

    cleanup_status values: "completed", "skipped", "failed", or None (don't update).
    """
    try:
        async with graph.write_lock:
            rows = await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $entry_id}) RETURN e.metadata_json AS meta",
                {"entry_id": entry_id},
            )
            existing_meta = {}
            if rows:
                blob = rows[0].get("meta") or ""
                try:
                    existing_meta = json.loads(blob) if blob else {}
                except (json.JSONDecodeError, TypeError):
                    existing_meta = {}

            existing_meta["transcription_status"] = status
            if error:
                existing_meta["transcription_error"] = error
            if cleanup_status is not None:
                existing_meta["cleanup_status"] = cleanup_status

            await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $entry_id}) SET e.metadata_json = $meta",
                {"entry_id": entry_id, "meta": json.dumps(existing_meta)},
            )
    except Exception as e:
        logger.error(f"Daily: failed to update transcription status for {entry_id}: {e}")


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
    assets_source_dir: Optional[str] = None  # root for resolving relative audio paths

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

    def __init__(self, home_path: Path, **kwargs):
        self.home_path = home_path
        self._redo_log_path = home_path / ".parachute" / "daily" / "entries.jsonl"

    async def on_load(self) -> None:
        """Daily-specific initialization.

        Schema registration, column migrations, and agent seeding are
        handled by BrainChatStore.ensure_schema() at server startup.
        This method only runs daily-specific tasks.
        """
        graph = self._get_graph()
        if graph is None:
            logger.warning("Daily: BrainDB not in registry — module will not function")
            return

        # Migrate relative audio paths to absolute (one-time, idempotent)
        await self._migrate_audio_paths_to_absolute(graph)

        # Trim redo log (90-day rolling), then replay any entries missing from graph
        redo_records = _trim_redo_log(self._redo_log_path)
        await self._recover_from_redo_log(graph, redo_records)

        logger.info("Daily: module loaded")

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

    async def _dispatch_event(self, event: str, entry_id: str) -> None:
        """Dispatch a Note lifecycle event to matching triggered Agents.

        Lifecycle bookkeeping (cleanup_status, transcription_status) lives here
        because it's domain-specific to the Daily module — the dispatcher stays
        event-agnostic.

        Runs as a background task. Errors are logged but don't propagate.
        """
        from parachute.core.agent_dispatch import AgentDispatcher

        graph = self._get_graph()
        if graph is None:
            return

        try:
            entry = await self.get_entry(entry_id)
            if not entry:
                logger.warning(f"Daily: dispatch event {event} — entry {entry_id} not found")
                return

            meta = entry.get("metadata", {})
            entry_meta = {
                "entry_type": meta.get("type", "text"),
                "tags": meta.get("tags", []),
                "date": meta.get("date", ""),
            }

            # Pre-dispatch lifecycle bookkeeping
            if event == "note.transcription_complete":
                await self._set_entry_meta(graph, entry_id, {"cleanup_status": "running"})

            dispatcher = AgentDispatcher(graph=graph, home_path=self.home_path)
            results = await dispatcher.dispatch(event, entry_id, entry_meta)

            # Post-dispatch lifecycle bookkeeping
            if event == "note.transcription_complete" and results:
                all_ok = all(
                    r.get("status") in ("completed", "completed_no_output")
                    for r in results
                )
                if all_ok:
                    await self._set_entry_meta(graph, entry_id, {
                        "transcription_status": "complete",
                        "cleanup_status": "completed",
                    })
                else:
                    await self._set_entry_meta(graph, entry_id, {"cleanup_status": "failed"})

            for r in results:
                logger.info(
                    f"Daily: triggered agent '{r.get('agent')}' on {entry_id} → {r.get('status')}"
                )
        except Exception as e:
            logger.error(f"Daily: event dispatch failed ({event}, {entry_id}): {e}", exc_info=True)
            # If we set cleanup_status=running but dispatch crashed, mark failed
            if event == "note.transcription_complete" and graph:
                try:
                    await self._set_entry_meta(graph, entry_id, {"cleanup_status": "failed"})
                except Exception:
                    pass

    @staticmethod
    async def _set_entry_meta(graph: Any, entry_id: str, updates: dict[str, Any]) -> None:
        """Update fields in an entry's metadata_json (read-modify-write under lock)."""
        try:
            async with graph.write_lock:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) RETURN e.metadata_json AS meta",
                    {"entry_id": entry_id},
                )
                if not rows:
                    return

                meta: dict[str, Any] = {}
                blob = rows[0].get("meta") or ""
                if blob:
                    try:
                        meta = json.loads(blob)
                    except (json.JSONDecodeError, TypeError):
                        pass

                meta.update(updates)

                await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) SET e.metadata_json = $meta",
                    {"entry_id": entry_id, "meta": json.dumps(meta)},
                )
        except Exception as e:
            logger.warning(f"Daily: failed to set entry meta on {entry_id}: {e}")

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

        meta = metadata or {}

        # Honor client-provided timestamps when present (offline entries carry
        # their original authoring time).  Fall back to server time otherwise.
        # Defaults: use server time; overridden below if valid client timestamp.
        now_utc = datetime.now(timezone.utc)
        parsed = now_utc

        client_created_at = meta.get("created_at")
        if client_created_at:
            try:
                candidate = datetime.fromisoformat(client_created_at)
                if candidate.tzinfo is None:
                    candidate = candidate.replace(tzinfo=timezone.utc)
                delta_secs = (now_utc - candidate).total_seconds()
                max_age_secs = 30 * 24 * 3600
                if delta_secs < -60:
                    logger.warning(f"Daily: rejecting future client timestamp {client_created_at}")
                elif delta_secs > max_age_secs:
                    logger.warning(f"Daily: rejecting too-old client timestamp {client_created_at}")
                else:
                    parsed = candidate
            except (ValueError, TypeError):
                logger.warning(f"Daily: invalid client timestamp {client_created_at!r}, using server time")

        entry_id = parsed.strftime("%Y-%m-%d-%H-%M-%S-%f")
        created_at = parsed.isoformat()
        # Use local wall-clock date so entries group under the day the user
        # experienced them (e.g. 8pm local = next UTC day in US timezones).
        date = parsed.astimezone().strftime("%Y-%m-%d")

        title = meta.get("title", "")
        entry_type = meta.get("type", "text")
        audio_path = meta.get("audio_path", "") or ""

        # Extra metadata (image_path, duration_seconds, etc.)
        known = {"title", "type", "audio_path", "created_at", "date"}  # excluded from extra_meta
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
        _append_redo_log(self._redo_log_path, entry_id, date, content, created_at, title, entry_type, audio_path, extra_meta)

        logger.info(f"Daily: created entry {entry_id}")

        # Dispatch note.created event (non-blocking background task)
        task = asyncio.create_task(self._dispatch_event("note.created", entry_id))
        _background_tasks.add(task)
        task.add_done_callback(_log_task_exception)

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

        # ── Validate transcription_status transitions ──────────────────────
        if metadata and "transcription_status" in metadata:
            new_status = metadata["transcription_status"]
            if new_status not in VALID_TRANSCRIPTION_STATUSES:
                raise ValueError(
                    f"Invalid transcription_status '{new_status}'. "
                    f"Valid: {sorted(VALID_TRANSCRIPTION_STATUSES)}"
                )

            # Check current status from metadata_json
            existing_blob = row.get("metadata_json") or ""
            try:
                existing_meta = json.loads(existing_blob) if existing_blob else {}
            except (json.JSONDecodeError, TypeError):
                existing_meta = {}

            current_status = existing_meta.get("transcription_status")
            if current_status is not None:
                allowed = VALID_TRANSCRIPTION_TRANSITIONS.get(current_status, set())
                if new_status not in allowed:
                    raise ValueError(
                        f"Invalid transition: '{current_status}' → '{new_status}'. "
                        f"Allowed from '{current_status}': {sorted(allowed) if allowed else 'none (terminal)'}"
                    )

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
        assets_source_dir: Path | None = None,
    ) -> dict:
        """Parse files from source_dir using fmt, optionally write to graph.

        When assets_source_dir is provided, relative audio paths are resolved
        against it.  Audio files are copied into ASSETS_DIR (preserving the
        date-subfolder structure) and the entry's audio_path is rewritten to
        the new absolute path.
        """
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

        # ── Resolve and copy audio assets ─────────────────────────────────
        audio_found = 0
        audio_missing = 0
        audio_copied = 0
        audio_already_existed = 0

        if assets_source_dir:
            for entry in to_import:
                rel_audio = entry.get("audio_path", "")
                if not rel_audio or rel_audio.startswith("/"):
                    continue  # no audio or already absolute

                source_file = assets_source_dir / rel_audio
                if not source_file.exists():
                    audio_missing += 1
                    logger.debug(
                        f"Daily import: audio not found: {source_file} "
                        f"(entry {entry['entry_id']})"
                    )
                    entry["audio_path"] = ""
                    continue

                audio_found += 1

                # Destination: ASSETS_DIR / date / original_filename
                entry_date = entry.get("date", "")
                filename = source_file.name
                dest_dir = ASSETS_DIR / entry_date
                dest_file = dest_dir / filename

                if dest_file.exists():
                    audio_already_existed += 1
                elif not dry_run:
                    await asyncio.to_thread(dest_dir.mkdir, parents=True, exist_ok=True)
                    await asyncio.to_thread(shutil.copy2, source_file, dest_file)
                    audio_copied += 1

                # Rewrite to absolute path (even in dry_run so sample looks right)
                entry["audio_path"] = str(dest_file)

        sample = [
            {"id": e["entry_id"], "date": e["date"], "snippet": e["content"][:100]}
            for e in all_entries[:3]
        ]

        audio_stats = {
            "audio_found": audio_found,
            "audio_missing": audio_missing,
            "audio_copied": audio_copied,
            "audio_already_existed": audio_already_existed,
        }

        if dry_run:
            return {
                "dry_run": True,
                "files_found": files_found,
                "entries_parsed": len(all_entries),
                "already_imported": already_imported,
                "to_import": len(to_import),
                "sample": sample,
                **audio_stats,
            }

        imported = 0
        # _write_to_graph accepts a fixed set of kwargs; strip any extras
        # that parsers may produce (e.g. brain_links from _parse_md_file).
        _graph_keys = {"entry_id", "date", "content", "created_at", "title", "entry_type", "audio_path", "extra_meta"}
        for entry in to_import:
            try:
                graph_entry = {k: v for k, v in entry.items() if k in _graph_keys}
                await self._write_to_graph(graph, **graph_entry)
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
            **audio_stats,
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

        @router.post("/entries/voice", status_code=201)
        async def create_voice_entry(
            file: UploadFile,
            date: str | None = Form(None),
            duration_seconds: float | None = Form(None),
            replace_entry_id: str | None = Form(None),
        ):
            """Upload audio and create (or replace) a voice entry.

            Saves the audio file, creates an entry with status "processing"
            (or resets an existing entry if replace_entry_id is given),
            and kicks off background transcription + LLM cleanup.
            """
            from parachute.core.interfaces import get_registry

            graph = self._get_graph()
            if graph is None:
                return JSONResponse(
                    status_code=503,
                    content={"error": "BrainDB not available"},
                )

            # Check transcription service availability
            ts = get_registry().get("TranscriptionService")
            if ts is None:
                return JSONResponse(
                    status_code=503,
                    content={"error": "Transcription service not available"},
                )

            # Determine date
            date_str = date or datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d")
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_str):
                return JSONResponse(
                    status_code=400,
                    content={"error": "Invalid date format, expected YYYY-MM-DD"},
                )

            # Validate file extension
            ext = (
                Path(file.filename).suffix.lower() if file.filename else ".wav"
            )
            if ext not in ALLOWED_AUDIO_EXTENSIONS:
                return JSONResponse(
                    status_code=400,
                    content={"error": f"Unsupported audio format: {ext}"},
                )

            # Read and validate file size
            contents = await file.read()
            if len(contents) > MAX_VOICE_BYTES:
                return JSONResponse(
                    status_code=413,
                    content={"error": f"File too large (max {MAX_VOICE_BYTES // (1024*1024)} MB)"},
                )

            # Save audio file (reuse asset upload pattern)
            assets_root = ASSETS_DIR.resolve()
            dest_dir = (assets_root / date_str).resolve()
            if not dest_dir.is_relative_to(assets_root):
                return JSONResponse(
                    status_code=400,
                    content={"error": "Invalid date parameter"},
                )

            safe_name = f"{uuid.uuid4().hex[:8]}{ext}"
            audio_path = dest_dir / safe_name

            await asyncio.to_thread(dest_dir.mkdir, parents=True, exist_ok=True)
            await asyncio.to_thread(audio_path.write_bytes, contents)
            logger.info(f"Daily: saved voice recording to {audio_path}")

            if replace_entry_id:
                # Re-transcribe: update existing entry in place
                entry_id = replace_entry_id
                meta_updates: dict[str, Any] = {
                    "audio_path": str(audio_path),
                    "transcription_status": "processing",
                    "cleanup_status": None,  # Clear stale cleanup state
                }
                if duration_seconds is not None:
                    meta_updates["duration_seconds"] = duration_seconds
                updated = await self.update_entry(
                    entry_id, content="", metadata=meta_updates
                )
                if updated is None:
                    return JSONResponse(
                        status_code=404,
                        content={"error": f"Entry {entry_id} not found"},
                    )
                logger.info(f"Daily: re-transcribing entry {entry_id} with new audio")
            else:
                # New entry
                meta: dict[str, Any] = {
                    "type": "voice",
                    "audio_path": str(audio_path),
                    "transcription_status": "processing",
                }
                if duration_seconds is not None:
                    meta["duration_seconds"] = duration_seconds
                result = await self.create_entry("", meta)
                entry_id = result["id"]

            # Kick off background transcription + event dispatch
            task = asyncio.create_task(
                _transcribe_and_cleanup(graph, entry_id, audio_path, dispatch_event_fn=self._dispatch_event)
            )
            _background_tasks.add(task)

            def _on_done(t: asyncio.Task, eid: str = entry_id) -> None:
                _background_tasks.discard(t)
                if not t.cancelled() and (exc := t.exception()):
                    logger.error(
                        "Background transcription failed for entry %s: %s",
                        eid, exc, exc_info=exc,
                    )

            task.add_done_callback(_on_done)

            return {
                "entry_id": entry_id,
                "status": "processing",
                "audio_path": str(audio_path),
            }

        @router.post("/entries/{entry_id}/cleanup")
        async def cleanup_entry(entry_id: str):
            """Run LLM cleanup on an existing entry's content.

            Used for:
            - Entries where audio is gone (can't re-transcribe, but can clean up text)
            - Local-mode re-transcribe follow-up (Parakeet transcribed on-device)
            - The "Clean up" action button on voice entry cards
            """
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(
                    status_code=503,
                    content={"error": "BrainDB not available"},
                )

            # Fetch the entry's current content
            rows = await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $entry_id}) "
                "RETURN e.content AS content, e.metadata_json AS meta",
                {"entry_id": entry_id},
            )
            if not rows:
                return JSONResponse(
                    status_code=404,
                    content={"error": "Entry not found", "id": entry_id},
                )

            content = rows[0].get("content") or ""
            if not content.strip():
                return JSONResponse(
                    status_code=400,
                    content={"error": "Entry has no content to clean up"},
                )

            # Save current content as transcription_raw if not already set
            existing_meta = {}
            blob = rows[0].get("meta") or ""
            try:
                existing_meta = json.loads(blob) if blob else {}
            except (json.JSONDecodeError, TypeError):
                existing_meta = {}

            if not existing_meta.get("transcription_raw"):
                existing_meta["transcription_raw"] = content

            # Mark as cleanup in progress
            existing_meta["transcription_status"] = "transcribed"
            existing_meta["cleanup_status"] = None
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MATCH (e:Note {entry_id: $entry_id}) SET e.metadata_json = $meta",
                    {"entry_id": entry_id, "meta": json.dumps(existing_meta)},
                )

            # Dispatch transcription_complete event to triggered Agents
            task = asyncio.create_task(
                self._dispatch_event("note.transcription_complete", entry_id)
            )
            _background_tasks.add(task)

            def _on_done(t: asyncio.Task, eid: str = entry_id) -> None:
                _background_tasks.discard(t)
                if not t.cancelled() and (exc := t.exception()):
                    logger.error(
                        "Background cleanup failed for entry %s: %s",
                        eid, exc, exc_info=exc,
                    )

            task.add_done_callback(_on_done)

            return {
                "entry_id": entry_id,
                "status": "transcribed",
                "message": "Cleanup started",
            }

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

        @router.get("/entries/{entry_id}/agent-activity")
        async def get_entry_agent_activity(entry_id: str):
            """Get Agent activity history for a specific entry."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})

            try:
                rows = await graph.execute_cypher(
                    "MATCH (r:AgentRun) "
                    "WHERE r.entry_id = $entry_id "
                    "RETURN r ORDER BY r.ran_at DESC",
                    {"entry_id": entry_id},
                )
                activity = []
                for row in rows:
                    agent_name = row.get("agent_name", "")
                    # display_name is stored on AgentRun at write time
                    display_name = (
                        row.get("display_name")
                        or agent_name.replace("-", " ").title()
                    )
                    activity.append({
                        "agent_name": agent_name,
                        "display_name": display_name,
                        "status": row.get("status", ""),
                        "ran_at": row.get("ran_at", ""),
                        "session_id": row.get("session_id", ""),
                    })

                return {"activity": activity, "count": len(activity)}
            except Exception as e:
                logger.warning(f"Failed to get agent activity for {entry_id}: {e}")
                return {"activity": [], "count": 0}

        @router.patch("/entries/{entry_id}")
        async def update_entry(entry_id: str, body: UpdateEntryRequest):
            """Update content and/or metadata of an existing entry."""
            try:
                entry = await self.update_entry(entry_id, content=body.content, metadata=body.metadata)
            except ValueError as e:
                return JSONResponse(
                    status_code=422,
                    content={"error": str(e), "id": entry_id},
                )
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
        async def serve_asset(path: str, request: Request):
            """Stream an audio/image file. Path is relative to ASSETS_DIR."""
            client_host = request.client.host if request.client else "unknown"
            logger.info(f"Daily: asset request from {client_host}: {path}")
            assets_root = ASSETS_DIR.resolve()
            full_path = (assets_root / path).resolve()
            if not full_path.is_relative_to(assets_root):
                logger.warning(f"Daily: asset forbidden (path escape): {path}")
                return JSONResponse(status_code=403, content={"error": "forbidden"})
            if not full_path.exists():
                logger.warning(f"Daily: asset not found: {full_path}")
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

            assets_source: Path | None = None
            if body.assets_source_dir:
                assets_source = Path(body.assets_source_dir).expanduser()
                if not assets_source.is_dir():
                    return JSONResponse(
                        status_code=400,
                        content={"error": f"assets_source_dir not found: {body.assets_source_dir}"},
                    )

            result = await self._flexible_import(
                graph,
                source_dir=source,
                fmt=body.format,
                dry_run=body.dry_run,
                date_from=body.date_from,
                date_to=body.date_to,
                assets_source_dir=assets_source,
            )
            return result

        @router.get("/cards")
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

        @router.get("/cards/unread")
        async def list_unread_cards():
            """Fetch all unread cards within a 7-day window."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            cutoff = (_date.today() - timedelta(days=7)).isoformat()
            rows = await graph.execute_cypher(
                "MATCH (c:Card) "
                "WHERE (c.read_at IS NULL OR c.read_at = '') "
                "AND c.status = 'done' "
                "AND c.date >= $cutoff "
                "RETURN c ORDER BY c.date DESC, c.generated_at DESC",
                {"cutoff": cutoff},
            )
            return {"cards": rows, "count": len(rows)}

        @router.post("/cards/{card_id:path}/read")
        async def mark_card_read(card_id: str):
            """Set read_at timestamp on a card."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            now = datetime.now(timezone.utc).isoformat()
            rows = await graph.execute_cypher(
                "MATCH (c:Card {card_id: $card_id}) "
                "SET c.read_at = $now "
                "RETURN c.card_id AS card_id",
                {"card_id": card_id, "now": now},
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "card not found"})
            return {"card_id": card_id, "read_at": now}

        @router.get("/cards/{agent_name}")
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

        @router.post("/cards/write", status_code=201)
        async def write_card(body: dict):
            """Write a Card to the graph (used by container-side daily tools MCP).

            Body: { agent_name, date, content, display_name?, card_type? }
            """
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            agent_name = body.get("agent_name", "").strip()
            date_str = body.get("date", "").strip()
            content = body.get("content", "").strip()
            card_type = (body.get("card_type") or "default").strip()
            if not agent_name or not date_str or not content:
                return JSONResponse(
                    status_code=400,
                    content={"error": "agent_name, date, and content are required"},
                )
            if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,63}", agent_name):
                return JSONResponse(status_code=400, content={"error": "invalid agent_name format"})
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_str):
                return JSONResponse(status_code=400, content={"error": "invalid date format"})
            if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,31}", card_type):
                return JSONResponse(status_code=400, content={"error": "invalid card_type format"})
            # Verify agent_name corresponds to a known Agent
            agent_rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a.name",
                {"name": agent_name},
            )
            if not agent_rows:
                return JSONResponse(status_code=403, content={"error": "unknown agent"})
            card_id = f"{agent_name}:{card_type}:{date_str}"
            display_name = body.get("display_name") or agent_name.replace("-", " ").title()
            generated_at = datetime.now(timezone.utc).isoformat()
            await graph.execute_cypher(
                "MERGE (c:Card {card_id: $card_id}) "
                "SET c.agent_name = $agent_name, "
                "    c.card_type = $card_type, "
                "    c.display_name = $display_name, "
                "    c.content = $content, "
                "    c.generated_at = $generated_at, "
                "    c.status = 'done', "
                "    c.date = $date, "
                "    c.read_at = ''",
                {
                    "card_id": card_id,
                    "agent_name": agent_name,
                    "card_type": card_type,
                    "display_name": display_name,
                    "content": content,
                    "generated_at": generated_at,
                    "date": date_str,
                },
            )
            return {"card_id": card_id, "status": "done", "date": date_str}

        @router.post("/cards/{agent_name}/run", status_code=202)
        async def run_card(
            agent_name: str,
            date: str | None = Query(None),
            force: bool = Query(False),
        ):
            """Trigger an agent run for a date (async — returns 202 immediately)."""
            from parachute.core.daily_agent import run_daily_agent
            task = asyncio.create_task(
                run_daily_agent(self.home_path, agent_name, date=date, force=force, trigger="manual")
            )
            _background_tasks.add(task)
            task.add_done_callback(_log_task_exception)
            return {"status": "started", "agent": agent_name, "date": date}

        @router.get("/agents/{agent_name}/runs/latest")
        async def get_agent_latest_run(agent_name: str):
            """Get the most recent run for an agent (used by Flutter to show failure state)."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            try:
                rows = await graph.execute_cypher(
                    "MATCH (r:AgentRun) "
                    "WHERE r.agent_name = $name "
                    "RETURN r ORDER BY r.started_at DESC",
                    {"name": agent_name},
                )
                if not rows:
                    return JSONResponse(status_code=404, content={"error": "No runs found"})
                row = rows[0]
                return {
                    "status": row.get("status", ""),
                    "error": row.get("error", ""),
                    "trigger": row.get("trigger", ""),
                }
            except Exception as e:
                logger.warning(f"Failed to get latest run for {agent_name}: {e}")
                return JSONResponse(status_code=500, content={"error": str(e)})

        # ── Agents (autonomous agent definitions) ─────────────────────────────
        # IMPORTANT: /agents/templates must be registered before /agents/{name}
        # so FastAPI matches the literal path before the path parameter.

        @router.get("/agents/templates")
        def list_agent_templates() -> dict[str, list[AgentTemplateDict]]:
            """Return starter Agent templates for onboarding.

            Templates have the same shape as POST /agents bodies so the
            client can create an agent directly from a template.
            """
            return {"templates": AGENT_TEMPLATES}

        @router.get("/agents/events")
        def list_agent_events():
            """Return available trigger events for Agents."""
            return {
                "events": [
                    {"event": "note.created", "description": "Fires when a new note is saved"},
                    {"event": "note.transcription_complete", "description": "Fires when voice transcription finishes"},
                ]
            }

        @router.get("/agents")
        async def list_agents():
            """List all Agent nodes from the graph, enriched with builtin status."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (a:Agent) RETURN a ORDER BY a.name"
            )
            # Enrich each agent with builtin/update metadata
            builtin_names = {t["name"]: t for t in AGENT_TEMPLATES}
            for agent in rows:
                name = agent.get("name", "")
                tpl = builtin_names.get(name)
                agent["is_builtin"] = tpl is not None
                if tpl:
                    tpl_v = tpl.get("template_version", "")
                    agent_v = (agent.get("template_version") or "").strip()
                    # NOTE: version comparison requires YYYY-MM-DD format for lexicographic ordering
                    agent["update_available"] = bool(
                        tpl_v and agent_v and agent_v < tpl_v
                    )
                    # Surface user_modified as bool for the client
                    agent["user_modified"] = (agent.get("user_modified") or "").strip() == "true"
                else:
                    agent["update_available"] = False
            return {"agents": rows, "count": len(rows)}

        @router.get("/agents/{name}")
        async def get_agent(name: str):
            """Get a specific Agent node."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a",
                {"name": name},
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "not found"})
            return rows[0]

        @router.get("/agents/{name}/transcript")
        async def get_agent_transcript(name: str, limit: int = Query(50)):
            """Get the SDK conversation transcript for an Agent's latest session.

            Returns parsed JSONL events in the shape the Flutter AgentLogScreen
            expects: ``{ hasTranscript, sessionId, totalMessages, messages }``.

            Uses the Agent node's ``container_slug`` and ``trust_level`` to
            resolve the transcript file location — sandboxed agents write
            inside their container bind-mount, direct agents write to the
            host's ``~/.claude/projects/``.
            """
            graph = self._get_graph()
            if graph is None:
                return {"hasTranscript": False, "message": "BrainDB not available"}

            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) "
                "RETURN a.sdk_session_id AS sid, "
                "       a.container_slug AS container_slug, "
                "       a.trust_level AS trust_level",
                {"name": name},
            )
            if not rows:
                return {"hasTranscript": False, "message": "Agent not found."}

            sid = (rows[0].get("sid") or "").strip()
            if not sid:
                return {"hasTranscript": False, "message": "This agent hasn't run yet."}

            # Resolve container slug: explicit config, or default for sandboxed agents
            container_slug = (rows[0].get("container_slug") or "").strip()
            trust_level = (rows[0].get("trust_level") or "sandboxed").strip()
            if not container_slug and trust_level == "sandboxed":
                container_slug = f"agent-{name}"

            parachute_dir = Path(self.home_path) / ".parachute"

            # Search for the JSONL transcript file and parse it off the
            # event loop (file I/O is blocking).
            return await asyncio.to_thread(
                _read_transcript_file, sid, limit,
                container_slug, parachute_dir,
            )

        @router.post("/agents", status_code=201)
        async def create_agent(body: dict):
            """Create or update an Agent node (MERGE on name)."""
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
            # Normalize trigger_filter to JSON string
            trigger_filter = body.get("trigger_filter") or {}
            if isinstance(trigger_filter, dict):
                trigger_filter = json.dumps(trigger_filter)

            memory_mode = body.get("memory_mode", "persistent")
            if memory_mode not in ("persistent", "fresh"):
                memory_mode = "persistent"

            await graph.execute_cypher(
                "MERGE (a:Agent {name: $name}) "
                "SET a.display_name = $display_name, a.description = $description, "
                "    a.system_prompt = $system_prompt, a.tools = $tools, "
                "    a.model = $model, a.schedule_enabled = $schedule_enabled, "
                "    a.schedule_time = $schedule_time, a.enabled = $enabled, "
                "    a.trust_level = $trust_level, "
                "    a.trigger_event = $trigger_event, "
                "    a.trigger_filter = $trigger_filter, "
                "    a.memory_mode = $memory_mode, "
                "    a.container_slug = $container_slug, "
                "    a.updated_at = $now",
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
                    "trigger_event": body.get("trigger_event") or "",
                    "trigger_filter": trigger_filter,
                    "memory_mode": memory_mode,
                    "container_slug": body.get("container_slug") or "",
                    "now": now,
                },
            )
            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a", {"name": name}
            )
            return rows[0] if rows else {"name": name}

        @router.put("/agents/{name}")
        async def update_agent(name: str, body: dict):
            """Update fields on an existing Agent node."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            now = datetime.now(timezone.utc).isoformat()
            # Fetch existing
            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a", {"name": name}
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "not found"})
            existing = rows[0]
            trust_level = body.get("trust_level", existing.get("trust_level") or "sandboxed")
            if trust_level not in ("sandboxed", "direct"):
                trust_level = "sandboxed"
            # Normalize trigger_filter
            trigger_filter = body.get("trigger_filter", existing.get("trigger_filter") or "{}")
            if isinstance(trigger_filter, dict):
                trigger_filter = json.dumps(trigger_filter)
            # Normalize memory_mode
            memory_mode = body.get("memory_mode", existing.get("memory_mode") or "persistent")
            if memory_mode not in ("persistent", "fresh"):
                memory_mode = "persistent"

            await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) "
                "SET a.display_name = $display_name, a.description = $description, "
                "    a.system_prompt = $system_prompt, a.tools = $tools, "
                "    a.model = $model, a.schedule_enabled = $schedule_enabled, "
                "    a.schedule_time = $schedule_time, a.enabled = $enabled, "
                "    a.trust_level = $trust_level, "
                "    a.trigger_event = $trigger_event, "
                "    a.trigger_filter = $trigger_filter, "
                "    a.memory_mode = $memory_mode, "
                "    a.user_modified = 'true', "
                "    a.updated_at = $now",
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
                    "trigger_event": body.get("trigger_event", existing.get("trigger_event") or ""),
                    "trigger_filter": trigger_filter,
                    "memory_mode": memory_mode,
                    "now": now,
                },
            )
            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a", {"name": name}
            )
            return rows[0] if rows else {"name": name}

        @router.post("/agents/{name}/trigger")
        async def trigger_agent(name: str, body: dict):
            """Manually trigger an Agent on a specific entry (ignores filters).

            Body: { "entry_id": "..." }
            """
            entry_id = body.get("entry_id", "").strip()
            if not entry_id:
                return JSONResponse(status_code=400, content={"error": "entry_id required"})

            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})

            # Verify agent exists
            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a.trigger_event AS trigger_event",
                {"name": name},
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "Agent not found"})

            event = rows[0].get("trigger_event") or "note.created"

            from parachute.core.daily_agent import run_triggered_agent
            task = asyncio.create_task(
                run_triggered_agent(self.home_path, name, entry_id, event)
            )
            _background_tasks.add(task)
            task.add_done_callback(_log_task_exception)

            return {"status": "triggered", "agent": name, "entry_id": entry_id, "event": event}

        @router.post("/agents/{name}/reset", status_code=200)
        async def reset_agent(name: str):
            """Reset an Agent's session state so its next run starts fresh."""
            # Validate name to prevent path traversal
            if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,63}", name):
                return JSONResponse(status_code=400, content={"error": "invalid agent name format"})
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            # Verify Agent exists
            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a", {"name": name}
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "not found"})
            # Clear the agent's SDK session so next run starts fresh
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MATCH (a:Agent {name: $name}) SET a.sdk_session_id = ''",
                    {"name": name},
                )
            return {"status": "reset", "agent": name}

        @router.post("/agents/{name}/reset-to-template")
        async def reset_to_template(name: str):
            """Reset a builtin agent to the latest template defaults.

            Preserves runtime state (schedule_enabled, enabled, sdk_session_id,
            last_run_at, run_count, last_processed_date).
            """
            tpl = next((t for t in AGENT_TEMPLATES if t["name"] == name), None)
            if tpl is None:
                return JSONResponse(
                    status_code=400,
                    content={"error": f"'{name}' is not a builtin agent"},
                )

            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})

            now = datetime.now(timezone.utc).isoformat()
            is_triggered = bool(tpl.get("trigger_event", ""))

            # Check existence and write atomically under the lock to avoid TOCTOU
            async with graph.write_lock:
                rows = await graph.execute_cypher(
                    "MATCH (a:Agent {name: $name}) RETURN a", {"name": name}
                )
                if not rows:
                    return JSONResponse(status_code=404, content={"error": "not found"})

                await graph.execute_cypher(
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
                    "    a.user_modified = 'false',"
                    "    a.updated_at = $now",
                    {
                        "name": name,
                        "display_name": tpl.get("display_name", name.replace("-", " ").title()),
                        "description": tpl.get("description", ""),
                        "system_prompt": tpl.get("system_prompt", ""),
                        "tools": json.dumps(tpl.get("tools", [])),
                        "schedule_time": tpl.get("schedule_time", "") if not is_triggered else "",
                        "trust_level": tpl.get("trust_level", "sandboxed"),
                        "trigger_event": tpl.get("trigger_event", ""),
                        "trigger_filter": tpl.get("trigger_filter", "{}"),
                        "memory_mode": tpl.get("memory_mode", "persistent"),
                        "template_version": tpl.get("template_version", ""),
                        "now": now,
                    },
                )

            # Re-fetch and return
            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a", {"name": name}
            )
            return rows[0] if rows else {"name": name, "status": "reset"}

        @router.delete("/agents/{name}", status_code=204)
        async def delete_agent(name: str):
            """Delete an Agent node and reload the scheduler."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MATCH (a:Agent {name: $name}) DELETE a", {"name": name}
                )
            # Reload scheduler so deleted scheduled agents are removed
            try:
                from parachute.core.scheduler import reload_scheduler
                home_path = Path(self.home_path)
                await reload_scheduler(home_path, graph=graph)
            except Exception as e:
                logger.warning(f"Daily: scheduler reload after delete failed: {e}")
            return Response(status_code=204)

        # ── Helper: inline trigger upsert from Flutter ────────────────────

        # Builtin trigger names that must not be overwritten by inline upserts
        _RESERVED_TRIGGER_NAMES = {t["name"] for t in TRIGGER_TEMPLATES}
        _TIME_RE = re.compile(r"^([01]?\d|2[0-3]):[0-5]\d$")

        async def _upsert_inline_trigger(graph, tool_name: str, body: dict) -> None:
            """Create/update a Trigger from inline schedule/event fields in the Tool body.

            Flutter sends schedule_enabled, schedule_time, trigger_event, trigger_filter
            as part of the Tool create/update body. This method bridges those fields to
            the Trigger table + INVOKES edge.
            """
            has_schedule = "schedule_enabled" in body or "schedule_time" in body
            has_event = "trigger_event" in body
            if not has_schedule and not has_event:
                return

            now = datetime.now(timezone.utc).isoformat()

            if has_event and body.get("trigger_event"):
                # Event trigger
                trigger_name = f"on-{tool_name}"
                if trigger_name in _RESERVED_TRIGGER_NAMES:
                    logger.warning(
                        f"Inline trigger '{trigger_name}' collides with builtin — skipping"
                    )
                    return
                event_filter = body.get("trigger_filter", {})
                if isinstance(event_filter, dict):
                    event_filter = json.dumps(event_filter)
                try:
                    async with graph.write_lock:
                        await graph.execute_cypher(
                            "MERGE (tr:Trigger {name: $tname}) "
                            "SET tr.type = 'event', "
                            "    tr.event = $event, "
                            "    tr.event_filter = $filter, "
                            "    tr.enabled = 'true', "
                            "    tr.updated_at = $now",
                            {
                                "tname": trigger_name,
                                "event": body["trigger_event"],
                                "filter": event_filter if isinstance(event_filter, str) else json.dumps(event_filter),
                                "now": now,
                            },
                        )
                        # Ensure INVOKES edge
                        await graph.execute_cypher(
                            "MATCH (tr:Trigger {name: $tname}), (t:Tool {name: $tool}) "
                            "MERGE (tr)-[:INVOKES]->(t)",
                            {"tname": trigger_name, "tool": tool_name},
                        )
                except Exception as e:
                    logger.warning(f"Inline trigger upsert (event) for '{tool_name}': {e}")

            elif has_schedule:
                # Schedule trigger
                trigger_name = f"scheduled-{tool_name}"
                if trigger_name in _RESERVED_TRIGGER_NAMES:
                    logger.warning(
                        f"Inline trigger '{trigger_name}' collides with builtin — skipping"
                    )
                    return
                enabled = body.get("schedule_enabled", True)
                enabled_str = "true" if enabled else "false"
                schedule_time = body.get("schedule_time", "03:00")
                if not _TIME_RE.match(schedule_time):
                    schedule_time = "03:00"
                # Validate scope.date
                scope_raw = body.get("scope", {"date": "yesterday"})
                if isinstance(scope_raw, dict):
                    date_val = scope_raw.get("date", "yesterday")
                    if date_val != "yesterday" and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(date_val)):
                        date_val = "yesterday"
                    scope_raw = {"date": date_val}
                scope = json.dumps(scope_raw)
                try:
                    async with graph.write_lock:
                        await graph.execute_cypher(
                            "MERGE (tr:Trigger {name: $tname}) "
                            "SET tr.type = 'schedule', "
                            "    tr.schedule_time = $time, "
                            "    tr.scope = $scope, "
                            "    tr.enabled = $enabled, "
                            "    tr.updated_at = $now",
                            {
                                "tname": trigger_name,
                                "time": schedule_time,
                                "scope": scope,
                                "enabled": enabled_str,
                                "now": now,
                            },
                        )
                        # Ensure INVOKES edge
                        await graph.execute_cypher(
                            "MATCH (tr:Trigger {name: $tname}), (t:Tool {name: $tool}) "
                            "MERGE (tr)-[:INVOKES]->(t)",
                            {"tname": trigger_name, "tool": tool_name},
                        )
                except Exception as e:
                    logger.warning(f"Inline trigger upsert (schedule) for '{tool_name}': {e}")

            # Reload scheduler so changes take effect
            try:
                from parachute.core.scheduler import reload_scheduler
                home_path = Path(self.home_path)
                await reload_scheduler(home_path, graph=graph)
            except Exception as e:
                logger.warning(f"Scheduler reload after trigger upsert: {e}")

        # ── Tool + Trigger endpoints (universal primitive) ─────────────────

        @router.get("/tools/templates")
        def list_tool_templates() -> dict[str, list[ToolTemplateDict]]:
            """Return TOOL_TEMPLATES for onboarding / reference."""
            return {"templates": TOOL_TEMPLATES}

        @router.get("/tools/events")
        def list_tool_events():
            """Return available trigger event types."""
            return {
                "events": [
                    {"event": "note.created", "description": "Fires when a new note is saved"},
                    {"event": "note.transcription_complete", "description": "Fires when voice transcription finishes"},
                ]
            }

        @router.get("/tools")
        async def list_tools():
            """List all Tool nodes from the graph."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (t:Tool) RETURN t ORDER BY t.name"
            )
            # Parse scope_keys from JSON string for client convenience
            for tool in rows:
                sk = tool.get("scope_keys", "[]")
                try:
                    tool["scope_keys_parsed"] = json.loads(sk) if sk else []
                except (json.JSONDecodeError, TypeError):
                    tool["scope_keys_parsed"] = []
            # Enrich with builtin/update metadata
            builtin_names = {t["name"]: t for t in TOOL_TEMPLATES}
            for tool in rows:
                name = tool.get("name", "")
                tpl = builtin_names.get(name)
                tool["is_builtin"] = tpl is not None
                if tpl:
                    tpl_v = tpl.get("template_version", "")
                    tool_v = (tool.get("template_version") or "").strip()
                    tool["update_available"] = bool(tpl_v and tool_v and tool_v < tpl_v)
                    tool["user_modified"] = (tool.get("user_modified") or "").strip() == "true"
                else:
                    tool["update_available"] = False
            return {"tools": rows, "count": len(rows)}

        @router.get("/tools/{name}")
        async def get_tool(name: str):
            """Get a specific Tool node with its CAN_CALL children and triggers."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) RETURN t",
                {"name": name},
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": f"Tool '{name}' not found"})
            tool = rows[0]
            # Fetch CAN_CALL children
            try:
                children = await graph.execute_cypher(
                    "MATCH (t:Tool {name: $name})-[:CAN_CALL]->(child:Tool) "
                    "RETURN child.name AS name, child.display_name AS display_name, "
                    "child.mode AS mode ORDER BY child.name",
                    {"name": name},
                )
            except Exception:
                children = []
            tool["can_call"] = children
            # Fetch triggers that invoke this tool
            try:
                triggers = await graph.execute_cypher(
                    "MATCH (trigger:Trigger)-[:INVOKES]->(t:Tool {name: $name}) "
                    "RETURN trigger",
                    {"name": name},
                )
            except Exception:
                triggers = []
            tool["triggers"] = triggers
            return tool

        @router.post("/tools", status_code=201)
        async def create_tool(request: Request):
            """Create or update a Tool node (MERGE on name)."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            body = await request.json()
            name = (body.get("name") or "").strip()
            if not name or not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,63}", name):
                return JSONResponse(
                    status_code=400,
                    content={"error": "name is required (lowercase alphanumeric + hyphens, max 64)"},
                )
            now = datetime.now(timezone.utc).isoformat()
            mode = body.get("mode", "function")
            if mode not in ("function", "transform", "agent", "mcp"):
                return JSONResponse(
                    status_code=400,
                    content={"error": f"Invalid mode '{mode}'. Must be function, transform, agent, or mcp"},
                )
            scope_keys = body.get("scope_keys", [])
            if isinstance(scope_keys, list):
                scope_keys = json.dumps(scope_keys)

            data = {
                "name": name,
                "display_name": body.get("display_name", name.replace("-", " ").title()),
                "description": body.get("description", ""),
                "mode": mode,
                "scope_keys": scope_keys,
                "input_schema": body.get("input_schema", ""),
                "query": body.get("query", ""),
                "write_query": body.get("write_query", ""),
                "transform_prompt": body.get("transform_prompt", ""),
                "transform_model": body.get("transform_model", ""),
                "system_prompt": body.get("system_prompt", ""),
                "model": body.get("model", ""),
                "memory_mode": body.get("memory_mode", ""),
                "trust_level": body.get("trust_level", "sandboxed") if body.get("trust_level") in ("sandboxed", "direct") else "sandboxed",
                "container_slug": body.get("container_slug", ""),
                "server_name": body.get("server_name", ""),
                "builtin": body.get("builtin", "false"),
                "enabled": "true" if body.get("enabled", True) else "false",
                "template_version": body.get("template_version", ""),
                "user_modified": "true",
                "now": now,
            }
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MERGE (t:Tool {name: $name}) "
                    "ON CREATE SET t.created_at = $now "
                    "SET t.display_name = $display_name,"
                    "    t.description = $description,"
                    "    t.mode = $mode,"
                    "    t.scope_keys = $scope_keys,"
                    "    t.input_schema = $input_schema,"
                    "    t.query = $query,"
                    "    t.write_query = $write_query,"
                    "    t.transform_prompt = $transform_prompt,"
                    "    t.transform_model = $transform_model,"
                    "    t.system_prompt = $system_prompt,"
                    "    t.model = $model,"
                    "    t.memory_mode = $memory_mode,"
                    "    t.trust_level = $trust_level,"
                    "    t.container_slug = $container_slug,"
                    "    t.server_name = $server_name,"
                    "    t.builtin = $builtin,"
                    "    t.enabled = $enabled,"
                    "    t.template_version = $template_version,"
                    "    t.user_modified = $user_modified,"
                    "    t.updated_at = $now",
                    data,
                )
            # Handle can_call edges
            can_call = body.get("can_call", [])
            if isinstance(can_call, list) and can_call:
                # Clear existing CAN_CALL edges, then recreate
                try:
                    async with graph.write_lock:
                        await graph.execute_cypher(
                            "MATCH (t:Tool {name: $name})-[r:CAN_CALL]->() DELETE r",
                            {"name": name},
                        )
                    for child_name in can_call:
                        try:
                            async with graph.write_lock:
                                await graph.execute_cypher(
                                    "MATCH (parent:Tool {name: $parent}), "
                                    "(child:Tool {name: $child}) "
                                    "CREATE (parent)-[:CAN_CALL]->(child)",
                                    {"parent": name, "child": child_name},
                                )
                        except Exception as e:
                            logger.debug(f"CAN_CALL {name} → {child_name}: {e}")
                except Exception as e:
                    logger.warning(f"Error managing CAN_CALL edges: {e}")
            # Handle inline trigger fields from Flutter (schedule/event)
            await _upsert_inline_trigger(graph, name, body)

            # Return the created tool
            result = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) RETURN t", {"name": name}
            )
            return result[0] if result else {"name": name}

        @router.put("/tools/{name}")
        async def update_tool(name: str, request: Request):
            """Update fields on an existing Tool node."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) RETURN t", {"name": name}
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": f"Tool '{name}' not found"})
            existing = rows[0]
            body = await request.json()
            now = datetime.now(timezone.utc).isoformat()

            # Merge with existing, body takes precedence
            updatable = [
                "display_name", "description", "mode", "scope_keys",
                "input_schema", "query", "write_query",
                "transform_prompt", "transform_model",
                "system_prompt", "model", "memory_mode",
                "trust_level", "container_slug", "server_name", "enabled",
            ]
            data: dict[str, Any] = {"name": name, "now": now}
            set_clauses = ["t.user_modified = 'true'", "t.updated_at = $now"]
            for field in updatable:
                if field in body:
                    val = body[field]
                    if field == "scope_keys" and isinstance(val, list):
                        val = json.dumps(val)
                    elif field == "enabled":
                        val = "true" if val else "false"
                    elif field == "trust_level":
                        val = val if val in ("sandboxed", "direct") else "sandboxed"
                    data[field] = val
                    set_clauses.append(f"t.{field} = ${field}")

            if len(set_clauses) > 2:  # more than just user_modified + updated_at
                async with graph.write_lock:
                    await graph.execute_cypher(
                        f"MATCH (t:Tool {{name: $name}}) SET {', '.join(set_clauses)}",
                        data,
                    )

            # Handle can_call if provided
            if "can_call" in body:
                can_call = body["can_call"]
                try:
                    async with graph.write_lock:
                        await graph.execute_cypher(
                            "MATCH (t:Tool {name: $name})-[r:CAN_CALL]->() DELETE r",
                            {"name": name},
                        )
                    if isinstance(can_call, list):
                        for child_name in can_call:
                            try:
                                async with graph.write_lock:
                                    await graph.execute_cypher(
                                        "MATCH (parent:Tool {name: $parent}), "
                                        "(child:Tool {name: $child}) "
                                        "CREATE (parent)-[:CAN_CALL]->(child)",
                                        {"parent": name, "child": child_name},
                                    )
                            except Exception as e:
                                logger.debug(f"CAN_CALL {name} → {child_name}: {e}")
                except Exception as e:
                    logger.warning(f"Error managing CAN_CALL edges: {e}")

            # Handle inline trigger fields from Flutter (schedule/event)
            await _upsert_inline_trigger(graph, name, body)

            result = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) RETURN t", {"name": name}
            )
            return result[0] if result else {"name": name}

        @router.delete("/tools/{name}", status_code=204)
        async def delete_tool(name: str):
            """Delete a Tool node and its edges."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            async with graph.write_lock:
                # Delete edges first, then node
                await graph.execute_cypher(
                    "MATCH (t:Tool {name: $name})-[r:CAN_CALL]->() DELETE r",
                    {"name": name},
                )
                await graph.execute_cypher(
                    "MATCH ()-[r:CAN_CALL]->(t:Tool {name: $name}) DELETE r",
                    {"name": name},
                )
                await graph.execute_cypher(
                    "MATCH ()-[r:INVOKES]->(t:Tool {name: $name}) DELETE r",
                    {"name": name},
                )
                await graph.execute_cypher(
                    "MATCH (t:Tool {name: $name}) DELETE t",
                    {"name": name},
                )
            # Also delete orphaned Triggers that INVOKES-ed this tool
            try:
                async with graph.write_lock:
                    await graph.execute_cypher(
                        "MATCH (tr:Trigger) WHERE NOT (tr)-[:INVOKES]->(:Tool) DELETE tr"
                    )
            except Exception as e:
                logger.debug(f"Orphan trigger cleanup: {e}")
            # Reload scheduler
            try:
                from parachute.core.scheduler import reload_scheduler
                await reload_scheduler(Path(self.home_path), graph=graph)
            except Exception as e:
                logger.warning(f"Scheduler reload after tool delete: {e}")
            return Response(status_code=204)

        @router.post("/tools/{name}/reset", status_code=200)
        async def reset_tool(name: str):
            """Reset a Tool's session state so its next run starts fresh.

            Clears the latest ToolRun's session_id and also clears the
            Agent node's sdk_session_id for backward compatibility.
            """
            if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,63}", name):
                return JSONResponse(status_code=400, content={"error": "invalid name format"})
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) RETURN t.name AS name", {"name": name}
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "not found"})
            # Clear Agent node session (backward compat)
            try:
                async with graph.write_lock:
                    await graph.execute_cypher(
                        "MATCH (a:Agent {name: $name}) SET a.sdk_session_id = ''",
                        {"name": name},
                    )
            except Exception:
                pass
            return {"status": "reset", "tool": name}

        @router.post("/tools/{name}/reset-to-template")
        async def reset_tool_to_template(name: str):
            """Reset a builtin tool to its latest template defaults."""
            tpl = next((t for t in TOOL_TEMPLATES if t["name"] == name), None)
            if tpl is None:
                return JSONResponse(
                    status_code=400,
                    content={"error": f"'{name}' is not a builtin tool"},
                )
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})

            now = datetime.now(timezone.utc).isoformat()
            rows = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) RETURN t", {"name": name}
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": "not found"})

            # Reset tool fields from template
            can_call = json.dumps(tpl.get("can_call", []))
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MATCH (t:Tool {name: $name}) "
                    "SET t.display_name = $display_name,"
                    "    t.description = $description,"
                    "    t.system_prompt = $system_prompt,"
                    "    t.can_call = $can_call,"
                    "    t.trust_level = $trust_level,"
                    "    t.memory_mode = $memory_mode,"
                    "    t.template_version = $template_version,"
                    "    t.user_modified = 'false',"
                    "    t.updated_at = $now",
                    {
                        "name": name,
                        "display_name": tpl.get("display_name", name.replace("-", " ").title()),
                        "description": tpl.get("description", ""),
                        "system_prompt": tpl.get("system_prompt", ""),
                        "can_call": can_call,
                        "trust_level": tpl.get("trust_level", "sandboxed"),
                        "memory_mode": tpl.get("memory_mode", "persistent"),
                        "template_version": tpl.get("template_version", ""),
                        "now": now,
                    },
                )

            # Also reset associated Agent node for backward compat
            agent_tpl = next((a for a in AGENT_TEMPLATES if a["name"] == name), None)
            if agent_tpl:
                try:
                    async with graph.write_lock:
                        await graph.execute_cypher(
                            "MATCH (a:Agent {name: $name}) "
                            "SET a.display_name = $display_name,"
                            "    a.description = $description,"
                            "    a.system_prompt = $system_prompt,"
                            "    a.tools = $tools,"
                            "    a.trust_level = $trust_level,"
                            "    a.memory_mode = $memory_mode,"
                            "    a.template_version = $template_version,"
                            "    a.user_modified = 'false',"
                            "    a.updated_at = $now",
                            {
                                "name": name,
                                "display_name": agent_tpl.get("display_name", ""),
                                "description": agent_tpl.get("description", ""),
                                "system_prompt": agent_tpl.get("system_prompt", ""),
                                "tools": json.dumps(agent_tpl.get("tools", [])),
                                "trust_level": agent_tpl.get("trust_level", "sandboxed"),
                                "memory_mode": agent_tpl.get("memory_mode", "persistent"),
                                "template_version": agent_tpl.get("template_version", ""),
                                "now": now,
                            },
                        )
                except Exception as e:
                    logger.debug(f"Agent reset-to-template backward compat: {e}")

            # Re-fetch
            result = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) RETURN t", {"name": name}
            )
            return result[0] if result else {"name": name, "status": "reset"}

        @router.post("/tools/{name}/run", status_code=202)
        async def run_tool_manually(name: str, request: Request):
            """Manually trigger a Tool. For agent/transform mode tools."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) RETURN t.mode AS mode",
                {"name": name},
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": f"Tool '{name}' not found"})

            body = await request.json()
            scope = body.get("scope", {})
            force = body.get("force", False)

            # For now, delegate to the old agent runner for agent/transform mode
            mode = rows[0].get("mode", "function")
            if mode in ("agent", "transform"):
                try:
                    from parachute.core.daily_agent import run_agent
                    home_path = Path(self.home_path)

                    async def _run():
                        try:
                            await run_agent(home_path, name, scope, force=force, trigger="manual")
                        except Exception as e:
                            logger.error(f"Manual tool run failed for '{name}': {e}")

                    task = asyncio.create_task(_run())
                    _background_tasks.add(task)
                    task.add_done_callback(_background_tasks.discard)
                except Exception as e:
                    return JSONResponse(status_code=500, content={"error": str(e)})
            else:
                return JSONResponse(
                    status_code=400,
                    content={"error": f"Tool '{name}' (mode={mode}) cannot be manually triggered"},
                )
            return {"status": "triggered", "tool": name, "scope": scope}

        @router.get("/tools/{name}/runs/latest")
        async def get_tool_latest_run(name: str):
            """Get the most recent ToolRun for a tool. Falls back to AgentRun."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            # Try ToolRun first
            rows = await graph.execute_cypher(
                "MATCH (r:ToolRun) WHERE r.tool_name = $name "
                "RETURN r ORDER BY r.started_at DESC",
                {"name": name},
            )
            if rows:
                return rows[0]
            # Fall back to AgentRun (transition period)
            rows = await graph.execute_cypher(
                "MATCH (r:AgentRun) WHERE r.agent_name = $name "
                "RETURN r ORDER BY r.started_at DESC",
                {"name": name},
            )
            if rows:
                return rows[0]
            return JSONResponse(status_code=404, content={"error": f"No runs found for tool '{name}'"})

        @router.get("/tools/{name}/transcript")
        async def get_tool_transcript(name: str, limit: int = 50):
            """Get agent transcript using Tool node metadata for container resolution."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})

            # Try Tool node first for container_slug and trust_level
            rows = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) "
                "RETURN t.container_slug AS container_slug, t.trust_level AS trust_level",
                {"name": name},
            )
            if not rows:
                # Fall back to Agent node (transition period)
                rows = await graph.execute_cypher(
                    "MATCH (a:Agent {name: $name}) "
                    "RETURN a.sdk_session_id AS sid, "
                    "a.container_slug AS container_slug, a.trust_level AS trust_level",
                    {"name": name},
                )
            if not rows:
                return JSONResponse(status_code=404, content={"error": f"Tool '{name}' not found"})

            # Get latest session_id from ToolRun, fall back to AgentRun, then Agent node
            sid = None
            run_rows = await graph.execute_cypher(
                "MATCH (r:ToolRun {tool_name: $name}) WHERE r.session_id IS NOT NULL "
                "AND r.session_id <> '' RETURN r.session_id AS sid "
                "ORDER BY r.started_at DESC LIMIT 1",
                {"name": name},
            )
            if run_rows:
                sid = run_rows[0].get("sid")
            if not sid:
                # Fall back to AgentRun
                run_rows = await graph.execute_cypher(
                    "MATCH (r:AgentRun {agent_name: $name}) WHERE r.session_id IS NOT NULL "
                    "AND r.session_id <> '' RETURN r.session_id AS sid "
                    "ORDER BY r.started_at DESC LIMIT 1",
                    {"name": name},
                )
                if run_rows:
                    sid = run_rows[0].get("sid")
            if not sid:
                # Fall back to Agent.sdk_session_id
                agent_rows = await graph.execute_cypher(
                    "MATCH (a:Agent {name: $name}) RETURN a.sdk_session_id AS sid",
                    {"name": name},
                )
                if agent_rows:
                    sid = (agent_rows[0].get("sid") or "").strip()

            if not sid:
                return {"hasTranscript": False, "sessionId": None, "totalMessages": 0, "messages": []}

            # Resolve container slug
            container_slug = (rows[0].get("container_slug") or "").strip()
            trust_level = (rows[0].get("trust_level") or "sandboxed").strip()
            if not container_slug and trust_level == "sandboxed":
                container_slug = f"agent-{name}"

            parachute_dir = Path(self.home_path) / ".parachute"
            transcript_path = await asyncio.to_thread(
                _find_transcript_file, sid, container_slug, parachute_dir
            )

            if not transcript_path:
                return {"hasTranscript": False, "sessionId": sid, "totalMessages": 0, "messages": []}

            messages = await asyncio.to_thread(
                _read_transcript_file, sid, limit, container_slug, parachute_dir
            )
            return {
                "hasTranscript": True,
                "sessionId": sid,
                "totalMessages": len(messages),
                "messages": messages[-limit:] if len(messages) > limit else messages,
            }

        # ── Trigger endpoints ─────────────────────────────────────────────

        @router.get("/triggers/templates")
        def list_trigger_templates() -> dict[str, list[TriggerTemplateDict]]:
            """Return TRIGGER_TEMPLATES for reference."""
            return {"templates": TRIGGER_TEMPLATES}

        @router.get("/triggers")
        async def list_triggers():
            """List all Trigger nodes with their target Tools."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (t:Trigger) "
                "OPTIONAL MATCH (t)-[:INVOKES]->(tool:Tool) "
                "RETURN t.name AS name, t.type AS type, "
                "t.schedule_time AS schedule_time, t.event AS event, "
                "t.event_filter AS event_filter, t.scope AS scope, "
                "t.enabled AS enabled, t.template_version AS template_version, "
                "t.user_modified AS user_modified, "
                "t.created_at AS created_at, t.updated_at AS updated_at, "
                "tool.name AS invokes_tool, tool.display_name AS invokes_display_name "
                "ORDER BY t.name"
            )
            triggers = []
            for row in rows:
                trigger = dict(row)
                # Parse scope from JSON
                scope_raw = trigger.get("scope", "{}")
                try:
                    trigger["scope_parsed"] = json.loads(scope_raw) if scope_raw else {}
                except (json.JSONDecodeError, TypeError):
                    trigger["scope_parsed"] = {}
                triggers.append(trigger)
            return {"triggers": triggers, "count": len(triggers)}

        @router.get("/triggers/{name}")
        async def get_trigger(name: str):
            """Get a specific Trigger node with its target Tool."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (t:Trigger {name: $name}) "
                "OPTIONAL MATCH (t)-[:INVOKES]->(tool:Tool) "
                "RETURN t.name AS name, t.type AS type, "
                "t.schedule_time AS schedule_time, t.event AS event, "
                "t.event_filter AS event_filter, t.scope AS scope, "
                "t.enabled AS enabled, t.template_version AS template_version, "
                "t.user_modified AS user_modified, "
                "t.created_at AS created_at, t.updated_at AS updated_at, "
                "tool.name AS invokes_tool",
                {"name": name},
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": f"Trigger '{name}' not found"})
            return rows[0]

        @router.post("/triggers", status_code=201)
        async def create_trigger(request: Request):
            """Create a Trigger node with INVOKES edge."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            body = await request.json()
            name = (body.get("name") or "").strip()
            if not name or not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,63}", name):
                return JSONResponse(
                    status_code=400,
                    content={"error": "name is required (lowercase alphanumeric + hyphens, max 64)"},
                )
            trigger_type = body.get("type", "schedule")
            if trigger_type not in ("schedule", "event"):
                return JSONResponse(
                    status_code=400,
                    content={"error": f"Invalid type '{trigger_type}'. Must be schedule or event"},
                )
            invokes_tool = (body.get("invokes") or "").strip()
            if not invokes_tool:
                return JSONResponse(
                    status_code=400,
                    content={"error": "invokes (tool name) is required"},
                )
            # Verify target tool exists
            tool_rows = await graph.execute_cypher(
                "MATCH (t:Tool {name: $name}) RETURN t.name",
                {"name": invokes_tool},
            )
            if not tool_rows:
                return JSONResponse(
                    status_code=400,
                    content={"error": f"Target tool '{invokes_tool}' not found"},
                )

            now = datetime.now(timezone.utc).isoformat()
            scope = body.get("scope", {})
            if isinstance(scope, dict):
                scope = json.dumps(scope)

            data = {
                "name": name,
                "type": trigger_type,
                "schedule_time": body.get("schedule_time", ""),
                "event": body.get("event", ""),
                "event_filter": body.get("event_filter", ""),
                "scope": scope,
                "enabled": "true" if body.get("enabled", True) else "false",
                "template_version": "",
                "user_modified": "true",
                "now": now,
            }
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MERGE (t:Trigger {name: $name}) "
                    "ON CREATE SET t.created_at = $now "
                    "SET t.type = $type,"
                    "    t.schedule_time = $schedule_time,"
                    "    t.event = $event,"
                    "    t.event_filter = $event_filter,"
                    "    t.scope = $scope,"
                    "    t.enabled = $enabled,"
                    "    t.template_version = $template_version,"
                    "    t.user_modified = $user_modified,"
                    "    t.updated_at = $now",
                    data,
                )
                # Create INVOKES edge (clear old one first)
                await graph.execute_cypher(
                    "MATCH (t:Trigger {name: $name})-[r:INVOKES]->() DELETE r",
                    {"name": name},
                )
                await graph.execute_cypher(
                    "MATCH (trigger:Trigger {name: $trigger}), (tool:Tool {name: $tool}) "
                    "CREATE (trigger)-[:INVOKES]->(tool)",
                    {"trigger": name, "tool": invokes_tool},
                )
            result = await graph.execute_cypher(
                "MATCH (t:Trigger {name: $name}) RETURN t", {"name": name}
            )
            return result[0] if result else {"name": name}

        @router.put("/triggers/{name}")
        async def update_trigger(name: str, request: Request):
            """Update fields on an existing Trigger node."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (t:Trigger {name: $name}) RETURN t", {"name": name}
            )
            if not rows:
                return JSONResponse(status_code=404, content={"error": f"Trigger '{name}' not found"})
            body = await request.json()
            now = datetime.now(timezone.utc).isoformat()

            updatable = ["type", "schedule_time", "event", "event_filter", "scope", "enabled"]
            data: dict[str, Any] = {"name": name, "now": now}
            set_clauses = ["t.user_modified = 'true'", "t.updated_at = $now"]
            for field in updatable:
                if field in body:
                    val = body[field]
                    if field == "scope" and isinstance(val, dict):
                        val = json.dumps(val)
                    elif field == "enabled":
                        val = "true" if val else "false"
                    data[field] = val
                    set_clauses.append(f"t.{field} = ${field}")

            if len(set_clauses) > 2:
                async with graph.write_lock:
                    await graph.execute_cypher(
                        f"MATCH (t:Trigger {{name: $name}}) SET {', '.join(set_clauses)}",
                        data,
                    )

            # Update INVOKES edge if target changed
            if "invokes" in body:
                invokes_tool = (body["invokes"] or "").strip()
                if invokes_tool:
                    tool_rows = await graph.execute_cypher(
                        "MATCH (t:Tool {name: $name}) RETURN t.name",
                        {"name": invokes_tool},
                    )
                    if tool_rows:
                        async with graph.write_lock:
                            await graph.execute_cypher(
                                "MATCH (t:Trigger {name: $name})-[r:INVOKES]->() DELETE r",
                                {"name": name},
                            )
                            await graph.execute_cypher(
                                "MATCH (trigger:Trigger {name: $trigger}), "
                                "(tool:Tool {name: $tool}) "
                                "CREATE (trigger)-[:INVOKES]->(tool)",
                                {"trigger": name, "tool": invokes_tool},
                            )

            result = await graph.execute_cypher(
                "MATCH (t:Trigger {name: $name}) RETURN t", {"name": name}
            )
            return result[0] if result else {"name": name}

        @router.delete("/triggers/{name}", status_code=204)
        async def delete_trigger(name: str):
            """Delete a Trigger node and its edges."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MATCH (t:Trigger {name: $name})-[r:INVOKES]->() DELETE r",
                    {"name": name},
                )
                await graph.execute_cypher(
                    "MATCH (t:Trigger {name: $name}) DELETE t",
                    {"name": name},
                )
            return Response(status_code=204)

        return router
