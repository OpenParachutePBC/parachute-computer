"""
Chat Log - Append chat activity to Daily/chat-log/ in journal format.

Creates daily log files compatible with the Daily journal format:
- YAML frontmatter with entry metadata
- # para:ID HH:MM headers
- Markdown content
- --- separators

This runs separately from Daily's journal files to avoid concurrent
edit conflicts, but uses the same format for future UI integration.
"""

import logging
import random
import string
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml

logger = logging.getLogger(__name__)

# Characters for para ID generation (same as Daily)
PARA_ID_CHARS = string.ascii_lowercase + string.digits


def generate_para_id(length: int = 6) -> str:
    """Generate a random para ID like 'rhxo89'."""
    return ''.join(random.choices(PARA_ID_CHARS, k=length))


class ChatLogEntry:
    """A chat log entry."""

    def __init__(
        self,
        para_id: str,
        timestamp: datetime,
        title: str,
        content: str,
        session_id: Optional[str] = None,
        entry_type: str = "chat",
    ):
        self.para_id = para_id
        self.timestamp = timestamp
        self.title = title
        self.content = content
        self.session_id = session_id
        self.entry_type = entry_type

    @property
    def time_str(self) -> str:
        """HH:MM format timestamp."""
        return self.timestamp.strftime("%H:%M")

    def to_markdown(self) -> str:
        """Render entry as markdown."""
        lines = [
            f"# para:{self.para_id} {self.time_str}",
            "",
        ]
        if self.title:
            lines.append(f"**{self.title}**")
            lines.append("")
        if self.session_id:
            lines.append(f"Session: `{self.session_id}`")
            lines.append("")
        lines.append(self.content)
        return "\n".join(lines)

    def to_metadata(self) -> dict:
        """Return metadata for YAML frontmatter."""
        meta = {
            "type": self.entry_type,
            "created": self.time_str,
        }
        if self.session_id:
            meta["session"] = self.session_id
        return meta


class ChatLogService:
    """
    Service for appending entries to Daily/chat-log/.

    Uses surgical append to avoid conflicts with external editors.
    """

    def __init__(self, vault_path: Path):
        self.vault_path = vault_path
        self.chat_log_dir = vault_path / "Daily" / "chat-log"

    def _ensure_dir(self) -> None:
        """Ensure chat-log directory exists."""
        self.chat_log_dir.mkdir(parents=True, exist_ok=True)

    def _get_log_path(self, date: datetime) -> Path:
        """Get path for a day's log file."""
        return self.chat_log_dir / f"{date.strftime('%Y-%m-%d')}.md"

    def append_entry(self, entry: ChatLogEntry) -> bool:
        """
        Append an entry to today's chat log.

        Uses surgical append - reads existing file, updates frontmatter,
        appends entry to end.
        """
        self._ensure_dir()

        log_path = self._get_log_path(entry.timestamp)

        try:
            if log_path.exists():
                content = log_path.read_text(encoding="utf-8")
                frontmatter, body = self._parse_file(content)
            else:
                frontmatter = {
                    "date": entry.timestamp.strftime("%Y-%m-%d"),
                    "entries": {},
                }
                body = ""

            # Add entry metadata to frontmatter
            frontmatter.setdefault("entries", {})
            frontmatter["entries"][entry.para_id] = entry.to_metadata()

            # Append entry to body
            separator = "\n\n---\n\n" if body.strip() else ""
            new_body = body.rstrip() + separator + entry.to_markdown() + "\n"

            # Write file
            new_content = self._serialize_file(frontmatter, new_body)
            log_path.write_text(new_content, encoding="utf-8")

            logger.info(f"Appended chat log entry {entry.para_id} to {log_path.name}")
            return True

        except Exception as e:
            logger.error(f"Failed to append chat log entry: {e}", exc_info=True)
            return False

    def _parse_file(self, content: str) -> tuple[dict, str]:
        """Parse a log file into frontmatter and body."""
        if not content.startswith("---"):
            return {}, content

        # Find end of frontmatter
        end_marker = content.find("\n---", 3)
        if end_marker == -1:
            return {}, content

        frontmatter_str = content[4:end_marker]
        body = content[end_marker + 4:].lstrip("\n")

        try:
            frontmatter = yaml.safe_load(frontmatter_str) or {}
        except yaml.YAMLError:
            frontmatter = {}

        return frontmatter, body

    def _serialize_file(self, frontmatter: dict, body: str) -> str:
        """Serialize frontmatter and body to file content."""
        fm_str = yaml.dump(frontmatter, default_flow_style=False, sort_keys=False)
        return f"---\n{fm_str}---\n\n{body}"

    def log_commits(
        self,
        session_id: str,
        session_title: Optional[str],
        commits: list[dict],
    ) -> bool:
        """
        Log git commits from a chat session.

        Args:
            session_id: The chat session ID
            session_title: Session title (optional)
            commits: List of commit dicts with 'hash' and 'message' keys

        Returns:
            True if logged successfully
        """
        if not commits:
            return True

        now = datetime.now(timezone.utc).astimezone()
        para_id = generate_para_id()

        # Build content
        content_lines = []
        for commit in commits:
            hash_short = commit.get("hash", "")[:7]
            message = commit.get("message", "").split("\n")[0]  # First line only

            # Try to build GitHub link if we can detect the repo
            # For now, just show hash and message
            if hash_short:
                content_lines.append(f"- `{hash_short}` {message}")
            else:
                content_lines.append(f"- {message}")

        content = "\n".join(content_lines)

        entry = ChatLogEntry(
            para_id=para_id,
            timestamp=now,
            title=session_title or "Chat Session",
            content=content,
            session_id=session_id,
            entry_type="commits",
        )

        return self.append_entry(entry)

    def log_session_summary(
        self,
        session_id: str,
        session_title: Optional[str],
        summary: str,
    ) -> bool:
        """
        Log a session summary/milestone.

        Args:
            session_id: The chat session ID
            session_title: Session title (optional)
            summary: Summary text

        Returns:
            True if logged successfully
        """
        now = datetime.now(timezone.utc).astimezone()
        para_id = generate_para_id()

        entry = ChatLogEntry(
            para_id=para_id,
            timestamp=now,
            title=session_title or "Chat Session",
            content=summary,
            session_id=session_id,
            entry_type="summary",
        )

        return self.append_entry(entry)


def get_chat_log_service(vault_path: Path) -> ChatLogService:
    """Get a ChatLogService instance."""
    return ChatLogService(vault_path)
