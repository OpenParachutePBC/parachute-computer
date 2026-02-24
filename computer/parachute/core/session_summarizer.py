"""
Session Title and Summary Generation

Generates AI titles and summaries for chat sessions. Called as a fire-and-forget
background task from the orchestrator's streaming event loop after each exchange.

This runs server-side, so it works uniformly for direct and sandboxed sessions
without any hook registration or Python path portability concerns.
"""

import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional

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
_SUMMARIZER_CACHE_FILE = ".activity_summarizer_sessions.json"

# Cadence control: don't run the summarizer on every exchange
_TITLE_UPDATE_EXCHANGES = {1, 3, 5}  # Always fire on these
_TITLE_UPDATE_INTERVAL = 10           # After 5, fire every 10th


def _should_update(exchange_number: int) -> bool:
    """Return True if this exchange warrants a title/summary update."""
    return (
        exchange_number in _TITLE_UPDATE_EXCHANGES
        or (exchange_number > 5 and exchange_number % _TITLE_UPDATE_INTERVAL == 0)
    )


async def get_daily_summarizer_session(vault_path: Path, date: str) -> Optional[str]:
    """Get the cached summarizer session ID for a given date."""
    cache_path = vault_path / "Daily" / ".activity" / _SUMMARIZER_CACHE_FILE
    if not cache_path.exists():
        return None
    try:
        cache = json.loads(cache_path.read_text())
        return cache.get(date)
    except Exception as e:
        logger.debug(f"Failed to read summarizer cache: {e}")
        return None


async def save_daily_summarizer_session(vault_path: Path, date: str, session_id: str) -> None:
    """Persist the summarizer session ID for a given date."""
    cache_dir = vault_path / "Daily" / ".activity"
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / _SUMMARIZER_CACHE_FILE

    cache: dict = {}
    if cache_path.exists():
        try:
            cache = json.loads(cache_path.read_text())
        except Exception as e:
            logger.debug(f"Failed to read existing summarizer cache: {e}")

    cache[date] = session_id
    cache_path.write_text(json.dumps(cache, indent=2))


async def _call_summarizer(
    session_title: Optional[str],
    user_message: str,
    assistant_response: str,
    tool_calls: list[str],
    exchange_number: int,
    vault_path: Path,
    claude_token: Optional[str],
) -> tuple[Optional[str], Optional[str]]:
    """Run the summarizer Claude session. Returns (summary, new_title).

    Both may be None on failure or if the model returns NO_CHANGE.
    """
    from parachute.core.claude_sdk import query_streaming

    today = datetime.utcnow().strftime("%Y-%m-%d")
    resume_session_id = await get_daily_summarizer_session(vault_path, today)

    tools_str = ", ".join(tool_calls) if tool_calls else "None"
    truncated_user = user_message[:1000] + ("... [truncated]" if len(user_message) > 1000 else "")
    truncated_response = assistant_response[:2000] + ("... [truncated]" if len(assistant_response) > 2000 else "")

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

    result_text = ""
    new_session_id = None

    async for event in query_streaming(
        prompt=prompt,
        system_prompt=SUMMARIZER_SYSTEM_PROMPT,
        use_claude_code_preset=False,
        tools=[],
        resume=resume_session_id,
        setting_sources=[],
        claude_token=claude_token,
    ):
        if event.get("type") == "system" and event.get("session_id"):
            new_session_id = event["session_id"]
        if event.get("type") == "assistant" and event.get("message"):
            for block in event["message"].get("content", []):
                if block.get("type") == "text":
                    result_text += block.get("text", "")

    if new_session_id and not resume_session_id:
        await save_daily_summarizer_session(vault_path, today, new_session_id)

    summary: Optional[str] = None
    title: Optional[str] = None
    for line in result_text.strip().split("\n"):
        if line.startswith("SUMMARY:"):
            summary = line[8:].strip() or None
        elif line.startswith("TITLE:"):
            raw = line[6:].strip()
            if raw and raw != "NO_CHANGE":
                title = raw

    return summary, title


async def summarize_session(
    session_id: str,
    message: str,
    result_text: str,
    tool_calls: list[str],
    exchange_number: int,
    session_title: Optional[str],
    title_source: Optional[str],
    database: object,
    vault_path: Path,
    claude_token: Optional[str],
) -> None:
    """Generate and persist title/summary for a session exchange.

    Fire-and-forget: all exceptions are caught, never raises.
    Respects the title_source guard — never overwrites user-set titles.
    """
    try:
        if not _should_update(exchange_number):
            return

        summary, new_title = await _call_summarizer(
            session_title=session_title,
            user_message=message,
            assistant_response=result_text,
            tool_calls=tool_calls,
            exchange_number=exchange_number,
            vault_path=vault_path,
            claude_token=claude_token,
        )

        # Title guard: never overwrite user-set titles
        title_to_write = (
            new_title
            if title_source != "user" and new_title and new_title != session_title
            else None
        )

        if not title_to_write and not summary:
            return

        from parachute.db.database import SessionUpdate

        update = SessionUpdate()
        if title_to_write:
            session = await database.get_session(session_id)
            if session:
                metadata = dict(session.metadata or {})
                metadata["title_source"] = "ai"
                update.title = title_to_write
                update.metadata = metadata
        if summary:
            update.summary = summary

        if update.title is not None or update.summary is not None:
            await database.update_session(session_id, update)
            logger.debug(
                f"Updated session {session_id[:8]}: "
                f"title={'set' if update.title else 'unchanged'}, "
                f"summary={'set' if update.summary else 'unchanged'}"
            )

    except Exception as e:
        logger.debug(f"Session summarizer failed for {session_id[:8]}: {e}")
