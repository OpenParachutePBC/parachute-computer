"""
Chat API endpoints with SSE streaming.

Streams directly from the orchestrator - client reconnection uses
SDK session resumption rather than event buffering.
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
    """
    Generate SSE events from orchestrator.

    Streams directly from the SDK - if client disconnects, they can
    resume the session using the SDK's resume parameter.
    """
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
        f"module={chat_request.module} contexts={chat_request.contexts}"
    )

    # Normalize 'new' to None - client sends 'new' when it wants a new session
    session_id = chat_request.session_id
    if session_id == 'new':
        session_id = None

    try:
        # Convert attachments to dicts if present
        attachments_data = None
        if chat_request.attachments:
            attachments_data = [att.model_dump() for att in chat_request.attachments]

        # Stream directly from orchestrator
        async for event in orchestrator.run_streaming(
            message=chat_request.message,
            session_id=session_id,
            module=chat_request.module,
            system_prompt=chat_request.system_prompt,
            working_directory=chat_request.working_directory,
            agent_path=chat_request.agent_path,
            initial_context=chat_request.initial_context,
            prior_conversation=chat_request.prior_conversation,
            contexts=chat_request.contexts,
            recovery_mode=chat_request.recovery_mode,
            attachments=attachments_data,
            agent_type=chat_request.agent_type,
        ):
            # Check if client disconnected
            if await request.is_disconnected():
                logger.info(f"Client disconnected, stopping stream")
                return

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


@router.get("/chat/{session_id}/stream-status")
async def get_stream_status(request: Request, session_id: str) -> dict[str, Any]:
    """
    Check if a session has an active stream.

    Returns:
        - active: True if the session has an active stream
        - sessionId: The session ID checked
    """
    orchestrator = get_orchestrator(request)

    if orchestrator.has_active_stream(session_id):
        return {
            "active": True,
            "sessionId": session_id,
        }

    return {
        "active": False,
        "sessionId": session_id,
    }


@router.get("/chat/active-streams")
async def get_active_streams(request: Request) -> dict[str, Any]:
    """
    Get all sessions with active streams.

    Returns:
        - streams: List of session IDs with active streams
        - count: Number of active streams
    """
    orchestrator = get_orchestrator(request)

    # Get session IDs from orchestrator's active_streams dict
    stream_ids = list(orchestrator.active_streams.keys())

    return {
        "streams": [{"session_id": sid} for sid in stream_ids],
        "count": len(stream_ids),
    }


@router.post("/chat/{session_id}/answer")
async def answer_questions(
    request: Request,
    session_id: str,
    body: dict[str, Any],
) -> dict[str, Any]:
    """
    Submit answers to a pending AskUserQuestion request.

    Request body:
    - request_id: The question request ID
    - answers: Dict mapping question text to selected answer(s)

    Returns success if answers were submitted, or 404 if no pending questions found.
    """
    orchestrator = get_orchestrator(request)

    request_id = body.get("request_id")
    answers = body.get("answers", {})

    if not request_id:
        raise HTTPException(status_code=400, detail="request_id is required")

    # Try to find the permission handler for this session
    handler = orchestrator.pending_permissions.get(session_id)
    if not handler:
        raise HTTPException(
            status_code=404,
            detail=f"No active session found: {session_id}",
        )

    # Submit the answers
    success = handler.answer_questions(request_id, answers)
    if not success:
        raise HTTPException(
            status_code=404,
            detail=f"No pending question with request_id: {request_id}",
        )

    return {
        "success": True,
        "message": "Answers submitted",
        "session_id": session_id,
        "request_id": request_id,
    }
