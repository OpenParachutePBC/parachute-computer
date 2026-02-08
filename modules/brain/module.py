"""
Brain module - Knowledge graph entity management.

Provides search and retrieval of entities stored as markdown files
with YAML frontmatter in vault/Brain/entities/.
"""

import logging
from pathlib import Path
from typing import Optional

import frontmatter
from fastapi import APIRouter, Query

logger = logging.getLogger(__name__)


class BrainModule:
    """Brain module for entity management and search."""

    name = "brain"
    provides = ["BrainInterface"]

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path
        self.entities_dir = vault_path / "Brain" / "entities"
        self._cache: dict[str, dict] = {}
        self._load_entities()

    def _load_entities(self):
        """Load all entity files into memory cache."""
        self._cache.clear()

        if not self.entities_dir.exists():
            logger.warning(f"Entities directory not found: {self.entities_dir}")
            return

        for md_file in self.entities_dir.rglob("*.md"):
            try:
                entity = self._parse_entity(md_file)
                if entity:
                    para_id = entity.get("para_id", "")
                    if para_id:
                        self._cache[para_id] = entity
                    else:
                        # Generate para_id from path
                        rel = md_file.relative_to(self.entities_dir)
                        generated_id = str(rel.with_suffix(""))
                        entity["para_id"] = generated_id
                        self._cache[generated_id] = entity
            except Exception as e:
                logger.error(f"Failed to parse entity {md_file}: {e}")

        logger.info(f"Loaded {len(self._cache)} entities from {self.entities_dir}")

    def _parse_entity(self, path: Path) -> Optional[dict]:
        """Parse a markdown entity file with optional frontmatter."""
        post = frontmatter.load(str(path))

        meta = dict(post.metadata) if post.metadata else {}
        content = post.content

        # Extract name from frontmatter or first heading
        name = meta.get("name", "")
        if not name:
            for line in content.splitlines():
                if line.startswith("# "):
                    name = line[2:].strip()
                    break

        return {
            "para_id": meta.get("para_id", ""),
            "name": name,
            "tags": meta.get("tags", []),
            "content": content,
            "path": str(path),
            **{k: v for k, v in meta.items() if k not in ("para_id", "name", "tags")},
        }

    # --- BrainInterface methods ---

    def search(self, query: str) -> list[dict]:
        """Search entities by name or content."""
        query_lower = query.lower()
        results = []

        for para_id, entity in self._cache.items():
            name = entity.get("name", "").lower()
            content = entity.get("content", "").lower()
            tags = [t.lower() for t in entity.get("tags", [])]

            if (
                query_lower in name
                or query_lower in content
                or any(query_lower in tag for tag in tags)
                or query_lower in para_id.lower()
            ):
                # Return without full content for search results
                results.append({
                    "para_id": entity["para_id"],
                    "name": entity["name"],
                    "tags": entity.get("tags", []),
                    "snippet": entity.get("content", "")[:200],
                })

        return results

    def resolve(self, name: str) -> Optional[dict]:
        """Resolve an entity by name (case-insensitive)."""
        name_lower = name.lower()
        for entity in self._cache.values():
            if entity.get("name", "").lower() == name_lower:
                return entity
        return None

    def get_entity(self, para_id: str) -> Optional[dict]:
        """Get a specific entity by para_id."""
        return self._cache.get(para_id)

    # --- Router ---

    def get_router(self) -> APIRouter:
        """Return API routes for the brain module."""
        router = APIRouter()

        @router.get("/search")
        async def search_entities(q: str = Query(..., description="Search query")):
            """Search brain entities by name, content, or tags."""
            results = self.search(q)
            return {"query": q, "count": len(results), "results": results}

        @router.get("/entities/{para_id:path}")
        async def get_entity(para_id: str):
            """Get a specific entity by para_id."""
            entity = self.get_entity(para_id)
            if not entity:
                from fastapi.responses import JSONResponse
                return JSONResponse(
                    status_code=404,
                    content={"error": "Entity not found", "para_id": para_id},
                )
            return entity

        @router.get("/resolve/{name}")
        async def resolve_entity(name: str):
            """Resolve an entity by name."""
            entity = self.resolve(name)
            if not entity:
                from fastapi.responses import JSONResponse
                return JSONResponse(
                    status_code=404,
                    content={"error": "Entity not found", "name": name},
                )
            return entity

        @router.post("/reload")
        async def reload_entities():
            """Reload entities from disk."""
            self._load_entities()
            return {"status": "reloaded", "count": len(self._cache)}

        return router
