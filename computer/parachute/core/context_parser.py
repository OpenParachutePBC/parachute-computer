"""
Context File Parser - Parse and update Parachute-native context files.

Parachute-native context format:
```markdown
# Project Name

> Brief description

---

## Facts
<!-- Updateable facts section - curator can modify these -->
- Key fact 1
- Key fact 2

## Current Focus
<!-- What's actively being worked on -->
- Active project or goal

## History
<!-- Append-only section for curator updates -->

<!-- Added by curator on 2025-01-05 12:00 UTC -->
- Learned something new
```

The format is designed to be:
- Human-readable and editable
- Curator-friendly (parseable sections)
- Token-efficient (concise bullet points)
- Compatible with existing markdown viewers
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
    name: str  # Display name (e.g., "Parachute", "General Context")
    description: str = ""

    # Main sections
    facts: list[str] = field(default_factory=list)
    current_focus: list[str] = field(default_factory=list)
    history: list[str] = field(default_factory=list)

    # Raw content for unparsed sections
    raw_content: str = ""

    # Metadata
    is_parachute_native: bool = False  # True if has structured sections
    last_modified: Optional[datetime] = None


class ContextParser:
    """Parse and manipulate Parachute-native context files."""

    SECTION_PATTERN = re.compile(r'^##\s+(.+)$', re.MULTILINE)
    TIMESTAMP_PATTERN = re.compile(
        r'<!--\s*Added by curator on (\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC)\s*-->'
    )

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
            history=self._parse_history_items(sections.get("history", "")),
            raw_content=content,
            is_parachute_native=is_native,
            last_modified=last_modified,
        )

    def _extract_sections(self, content: str) -> dict[str, str]:
        """Extract sections from markdown content."""
        sections: dict[str, str] = {}

        # Find all ## headings
        matches = list(self.SECTION_PATTERN.finditer(content))

        for i, match in enumerate(matches):
            section_name = match.group(1).lower().strip()
            start = match.end()

            # Find end of section (next ## or end of content)
            if i + 1 < len(matches):
                end = matches[i + 1].start()
            else:
                end = len(content)

            section_content = content[start:end].strip()
            sections[section_name] = section_content

        return sections

    def _parse_bullets(self, content: str) -> list[str]:
        """Parse bullet points from content."""
        bullets = []
        for line in content.split('\n'):
            line = line.strip()
            # Match - or * bullet points
            if re.match(r'^[-*]\s+', line):
                bullet_text = re.sub(r'^[-*]\s+', '', line)
                if bullet_text:
                    bullets.append(bullet_text)
        return bullets

    def _parse_history_items(self, content: str) -> list[str]:
        """Parse history items, including timestamps."""
        items = []
        current_item = ""

        for line in content.split('\n'):
            line = line.strip()

            # Skip empty lines
            if not line:
                if current_item:
                    items.append(current_item)
                    current_item = ""
                continue

            # Timestamp comments start a new item
            if line.startswith('<!--'):
                if current_item:
                    items.append(current_item)
                current_item = line
            elif re.match(r'^[-*]\s+', line):
                bullet_text = re.sub(r'^[-*]\s+', '', line)
                if current_item:
                    current_item += "\n- " + bullet_text
                else:
                    current_item = "- " + bullet_text
            else:
                if current_item:
                    current_item += "\n" + line

        if current_item:
            items.append(current_item)

        return items

    def update_facts(self, file_path: Path, new_facts: list[str]) -> bool:
        """
        Update the Facts section of a context file.

        If the file doesn't have a Facts section, create one.
        """
        if not file_path.exists():
            logger.warning(f"Cannot update facts: file doesn't exist: {file_path}")
            return False

        content = file_path.read_text(encoding="utf-8")

        # Find Facts section
        facts_match = re.search(
            r'(##\s+Facts\s*\n)(.*?)(?=\n##|\Z)',
            content,
            re.DOTALL | re.IGNORECASE
        )

        if facts_match:
            # Replace existing Facts section content
            new_facts_content = "\n".join(f"- {fact}" for fact in new_facts)

            # Preserve any comments in the section
            section_content = facts_match.group(2)
            comment_match = re.search(r'(<!--.*?-->)', section_content, re.DOTALL)
            if comment_match:
                new_section = f"{comment_match.group(1)}\n{new_facts_content}\n"
            else:
                new_section = f"{new_facts_content}\n"

            new_content = (
                content[:facts_match.start(2)] +
                new_section +
                content[facts_match.end(2):]
            )
        else:
            # No Facts section - add one after the description/separator
            separator_match = re.search(r'^---\s*$', content, re.MULTILINE)
            if separator_match:
                insert_pos = separator_match.end()
                new_facts_content = "\n\n## Facts\n" + "\n".join(f"- {fact}" for fact in new_facts) + "\n"
                new_content = content[:insert_pos] + new_facts_content + content[insert_pos:]
            else:
                # No separator, add at end
                new_facts_content = "\n\n## Facts\n" + "\n".join(f"- {fact}" for fact in new_facts) + "\n"
                new_content = content + new_facts_content

        file_path.write_text(new_content, encoding="utf-8")
        logger.info(f"Updated facts in {file_path.name}")
        return True

    def update_current_focus(self, file_path: Path, focus_items: list[str]) -> bool:
        """Update the Current Focus section."""
        if not file_path.exists():
            return False

        content = file_path.read_text(encoding="utf-8")

        focus_match = re.search(
            r'(##\s+Current\s+Focus\s*\n)(.*?)(?=\n##|\Z)',
            content,
            re.DOTALL | re.IGNORECASE
        )

        new_focus_content = "\n".join(f"- {item}" for item in focus_items)

        if focus_match:
            # Preserve comments
            section_content = focus_match.group(2)
            comment_match = re.search(r'(<!--.*?-->)', section_content, re.DOTALL)
            if comment_match:
                new_section = f"{comment_match.group(1)}\n{new_focus_content}\n"
            else:
                new_section = f"{new_focus_content}\n"

            new_content = (
                content[:focus_match.start(2)] +
                new_section +
                content[focus_match.end(2):]
            )
        else:
            # Add after Facts section if exists, otherwise after separator
            facts_match = re.search(r'##\s+Facts.*?(?=\n##|\Z)', content, re.DOTALL | re.IGNORECASE)
            if facts_match:
                insert_pos = facts_match.end()
            else:
                separator_match = re.search(r'^---\s*$', content, re.MULTILINE)
                insert_pos = separator_match.end() if separator_match else len(content)

            new_section = f"\n\n## Current Focus\n{new_focus_content}\n"
            new_content = content[:insert_pos] + new_section + content[insert_pos:]

        file_path.write_text(new_content, encoding="utf-8")
        logger.info(f"Updated current focus in {file_path.name}")
        return True

    def append_history(self, file_path: Path, entry: str) -> bool:
        """
        Append an entry to the History section with timestamp.

        This is the append-only operation the curator uses.
        """
        if not file_path.exists():
            return False

        content = file_path.read_text(encoding="utf-8")
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

        formatted_entry = f"\n<!-- Added by curator on {timestamp} -->\n{entry}"

        history_match = re.search(
            r'(##\s+History\s*\n)',
            content,
            re.IGNORECASE
        )

        if history_match:
            # Append to end of History section
            # Find where the next section starts (if any)
            remaining = content[history_match.end():]
            next_section = re.search(r'\n##\s+', remaining)

            if next_section:
                insert_pos = history_match.end() + next_section.start()
            else:
                insert_pos = len(content)

            new_content = content[:insert_pos] + formatted_entry + "\n" + content[insert_pos:]
        else:
            # No History section - add one at the end
            new_content = content.rstrip() + "\n\n## History\n" + formatted_entry + "\n"

        file_path.write_text(new_content, encoding="utf-8")
        logger.info(f"Appended history to {file_path.name}")
        return True

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

    def get_context_summary(self) -> str:
        """
        Get a summary of all context files for the curator.

        This helps the curator know what files exist and what they contain.
        """
        files = self.list_context_files()

        if not files:
            return "No context files found."

        lines = ["Available context files:"]
        for ctx in files:
            desc = f" - {ctx.description}" if ctx.description else ""
            native = " [structured]" if ctx.is_parachute_native else ""
            fact_count = len(ctx.facts)
            lines.append(f"- **{ctx.name}** ({ctx.path.name}){desc}{native}")
            if fact_count:
                lines.append(f"  Facts: {fact_count} items")

        return "\n".join(lines)

    def find_relevant_file(self, topic: str, existing_files: list[ContextFile]) -> Optional[Path]:
        """
        Find the most relevant context file for a topic.

        Returns None if no existing file is a good match (curator should create new).
        """
        topic_lower = topic.lower()

        for ctx in existing_files:
            name_lower = ctx.name.lower()

            # Direct name match
            if topic_lower in name_lower or name_lower in topic_lower:
                return ctx.path

            # Check if topic is mentioned in facts or description
            desc_lower = ctx.description.lower()
            if topic_lower in desc_lower:
                return ctx.path

            for fact in ctx.facts:
                if topic_lower in fact.lower():
                    return ctx.path

        # No good match - could be general-context or a new file
        general = self.contexts_dir / "general-context.md"
        if general.exists():
            return general

        return None
