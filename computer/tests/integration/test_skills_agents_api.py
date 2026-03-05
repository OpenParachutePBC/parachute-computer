"""
Integration tests for chat API and server health.

Note: Vault-level skills pipeline was removed (March 2026). Skills
live in .claude/skills/ and are discovered natively by the SDK via
setting_sources=["project"]. Custom agents are also SDK-native.
"""

import asyncio
import json
import os
import pytest
import httpx
from pathlib import Path

# Test server configuration
TEST_SERVER_URL = os.environ.get("TEST_SERVER_URL", "http://localhost:3335")
TEST_VAULT_PATH = Path(os.environ.get("TEST_VAULT_PATH", "/tmp/parachute-skills-test"))


def is_server_running():
    """Check if test server is running."""
    try:
        response = httpx.get(f"{TEST_SERVER_URL}/api/health", timeout=5)
        return response.status_code == 200
    except (httpx.HTTPError, httpx.TimeoutException, OSError):
        return False


@pytest.fixture(scope="module")
def server_url():
    """Get test server URL and verify it's running."""
    if not is_server_running():
        pytest.skip(f"Test server not running at {TEST_SERVER_URL}")
    return TEST_SERVER_URL


@pytest.fixture(scope="module")
def test_vault():
    """Get test vault path and verify it exists."""
    if not TEST_VAULT_PATH.exists():
        pytest.skip(f"Test vault not found at {TEST_VAULT_PATH}")
    return TEST_VAULT_PATH


class TestServerHealth:
    """Basic server connectivity tests."""

    def test_health_endpoint(self, server_url):
        """Test health endpoint responds."""
        response = httpx.get(f"{server_url}/api/health")
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "ok"


class TestSkillsAPI:
    """Test skills-related API endpoints."""

    def test_capabilities_endpoint_exists(self, server_url):
        """Test capabilities list endpoint."""
        response = httpx.get(f"{server_url}/api/capabilities")
        assert response.status_code == 200
        data = response.json()
        assert "skills" in data


class TestChatWithSkillsAndAgents:
    """Test chat endpoint with skills/agents context."""

    @pytest.mark.asyncio
    async def test_chat_stream_connects(self, server_url):
        """Test chat SSE endpoint accepts connections."""
        async with httpx.AsyncClient() as client:
            async with client.stream(
                "POST",
                f"{server_url}/api/chat",
                json={"message": "Hello"},
                timeout=60.0,
            ) as response:
                # Should establish SSE connection
                assert response.status_code == 200
                assert "text/event-stream" in response.headers.get("content-type", "")

                # Read first few events
                events = []
                async for line in response.aiter_lines():
                    if line.startswith("data: "):
                        data = json.loads(line[6:])
                        events.append(data)
                        if len(events) >= 3:
                            break

                # Should receive some events
                assert len(events) >= 1

    @pytest.mark.asyncio
    async def test_session_created_with_skills_context(self, server_url):
        """Test that sessions are created with skills context."""
        async with httpx.AsyncClient() as client:
            session_id = None

            async with client.stream(
                "POST",
                f"{server_url}/api/chat",
                json={"message": "List available skills"},
                timeout=120.0,
            ) as response:
                assert response.status_code == 200

                async for line in response.aiter_lines():
                    if line.startswith("data: "):
                        try:
                            data = json.loads(line[6:])
                            if data.get("type") == "session":
                                session_id = data.get("sessionId")
                            elif data.get("type") == "done":
                                break
                        except json.JSONDecodeError:
                            continue

            # Session should have been created
            assert session_id is not None


class TestSystemPromptInclusion:
    """Test that skills/agents are included in system prompts."""

    @pytest.mark.asyncio
    async def test_prompt_metadata_includes_skills_info(self, server_url):
        """Test prompt metadata event includes context about skills."""
        async with httpx.AsyncClient() as client:
            prompt_metadata = None

            async with client.stream(
                "POST",
                f"{server_url}/api/chat",
                json={"message": "What can you help me with?"},
                timeout=120.0,
            ) as response:
                assert response.status_code == 200

                async for line in response.aiter_lines():
                    if line.startswith("data: "):
                        try:
                            data = json.loads(line[6:])
                            if data.get("type") == "prompt_metadata":
                                prompt_metadata = data
                            elif data.get("type") == "done":
                                break
                        except json.JSONDecodeError:
                            continue

            # Should have received prompt metadata
            assert prompt_metadata is not None
            assert "promptSource" in prompt_metadata


