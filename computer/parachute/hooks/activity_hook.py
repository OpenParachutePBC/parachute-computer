#!/usr/bin/env python3
"""
Activity Hook - logs all session exchanges with AI-generated summaries.

This script is triggered by the SDK's Stop hook after each response.
It reads the transcript, summarizes the last exchange, and logs it.

Usage: python -m parachute.hooks.activity_hook
       (SDK passes hook input via stdin)

Hook Configuration (in .claude/settings.json):
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "python -m parachute.hooks.activity_hook"
          }
        ]
      }
    ]
  }
}
"""

import asyncio
import json
import sys
import logging
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

# System prompt for the summarizer agent
SUMMARIZER_SYSTEM_PROMPT = """You are a concise summarizer for conversation activity logs.

Your job is to summarize each conversation exchange in 1-3 sentences, capturing:
- What was accomplished or discussed
- Any decisions made
- Key insights or realizations

Also suggest a title for the conversation (3-8 words).

Always respond in this exact format:
SUMMARY: <your summary>
TITLE: <title or NO_CHANGE if current title is still accurate>

Be concise. Focus on what matters for future context."""

# Simple file-based cache for daily summarizer session
SUMMARIZER_CACHE_FILE = ".activity_summarizer_sessions.json"


def main():
    """Entry point - read hook input from stdin and process."""
    # SDK passes hook input as JSON on stdin
    try:
        hook_input = json.loads(sys.stdin.read())
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse hook input: {e}")
        return

    # Run the async handler
    asyncio.run(handle_stop_hook(hook_input))


async def handle_stop_hook(hook_input: dict) -> None:
    """
    Handle the Stop hook event.

    Args:
        hook_input: JSON from SDK containing transcript_path, session_id, etc.
    """
    try:
        transcript_path = Path(hook_input.get("transcript_path", ""))
        session_id = hook_input.get("session_id", "")

        if not transcript_path or not session_id:
            logger.debug("Missing transcript_path or session_id, skipping")
            return

        if not transcript_path.exists():
            logger.debug(f"Transcript not found: {transcript_path}")
            return

        # 1. Read the last exchange from the transcript
        exchange = read_last_exchange(transcript_path)
        if not exchange:
            logger.debug("No exchange to summarize")
            return

        exchange_num = exchange.get("exchange_number", 1)

        # 2. Decide whether this exchange warrants a title update
        if not _should_update_title(exchange_num):
            return

        # 3. Fetch session once — reuse for title, metadata, and agent_type
        session = await _get_session(session_id)
        session_title = session.title if session else None
        agent_type = session.get_agent_type() if session else None
        title_source = (
            session.metadata.get("title_source")
            if session and session.metadata
            else None
        )
        user_renamed = title_source == "user"

        # 4. Call the summarizer (uses SDK internally)
        summary, new_title = await call_summarizer(
            session_id=session_id,
            session_title=session_title,
            user_message=exchange["user_message"],
            assistant_response=exchange["assistant_response"],
            tools_used=exchange.get("tools_used", []),
            thinking=exchange.get("thinking", ""),
            exchange_number=exchange_num,
        )

        # 5. Append to activity log
        await append_activity_log(
            session_id=session_id,
            session_title=session_title,
            agent_type=agent_type,
            exchange_number=exchange_num,
            summary=summary,
        )

        # 6. Persist summary to session record
        if summary:
            await update_session_summary(session_id, summary)

        # 7. Update session title if changed (and user hasn't renamed it)
        if not user_renamed and new_title and new_title != "NO_CHANGE" and new_title != session_title:
            await update_session_title(session_id, new_title, title_source="ai")

    except Exception as e:
        # Fire-and-forget - log but don't fail
        logger.warning(f"Activity hook failed: {e}")


# Cadence control: don't call Haiku on every exchange
_TITLE_UPDATE_EXCHANGES = {1, 3, 5}  # Always fire on these
_TITLE_UPDATE_INTERVAL = 10           # After 5, fire every 10th


def _should_update_title(exchange_number: int) -> bool:
    """Decide whether this exchange warrants a title update via Haiku."""
    return (
        exchange_number in _TITLE_UPDATE_EXCHANGES
        or (exchange_number > 5 and exchange_number % _TITLE_UPDATE_INTERVAL == 0)
    )


def read_last_exchange(transcript_path: Path) -> Optional[dict]:
    """
    Read and parse the last exchange from the transcript JSONL.

    Returns dict with user_message, assistant_response, tools_used, thinking, exchange_number.
    """
    if not transcript_path.exists():
        return None

    try:
        lines = transcript_path.read_text().strip().split("\n")
    except Exception as e:
        logger.warning(f"Failed to read transcript: {e}")
        return None

    if not lines:
        return None

    # Parse messages
    messages = []
    for line in lines:
        if line.strip():
            try:
                messages.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    if not messages:
        return None

    # Find the last user message and subsequent assistant response
    user_message = None
    assistant_response = ""
    tools_used = []
    thinking = ""
    exchange_number = 0

    # Count exchanges (user messages)
    for msg in messages:
        if msg.get("type") == "user":
            exchange_number += 1

    # Find last user message by iterating backwards
    for i, msg in enumerate(reversed(messages)):
        if msg.get("type") == "user":
            # Extract text content from user message
            user_msg = msg.get("message", {})
            content = user_msg.get("content", [])
            if isinstance(content, str):
                user_message = content
            elif isinstance(content, list):
                user_message = " ".join(
                    block.get("text", "")
                    for block in content
                    if isinstance(block, dict) and block.get("type") == "text"
                )

            # Now look at messages after this for assistant response
            actual_index = len(messages) - 1 - i
            for subsequent in messages[actual_index + 1:]:
                if subsequent.get("type") == "assistant":
                    asst_msg = subsequent.get("message", {})
                    content = asst_msg.get("content", [])
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict):
                                if block.get("type") == "text":
                                    assistant_response += block.get("text", "")
                                elif block.get("type") == "tool_use":
                                    tools_used.append(block.get("name", ""))
                                elif block.get("type") == "thinking":
                                    thinking += block.get("thinking", "")
            break

    if not user_message:
        return None

    return {
        "user_message": user_message,
        "assistant_response": assistant_response,
        "tools_used": tools_used,
        "thinking": thinking,
        "exchange_number": exchange_number,
    }


async def _get_session(session_id: str) -> Optional[Any]:
    """Fetch a session from the database. Returns None on any failure."""
    try:
        from parachute.db.database import get_database
        db = await get_database()
        return await db.get_session(session_id)
    except Exception as e:
        logger.debug(f"Failed to fetch session {session_id[:8]}: {e}")
        return None


async def call_summarizer(
    session_id: str,
    session_title: Optional[str],
    user_message: str,
    assistant_response: str,
    tools_used: list[str],
    thinking: str,
    exchange_number: int,
) -> tuple[str, str]:
    """
    Call the daily summarizer agent to summarize this exchange.

    Uses SDK query_streaming() with resume for session continuity.
    """
    from parachute.config import get_settings
    from parachute.core.claude_sdk import query_streaming

    settings = get_settings()
    vault_path = settings.vault_path

    # Get or create today's summarizer session
    today = datetime.utcnow().strftime("%Y-%m-%d")
    resume_session_id = await get_daily_summarizer_session(vault_path, today)

    # Build the prompt
    tools_str = ", ".join(tools_used) if tools_used else "None"
    truncated_response = assistant_response[:2000]
    if len(assistant_response) > 2000:
        truncated_response += "... [truncated]"

    truncated_user = user_message[:1000]
    if len(user_message) > 1000:
        truncated_user += "... [truncated]"

    prompt = f"""Summarize this conversation exchange:

Current session title: {session_title or "None"}
Exchange #{exchange_number}

---

User: {truncated_user}

Tools used: {tools_str}
Assistant: {truncated_response}

---

Respond in this exact format:
SUMMARY: <your 1-3 sentence summary>
TITLE: <new title or NO_CHANGE>"""

    # Call the SDK
    result_text = ""
    new_session_id = None

    async for event in query_streaming(
        prompt=prompt,
        system_prompt=SUMMARIZER_SYSTEM_PROMPT,
        use_claude_code_preset=False,
        tools=[],
        resume=resume_session_id,
        setting_sources=[],  # Don't load CLAUDE.md
        claude_token=settings.claude_code_oauth_token,
    ):
        if event.get("type") == "system" and event.get("session_id"):
            new_session_id = event["session_id"]

        if event.get("type") == "assistant" and event.get("message"):
            for block in event["message"].get("content", []):
                if block.get("type") == "text":
                    result_text += block.get("text", "")

    # Save session ID for today if new
    if new_session_id and not resume_session_id:
        await save_daily_summarizer_session(vault_path, today, new_session_id)

    # Parse response
    summary = ""
    title = "NO_CHANGE"
    for line in result_text.strip().split("\n"):
        if line.startswith("SUMMARY:"):
            summary = line[8:].strip()
        elif line.startswith("TITLE:"):
            title = line[6:].strip()

    return summary, title


async def get_daily_summarizer_session(vault_path: Path, date: str) -> Optional[str]:
    """Get the summarizer session ID for a given date."""
    cache_path = vault_path / "Daily" / ".activity" / SUMMARIZER_CACHE_FILE
    if not cache_path.exists():
        return None

    try:
        cache = json.loads(cache_path.read_text())
        return cache.get(date)
    except Exception as e:
        logger.debug(f"Failed to read summarizer cache: {e}")
        return None


async def save_daily_summarizer_session(vault_path: Path, date: str, session_id: str) -> None:
    """Save the summarizer session ID for a given date."""
    cache_dir = vault_path / "Daily" / ".activity"
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / SUMMARIZER_CACHE_FILE

    cache = {}
    if cache_path.exists():
        try:
            cache = json.loads(cache_path.read_text())
        except Exception as e:
            logger.debug(f"Failed to read existing summarizer cache: {e}")

    cache[date] = session_id
    cache_path.write_text(json.dumps(cache, indent=2))


async def append_activity_log(
    session_id: str,
    session_title: Optional[str],
    agent_type: Optional[str],
    exchange_number: int,
    summary: str,
) -> None:
    """Append an entry to the daily activity log."""
    from parachute.config import get_settings

    settings = get_settings()
    vault_path = settings.vault_path

    today = datetime.utcnow().strftime("%Y-%m-%d")
    log_dir = vault_path / "Daily" / ".activity"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / f"{today}.jsonl"

    entry = {
        "ts": datetime.utcnow().isoformat() + "Z",
        "session_id": session_id,
        "session_title": session_title,
        "agent_type": agent_type,
        "exchange_number": exchange_number,
        "summary": summary,
    }

    with open(log_file, "a") as f:
        f.write(json.dumps(entry) + "\n")


async def update_session_title(
    session_id: str, new_title: str, title_source: str = "ai"
) -> None:
    """Update session title and title_source in the database."""
    try:
        from parachute.db.database import get_database
        from parachute.models.session import SessionUpdate

        session = await _get_session(session_id)
        metadata = dict(session.metadata or {}) if session and session.metadata else {}
        metadata["title_source"] = title_source
        db = await get_database()
        await db.update_session(
            session_id, SessionUpdate(title=new_title, metadata=metadata)
        )
    except Exception as e:
        logger.warning(f"Failed to update session title: {e}")


async def update_session_summary(session_id: str, summary: str) -> None:
    """Persist AI-generated summary to the session record."""
    if not summary:
        return
    try:
        from parachute.db.database import get_database
        from parachute.models.session import SessionUpdate

        db = await get_database()
        await db.update_session(session_id, SessionUpdate(summary=summary))
    except Exception as e:
        logger.debug(f"Failed to update session summary: {e}")


if __name__ == "__main__":
    main()
