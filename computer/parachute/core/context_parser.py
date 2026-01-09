"""
Context File Parser - Parse Parachute-native context files.

These are markdown files in Chat/contexts/ that can have structured sections:
- Facts: Key information about the user/topic
- Current Focus: Active goals or projects
- History: Timestamped entries

The format is human-readable and editable while being parseable.
"""

import logging
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


@dataclass
class ContextFile:
    """Parsed representation of a context file."""

    path: Path
    name: str  # Display name
    description: str = ""

    # Main sections
    facts: list[str] = field(default_factory=list)
    current_focus: list[str] = field(default_factory=list)
    history: list[str] = field(default_factory=list)

    # Raw content
    raw_content: str = ""

    # Metadata
    is_parachute_native: bool = False  # True if has structured sections
    last_modified: Optional[datetime] = None


class ContextParser:
    """Parse Parachute-native context files."""

    SECTION_PATTERN = re.compile(r'^##\s+(.+)$', re.MULTILINE)

    def __init__(self, vault_path: Path):
        self.vault_path = vault_path
        self.contexts_dir = vault_path / "Chat" / "contexts"

    def parse_file(self, file_path: Path) -> ContextFile:
        """Parse a context file into structured representation."""
        if not file_path.exists():
            return ContextFile(path=file_path, name=file_path.stem)

        content = file_path.read_text(encoding="utf-8")

        # Extract name from first heading
        name_match = re.match(r'^#\s+(.+)$', content, re.MULTILINE)
        name = name_match.group(1) if name_match else file_path.stem

        # Extract description (blockquote after title)
        desc_match = re.search(r'^#\s+.+\n+>\s*(.+)$', content, re.MULTILINE)
        description = desc_match.group(1) if desc_match else ""

        # Check if it has structured sections
        sections = self._extract_sections(content)
        is_native = bool(sections.get("facts") or sections.get("current focus") or sections.get("history"))

        # Get last modified time
        try:
            last_modified = datetime.fromtimestamp(file_path.stat().st_mtime, tz=timezone.utc)
        except Exception:
            last_modified = None

        return ContextFile(
            path=file_path,
            name=name,
            description=description,
            facts=self._parse_bullets(sections.get("facts", "")),
            current_focus=self._parse_bullets(sections.get("current focus", "")),
            history=self._parse_bullets(sections.get("history", "")),
            raw_content=content,
            is_parachute_native=is_native,
            last_modified=last_modified,
        )

    def _extract_sections(self, content: str) -> dict[str, str]:
        """Extract sections from markdown content."""
        sections: dict[str, str] = {}
        matches = list(self.SECTION_PATTERN.finditer(content))

        for i, match in enumerate(matches):
            section_name = match.group(1).lower().strip()
            start = match.end()
            end = matches[i + 1].start() if i + 1 < len(matches) else len(content)
            sections[section_name] = content[start:end].strip()

        return sections

    def _parse_bullets(self, content: str) -> list[str]:
        """Parse bullet points from content."""
        bullets = []
        for line in content.split('\n'):
            line = line.strip()
            if re.match(r'^[-*]\s+', line):
                bullet_text = re.sub(r'^[-*]\s+', '', line)
                if bullet_text:
                    bullets.append(bullet_text)
        return bullets

    def list_context_files(self) -> list[ContextFile]:
        """List all context files with basic info."""
        files = []

        if not self.contexts_dir.exists():
            return files

        for f in sorted(self.contexts_dir.iterdir()):
            if f.is_file() and f.suffix == ".md":
                try:
                    context = self.parse_file(f)
                    files.append(context)
                except Exception as e:
                    logger.warning(f"Failed to parse context file {f}: {e}")

        return files
