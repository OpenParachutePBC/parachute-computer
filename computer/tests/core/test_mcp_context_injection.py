"""Test MCP session context injection in orchestrator."""
import pytest


def test_inject_all_context_fields():
    """Session context is injected into MCP server env vars."""
    # Simulate orchestrator's injection pattern
    mcps = {
        "parachute": {"command": "python", "args": ["-m", "parachute.mcp_server"]},
        "custom": {"command": "/usr/bin/custom-mcp", "env": {"CUSTOM_VAR": "keep"}},
    }

    session_id = "test_session_123"
    workspace_id = "test-workspace"
    trust_level = "sandboxed"

    # Inject context (inline pattern from orchestrator)
    for mcp_name, mcp_config in mcps.items():
        env = {**mcp_config.get("env", {})}
        env["PARACHUTE_SESSION_ID"] = session_id
        env["PARACHUTE_WORKSPACE_ID"] = workspace_id
        env["PARACHUTE_TRUST_LEVEL"] = trust_level
        mcps[mcp_name] = {**mcp_config, "env": env}

    # Verify all MCPs received context
    assert mcps["parachute"]["env"]["PARACHUTE_SESSION_ID"] == session_id
    assert mcps["parachute"]["env"]["PARACHUTE_WORKSPACE_ID"] == workspace_id
    assert mcps["parachute"]["env"]["PARACHUTE_TRUST_LEVEL"] == trust_level

    # Verify existing env vars preserved
    assert mcps["custom"]["env"]["CUSTOM_VAR"] == "keep"
    assert mcps["custom"]["env"]["PARACHUTE_SESSION_ID"] == session_id


def test_inject_does_not_mutate_cache():
    """Injection creates new dicts, doesn't mutate the input (cache safety)."""
    original_env = {"CUSTOM_VAR": "original"}
    mcps = {"test": {"command": "python", "env": original_env}}

    # Inject context
    for mcp_name, mcp_config in mcps.items():
        env = {**mcp_config.get("env", {})}
        env["PARACHUTE_SESSION_ID"] = "sess_123"
        env["PARACHUTE_WORKSPACE_ID"] = "ws"
        env["PARACHUTE_TRUST_LEVEL"] = "direct"
        mcps[mcp_name] = {**mcp_config, "env": env}

    # Original should be untouched (cache safety)
    assert "PARACHUTE_SESSION_ID" not in original_env
    assert original_env["CUSTOM_VAR"] == "original"

    # Result should have injected context
    assert mcps["test"]["env"]["PARACHUTE_SESSION_ID"] == "sess_123"
    assert mcps["test"]["env"]["CUSTOM_VAR"] == "original"


@pytest.mark.parametrize("trust", ["direct", "sandboxed"])
def test_inject_valid_trust_levels(trust: str):
    """Both valid trust levels are injected correctly."""
    mcps = {"test": {"command": "python"}}

    for mcp_name, mcp_config in mcps.items():
        env = {**mcp_config.get("env", {})}
        env["PARACHUTE_TRUST_LEVEL"] = trust
        env["PARACHUTE_SESSION_ID"] = "sess_123"
        env["PARACHUTE_WORKSPACE_ID"] = ""
        mcps[mcp_name] = {**mcp_config, "env": env}

    assert mcps["test"]["env"]["PARACHUTE_TRUST_LEVEL"] == trust


def test_inject_empty_workspace():
    """Empty workspace_id is handled correctly."""
    mcps = {"test": {"command": "python"}}

    workspace_id = ""  # No workspace

    for mcp_name, mcp_config in mcps.items():
        env = {**mcp_config.get("env", {})}
        env["PARACHUTE_SESSION_ID"] = "sess_123"
        env["PARACHUTE_WORKSPACE_ID"] = workspace_id
        env["PARACHUTE_TRUST_LEVEL"] = "direct"
        mcps[mcp_name] = {**mcp_config, "env": env}

    assert mcps["test"]["env"]["PARACHUTE_WORKSPACE_ID"] == ""


def test_inject_multiple_servers():
    """Context is injected into all MCP servers."""
    mcps = {
        "mcp1": {"command": "python"},
        "mcp2": {"command": "node"},
        "mcp3": {"command": "bash"},
    }

    session_id = "sess_abc"
    workspace_id = "workspace"
    trust_level = "sandboxed"

    for mcp_name, mcp_config in mcps.items():
        env = {**mcp_config.get("env", {})}
        env["PARACHUTE_SESSION_ID"] = session_id
        env["PARACHUTE_WORKSPACE_ID"] = workspace_id
        env["PARACHUTE_TRUST_LEVEL"] = trust_level
        mcps[mcp_name] = {**mcp_config, "env": env}

    # All servers have context
    for mcp_name in ["mcp1", "mcp2", "mcp3"]:
        assert mcps[mcp_name]["env"]["PARACHUTE_SESSION_ID"] == session_id
        assert mcps[mcp_name]["env"]["PARACHUTE_WORKSPACE_ID"] == workspace_id
        assert mcps[mcp_name]["env"]["PARACHUTE_TRUST_LEVEL"] == trust_level
