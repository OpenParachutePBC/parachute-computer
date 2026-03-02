"""
Daily module — Journal entries with Kuzu graph as primary storage.

Provides CRUD operations for daily journal entries stored as nodes in the
shared Kuzu graph database. Audio and image files remain on the filesystem;
only metadata and content are stored in the graph.

Entry IDs are timestamp strings: "YYYY-MM-DD-HH-MM-SS"

Storage layout:
  ~/Parachute/.parachute/graph/  ← Kuzu database (primary store, all modules share)
  ~/Parachute/Daily/assets/      ← Audio/image files (filesystem)
  ~/Parachute/Daily/entries/     ← Legacy .md files (migrated on first load, then unused)
"""

import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)


class CreateEntryRequest(BaseModel):
    content: str
    metadata: Optional[dict] = None


class UpdateEntryRequest(BaseModel):
    content: Optional[str] = None
    metadata: Optional[dict] = None  # merged (not replaced) into existing metadata


class DailyModule:
    """Daily module for journal entry management. Kuzu graph is primary storage."""

    name = "daily"
    provides = []

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path
        # entries_dir kept for audio file storage and one-time markdown migration
        self.entries_dir = vault_path / "Daily" / "entries"
        self.entries_dir.mkdir(parents=True, exist_ok=True)
        self._brain = None

    async def on_load(self) -> None:
        """Register Daily schema in shared graph and migrate any existing .md files."""
        from parachute.core.interfaces import get_registry
        graph = get_registry().get("GraphDB")
        if graph is None:
            logger.warning("Daily: GraphDB not in registry — module will not function")
            return

        # Ensure schema tables exist
        await graph.ensure_node_table(
            "Journal_Entry",
            {
                "entry_id": "STRING",
                "date": "STRING",
                "content": "STRING",
                "snippet": "STRING",
                "created_at": "STRING",
                "title": "STRING",
                "entry_type": "STRING",
                "audio_path": "STRING",
                "metadata_json": "STRING",
                "brain_links_json": "STRING",
            },
            primary_key="entry_id",
        )
        await graph.ensure_node_table(
            "Day",
            {"date": "STRING", "created_at": "STRING"},
            primary_key="date",
        )
        await graph.ensure_rel_table("HAS_ENTRY", "Day", "Journal_Entry")

        # Add new columns to existing databases (idempotent migration)
        await self._ensure_new_columns(graph)

        # One-time import of any existing .md files into graph
        await self._migrate_from_markdown(graph)

        logger.info("Daily: graph schema ready (Kuzu primary storage)")

    async def _ensure_new_columns(self, graph) -> None:
        """Add columns introduced in the Kuzu-primary migration to existing databases."""
        existing = await graph.get_table_columns("Journal_Entry")
        new_cols = {
            "title": "STRING",
            "entry_type": "STRING",
            "audio_path": "STRING",
            "metadata_json": "STRING",
            "brain_links_json": "STRING",
        }
        for col, typ in new_cols.items():
            if col not in existing:
                async with graph.write_lock:
                    await graph.execute_cypher(
                        f"ALTER TABLE Journal_Entry ADD {col} {typ} DEFAULT NULL"
                    )
                logger.info(f"Daily: added column Journal_Entry.{col}")

    async def _migrate_from_markdown(self, graph) -> None:
        """
        One-time migration: import existing .md files into graph. Idempotent.

        Checks which .md files don't yet have a corresponding graph node and
        MERGEs them in. Safe to call on every startup — skips already-imported entries.
        After migration the .md files remain on disk as read-only archives.
        """
        md_files = list(self.entries_dir.glob("*.md"))
        if not md_files:
            return

        # Which entries are already in the graph?
        rows = await graph.execute_cypher(
            "MATCH (e:Journal_Entry) RETURN e.entry_id AS entry_id"
        )
        existing_ids = {r["entry_id"] for r in rows}

        to_import = [f for f in md_files if f.stem not in existing_ids]
        if not to_import:
            logger.debug(
                f"Daily: {len(md_files)} .md file(s) already in graph — no migration needed"
            )
            return

        try:
            import frontmatter as fm
        except ImportError:
            logger.warning("Daily: python-frontmatter not installed — markdown migration skipped")
            return

        logger.info(f"Daily: migrating {len(to_import)} .md file(s) to graph...")
        imported = 0
        for md_file in sorted(to_import):
            try:
                post = fm.load(str(md_file))
                meta = dict(post.metadata)
                entry_id = meta.get("entry_id", md_file.stem)
                content = post.content or ""
                date = entry_id[:10]
                created_at = meta.get("created_at", "")
                title = meta.get("title", "")
                entry_type = meta.get("type", "text")
                audio_path = meta.get("audio_path", "") or ""
                brain_links = meta.get("brain_links", [])

                # Remaining fields go into the metadata blob
                known = {"entry_id", "created_at", "title", "type", "audio_path", "brain_links"}
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
                    brain_links=brain_links,
                    extra_meta=extra_meta,
                )
                imported += 1
            except Exception as e:
                logger.error(f"Daily: migration failed for {md_file.name}: {e}")

        logger.info(f"Daily: migrated {imported}/{len(to_import)} entries to graph")

    # ── Graph helpers ─────────────────────────────────────────────────────────

    def _get_graph(self):
        """Return GraphDB from registry, or None if unavailable."""
        from parachute.core.interfaces import get_registry
        return get_registry().get("GraphDB")

    def _get_brain(self):
        """Lazily get BrainInterface from registry."""
        if self._brain is None:
            try:
                from parachute.core.interfaces import get_registry
                self._brain = get_registry().get("BrainInterface")
            except Exception:
                pass
        return self._brain

    def _find_brain_suggestions(self, content: str) -> list[dict]:
        """Search Brain for entities mentioned in the content."""
        brain = self._get_brain()
        if not brain:
            return []

        suggestions = []
        seen_ids = set()
        words = set()
        for match in re.finditer(r'\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\b', content):
            words.add(match.group())
        for match in re.finditer(r'\b[A-Z][a-z]{2,}\b', content):
            words.add(match.group())

        for word in words:
            try:
                results = brain.search(word)
                for result in results:
                    para_id = result.get("para_id", "")
                    if para_id and para_id not in seen_ids:
                        seen_ids.add(para_id)
                        suggestions.append({
                            "para_id": para_id,
                            "name": result.get("name", ""),
                            "matched_term": word,
                        })
            except Exception as e:
                logger.debug(f"Brain search failed for '{word}': {e}")

        return suggestions

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
        brain_links: list = None,
        extra_meta: dict = None,
    ) -> None:
        """Write (MERGE) a Journal_Entry node + Day node + HAS_ENTRY edge."""
        snippet = content[:200]
        brain_links_json = json.dumps(brain_links or [])
        metadata_json = json.dumps(extra_meta or {})

        async with graph.write_lock:
            # 1. Lazy-upsert Day node
            await graph.execute_cypher(
                "MERGE (d:Day {date: $date}) ON CREATE SET d.created_at = $created_at",
                {"date": date, "created_at": created_at},
            )
            # 2. MERGE Journal_Entry — ON CREATE SET protects original timestamp
            await graph.execute_cypher(
                "MERGE (e:Journal_Entry {entry_id: $entry_id}) "
                "ON CREATE SET e.created_at = $created_at "
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
                    "metadata_json": metadata_json,
                    "brain_links_json": brain_links_json,
                },
            )
            # 3. HAS_ENTRY relationship
            await graph.execute_cypher(
                "MATCH (d:Day {date: $date}), (e:Journal_Entry {entry_id: $entry_id}) "
                "MERGE (d)-[:HAS_ENTRY]->(e)",
                {"date": date, "entry_id": entry_id},
            )

    def _row_to_entry(self, row: dict) -> dict:
        """Convert a Kuzu Journal_Entry node dict to the API response shape."""
        entry_id = row.get("entry_id", "")
        content = row.get("content", "")
        title = row.get("title") or ""
        entry_type = row.get("entry_type") or "text"
        audio_path = row.get("audio_path") or ""

        # Reconstruct metadata dict — Flutter reads: type, title, audio_path, image_path, duration_seconds
        meta: dict[str, Any] = {
            "entry_id": entry_id,
            "created_at": row.get("created_at", ""),
        }
        if title:
            meta["title"] = title
        if entry_type:
            meta["type"] = entry_type
        if audio_path:
            meta["audio_path"] = audio_path

        # Merge extra fields from JSON blob (image_path, duration_seconds, etc.)
        metadata_json = row.get("metadata_json") or ""
        if metadata_json:
            try:
                extra = json.loads(metadata_json)
                meta.update(extra)
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
        """Create a new daily entry in the graph. Returns {id, created_at, brain_suggestions}."""
        graph = self._get_graph()
        if graph is None:
            raise RuntimeError("GraphDB unavailable — cannot create entry")

        now = datetime.now(timezone.utc)
        entry_id = now.strftime("%Y-%m-%d-%H-%M-%S-%f")
        date = entry_id[:10]
        created_at = now.isoformat()

        meta = metadata or {}
        title = meta.get("title", "")
        entry_type = meta.get("type", "text")
        audio_path = meta.get("audio_path", "") or ""

        # Extra metadata (image_path, duration_seconds, etc.)
        known = {"title", "type", "audio_path"}
        extra_meta = {k: v for k, v in meta.items() if k not in known}

        # Brain suggestions
        brain_suggestions = self._find_brain_suggestions(content)
        brain_links = [s["para_id"] for s in brain_suggestions]

        await self._write_to_graph(
            graph,
            entry_id=entry_id,
            date=date,
            content=content,
            created_at=created_at,
            title=title,
            entry_type=entry_type,
            audio_path=audio_path,
            brain_links=brain_links,
            extra_meta=extra_meta,
        )

        logger.info(f"Daily: created entry {entry_id}")
        return {
            "id": entry_id,
            "created_at": created_at,
            "brain_suggestions": brain_suggestions,
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
            raise RuntimeError("GraphDB unavailable — cannot update entry")

        # Check existence
        rows = await graph.execute_cypher(
            "MATCH (e:Journal_Entry {entry_id: $entry_id}) RETURN e",
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
                "MATCH (e:Journal_Entry {entry_id: $entry_id}) "
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
            raise RuntimeError("GraphDB unavailable — cannot delete entry")

        rows = await graph.execute_cypher(
            "MATCH (e:Journal_Entry {entry_id: $entry_id}) RETURN e.entry_id AS entry_id",
            {"entry_id": entry_id},
        )
        if not rows:
            return True  # already gone — idempotent

        try:
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MATCH (e:Journal_Entry {entry_id: $entry_id}) DETACH DELETE e",
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
                "MATCH (e:Journal_Entry) WHERE e.date = $date "
                "RETURN e ORDER BY e.created_at DESC",
                {"date": date},
            )
        else:
            rows = await graph.execute_cypher(
                "MATCH (e:Journal_Entry) RETURN e ORDER BY e.created_at DESC"
            )

        return [self._row_to_entry(r) for r in rows[offset: offset + limit]]

    async def get_entry(self, entry_id: str) -> Optional[dict]:
        """Get a specific entry by ID."""
        graph = self._get_graph()
        if graph is None:
            return None

        rows = await graph.execute_cypher(
            "MATCH (e:Journal_Entry {entry_id: $entry_id}) RETURN e",
            {"entry_id": entry_id},
        )
        if not rows:
            return None
        return self._row_to_entry(rows[0])

    async def search_entries(self, query: str, limit: int = 30) -> list[dict]:
        """Keyword search across all entries. Returns results with snippet and match_count."""
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
            "MATCH (e:Journal_Entry) RETURN e ORDER BY e.created_at DESC"
        )

        results = []
        for row in all_rows:
            content = row.get("content") or ""
            content_lower = content.lower()
            match_count = sum(content_lower.count(term) for term in query_terms)
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

    # ── Routes ────────────────────────────────────────────────────────────────

    def get_router(self) -> APIRouter:
        """Return API routes for the daily module."""
        router = APIRouter()

        @router.post("/entries")
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
            """Search entries by keyword across all dates."""
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

        @router.delete("/entries/{entry_id}")
        async def delete_entry(entry_id: str):
            """Delete an entry and its graph edges."""
            ok = await self.delete_entry(entry_id)
            if not ok:
                return JSONResponse(status_code=500, content={"error": "Delete failed"})
            return JSONResponse(status_code=204, content=None)

        return router
