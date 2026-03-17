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
from typing import Any, Literal, Optional, TypedDict

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
# DailyModule derives the actual path from its vault_path at init time,
# so tests with a temp vault don't pollute the production log.
_DEFAULT_REDO_LOG_PATH = Path.home() / ".parachute" / "daily" / "entries.jsonl"

logger = logging.getLogger(__name__)

# ── Agent templates ──────────────────────────────────────────────────────────
# Starter definitions returned by GET /agents/templates. Each has the same
# shape as the POST /agents body so the client can create directly from them.


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
    memory_mode: str  # "persistent" (default) | "fresh"


AGENT_TEMPLATES: list[AgentTemplateDict] = [
    {
        "name": "daily-reflection",
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
            "1. Read yesterday's journal entries with `read_journal`\n"
            "2. Read recent journals with `read_recent_journals` for broader context\n"
            "3. Optionally read chat logs with `read_chat_log` for additional context\n"
            "4. Write your reflection using `write_output`\n\n"
            "## User Context\n\n"
            "{user_context}"
        ),
        "tools": ["read_journal", "read_chat_log", "read_recent_journals"],
        "schedule_time": "4:00",
        "trust_level": "sandboxed",
        "memory_mode": "persistent",
    },
]


def _read_transcript_file(sid: str, limit: int) -> dict:
    """Read and parse a Claude SDK JSONL transcript file (sync, for to_thread).

    Returns a dict matching the Flutter AgentTranscript shape.
    """
    session_file = None
    for projects_dir in [
        Path.home() / ".claude" / "projects",
        Path.home() / "Parachute" / ".claude" / "projects",
    ]:
        if not projects_dir.exists():
            continue
        for project_dir in projects_dir.iterdir():
            if project_dir.is_dir():
                candidate = project_dir / f"{sid}.jsonl"
                if candidate.exists():
                    session_file = candidate
                    break
        if session_file:
            break

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


# ── Cleanup Agent system prompt ───────────────────────────────────────────────
POST_PROCESS_SYSTEM_PROMPT = (
    "You are a post-processing assistant for journal entries.\n\n"
    "## Your Job\n\n"
    "Read the entry with `read_entry`. If it came from a voice recording, "
    "clean up the transcript and save it with `update_entry_content`. "
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
            use_claude_code_preset=False,
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

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path
        self._redo_log_path = vault_path / ".parachute" / "daily" / "entries.jsonl"

    async def on_load(self) -> None:
        """Register Daily schema in shared graph."""
        graph = self._get_graph()
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
            "Agent",
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
                # Runtime state
                "sdk_session_id": "STRING",      # Claude SDK session ID for resume
                "last_run_at": "STRING",         # ISO timestamp of last completed run
                "last_processed_date": "STRING", # YYYY-MM-DD of last processed journal date
                "run_count": "INT64",            # Total number of completed runs
                "memory_mode": "STRING",         # "persistent" (default) | "fresh"
            },
            primary_key="name",
        )

        await graph.ensure_node_table(
            "AgentRun",
            {
                "run_id": "STRING",         # PK: "{agent_name}:{entry_id}:{timestamp}"
                "agent_name": "STRING",
                "display_name": "STRING",   # Human-readable name (avoids N+1 lookup)
                "entry_id": "STRING",
                "status": "STRING",         # "completed" | "error" | etc.
                "ran_at": "STRING",         # ISO timestamp
                "session_id": "STRING",     # Claude SDK session ID
            },
            primary_key="run_id",
        )

        # Add new columns to existing databases (idempotent schema migration)
        await self._ensure_new_columns(graph)

        # Seed built-in Agents (idempotent — skips if already exists)
        await self._seed_builtin_agents(graph)

        # Migrate relative audio paths to absolute (one-time, idempotent)
        await self._migrate_audio_paths_to_absolute(graph)

        # Trim redo log (90-day rolling), then replay any entries missing from graph
        redo_records = _trim_redo_log(self._redo_log_path)
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

        # Agent table migrations — skip gracefully if Agent table doesn't exist
        # yet (first run before _seed_builtin_agents creates it).
        try:
            agent_cols = await graph.get_table_columns("Agent")
        except Exception:
            return  # Agent table doesn't exist yet — nothing to migrate

        agent_new = {
            "trust_level": ("STRING", "'sandboxed'"),
            "sdk_session_id": ("STRING", "''"),
            "last_run_at": ("STRING", "''"),
            "last_processed_date": ("STRING", "''"),
            "run_count": ("INT64", "0"),
            "trigger_event": ("STRING", "''"),
            "trigger_filter": ("STRING", "'{}'"),
            "memory_mode": ("STRING", "'persistent'"),
        }
        missing = {col: v for col, v in agent_new.items() if col not in agent_cols}
        if missing:
            async with graph.write_lock:
                for col, (typ, default) in missing.items():
                    await graph.execute_cypher(
                        f"ALTER TABLE Agent ADD {col} {typ} DEFAULT {default}"
                    )
                    logger.info(f"Daily: added column Agent.{col}")

    async def _seed_builtin_agents(self, graph) -> None:
        """Seed built-in Agents that ship with Parachute. Idempotent — skips existing."""
        now = datetime.now(timezone.utc).isoformat()

        # Look up the daily-reflection template by name (not index) so seed
        # data stays correct even if the AGENT_TEMPLATES list is reordered.
        _reflection_tpl = next(
            (t for t in AGENT_TEMPLATES if t["name"] == "daily-reflection"),
            None,
        )
        if _reflection_tpl is None:
            logger.error("Daily: daily-reflection template missing from AGENT_TEMPLATES")
            _reflection_tpl = AGENT_TEMPLATES[0]  # fallback to first

        builtin_agents = [
            {
                "name": "post-process",
                "display_name": "Post-Process",
                "description": (
                    "Runs after voice transcription completes. Cleans up filler "
                    "words, fixes grammar, adds punctuation."
                ),
                "system_prompt": POST_PROCESS_SYSTEM_PROMPT,
                "tools": json.dumps(["read_entry", "update_entry_content"]),
                "schedule_enabled": "false",
                "schedule_time": "",
                "enabled": "true",
                "trust_level": "direct",
                "trigger_event": "note.transcription_complete",
                "trigger_filter": "{}",
                "memory_mode": "fresh",
                "created_at": now,
                "updated_at": now,
            },
            {
                "name": "daily-reflection",
                "display_name": "Daily Reflection",
                "description": _reflection_tpl["description"],
                "system_prompt": _reflection_tpl["system_prompt"],
                "tools": json.dumps(_reflection_tpl["tools"]),
                "schedule_enabled": "true",
                "schedule_time": _reflection_tpl.get("schedule_time", "4:00"),
                "enabled": "true",
                "trust_level": _reflection_tpl.get("trust_level", "sandboxed"),
                "trigger_event": "",
                "trigger_filter": "{}",
                "memory_mode": _reflection_tpl.get("memory_mode", "persistent"),
                "created_at": now,
                "updated_at": now,
            },
        ]

        for agent in builtin_agents:
            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a.name AS name",
                {"name": agent["name"]},
            )
            if rows:
                continue  # Already exists — don't overwrite user customizations

            try:
                async with graph.write_lock:
                    await graph.execute_cypher(
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
                        "  created_at: $created_at,"
                        "  updated_at: $updated_at"
                        "})",
                        agent,
                    )
                logger.info(f"Daily: seeded built-in Agent '{agent['name']}'")
            except Exception as e:
                logger.warning(f"Daily: failed to seed Agent '{agent['name']}': {e}")

        # Clean up renamed/retired Agent nodes and their orphaned AgentRun rows
        for old_name in ["transcription-cleanup"]:
            try:
                rows = await graph.execute_cypher(
                    "MATCH (a:Agent {name: $name}) RETURN a.name",
                    {"name": old_name},
                )
                if rows:
                    async with graph.write_lock:
                        await graph.execute_cypher(
                            "MATCH (a:Agent {name: $name}) DELETE a",
                            {"name": old_name},
                        )
                    logger.info(f"Daily: removed retired Agent '{old_name}'")
                # Also clean up orphaned AgentRun rows for this agent
                try:
                    run_rows = await graph.execute_cypher(
                        "MATCH (r:AgentRun {agent_name: $name}) RETURN r.run_id",
                        {"name": old_name},
                    )
                    if run_rows:
                        async with graph.write_lock:
                            await graph.execute_cypher(
                                "MATCH (r:AgentRun {agent_name: $name}) DELETE r",
                                {"name": old_name},
                            )
                        logger.info(
                            f"Daily: removed {len(run_rows)} orphaned AgentRun(s) for '{old_name}'"
                        )
                except Exception:
                    pass  # AgentRun table may not exist yet
            except Exception:
                pass

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

            dispatcher = AgentDispatcher(graph=graph, vault_path=self.vault_path)
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

        @router.post("/cards/{agent_name}/run", status_code=202)
        async def run_card(
            agent_name: str,
            date: str | None = Query(None),
            force: bool = Query(False),
        ):
            """Trigger an agent run for a date (async — returns 202 immediately)."""
            from parachute.core.daily_agent import run_daily_agent
            task = asyncio.create_task(
                run_daily_agent(self.vault_path, agent_name, date=date, force=force)
            )
            _background_tasks.add(task)
            task.add_done_callback(_log_task_exception)
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
            # Verify agent_name corresponds to a known Agent
            agent_rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a.name",
                {"name": agent_name},
            )
            if not agent_rows:
                return JSONResponse(status_code=403, content={"error": "unknown agent"})
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
            """List all Agent nodes from the graph."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            rows = await graph.execute_cypher(
                "MATCH (a:Agent) RETURN a ORDER BY a.name"
            )
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
            """
            graph = self._get_graph()
            if graph is None:
                return {"hasTranscript": False, "message": "BrainDB not available"}

            rows = await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) RETURN a.sdk_session_id AS sid",
                {"name": name},
            )
            if not rows:
                return {"hasTranscript": False, "message": "Agent not found."}

            sid = (rows[0].get("sid") or "").strip()
            if not sid:
                return {"hasTranscript": False, "message": "This agent hasn't run yet."}

            # Search for the JSONL transcript file and parse it off the
            # event loop (file I/O is blocking).
            return await asyncio.to_thread(
                _read_transcript_file, sid, limit,
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
                run_triggered_agent(self.vault_path, name, entry_id, event)
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

        @router.delete("/agents/{name}", status_code=204)
        async def delete_agent(name: str):
            """Delete an Agent node."""
            graph = self._get_graph()
            if graph is None:
                return JSONResponse(status_code=503, content={"error": "BrainDB not available"})
            await graph.execute_cypher(
                "MATCH (a:Agent {name: $name}) DELETE a", {"name": name}
            )
            return Response(status_code=204)

        return router
