"""
Import service for converting Claude/ChatGPT exports to SDK JSONL format.

This service:
1. Parses export files from Claude.ai and ChatGPT
2. Converts conversations to SDK JSONL format
3. Writes JSONL files to ~/.claude/projects/{vault}/
4. Inserts session records into SQLite
"""

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from dataclasses import dataclass, field

from ..db.database import Database
from ..models.session import Session, SessionSource


@dataclass
class ImportedMessage:
    """A message from an imported conversation."""
    role: str  # 'user' or 'assistant'
    content: str
    timestamp: Optional[datetime] = None


@dataclass
class ImportedConversation:
    """A parsed conversation from an export."""
    original_id: str
    title: str
    created_at: datetime
    updated_at: Optional[datetime] = None
    messages: list[ImportedMessage] = field(default_factory=list)
    source: SessionSource = SessionSource.CLAUDE_WEB


@dataclass
class ImportResult:
    """Result of an import operation."""
    total_conversations: int
    imported_count: int
    skipped_count: int
    errors: list[str]
    session_ids: list[str]


class ImportService:
    """Service for importing external chat exports."""

    def __init__(self, vault_path: str, database: Database, module: str = "chat"):
        self.vault_path = vault_path
        self.database = database
        self.module = module
        self._sdk_projects_dir = Path.home() / ".claude" / "projects"

        # Working directory for this module (e.g., ~/Parachute/Chat)
        self.working_directory = str(Path(vault_path) / module.capitalize())

    def _get_encoded_working_dir(self) -> str:
        """Encode working directory for SDK directory naming."""
        # /Users/foo/Parachute/Chat -> -Users-foo-Parachute-Chat
        return self.working_directory.replace("/", "-")

    def _get_sdk_session_dir(self) -> Path:
        """Get the SDK projects directory for this module."""
        encoded = self._get_encoded_working_dir()
        return self._sdk_projects_dir / encoded

    # =========================================================================
    # Parsing
    # =========================================================================

    def detect_source(self, data: dict | list) -> SessionSource:
        """Detect whether export is from Claude or ChatGPT."""
        if isinstance(data, list) and len(data) > 0:
            first = data[0]
            if isinstance(first, dict):
                # ChatGPT has 'mapping' with message tree
                if "mapping" in first:
                    return SessionSource.CHATGPT
                # Claude has 'chat_messages'
                if "chat_messages" in first:
                    return SessionSource.CLAUDE_WEB
        elif isinstance(data, dict):
            if "mapping" in data:
                return SessionSource.CHATGPT
            if "chat_messages" in data or "conversations" in data:
                return SessionSource.CLAUDE_WEB

        return SessionSource.CLAUDE_WEB  # Default fallback

    def parse_export(self, data: dict | list) -> list[ImportedConversation]:
        """Parse an export file and return conversations."""
        source = self.detect_source(data)

        if source == SessionSource.CHATGPT:
            return self._parse_chatgpt_export(data)
        else:
            return self._parse_claude_export(data)

    def _parse_claude_export(self, data: dict | list) -> list[ImportedConversation]:
        """Parse Claude.ai export format."""
        conversations = []

        # Handle array or wrapped format
        if isinstance(data, list):
            items = data
        elif isinstance(data, dict):
            items = data.get("conversations", data.get("chats", [data]))
        else:
            return []

        for conv in items:
            try:
                parsed = self._parse_claude_conversation(conv)
                if parsed and parsed.messages:
                    conversations.append(parsed)
            except Exception as e:
                print(f"[Import] Error parsing Claude conversation: {e}")

        return conversations

    def _parse_claude_conversation(self, conv: dict) -> Optional[ImportedConversation]:
        """Parse a single Claude conversation."""
        # Get ID
        original_id = conv.get("uuid") or conv.get("id") or conv.get("conversation_id")
        if not original_id:
            return None

        # Get title
        title = conv.get("name") or conv.get("title") or "Untitled Conversation"

        # Parse timestamps
        created_at = self._parse_iso_timestamp(conv.get("created_at")) or datetime.now(timezone.utc)
        updated_at = self._parse_iso_timestamp(conv.get("updated_at"))

        # Parse messages
        chat_messages = conv.get("chat_messages") or conv.get("messages") or []
        messages = []

        for msg in chat_messages:
            if not isinstance(msg, dict):
                continue

            # Claude uses 'sender' (human/assistant)
            sender = msg.get("sender") or msg.get("role")
            if sender == "human":
                role = "user"
            elif sender == "assistant":
                role = "assistant"
            else:
                continue  # Skip system messages

            # Get content - might be 'text' or 'content' blocks
            content = None
            text_field = msg.get("text") or msg.get("content")

            if isinstance(text_field, str):
                content = text_field
            elif isinstance(text_field, list):
                # Content blocks format
                parts = []
                for block in text_field:
                    if isinstance(block, dict) and block.get("type") == "text":
                        parts.append(block.get("text", ""))
                content = "\n".join(parts)

            if not content or not content.strip():
                continue

            timestamp = self._parse_iso_timestamp(msg.get("created_at"))

            messages.append(ImportedMessage(
                role=role,
                content=content.strip(),
                timestamp=timestamp
            ))

        if not messages:
            return None

        return ImportedConversation(
            original_id=original_id,
            title=title,
            created_at=created_at,
            updated_at=updated_at,
            messages=messages,
            source=SessionSource.CLAUDE_WEB
        )

    def _parse_chatgpt_export(self, data: dict | list) -> list[ImportedConversation]:
        """Parse ChatGPT export format."""
        conversations = []

        items = data if isinstance(data, list) else [data]

        for conv in items:
            try:
                parsed = self._parse_chatgpt_conversation(conv)
                if parsed and parsed.messages:
                    conversations.append(parsed)
            except Exception as e:
                print(f"[Import] Error parsing ChatGPT conversation: {e}")

        return conversations

    def _parse_chatgpt_conversation(self, conv: dict) -> Optional[ImportedConversation]:
        """Parse a single ChatGPT conversation."""
        original_id = conv.get("id") or conv.get("conversation_id")
        if not original_id:
            return None

        title = conv.get("title") or "Untitled Conversation"

        # Parse timestamps (Unix seconds)
        create_time = conv.get("create_time")
        update_time = conv.get("update_time")
        created_at = self._parse_unix_timestamp(create_time) or datetime.now(timezone.utc)
        updated_at = self._parse_unix_timestamp(update_time)

        # ChatGPT uses a tree structure with mapping
        mapping = conv.get("mapping")
        if not mapping:
            return None

        # Trace path from root to current node
        message_order = []
        current_id = conv.get("current_node")

        if current_id:
            visited = set()
            while current_id and current_id not in visited:
                visited.add(current_id)
                message_order.insert(0, current_id)
                node = mapping.get(current_id, {})
                current_id = node.get("parent")

        # Fallback: iterate all messages
        if not message_order:
            message_order = list(mapping.keys())

        messages = []
        for msg_id in message_order:
            node = mapping.get(msg_id, {})
            message = node.get("message")
            if not message:
                continue

            author = message.get("author", {})
            role_str = author.get("role")

            if role_str not in ("user", "assistant"):
                continue

            content_obj = message.get("content", {})
            parts = content_obj.get("parts", [])

            # Combine text parts
            text_parts = [p for p in parts if isinstance(p, str)]
            content = "\n".join(text_parts).strip()

            if not content:
                continue

            msg_timestamp = self._parse_unix_timestamp(message.get("create_time"))

            messages.append(ImportedMessage(
                role=role_str,
                content=content,
                timestamp=msg_timestamp
            ))

        if not messages:
            return None

        return ImportedConversation(
            original_id=original_id,
            title=title,
            created_at=created_at,
            updated_at=updated_at,
            messages=messages,
            source=SessionSource.CHATGPT
        )

    # =========================================================================
    # Conversion to SDK JSONL
    # =========================================================================

    def convert_to_sdk_jsonl(
        self,
        conversation: ImportedConversation,
        session_id: Optional[str] = None
    ) -> tuple[str, list[dict]]:
        """
        Convert an imported conversation to SDK JSONL format.

        Returns:
            tuple: (session_id, list of JSONL events)
        """
        session_id = session_id or str(uuid.uuid4())
        events = []

        # Initial queue-operation event
        events.append({
            "type": "queue-operation",
            "operation": "dequeue",
            "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "sessionId": session_id
        })

        prev_uuid = None

        for msg in conversation.messages:
            msg_uuid = str(uuid.uuid4())
            timestamp = msg.timestamp or conversation.created_at
            timestamp_str = timestamp.isoformat().replace("+00:00", "Z")
            if not timestamp_str.endswith("Z"):
                timestamp_str += "Z"

            if msg.role == "user":
                event = {
                    "parentUuid": prev_uuid,
                    "isSidechain": False,
                    "userType": "external",
                    "cwd": self.working_directory,
                    "sessionId": session_id,
                    "version": "2.0.60",
                    "gitBranch": "",
                    "type": "user",
                    "message": {
                        "role": "user",
                        "content": [{"type": "text", "text": msg.content}]
                    },
                    "uuid": msg_uuid,
                    "timestamp": timestamp_str
                }
            else:  # assistant
                event = {
                    "parentUuid": prev_uuid,
                    "isSidechain": False,
                    "userType": "external",
                    "cwd": self.working_directory,
                    "sessionId": session_id,
                    "version": "2.0.60",
                    "gitBranch": "",
                    "message": {
                        "model": "claude-3-5-sonnet-20241022",  # Original unknown
                        "id": f"msg_{uuid.uuid4().hex[:24]}",
                        "type": "message",
                        "role": "assistant",
                        "content": [{"type": "text", "text": msg.content}],
                        "stop_reason": "end_turn",
                        "stop_sequence": None,
                        "usage": {"input_tokens": 0, "output_tokens": 0}
                    },
                    "requestId": f"req_{uuid.uuid4().hex[:24]}",
                    "type": "assistant",
                    "uuid": msg_uuid,
                    "timestamp": timestamp_str
                }

            events.append(event)
            prev_uuid = msg_uuid

        return session_id, events

    def write_sdk_jsonl(self, session_id: str, events: list[dict]) -> Path:
        """Write events to SDK JSONL file."""
        sdk_dir = self._get_sdk_session_dir()
        sdk_dir.mkdir(parents=True, exist_ok=True)

        jsonl_path = sdk_dir / f"{session_id}.jsonl"

        with open(jsonl_path, "w") as f:
            for event in events:
                f.write(json.dumps(event) + "\n")

        return jsonl_path

    # =========================================================================
    # Full Import Flow
    # =========================================================================

    async def import_conversations(
        self,
        conversations: list[ImportedConversation],
        archived: bool = True
    ) -> ImportResult:
        """
        Import conversations: convert to SDK JSONL and add to database.

        Args:
            conversations: List of parsed conversations
            archived: Whether to mark imported sessions as archived

        Returns:
            ImportResult with counts and session IDs
        """
        errors = []
        session_ids = []
        imported_count = 0
        skipped_count = 0

        for conv in conversations:
            try:
                # Generate new session ID
                session_id = str(uuid.uuid4())

                # Convert to SDK JSONL
                _, events = self.convert_to_sdk_jsonl(conv, session_id)

                # Write JSONL file
                jsonl_path = self.write_sdk_jsonl(session_id, events)
                print(f"[Import] Written: {jsonl_path}")

                # Create session record
                session = Session(
                    id=session_id,
                    title=conv.title,
                    module=self.module,
                    source=conv.source,
                    working_directory=self.working_directory,
                    created_at=conv.created_at,
                    last_accessed=conv.updated_at or conv.created_at,
                    message_count=len(conv.messages),
                    archived=archived,
                    metadata={
                        "original_id": conv.original_id,
                        "imported_at": datetime.now(timezone.utc).isoformat()
                    }
                )

                # Insert into database
                await self.database.create_session(session)
                print(f"[Import] Created session: {session_id} - {conv.title}")

                session_ids.append(session_id)
                imported_count += 1

            except Exception as e:
                print(f"[Import] Error importing '{conv.title}': {e}")
                errors.append(f"Failed to import '{conv.title}': {e}")
                skipped_count += 1

        return ImportResult(
            total_conversations=len(conversations),
            imported_count=imported_count,
            skipped_count=skipped_count,
            errors=errors,
            session_ids=session_ids
        )

    async def import_from_file(
        self,
        file_path: str,
        archived: bool = True
    ) -> ImportResult:
        """
        Import from a JSON export file.

        Args:
            file_path: Path to conversations.json or similar
            archived: Whether to mark imported sessions as archived

        Returns:
            ImportResult
        """
        with open(file_path, "r") as f:
            data = json.load(f)

        conversations = self.parse_export(data)
        print(f"[Import] Parsed {len(conversations)} conversations from {file_path}")

        return await self.import_conversations(conversations, archived=archived)

    async def import_from_json(
        self,
        json_data: dict | list,
        archived: bool = True
    ) -> ImportResult:
        """
        Import from already-parsed JSON data.

        Args:
            json_data: Parsed JSON (list of conversations or container object)
            archived: Whether to mark imported sessions as archived

        Returns:
            ImportResult
        """
        conversations = self.parse_export(json_data)
        print(f"[Import] Parsed {len(conversations)} conversations")

        return await self.import_conversations(conversations, archived=archived)

    # =========================================================================
    # Helpers
    # =========================================================================

    def _parse_iso_timestamp(self, value: Optional[str]) -> Optional[datetime]:
        """Parse ISO 8601 timestamp string."""
        if not value:
            return None
        try:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return dt
        except Exception:
            return None

    def _parse_unix_timestamp(self, value) -> Optional[datetime]:
        """Parse Unix timestamp (seconds since epoch)."""
        if value is None:
            return None
        try:
            if isinstance(value, (int, float)):
                return datetime.fromtimestamp(value, tz=timezone.utc)
        except Exception:
            pass
        return None
