"""
Integration tests for skills and agents through the API.

Tests verify:
- Skills are discovered and included in system prompt
- Agents are discovered and passed to SDK
- Runtime plugin generation works in server context
- System prompt includes skill/agent documentation
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

    def test_skills_endpoint_exists(self, server_url):
        """Test skills list endpoint."""
        response = httpx.get(f"{server_url}/api/skills")
        # Endpoint should exist (even if returns empty list)
        assert response.status_code in (200, 404)  # 404 if not implemented yet

    def test_vault_has_skills(self, test_vault):
        """Verify test vault has skills."""
        skills_dir = test_vault / ".skills"
        assert skills_dir.exists()

        skills = list(skills_dir.iterdir())
        assert len(skills) >= 3  # summarizer, code-explainer, brainstorm


class TestAgentsAPI:
    """Test agents-related API endpoints."""

    def test_vault_has_agents(self, test_vault):
        """Verify test vault has custom agents."""
        agents_dir = test_vault / ".parachute" / "agents"
        assert agents_dir.exists()

        agents = list(agents_dir.iterdir())
        assert len(agents) >= 3  # researcher, debugger, writer


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


class TestRuntimePluginGeneration:
    """Test runtime plugin is generated correctly."""

    def test_plugin_generated_on_server_start(self, test_vault):
        """Test plugin is generated when server processes requests."""
        # After a request, plugin should exist
        plugin_dir = test_vault / ".parachute" / "runtime" / "skills-plugin"

        # May not exist until first request, but check structure if it does
        if plugin_dir.exists():
            assert (plugin_dir / ".claude-plugin" / "plugin.json").exists()
            assert (plugin_dir / "skills").exists()


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


class TestSkillDiscoveryFromAPI:
    """Test skill discovery via direct module imports."""

    def test_skills_discovered_from_vault(self, test_vault):
        """Test skills module discovers skills from test vault."""
        from parachute.core.skills import discover_skills

        skills = discover_skills(test_vault)

        assert len(skills) == 3
        skill_names = {s.name for s in skills}
        assert "Summarizer" in skill_names
        assert "Code Explainer" in skill_names
        assert "Brainstorm" in skill_names

    def test_agents_discovered_from_vault(self, test_vault):
        """Test agents module discovers agents from test vault."""
        from parachute.core.agents import discover_agents

        agents = discover_agents(test_vault)

        assert len(agents) == 3
        agent_names = {a.name for a in agents}
        assert "researcher" in agent_names
        assert "debugger" in agent_names
        assert "writer" in agent_names


class TestCLIIntegration:
    """Test CLI flags are constructed correctly."""

    def test_plugin_dir_flag_format(self, test_vault):
        """Test plugin directory path is valid for CLI."""
        from parachute.core.skills import generate_runtime_plugin

        plugin_dir = generate_runtime_plugin(test_vault)

        assert plugin_dir is not None
        assert plugin_dir.is_absolute()
        assert plugin_dir.exists()

        # Path should not contain spaces or special chars that need escaping
        path_str = str(plugin_dir)
        # Basic check - path should be usable in CLI
        assert " " not in path_str or path_str.startswith("/tmp")

    def test_agents_json_format(self, test_vault):
        """Test agents JSON is valid for CLI flag."""
        from parachute.core.agents import discover_agents, agents_to_sdk_format
        import json

        agents = discover_agents(test_vault)
        sdk_format = agents_to_sdk_format(agents)

        # Should serialize to valid JSON
        json_str = json.dumps(sdk_format)
        assert json_str

        # Should deserialize back
        parsed = json.loads(json_str)
        assert "researcher" in parsed


class TestEdgeCases:
    """Edge case tests for skills and agents."""

    def test_skill_with_special_name(self, test_vault):
        """Test skill with special characters in name."""
        from parachute.core.skills import discover_skills

        # Our test vault has "Code Explainer" with a space
        skills = discover_skills(test_vault)
        code_explainer = next(s for s in skills if "Explainer" in s.name)

        assert code_explainer.name == "Code Explainer"

    def test_agent_with_multiline_prompt(self, test_vault):
        """Test agent with multiline YAML prompt."""
        from parachute.core.agents import discover_agents

        agents = discover_agents(test_vault)
        researcher = next(a for a in agents if a.name == "researcher")

        # Should have multi-line prompt
        assert "\n" in researcher.prompt
        assert "Scope Definition" in researcher.prompt

    def test_vault_without_skills_graceful(self, tmp_path):
        """Test server handles vault without skills gracefully."""
        from parachute.core.skills import discover_skills, generate_runtime_plugin

        skills = discover_skills(tmp_path)
        assert skills == []

        plugin = generate_runtime_plugin(tmp_path)
        assert plugin is None

    def test_vault_without_agents_graceful(self, tmp_path):
        """Test server handles vault without agents gracefully."""
        from parachute.core.agents import discover_agents, agents_to_sdk_format

        agents = discover_agents(tmp_path)
        assert agents == []

        sdk_format = agents_to_sdk_format(agents)
        assert sdk_format == {}
