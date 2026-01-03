"""
End-to-end test for chat flow with real Claude SDK.

Uses Claude Haiku for cost-efficiency during testing.
Run with: pytest tests/e2e/ -v --tb=short
"""

import asyncio
import json
import pytest
from httpx import AsyncClient, ASGITransport
from unittest.mock import patch, MagicMock

# Skip all tests in this module if ANTHROPIC_API_KEY not set
pytestmark = pytest.mark.skipif(
    "ANTHROPIC_API_KEY" not in __import__("os").environ,
    reason="ANTHROPIC_API_KEY not set - skip E2E tests"
)


@pytest.fixture
def test_app():
    """Create test app with temporary vault."""
    import tempfile
    from pathlib import Path
    import os

    # Create temporary vault
    with tempfile.TemporaryDirectory() as tmpdir:
        vault_path = Path(tmpdir)

        # Set up required directories
        (vault_path / "Chat" / "sessions").mkdir(parents=True)
        (vault_path / "Chat" / "contexts").mkdir(parents=True)
        (vault_path / ".parachute").mkdir()
        (vault_path / ".agents").mkdir()

        # Write a general context file
        (vault_path / "Chat" / "contexts" / "general-context.md").write_text("""
# Test Context

This is a test context file for E2E testing.
""")

        # Override vault path
        original_env = os.environ.get("VAULT_PATH")
        os.environ["VAULT_PATH"] = str(vault_path)

        # Import app after setting env
        from parachute.server import app

        yield app, vault_path

        # Restore env
        if original_env:
            os.environ["VAULT_PATH"] = original_env
        else:
            os.environ.pop("VAULT_PATH", None)


@pytest.fixture
async def client(test_app):
    """Create async test client."""
    app, vault_path = test_app

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


class TestChatFlow:
    """Test the complete chat flow with real SDK."""

    @pytest.mark.asyncio
    async def test_simple_chat_message(self, client):
        """Test sending a simple message and receiving a response."""
        # Send a simple message that Haiku can answer quickly
        response = await client.post(
            "/api/chat",
            json={
                "message": "What is 2+2? Reply with just the number.",
            },
            timeout=60.0,
        )

        assert response.status_code == 200
        assert response.headers["content-type"] == "text/event-stream; charset=utf-8"

        # Parse SSE events
        events = []
        for line in response.text.split("\n"):
            if line.startswith("data: "):
                data = json.loads(line[6:])
                events.append(data)

        # Should have session event
        session_events = [e for e in events if e.get("type") == "session"]
        assert len(session_events) >= 1

        # Should have text event with response
        text_events = [e for e in events if e.get("type") == "text"]
        assert len(text_events) >= 1

        # Response should contain "4"
        all_text = " ".join(e.get("content", "") for e in text_events)
        assert "4" in all_text

        # Should have done event
        done_events = [e for e in events if e.get("type") == "done"]
        assert len(done_events) == 1

        # Done event should have session ID
        done = done_events[0]
        assert done.get("sessionId")

    @pytest.mark.asyncio
    async def test_session_continuity(self, client):
        """Test that sessions can be continued."""
        # First message
        response1 = await client.post(
            "/api/chat",
            json={
                "message": "My favorite color is blue. Remember this.",
            },
            timeout=60.0,
        )

        assert response1.status_code == 200

        # Extract session ID
        session_id = None
        for line in response1.text.split("\n"):
            if line.startswith("data: "):
                data = json.loads(line[6:])
                if data.get("type") == "done":
                    session_id = data.get("sessionId")
                    break

        assert session_id, "Should get session ID from first message"

        # Second message continuing the session
        response2 = await client.post(
            "/api/chat",
            json={
                "message": "What is my favorite color?",
                "sessionId": session_id,
            },
            timeout=60.0,
        )

        assert response2.status_code == 200

        # Check response mentions blue
        text_events = []
        for line in response2.text.split("\n"):
            if line.startswith("data: "):
                data = json.loads(line[6:])
                if data.get("type") == "text":
                    text_events.append(data)

        all_text = " ".join(e.get("content", "") for e in text_events).lower()
        assert "blue" in all_text, f"Response should mention blue: {all_text[:200]}"

    @pytest.mark.asyncio
    async def test_session_stored_in_database(self, client, test_app):
        """Test that sessions are stored in SQLite."""
        # Send a message
        response = await client.post(
            "/api/chat",
            json={"message": "Hello!"},
            timeout=60.0,
        )

        assert response.status_code == 200

        # Extract session ID
        session_id = None
        for line in response.text.split("\n"):
            if line.startswith("data: "):
                data = json.loads(line[6:])
                if data.get("type") == "done":
                    session_id = data.get("sessionId")
                    break

        assert session_id

        # List sessions - should include our session
        list_response = await client.get("/api/sessions")
        assert list_response.status_code == 200

        sessions = list_response.json()
        assert isinstance(sessions, list)

        # Find our session
        our_session = next((s for s in sessions if s["id"] == session_id), None)
        assert our_session, f"Session {session_id} should be in list"
        assert our_session["message_count"] >= 2  # At least user + assistant


class TestChatErrors:
    """Test error handling in chat flow."""

    @pytest.mark.asyncio
    async def test_empty_message_error(self, client):
        """Test that empty messages return an error."""
        response = await client.post(
            "/api/chat",
            json={"message": ""},
            timeout=10.0,
        )

        assert response.status_code == 200  # SSE stream returns 200

        # Should get error event
        for line in response.text.split("\n"):
            if line.startswith("data: "):
                data = json.loads(line[6:])
                if data.get("type") == "error":
                    assert "required" in data.get("error", "").lower()
                    return

        pytest.fail("Should have received error event for empty message")

    @pytest.mark.asyncio
    async def test_invalid_session_recovery(self, client):
        """Test that invalid session IDs trigger recovery."""
        response = await client.post(
            "/api/chat",
            json={
                "message": "Hello",
                "sessionId": "nonexistent-session-id-12345",
            },
            timeout=60.0,
        )

        # Should still succeed (creates new session or recovers)
        assert response.status_code == 200

        # Parse events - should get session event
        for line in response.text.split("\n"):
            if line.startswith("data: "):
                data = json.loads(line[6:])
                # Either session or session_unavailable event
                if data.get("type") in ["session", "session_unavailable"]:
                    return

        pytest.fail("Should have received session-related event")
