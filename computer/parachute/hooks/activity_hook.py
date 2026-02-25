#!/usr/bin/env python3
"""
Activity Hook - logs session exchanges to Daily/.activity/ JSONL files.

This script is triggered by the SDK's Stop hook after each response.
It reads the transcript and appends an entry to the daily activity log.

Note: Title and summary generation has moved to the server's streaming event
loop (session_summarizer.py). This hook handles activity logging only.

Usage: python -m parachute.hooks.activity_hook
       (SDK passes hook input via stdin)
"""

import asyncio
import json
import os
import sys
import logging
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


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
    Handle the Stop hook event — append to Daily/.activity/ log.

    Title and summary generation is handled server-side by session_summarizer.py.
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
            logger.debug("No exchange found in transcript")
            return

        # 2. Fetch session for agent_type (used in activity log entry)
        session = await _get_session(session_id)
        session_title = session.title if session else None
        agent_type = session.get_agent_type() if session else None

        # 3. Append to daily activity log
        await append_activity_log(
            session_id=session_id,
            session_title=session_title,
            agent_type=agent_type,
            exchange_number=exchange.get("exchange_number", 1),
            summary=None,  # Summary written server-side by session_summarizer
        )

    except Exception as e:
        logger.warning(f"Activity hook failed: {e}")


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

    # Find last human text message by iterating backwards (skip tool-result-only entries)
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

            # Skip tool-result-only user entries (no human text) and keep searching
            if not user_message:
                continue

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


def _get_server_url() -> str:
    """Return the Parachute server base URL reachable from this process.

    Inside a Docker sandbox, localhost points to the container — use the
    Docker host gateway instead. Outside Docker, localhost is correct.
    """
    port = os.environ.get("PARACHUTE_SERVER_PORT", "3333")
    if Path("/.dockerenv").exists():
        return f"http://host.docker.internal:{port}"
    return f"http://localhost:{port}"


class _SessionStub:
    """Minimal session-like object built from the API GET response."""

    def __init__(self, data: dict):
        self.title = data.get("title")
        self.metadata = data.get("metadata") or {}
        self._agent_type = data.get("agentType")

    def get_agent_type(self) -> Optional[str]:
        return self._agent_type or self.metadata.get("agent_type")


async def _get_session(session_id: str) -> Optional[Any]:
    """Fetch a session via the Parachute server API. Returns None on any failure."""
    try:
        import httpx

        url = f"{_get_server_url()}/api/chat/{session_id}"
        async with httpx.AsyncClient() as client:
            resp = await client.get(url, timeout=5.0)
        if resp.status_code == 200:
            return _SessionStub(resp.json())
    except Exception as e:
        logger.debug(f"Failed to fetch session {session_id[:8]}: {e}")
    return None


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


if __name__ == "__main__":
    main()
