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


class UpdateEntryRequest(BaseModel):
    content: Optional[str] = None
    metadata: Optional[dict] = None  # merged (not replaced) into existing frontmatter


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
        entry_id = now.strftime("%Y-%m-%d-%H-%M-%S")
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

        date = entry_id[:10]  # "YYYY-MM-DD" prefix of "YYYY-MM-DD-HH-MM-SS"
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

    async def update_entry(
        self, entry_id: str, content: str | None = None, metadata: dict | None = None
    ) -> Optional[dict]:
        """Update content and/or metadata of an existing entry. Returns updated entry or None."""
        filepath = self.entries_dir / f"{entry_id}.md"
        if not filepath.exists():
            return None

        try:
            post = frontmatter.load(str(filepath))

            if content is not None:
                post.content = content
            if metadata:
                post.metadata.update(metadata)

            filepath.write_text(frontmatter.dumps(post), encoding="utf-8")
            logger.info(f"Updated daily entry: {entry_id}")

            # Update graph
            await self._update_entry_in_graph(entry_id, post.content)

            return {
                "id": post.metadata.get("entry_id", entry_id),
                "created_at": post.metadata.get("created_at", ""),
                "content": post.content,
                "metadata": dict(post.metadata),
                "brain_links": post.metadata.get("brain_links", []),
            }
        except Exception as e:
            logger.error(f"Failed to update entry {entry_id}: {e}")
            return None

    async def _update_entry_in_graph(self, entry_id: str, content: str) -> None:
        """Update content/snippet on the graph node. Silent no-op if unavailable."""
        from parachute.core.interfaces import get_registry
        graph = get_registry().get("GraphDB")
        if graph is None:
            return
        try:
            async with graph.write_lock:
                await graph.execute_cypher(
                    "MATCH (e:Journal_Entry {entry_id: $entry_id}) "
                    "SET e.content = $content, e.snippet = $snippet",
                    {"entry_id": entry_id, "content": content, "snippet": content[:200]},
                )
        except Exception as e:
            logger.warning(f"Daily: graph update failed for {entry_id}: {e}")

    async def delete_entry(self, entry_id: str) -> bool:
        """Delete an entry file and its graph node. Returns True on success (including 404)."""
        filepath = self.entries_dir / f"{entry_id}.md"
        if not filepath.exists():
            return True  # already gone — idempotent

        try:
            filepath.unlink()
            logger.info(f"Deleted daily entry: {entry_id}")
            await self._delete_entry_from_graph(entry_id)
            return True
        except Exception as e:
            logger.error(f"Failed to delete entry {entry_id}: {e}")
            return False

    async def _delete_entry_from_graph(self, entry_id: str) -> None:
        """Remove Journal_Entry node and HAS_ENTRY edge. Silent no-op if unavailable."""
        from parachute.core.interfaces import get_registry
        graph = get_registry().get("GraphDB")
        if graph is None:
            return
        try:
            async with graph.write_lock:
                # Delete the edge first, then the node
                await graph.execute_cypher(
                    "MATCH (:Day)-[r:HAS_ENTRY]->(e:Journal_Entry {entry_id: $entry_id}) DELETE r",
                    {"entry_id": entry_id},
                )
                await graph.execute_cypher(
                    "MATCH (e:Journal_Entry {entry_id: $entry_id}) DELETE e",
                    {"entry_id": entry_id},
                )
        except Exception as e:
            logger.warning(f"Daily: graph delete failed for {entry_id}: {e}")

    def search_entries(self, query: str, limit: int = 30) -> list[dict]:
        """Keyword search across all entries. Returns results with snippet and match_count."""
        if not query.strip():
            return []

        query_lower = query.lower()
        query_terms = [t for t in query_lower.split() if len(t) > 1]
        if not query_terms:
            return []

        results = []
        # Newest-first
        for md_file in sorted(self.entries_dir.glob("*.md"), reverse=True):
            try:
                post = frontmatter.load(str(md_file))
                content = post.content or ""
                content_lower = content.lower()

                match_count = sum(content_lower.count(term) for term in query_terms)
                if match_count == 0:
                    continue

                snippet = self._extract_snippet(content, content_lower, query_terms)
                meta = dict(post.metadata)
                results.append({
                    "id": meta.get("entry_id", md_file.stem),
                    "created_at": meta.get("created_at", ""),
                    "content": content,
                    "snippet": snippet,
                    "match_count": match_count,
                    "metadata": meta,
                })
            except Exception as e:
                logger.error(f"Search: failed to read {md_file}: {e}")

        # Sort by match count descending, then newest first (created_at is ISO string — lexicographic ok)
        results.sort(key=lambda r: (-r["match_count"], r.get("created_at", "")), reverse=False)
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
        import re as _re
        snippet = _re.sub(r"\s+", " ", snippet).strip()
        if start > 0:
            snippet = f"...{snippet}"
        if end < len(content):
            snippet = f"{snippet}..."
        return snippet

    def list_entries(self, limit: int = 20, offset: int = 0, date: str | None = None) -> list[dict]:
        """List daily entries with pagination, optionally filtered by date (YYYY-MM-DD)."""
        entries = []

        # Glob only the relevant files — O(entries_for_date) when date is given
        if date:
            files = sorted(self.entries_dir.glob(f"{date}-*.md"), reverse=True)
        else:
            files = sorted(self.entries_dir.glob("*.md"), reverse=True)

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

        @router.get("/entries/search")
        async def search_entries(
            q: str = Query(..., description="Keyword search query"),
            limit: int = Query(30, ge=1, le=100),
        ):
            """Search entries by keyword across all dates."""
            results = self.search_entries(q, limit=limit)
            return {"results": results, "query": q, "count": len(results)}

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
            """Delete an entry and its graph node."""
            ok = await self.delete_entry(entry_id)
            if not ok:
                return JSONResponse(status_code=500, content={"error": "Delete failed"})
            return JSONResponse(status_code=204, content=None)

        return router
