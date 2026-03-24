#!/usr/bin/env python3
"""
Migrate context markdown files to graph-native Note nodes.

One-time migration to seed initial context notes from existing
parachute/context/*.md files. Creates Note nodes with note_type='context'.

Usage:
    python -m scripts.migrate_context_to_graph

Idempotent — uses MERGE on entry_id so re-running is safe.
"""

import asyncio
import re
import sys
from pathlib import Path

# Context files to migrate: (filename, note_title)
CONTEXT_FILES = [
    ("profile.md", "Profile"),
    ("now.md", "Now"),
    ("memory.md", "Preferences"),
    ("orientation.md", "Orientation"),
]

# Files to skip (redundant with PARACHUTE_PROMPT)
SKIP_FILES = {"identity.md", "tools.md"}


def strip_frontmatter(content: str) -> str:
    """Remove YAML-style frontmatter and header lines from markdown.

    Strips:
    - Lines starting with # (title headers)
    - Lines starting with > (blockquotes used as descriptions)
    - Lines that are just '---' (horizontal rules / frontmatter delimiters)
    - Leading blank lines after stripping
    """
    lines = content.split("\n")
    result = []
    in_frontmatter = False
    past_header = False

    for line in lines:
        stripped = line.strip()

        # Skip frontmatter delimiters and content
        if stripped == "---":
            if not past_header:
                in_frontmatter = not in_frontmatter
                continue
            else:
                result.append(line)
                continue

        if in_frontmatter:
            continue

        # Skip leading header lines (# Title) and blockquotes (> description)
        if not past_header:
            if stripped.startswith("#") or stripped.startswith(">") or stripped == "":
                continue
            past_header = True

        result.append(line)

    return "\n".join(result).strip()


async def migrate(home_path: Path) -> None:
    """Run the migration."""
    # Import here to avoid import errors when running standalone
    from parachute.db.brain import BrainService

    graph_path = Path.home() / ".parachute" / "graph" / "parachute.kz"
    if not graph_path.parent.exists():
        print(f"Graph directory not found: {graph_path.parent}")
        sys.exit(1)

    graph = BrainService(str(graph_path))

    # Ensure Note table exists
    await graph.ensure_node_table(
        "Note",
        {
            "entry_id": "STRING",
            "note_type": "STRING",
            "date": "STRING",
            "content": "STRING",
            "snippet": "STRING",
            "created_at": "STRING",
            "title": "STRING",
            "entry_type": "STRING",
            "audio_path": "STRING",
            "aliases": "STRING",
            "status": "STRING",
            "created_by": "STRING",
            "metadata_json": "STRING",
            "brain_links_json": "STRING",
            "updated_at": "STRING",
        },
        primary_key="entry_id",
    )

    context_dir = home_path / "parachute" / "context"
    if not context_dir.exists():
        # Try alternate path
        context_dir = home_path / "context"

    if not context_dir.exists():
        print(f"Context directory not found: {context_dir}")
        print("Looked in: parachute/context/ and context/")
        sys.exit(1)

    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()

    migrated = 0
    for filename, title in CONTEXT_FILES:
        filepath = context_dir / filename
        if not filepath.exists():
            print(f"  SKIP {filename} — file not found")
            continue

        raw_content = filepath.read_text().strip()
        content = strip_frontmatter(raw_content)

        if not content:
            print(f"  SKIP {filename} — empty after stripping frontmatter")
            continue

        entry_id = f"context:{title.lower().replace(' ', '-')}"

        await graph.execute_cypher(
            "MERGE (n:Note {entry_id: $entry_id}) "
            "SET n.note_type = 'context', "
            "    n.title = $title, "
            "    n.content = $content, "
            "    n.snippet = $snippet, "
            "    n.status = 'active', "
            "    n.created_by = CASE WHEN n.created_by IS NULL THEN 'import' ELSE n.created_by END, "
            "    n.created_at = CASE WHEN n.created_at IS NULL THEN $now ELSE n.created_at END, "
            "    n.updated_at = $now",
            {
                "entry_id": entry_id,
                "title": title,
                "content": content,
                "snippet": content[:200],
                "now": now,
            },
        )
        print(f"  OK   {filename} → Note(entry_id='{entry_id}', title='{title}')")
        migrated += 1

    print(f"\nMigrated {migrated} context files to graph.")
    print("Skipped files (redundant with system prompt): " + ", ".join(sorted(SKIP_FILES)))


if __name__ == "__main__":
    home_path = Path.home() / "Parachute"
    if not home_path.exists():
        home_path = Path.home()  # Fallback: vault root is home

    print(f"Migrating context files from: {home_path}")
    print()
    asyncio.run(migrate(home_path))
