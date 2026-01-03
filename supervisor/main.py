"""
Parachute Supervisor Service

A lightweight service that:
- Manages the main Parachute server process
- Provides health monitoring and auto-restart
- Serves a simple management web UI
- Exposes control API endpoints
"""

import asyncio
import logging
import os
import signal
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles

from supervisor.process_manager import ProcessConfig, ProcessManager

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Global process manager
_manager: ProcessManager | None = None


def get_config() -> ProcessConfig:
    """Get supervisor configuration from environment."""
    return ProcessConfig(
        vault_path=Path(os.environ.get("VAULT_PATH", "./sample-vault")),
        port=int(os.environ.get("SERVER_PORT", "3333")),
        host=os.environ.get("SERVER_HOST", "0.0.0.0"),
        health_check_interval=int(os.environ.get("HEALTH_CHECK_INTERVAL", "10")),
        max_restart_attempts=int(os.environ.get("MAX_RESTART_ATTEMPTS", "5")),
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    global _manager

    config = get_config()
    _manager = ProcessManager(config)

    logger.info("Supervisor starting...")
    logger.info(f"Vault path: {config.vault_path}")
    logger.info(f"Server will run on {config.host}:{config.port}")

    # Auto-start server
    if os.environ.get("AUTO_START", "true").lower() == "true":
        await _manager.start()

    yield

    # Shutdown
    logger.info("Supervisor shutting down...")
    if _manager:
        await _manager.stop()


# Create FastAPI app
app = FastAPI(
    title="Parachute Supervisor",
    description="Process manager for Parachute server",
    version="0.1.0",
    lifespan=lifespan,
)


# ============================================================================
# API Endpoints
# ============================================================================


@app.get("/supervisor/status")
async def get_status() -> dict[str, Any]:
    """Get server status."""
    if not _manager:
        raise HTTPException(status_code=503, detail="Supervisor not initialized")

    return {
        "supervisor": "running",
        "server": _manager.get_info(),
        "config": {
            "vault_path": str(_manager.config.vault_path),
            "port": _manager.config.port,
            "host": _manager.config.host,
        },
    }


@app.post("/supervisor/start")
async def start_server() -> dict[str, Any]:
    """Start the server."""
    if not _manager:
        raise HTTPException(status_code=503, detail="Supervisor not initialized")

    success = await _manager.start()
    return {
        "success": success,
        "server": _manager.get_info(),
    }


@app.post("/supervisor/stop")
async def stop_server() -> dict[str, Any]:
    """Stop the server."""
    if not _manager:
        raise HTTPException(status_code=503, detail="Supervisor not initialized")

    success = await _manager.stop()
    return {
        "success": success,
        "server": _manager.get_info(),
    }


@app.post("/supervisor/restart")
async def restart_server() -> dict[str, Any]:
    """Restart the server."""
    if not _manager:
        raise HTTPException(status_code=503, detail="Supervisor not initialized")

    success = await _manager.restart()
    return {
        "success": success,
        "server": _manager.get_info(),
    }


@app.get("/supervisor/config")
async def get_config_endpoint() -> dict[str, Any]:
    """Get current configuration."""
    if not _manager:
        raise HTTPException(status_code=503, detail="Supervisor not initialized")

    return {
        "vault_path": str(_manager.config.vault_path),
        "port": _manager.config.port,
        "host": _manager.config.host,
        "health_check_interval": _manager.config.health_check_interval,
        "max_restart_attempts": _manager.config.max_restart_attempts,
    }


# ============================================================================
# Management UI
# ============================================================================


MANAGEMENT_UI_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Parachute Supervisor</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #1a1a2e;
            color: #eee;
            min-height: 100vh;
            padding: 2rem;
        }
        .container { max-width: 800px; margin: 0 auto; }
        h1 { color: #5EA8A7; margin-bottom: 2rem; }
        .card {
            background: #16213e;
            border-radius: 12px;
            padding: 1.5rem;
            margin-bottom: 1.5rem;
            border: 1px solid #0f3460;
        }
        .card h2 { color: #5EA8A7; margin-bottom: 1rem; font-size: 1.2rem; }
        .status-indicator {
            display: inline-block;
            width: 12px;
            height: 12px;
            border-radius: 50%;
            margin-right: 8px;
        }
        .status-running { background: #4ade80; }
        .status-stopped { background: #f87171; }
        .status-starting { background: #fbbf24; animation: pulse 1s infinite; }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
        .info-row {
            display: flex;
            justify-content: space-between;
            padding: 0.5rem 0;
            border-bottom: 1px solid #0f3460;
        }
        .info-row:last-child { border: none; }
        .info-label { color: #888; }
        .buttons { display: flex; gap: 1rem; margin-top: 1rem; }
        button {
            background: #5EA8A7;
            color: white;
            border: none;
            padding: 0.75rem 1.5rem;
            border-radius: 8px;
            cursor: pointer;
            font-size: 1rem;
            transition: background 0.2s;
        }
        button:hover { background: #40695B; }
        button:disabled { background: #444; cursor: not-allowed; }
        button.danger { background: #ef4444; }
        button.danger:hover { background: #dc2626; }
        .error { color: #f87171; margin-top: 1rem; }
        .success { color: #4ade80; margin-top: 1rem; }
        pre {
            background: #0f3460;
            padding: 1rem;
            border-radius: 8px;
            overflow-x: auto;
            font-size: 0.9rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🪂 Parachute Supervisor</h1>

        <div class="card">
            <h2>Server Status</h2>
            <div id="status-content">Loading...</div>
            <div class="buttons">
                <button onclick="startServer()" id="start-btn">Start</button>
                <button onclick="stopServer()" id="stop-btn" class="danger">Stop</button>
                <button onclick="restartServer()" id="restart-btn">Restart</button>
            </div>
            <div id="action-result"></div>
        </div>

        <div class="card">
            <h2>Configuration</h2>
            <div id="config-content">Loading...</div>
        </div>
    </div>

    <script>
        async function fetchStatus() {
            try {
                const res = await fetch('/supervisor/status');
                const data = await res.json();

                const server = data.server;
                const stateClass = {
                    'running': 'status-running',
                    'stopped': 'status-stopped',
                    'starting': 'status-starting',
                    'restarting': 'status-starting',
                    'failed': 'status-stopped',
                }[server.state] || 'status-stopped';

                document.getElementById('status-content').innerHTML = `
                    <div class="info-row">
                        <span class="info-label">State</span>
                        <span><span class="status-indicator ${stateClass}"></span>${server.state}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">PID</span>
                        <span>${server.pid || '-'}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Uptime</span>
                        <span>${server.uptime_seconds ? Math.floor(server.uptime_seconds) + 's' : '-'}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Restarts</span>
                        <span>${server.restart_count}</span>
                    </div>
                    ${server.last_error ? `<div class="info-row">
                        <span class="info-label">Last Error</span>
                        <span class="error">${server.last_error}</span>
                    </div>` : ''}
                `;

                // Update button states
                const isRunning = server.state === 'running';
                document.getElementById('start-btn').disabled = isRunning;
                document.getElementById('stop-btn').disabled = !isRunning;

            } catch (e) {
                document.getElementById('status-content').innerHTML =
                    '<div class="error">Failed to fetch status</div>';
            }
        }

        async function fetchConfig() {
            try {
                const res = await fetch('/supervisor/config');
                const data = await res.json();

                document.getElementById('config-content').innerHTML = `
                    <div class="info-row">
                        <span class="info-label">Vault Path</span>
                        <span>${data.vault_path}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Server Address</span>
                        <span>${data.host}:${data.port}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Health Check Interval</span>
                        <span>${data.health_check_interval}s</span>
                    </div>
                `;
            } catch (e) {
                document.getElementById('config-content').innerHTML =
                    '<div class="error">Failed to fetch config</div>';
            }
        }

        async function serverAction(action) {
            const resultEl = document.getElementById('action-result');
            resultEl.innerHTML = '<span style="color: #fbbf24">Working...</span>';

            try {
                const res = await fetch(`/supervisor/${action}`, { method: 'POST' });
                const data = await res.json();

                if (data.success) {
                    resultEl.innerHTML = '<span class="success">Success!</span>';
                } else {
                    resultEl.innerHTML = '<span class="error">Failed</span>';
                }

                fetchStatus();
            } catch (e) {
                resultEl.innerHTML = `<span class="error">Error: ${e.message}</span>`;
            }

            setTimeout(() => { resultEl.innerHTML = ''; }, 3000);
        }

        function startServer() { serverAction('start'); }
        function stopServer() { serverAction('stop'); }
        function restartServer() { serverAction('restart'); }

        // Initial load
        fetchStatus();
        fetchConfig();

        // Auto-refresh status
        setInterval(fetchStatus, 5000);
    </script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
async def management_ui():
    """Serve management UI."""
    return MANAGEMENT_UI_HTML


def main():
    """Main entry point."""
    supervisor_port = int(os.environ.get("SUPERVISOR_PORT", "3330"))

    print(f"""
╔═══════════════════════════════════════════════════════════════╗
║           🪂 Parachute Supervisor                             ║
╠═══════════════════════════════════════════════════════════════╣
║  Supervisor:  http://localhost:{supervisor_port:<26}║
║  Server will run on port: {os.environ.get("SERVER_PORT", "3333"):<30}║
╠═══════════════════════════════════════════════════════════════╣
║  Management UI: http://localhost:{supervisor_port:<24}║
║  Status API:    http://localhost:{supervisor_port}/supervisor/status   ║
╚═══════════════════════════════════════════════════════════════╝
    """)

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=supervisor_port,
        log_level="info",
    )


if __name__ == "__main__":
    main()
