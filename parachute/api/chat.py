"""
Chat API endpoints with SSE streaming.
"""

import json
import logging
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse

from parachute.config import get_settings
from parachute.models.requests import ChatRequest

router = APIRouter()
logger = logging.getLogger(__name__)


def get_orchestrator(request: Request):
    """Get orchestrator from app state."""
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Server not ready")
    return orchestrator


async def event_generator(request: Request, chat_request: ChatRequest):
    """Generate SSE events from orchestrator."""
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        yield f"data: {json.dumps({'type': 'error', 'error': 'Server not ready'})}\n\n"
        return

    settings = get_settings()

    # Validate message
    if not chat_request.message:
        yield f"data: {json.dumps({'type': 'error', 'error': 'message is required'})}\n\n"
        return

    if len(chat_request.message) > settings.max_message_length:
        yield f"data: {json.dumps({'type': 'error', 'error': f'Message too long: {len(chat_request.message)} chars'})}\n\n"
        return

    logger.info(
        f"Chat request: session={chat_request.session_id or 'new'} "
        f"module={chat_request.module}"
    )

    # Stream events
    try:
        async for event in orchestrator.run_streaming(
            message=chat_request.message,
            session_id=chat_request.session_id,
            module=chat_request.module,
            system_prompt=chat_request.system_prompt,
            working_directory=chat_request.working_directory,
            agent_path=chat_request.agent_path,
            initial_context=chat_request.initial_context,
            prior_conversation=chat_request.prior_conversation,
            contexts=chat_request.contexts,
            recovery_mode=chat_request.recovery_mode,
        ):
            # Check if client disconnected
            if await request.is_disconnected():
                logger.info("Client disconnected")
                break

            yield f"data: {json.dumps(event)}\n\n"

    except Exception as e:
        logger.error(f"Stream error: {e}", exc_info=True)
        yield f"data: {json.dumps({'type': 'error', 'error': str(e)})}\n\n"


@router.post("/chat")
async def chat_stream(request: Request, chat_request: ChatRequest):
    """
    Run agent with streaming response (SSE).

    Request body:
    - message: User message (required)
    - sessionId: SDK session ID to resume
    - module: Module (chat, daily, build)
    - systemPrompt: Override system prompt
    - workingDirectory: Working directory for file operations
    - initialContext: Initial context for new sessions
    - priorConversation: Prior conversation for continuation
    - contexts: Context files to load
    - recoveryMode: 'inject_context' or 'fresh_start'
    """
    return StreamingResponse(
        event_generator(request, chat_request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*",
        },
    )


@router.post("/chat/{session_id}/abort")
async def abort_stream(request: Request, session_id: str) -> dict[str, Any]:
    """
    Abort an active streaming session.

    Returns success if stream was aborted, or 404 if no active stream found.
    """
    orchestrator = get_orchestrator(request)

    success = await orchestrator.abort_stream(session_id)

    if not success:
        raise HTTPException(
            status_code=404,
            detail=f"No active stream found for session {session_id}",
        )

    return {
        "success": True,
        "message": "Stream abort signal sent",
        "sessionId": session_id,
    }
