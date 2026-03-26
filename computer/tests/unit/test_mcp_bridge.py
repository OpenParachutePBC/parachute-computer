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
            allowed_writes=["write_card"],
        )
        token = store.create_token(ctx)

        assert isinstance(token, str)
        assert len(token) > 20  # token_urlsafe(32) produces ~43 chars

        validated = store.validate_token(token)
        assert validated is not None
        assert validated.session_id == "caller-test"
        assert validated.agent_name == "test-agent"
        assert validated.allowed_writes == ["write_card"]

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
        assert "read_brain_entity" in tool_names
        assert "write_card" in tool_names
        # Shared vault tools
        assert "search_memory" in tool_names
        assert "search_chats" in tool_names
        assert "list_chats" in tool_names
        assert "list_notes" in tool_names
        assert "get_chat" in tool_names
        assert "get_exchange" in tool_names
        assert "write_note" in tool_names

    def test_all_tools_have_handlers(self):
        from parachute.api.mcp_tools import TOOLS, _HANDLERS, _VAULT_TOOL_NAMES
        for tool in TOOLS:
            has_handler = tool.name in _HANDLERS or tool.name in _VAULT_TOOL_NAMES
            assert has_handler, f"No handler for tool: {tool.name}"

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


class TestToolFiltering:
    """Tests for scoped tool visibility based on allowed_tools."""

    @pytest.mark.asyncio
    async def test_list_tools_no_context_returns_all(self):
        """With no sandbox context, all tools are returned."""
        from parachute.api.mcp_tools import TOOLS, register_tools
        from parachute.api.mcp_bridge import _current_sandbox_ctx
        from mcp.server import Server
        from mcp.types import ListToolsRequest

        server = Server("test")
        register_tools(server)

        handler = server.request_handlers[ListToolsRequest]
        reset = _current_sandbox_ctx.set(None)
        try:
            result = await handler(ListToolsRequest(method="tools/list"))
            assert len(result.root.tools) == len(TOOLS)
        finally:
            _current_sandbox_ctx.reset(reset)

    @pytest.mark.asyncio
    async def test_list_tools_filtered_by_allowed_tools(self):
        """With allowed_tools set, only those tools are returned."""
        from parachute.api.mcp_tools import register_tools
        from parachute.api.mcp_bridge import _current_sandbox_ctx
        from mcp.server import Server
        from mcp.types import ListToolsRequest

        server = Server("test")
        register_tools(server)
        handler = server.request_handlers[ListToolsRequest]

        ctx = SandboxTokenContext(
            session_id="test",
            trust_level="sandboxed",
            allowed_tools=frozenset({"search_memory", "list_notes"}),
        )
        reset = _current_sandbox_ctx.set(ctx)
        try:
            result = await handler(ListToolsRequest(method="tools/list"))
            tool_names = {t.name for t in result.root.tools}
            assert tool_names == {"search_memory", "list_notes"}
        finally:
            _current_sandbox_ctx.reset(reset)

    def test_chat_tools_profile_exact_membership(self):
        """CHAT_TOOLS contains exactly the expected read-only vault tools."""
        from parachute.api.mcp_tools import CHAT_TOOLS
        assert CHAT_TOOLS == {
            "search_memory", "search_chats", "list_chats",
            "get_chat", "get_exchange", "list_notes",
        }

    def test_daily_tools_profile_exact_membership(self):
        """DAILY_TOOLS contains exactly the expected daily agent tools."""
        from parachute.api.mcp_tools import DAILY_TOOLS
        assert DAILY_TOOLS == {
            "read_brain_entity", "write_card",
            "search_memory", "list_notes", "get_exchange",
        }

    @pytest.mark.asyncio
    async def test_call_tool_rejected_when_not_in_allowed(self):
        """call_tool rejects tools not in allowed_tools (defense in depth)."""
        from parachute.api.mcp_tools import register_tools
        from parachute.api.mcp_bridge import _current_sandbox_ctx
        from mcp.server import Server
        from mcp.types import CallToolRequest

        server = Server("test")
        register_tools(server)
        handler = server.request_handlers[CallToolRequest]

        ctx = SandboxTokenContext(
            session_id="test",
            trust_level="sandboxed",
            allowed_tools=frozenset({"search_memory"}),
        )
        reset = _current_sandbox_ctx.set(ctx)
        try:
            result = await handler(CallToolRequest(
                method="tools/call",
                params={"name": "write_card", "arguments": {"content": "hi", "date": "2026-01-01"}},
            ))
            data = json.loads(result.root.content[0].text)
            assert "error" in data
            assert "not available" in data["error"]
        finally:
            _current_sandbox_ctx.reset(reset)


class TestAgentToolScoping:
    """Tests for per-agent bridge tool resolution (#319).

    Agents can narrow the default profile by declaring bridge tool names
    in their tools config. Constrained to the profile ceiling — agents
    cannot self-grant tools outside the fallback.
    """

    def test_agent_can_narrow_daily_profile(self):
        """Agent declaring a subset of DAILY_TOOLS gets only those."""
        from parachute.api.mcp_tools import DAILY_TOOLS
        agent_tools = ["search_memory", "write_card"]
        result = frozenset(agent_tools) & DAILY_TOOLS
        assert result == frozenset({"search_memory", "write_card"})

    def test_agent_cannot_exceed_profile_ceiling(self):
        """Agent cannot self-grant tools outside the fallback profile."""
        from parachute.api.mcp_tools import DAILY_TOOLS
        # write_note is a bridge tool but NOT in DAILY_TOOLS
        agent_tools = ["write_note", "search_memory"]
        result = frozenset(agent_tools) & DAILY_TOOLS
        assert "write_note" not in result
        assert result == frozenset({"search_memory"})

    def test_domain_only_tools_yield_empty_intersection(self):
        """Agent with only domain tools gets empty set (caller falls back)."""
        from parachute.api.mcp_tools import DAILY_TOOLS
        agent_tools = ["read_days_notes", "read_days_chats"]
        result = frozenset(agent_tools) & DAILY_TOOLS
        assert result == frozenset()
        # Caller uses: `result or DAILY_TOOLS` → falls back to full profile


class TestWritePermissionGating:
    """Tests for write tool permission enforcement."""

    @pytest.mark.asyncio
    async def test_write_card_denied_without_permission(self):
        from parachute.api.mcp_tools import _handle_write_card
        from parachute.api.mcp_bridge import _current_sandbox_ctx

        ctx = SandboxTokenContext(
            session_id="test",
            trust_level="sandboxed",
            agent_name="test-agent",
            allowed_writes=[],  # No writes allowed
        )
        reset = _current_sandbox_ctx.set(ctx)
        try:
            result = await _handle_write_card({"content": "hello", "date": "2026-03-12"})
            data = json.loads(result)
            assert "error" in data
            assert "not permitted" in data["error"]
        finally:
            _current_sandbox_ctx.reset(reset)

    @pytest.mark.asyncio
    async def test_write_card_denied_without_context(self):
        from parachute.api.mcp_tools import _handle_write_card
        from parachute.api.mcp_bridge import _current_sandbox_ctx

        reset = _current_sandbox_ctx.set(None)
        try:
            result = await _handle_write_card({"content": "hello", "date": "2026-03-12"})
            data = json.loads(result)
            assert "error" in data
            assert "No sandbox context" in data["error"]
        finally:
            _current_sandbox_ctx.reset(reset)
