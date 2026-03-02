"""
Daily module - Journal entries and agent framework.

Provides CRUD operations for daily journal entries stored as markdown
files with YAML frontmatter in vault/Daily/entries/.

Optionally integrates with BrainInterface for entity cross-referencing.
"""

import logging
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import frontmatter
from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)


class CreateEntryRequest(BaseModel):
    content: str
    metadata: Optional[dict] = None


class DailyModule:
    """Daily module for journal entry management."""

    name = "daily"
    provides = []

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path
        self.entries_dir = vault_path / "Daily" / "entries"
        self.entries_dir.mkdir(parents=True, exist_ok=True)
        self._brain = None

    async def on_load(self) -> None:
        """Register Daily schema tables in the shared graph."""
        from parachute.core.interfaces import get_registry
        graph = get_registry().get("GraphDB")
        if graph is None:
            logger.warning("Daily: GraphDB not in registry, schema registration skipped")
            return
        await graph.ensure_node_table(
            "Journal_Entry",
            {
                "entry_id": "STRING",
                "date": "STRING",
                "content": "STRING",
                "snippet": "STRING",
                "created_at": "STRING",
            },
            primary_key="entry_id",
        )
        await graph.ensure_node_table(
            "Day",
            {"date": "STRING", "created_at": "STRING"},
            primary_key="date",
        )
        await graph.ensure_rel_table("HAS_ENTRY", "Day", "Journal_Entry")
        logger.info("Daily: graph schema registered (Journal_Entry, Day, HAS_ENTRY)")

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

        # Extract potential entity names - words starting with uppercase,
        # multi-word names, etc.
        words = set()
        # Find capitalized words (potential proper nouns)
        for match in re.finditer(r'\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\b', content):
            words.add(match.group())
        # Also try individual capitalized words
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

    async def create_entry(self, content: str, metadata: dict[str, Any] | None = None) -> dict:
        """Create a new daily entry."""
        now = datetime.now(timezone.utc)
        entry_id = now.strftime("%Y-%m-%d-%H-%M")
        filename = f"{entry_id}.md"
        filepath = self.entries_dir / filename

        # Build frontmatter metadata
        meta = {
            "entry_id": entry_id,
            "created_at": now.isoformat(),
        }
        if metadata:
            meta.update(metadata)

        # Find brain suggestions
        brain_suggestions = self._find_brain_suggestions(content)
        if brain_suggestions:
            meta["brain_links"] = [s["para_id"] for s in brain_suggestions]

        # Write the file
        post = frontmatter.Post(content, **meta)
        filepath.write_text(frontmatter.dumps(post), encoding="utf-8")

        logger.info(f"Created daily entry: {filename}")

        # Write to graph (silently skips if GraphDB not available)
        await self._write_entry_to_graph(entry_id, content, now)

        return {
            "id": entry_id,
            "path": str(filepath),
            "created_at": now.isoformat(),
            "brain_suggestions": brain_suggestions,
        }

    async def _write_entry_to_graph(self, entry_id: str, content: str, now: datetime) -> None:
        """Write a new journal entry to the graph index. Silent no-op if unavailable."""
        from parachute.core.interfaces import get_registry
        graph = get_registry().get("GraphDB")
        if graph is None:
            logger.debug("Daily: GraphDB not in registry, skipping graph write")
            return

        date = entry_id[:10]  # "YYYY-MM-DD" prefix of "YYYY-MM-DD-HH-MM"
        created_at = now.isoformat()
        snippet = content[:200]

        try:
            async with graph.write_lock:
                # Hold lock for all 3 writes — Day + Entry + edge are one atomic unit.
                # 1. Lazy-upsert Day node
                await graph.execute_cypher(
                    "MERGE (d:Day {date: $date}) ON CREATE SET d.created_at = $created_at",
                    {"date": date, "created_at": created_at},
                )
                # 2. Upsert Journal_Entry node (ON CREATE SET protects original timestamp)
                await graph.execute_cypher(
                    "MERGE (e:Journal_Entry {entry_id: $entry_id}) "
                    "ON CREATE SET e.created_at = $created_at "
                    "SET e.date = $date, e.content = $content, e.snippet = $snippet",
                    {
                        "entry_id": entry_id,
                        "date": date,
                        "content": content,
                        "snippet": snippet,
                        "created_at": created_at,
                    },
                )
                # 3. HAS_ENTRY relationship
                await graph.execute_cypher(
                    "MATCH (d:Day {date: $date}), (e:Journal_Entry {entry_id: $entry_id}) "
                    "MERGE (d)-[:HAS_ENTRY]->(e)",
                    {"date": date, "entry_id": entry_id},
                )
            logger.debug(f"Daily: wrote entry {entry_id} to graph")
        except Exception as e:
            logger.warning(f"Daily: graph write failed for {entry_id}: {e}")

    def list_entries(self, limit: int = 20, offset: int = 0, date: str | None = None) -> list[dict]:
        """List daily entries with pagination, optionally filtered by date (YYYY-MM-DD)."""
        entries = []

        # Get all .md files sorted by name (newest first due to date naming)
        files = sorted(self.entries_dir.glob("*.md"), reverse=True)

        # Filter by date prefix if provided (entry_id format: YYYY-MM-DD-HH-MM)
        if date:
            files = [f for f in files if f.stem.startswith(date)]

        for md_file in files[offset:offset + limit]:
            try:
                post = frontmatter.load(str(md_file))
                meta = dict(post.metadata)
                entries.append({
                    "id": post.metadata.get("entry_id", md_file.stem),
                    "created_at": post.metadata.get("created_at", ""),
                    "content": post.content or "",
                    "snippet": post.content[:200] if post.content else "",
                    "metadata": meta,
                    "brain_links": post.metadata.get("brain_links", []),
                })
            except Exception as e:
                logger.error(f"Failed to parse entry {md_file}: {e}")

        return entries

    def get_entry(self, entry_id: str) -> Optional[dict]:
        """Get a specific entry by ID."""
        filepath = self.entries_dir / f"{entry_id}.md"
        if not filepath.exists():
            return None

        try:
            post = frontmatter.load(str(filepath))
            return {
                "id": post.metadata.get("entry_id", entry_id),
                "created_at": post.metadata.get("created_at", ""),
                "content": post.content,
                "metadata": dict(post.metadata),
                "brain_links": post.metadata.get("brain_links", []),
            }
        except Exception as e:
            logger.error(f"Failed to read entry {entry_id}: {e}")
            return None

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
            entries = self.list_entries(limit=limit, offset=offset, date=date)
            return {"entries": entries, "count": len(entries), "offset": offset}

        @router.get("/entries/{entry_id}")
        async def get_entry(entry_id: str):
            """Get a specific daily entry."""
            entry = self.get_entry(entry_id)
            if not entry:
                return JSONResponse(
                    status_code=404,
                    content={"error": "Entry not found", "id": entry_id},
                )
            return entry

        return router
