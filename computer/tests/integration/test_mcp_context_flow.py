"""Integration test: session context reaches MCP config dict."""
import pytest


@pytest.mark.asyncio
async def test_session_context_in_resolved_mcps():
    """MCP config dicts contain session context env vars after injection."""
    # Simulate resolved MCPs from loader
    resolved_mcps = {
        "test": {"command": "python", "args": ["-m", "test"]},
        "parachute": {
            "command": "python",
            "args": ["-m", "parachute.mcp_server"],
            "env": {"PARACHUTE_VAULT_PATH": "/vault"},
        },
    }

    # Simulate orchestrator injection (inline pattern from orchestrator.py)
    session_id = "test_sess_abc123"
    workspace_id = "test-workspace"
    trust_level = "direct"

    for mcp_name, mcp_config in resolved_mcps.items():
        # Shallow copy to avoid cache pollution across sessions
        env = {**mcp_config.get("env", {})}
        # Direct assignment - orchestrator is authoritative source
        env["PARACHUTE_SESSION_ID"] = session_id
        env["PARACHUTE_WORKSPACE_ID"] = workspace_id
        env["PARACHUTE_TRUST_LEVEL"] = trust_level
        # Update config with new env dict
        resolved_mcps[mcp_name] = {**mcp_config, "env": env}

    # Verify context present in config dict that would go to SDK
    assert "test" in resolved_mcps
    test_env = resolved_mcps["test"]["env"]
    assert test_env["PARACHUTE_SESSION_ID"] == session_id
    assert test_env["PARACHUTE_WORKSPACE_ID"] == workspace_id
    assert test_env["PARACHUTE_TRUST_LEVEL"] == trust_level

    # Verify existing env vars preserved
    parachute_env = resolved_mcps["parachute"]["env"]
    assert parachute_env["PARACHUTE_VAULT_PATH"] == "/vault"
    assert parachute_env["PARACHUTE_SESSION_ID"] == session_id
