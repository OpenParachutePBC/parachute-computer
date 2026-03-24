"""
E2E test: boot the server, send a message, get a response via SSE.

Requires:
  - CLAUDE_CODE_OAUTH_TOKEN env var (Claude SDK auth)
  - DEFAULT_MODEL=haiku recommended (fast + cheap)

Skipped automatically if token is not set.
"""

import asyncio
import json
import os
import signal
import subprocess
import sys
import tempfile

import httpx
import pytest

pytestmark = pytest.mark.skipif(
    "CLAUDE_CODE_OAUTH_TOKEN" not in os.environ,
    reason="CLAUDE_CODE_OAUTH_TOKEN not set — skip E2E tests",
)

E2E_PORT = 3399


@pytest.fixture(scope="module")
def server():
    """Boot the Parachute server on a test port with an isolated home dir."""
    home = tempfile.mkdtemp(prefix="parachute-e2e-")
    os.makedirs(f"{home}/graph", exist_ok=True)
    os.makedirs(f"{home}/modules", exist_ok=True)
    os.makedirs(f"{home}/logs", exist_ok=True)

    env = {
        **os.environ,
        "PARACHUTE_HOME": home,
        "PORT": str(E2E_PORT),
        "HOST": "127.0.0.1",
        "LOG_LEVEL": "WARNING",
        "DEFAULT_MODEL": os.environ.get("DEFAULT_MODEL", "haiku"),
    }

    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "parachute.server:app",
         "--port", str(E2E_PORT), "--host", "127.0.0.1"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    # Wait for server to be ready
    url = f"http://127.0.0.1:{E2E_PORT}/api/health"
    for _ in range(30):
        try:
            r = httpx.get(url, timeout=2)
            if r.status_code == 200:
                break
        except (httpx.ConnectError, httpx.TimeoutException):
            pass
        import time
        time.sleep(1)
    else:
        proc.kill()
        stdout, stderr = proc.communicate(timeout=5)
        pytest.fail(
            f"Server failed to start on port {E2E_PORT}.\n"
            f"stdout: {stdout.decode()[-500:]}\n"
            f"stderr: {stderr.decode()[-500:]}"
        )

    yield f"http://127.0.0.1:{E2E_PORT}"

    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()


@pytest.mark.timeout(90)
def test_chat_roundtrip(server):
    """Send a simple message and verify we get text back via SSE."""
    response = httpx.post(
        f"{server}/api/chat",
        json={
            "message": "Reply with exactly: PONG",
            "module": "chat",
        },
        timeout=90.0,
    )
    assert response.status_code == 200

    events = []
    for line in response.text.split("\n"):
        if line.startswith("data: "):
            try:
                events.append(json.loads(line[6:]))
            except json.JSONDecodeError:
                continue

    event_types = [e.get("type") for e in events]

    # Check for errors first — surface them clearly
    error_events = [e for e in events if e.get("type") in ("error", "typed_error")]
    if error_events:
        error_detail = json.dumps(error_events, indent=2)[:500]
        # typed_error with auth/model issues means the SDK couldn't start
        pytest.fail(f"Server returned error events:\n{error_detail}")

    # Should have a session event (confirms orchestrator is running)
    assert "session" in event_types, f"No session event. Got: {event_types}"

    # Should have text content
    text_events = [e for e in events if e.get("type") == "text"]
    assert len(text_events) > 0, f"No text events. Got: {event_types}"

    # Combine all text
    full_text = "".join(e.get("text", "") for e in text_events)
    assert "PONG" in full_text.upper(), f"Expected PONG in response, got: {full_text[:200]}"

    # Should end with result
    assert "result" in event_types, f"No result event. Got: {event_types}"
