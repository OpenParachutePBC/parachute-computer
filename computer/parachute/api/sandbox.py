"""Sandbox management API endpoints."""

import asyncio
import json
import logging
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse

from parachute.core.sandbox import SANDBOX_IMAGE

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/sandbox", tags=["sandbox"])

_build_lock = asyncio.Lock()


@router.post("/build")
async def build_sandbox_image(request: Request):
    """Build the sandbox Docker image. Streams progress via SSE."""
    sandbox = getattr(request.app.state, "sandbox", None)
    if not sandbox or not await sandbox.is_available():
        raise HTTPException(status_code=400, detail="Docker not available")

    async def build_stream():
        if _build_lock.locked():
            yield f"data: {json.dumps({'type': 'build_error', 'error': 'Build already in progress'})}\n\n"
            return
        async with _build_lock:
            dockerfile_dir = Path(__file__).parent.parent / "docker"
            proc = await asyncio.create_subprocess_exec(
                "docker",
                "build",
                "-t",
                SANDBOX_IMAGE,
                "-f",
                str(dockerfile_dir / "Dockerfile.sandbox"),
                str(dockerfile_dir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            if proc.stdout:
                async for line in proc.stdout:
                    text = line.decode().strip()
                    if text:
                        yield f"data: {json.dumps({'type': 'build_progress', 'line': text})}\n\n"
            await proc.wait()
            if proc.returncode == 0:
                yield f"data: {json.dumps({'type': 'build_complete'})}\n\n"
            else:
                yield f"data: {json.dumps({'type': 'build_error', 'error': f'Build failed (exit {proc.returncode})'})}\n\n"

    return StreamingResponse(build_stream(), media_type="text/event-stream")


