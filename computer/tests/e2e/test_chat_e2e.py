"""
E2E test: send a message through the server and get a response via SSE.

Requires:
  - CLAUDE_CODE_OAUTH_TOKEN env var (Claude SDK auth)
  - DEFAULT_MODEL=haiku recommended (fast + cheap)

Skipped automatically if token is not set.
"""

import json
import os

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

pytestmark = pytest.mark.skipif(
    "CLAUDE_CODE_OAUTH_TOKEN" not in os.environ,
    reason="CLAUDE_CODE_OAUTH_TOKEN not set — skip E2E tests",
)


@pytest_asyncio.fixture
async def client(tmp_path):
    """Test client with an isolated home path so we don't touch real data."""
    # Set up minimal home structure
    home = tmp_path / "home"
    home.mkdir()
    (home / "graph").mkdir()
    (home / "modules").mkdir()
    (home / "logs").mkdir()

    os.environ["PARACHUTE_HOME"] = str(home)
    os.environ.setdefault("DEFAULT_MODEL", "haiku")

    from parachute.server import app

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
        timeout=120.0,
    ) as c:
        yield c

    os.environ.pop("PARACHUTE_HOME", None)


@pytest.mark.timeout(90)
async def test_chat_roundtrip(client):
    """Send a simple message and verify we get text back via SSE."""
    response = await client.post(
        "/api/chat",
        json={
            "message": "Reply with exactly: PONG",
            "module": "chat",
        },
    )
    assert response.status_code == 200

    events = []
    for line in response.text.split("\n"):
        if line.startswith("data: "):
            try:
                events.append(json.loads(line[6:]))
            except json.JSONDecodeError:
                continue

    # Should have at least session_id and some text
    event_types = [e.get("type") for e in events]
    assert "session_id" in event_types, f"No session_id event. Got: {event_types}"

    # Should have text content
    text_events = [e for e in events if e.get("type") == "text"]
    assert len(text_events) > 0, f"No text events. Got: {event_types}"

    # Combine all text
    full_text = "".join(e.get("text", "") for e in text_events)
    assert "PONG" in full_text.upper(), f"Expected PONG in response, got: {full_text[:200]}"

    # Should end with result
    assert "result" in event_types, f"No result event. Got: {event_types}"
