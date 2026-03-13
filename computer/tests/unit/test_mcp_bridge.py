"""Tests for the MCP HTTP bridge — token system, tool registration, and auth."""

import json
import pytest

from parachute.lib.sandbox_tokens import SandboxTokenContext, SandboxTokenStore


class TestSandboxTokenStore:
    """Tests for token creation, validation, and revocation."""

    def test_create_and_validate(self):
        store = SandboxTokenStore()
        ctx = SandboxTokenContext(
            session_id="caller-test",
            trust_level="sandboxed",
            agent_name="test-agent",
            allowed_writes=["write_output"],
        )
        token = store.create_token(ctx)

        assert isinstance(token, str)
        assert len(token) > 20  # token_urlsafe(32) produces ~43 chars

        validated = store.validate_token(token)
        assert validated is not None
        assert validated.session_id == "caller-test"
        assert validated.agent_name == "test-agent"
        assert validated.allowed_writes == ["write_output"]

    def test_invalid_token_returns_none(self):
        store = SandboxTokenStore()
        assert store.validate_token("bogus-token-value") is None
        assert store.validate_token("") is None

    def test_revoke_token(self):
        store = SandboxTokenStore()
        ctx = SandboxTokenContext(
            session_id="caller-test",
            trust_level="sandboxed",
        )
        token = store.create_token(ctx)
        assert store.validate_token(token) is not None

        store.revoke_token(token)
        assert store.validate_token(token) is None

    def test_revoke_nonexistent_is_noop(self):
        store = SandboxTokenStore()
        store.revoke_token("nonexistent")  # Should not raise

    def test_active_count(self):
        store = SandboxTokenStore()
        assert store.active_count == 0

        ctx = SandboxTokenContext(session_id="s1", trust_level="sandboxed")
        t1 = store.create_token(ctx)
        assert store.active_count == 1

        ctx2 = SandboxTokenContext(session_id="s2", trust_level="sandboxed")
        t2 = store.create_token(ctx2)
        assert store.active_count == 2

        store.revoke_token(t1)
        assert store.active_count == 1

    def test_multiple_tokens_independent(self):
        store = SandboxTokenStore()
        ctx1 = SandboxTokenContext(session_id="s1", trust_level="sandboxed", agent_name="a1")
        ctx2 = SandboxTokenContext(session_id="s2", trust_level="sandboxed", agent_name="a2")

        t1 = store.create_token(ctx1)
        t2 = store.create_token(ctx2)

        assert store.validate_token(t1).agent_name == "a1"
        assert store.validate_token(t2).agent_name == "a2"

        store.revoke_token(t1)
        assert store.validate_token(t1) is None
        assert store.validate_token(t2) is not None  # t2 still valid


class TestMcpToolRegistration:
    """Tests for tool definitions and handler dispatch."""

    def test_tools_defined(self):
        from parachute.api.mcp_tools import TOOLS
        tool_names = {t.name for t in TOOLS}
        assert "read_journal" in tool_names
        assert "read_recent_journals" in tool_names
        assert "search_memory" in tool_names
        assert "list_recent_sessions" in tool_names
        assert "read_brain_entity" in tool_names
        assert "write_output" in tool_names
        # Chat memory tools (shared handlers)
        assert "search_chats" in tool_names
        assert "get_chat" in tool_names
        assert "get_exchange" in tool_names

    def test_all_tools_have_handlers(self):
        from parachute.api.mcp_tools import TOOLS, _HANDLERS
        for tool in TOOLS:
            assert tool.name in _HANDLERS, f"No handler for tool: {tool.name}"

    def test_tool_schemas_valid(self):
        from parachute.api.mcp_tools import TOOLS
        for tool in TOOLS:
            schema = tool.inputSchema
            assert schema.get("type") == "object"
            assert "properties" in schema


class TestMcpBridge:
    """Tests for MCP bridge setup."""

    def test_create_mcp_server(self):
        from parachute.api.mcp_bridge import create_mcp_server
        server = create_mcp_server()
        assert server is not None
        assert server.name == "parachute-sandbox"

    def test_create_session_manager(self):
        from parachute.api.mcp_bridge import create_mcp_server, create_session_manager
        server = create_mcp_server()
        manager = create_session_manager(server)
        assert manager is not None

    def test_create_asgi_app(self):
        from parachute.api.mcp_bridge import (
            create_mcp_server,
            create_session_manager,
            create_mcp_asgi_app,
        )
        server = create_mcp_server()
        manager = create_session_manager(server)
        store = SandboxTokenStore()
        asgi_app = create_mcp_asgi_app(manager, store)
        assert callable(asgi_app)


class TestWritePermissionGating:
    """Tests for write tool permission enforcement."""

    @pytest.mark.asyncio
    async def test_write_output_denied_without_permission(self):
        from parachute.api.mcp_tools import _handle_write_output
        from parachute.api.mcp_bridge import _current_sandbox_ctx

        ctx = SandboxTokenContext(
            session_id="test",
            trust_level="sandboxed",
            agent_name="test-agent",
            allowed_writes=[],  # No writes allowed
        )
        reset = _current_sandbox_ctx.set(ctx)
        try:
            result = await _handle_write_output({"content": "hello", "date": "2026-03-12"})
            data = json.loads(result)
            assert "error" in data
            assert "not permitted" in data["error"]
        finally:
            _current_sandbox_ctx.reset(reset)

    @pytest.mark.asyncio
    async def test_write_output_denied_without_context(self):
        from parachute.api.mcp_tools import _handle_write_output
        from parachute.api.mcp_bridge import _current_sandbox_ctx

        reset = _current_sandbox_ctx.set(None)
        try:
            result = await _handle_write_output({"content": "hello", "date": "2026-03-12"})
            data = json.loads(result)
            assert "error" in data
            assert "No sandbox context" in data["error"]
        finally:
            _current_sandbox_ctx.reset(reset)
