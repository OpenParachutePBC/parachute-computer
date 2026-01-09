"""
Chat API endpoints with SSE streaming.

Supports multi-client streaming where:
- SDK queries run in background, surviving client disconnections
- Multiple clients can subscribe to the same active stream
- Late-joining clients receive buffered events to catch up
"""

import json
import logging
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse

from parachute.config import get_settings
from parachute.core.stream_manager import get_stream_manager
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

    Uses StreamManager to run the SDK query in background, allowing:
    - Client disconnection without losing the stream
    - Multiple clients to subscribe to the same stream
    - Late-joining clients to catch up via buffered events
    """
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        yield f"data: {json.dumps({'type': 'error', 'error': 'Server not ready'})}\n\n"
        return

    settings = get_settings()
    stream_manager = get_stream_manager()

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

    # Get the session ID - we need this for stream management
    # For new sessions, we'll capture it from the first event
    # Normalize 'new' to None - client sends 'new' when it wants a new session
    session_id = chat_request.session_id
    if session_id == 'new':
        session_id = None
    captured_session_id = None

    try:
        # Create the event generator from orchestrator
        # Convert attachments to dicts if present
        attachments_data = None
        if chat_request.attachments:
            attachments_data = [att.model_dump() for att in chat_request.attachments]

        orchestrator_gen = orchestrator.run_streaming(
            message=chat_request.message,
            session_id=session_id,  # Use normalized value (None for new sessions)
            module=chat_request.module,
            system_prompt=chat_request.system_prompt,
            working_directory=chat_request.working_directory,
            agent_path=chat_request.agent_path,
            initial_context=chat_request.initial_context,
            prior_conversation=chat_request.prior_conversation,
            contexts=chat_request.contexts,
            recovery_mode=chat_request.recovery_mode,
            attachments=attachments_data,
        )

        # Start the stream in background via StreamManager
        # We need a wrapper that captures the session_id and registers with manager
        async def wrapped_generator():
            nonlocal captured_session_id
            async for event in orchestrator_gen:
                # Capture session ID from first event that has it
                if not captured_session_id and event.get("sessionId"):
                    captured_session_id = event["sessionId"]
                yield event

        # Get the interrupt callback from orchestrator for abort support
        def get_interrupt_callback():
            if captured_session_id and captured_session_id in orchestrator.active_streams:
                return orchestrator.active_streams[captured_session_id].interrupt
            return None

        # Start background stream
        # Note: For new sessions, we don't have session_id yet - we'll use a temp ID
        temp_session_id = session_id or f"pending-{id(orchestrator_gen)}"

        # Start the stream in background
        await stream_manager.start_stream(
            session_id=temp_session_id,
            event_generator=wrapped_generator(),
            interrupt_callback=None,  # Will be set once we have real session ID
        )

        # Subscribe to the stream
        async for event in stream_manager.subscribe(temp_session_id, include_buffer=False):
            # Update session ID tracking if we captured it
            if captured_session_id and captured_session_id != temp_session_id:
                # Re-register with real session ID
                if temp_session_id in stream_manager.streams:
                    state = stream_manager.streams[temp_session_id]
                    stream_manager.streams[captured_session_id] = state
                    del stream_manager.streams[temp_session_id]
                    logger.info(f"Re-registered stream: {temp_session_id[:8]} -> {captured_session_id[:8]}")
                    temp_session_id = captured_session_id

            # Check if client disconnected - but DON'T stop the stream!
            # Just stop sending to this client, stream continues in background
            if await request.is_disconnected():
                logger.info(f"Client disconnected from {temp_session_id[:8]}, stream continues in background")
                return

            yield f"data: {json.dumps(event)}\n\n"

    except KeyError as e:
        # No stream found - shouldn't happen for new streams
        logger.error(f"Stream not found: {e}")
        yield f"data: {json.dumps({'type': 'error', 'error': str(e)})}\n\n"

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
    stream_manager = get_stream_manager()
    orchestrator = get_orchestrator(request)

    # Try StreamManager first
    if stream_manager.abort_stream(session_id):
        logger.info(f"Aborted stream via StreamManager: {session_id[:8]}")
        return {
            "success": True,
            "message": "Stream abort signal sent",
            "sessionId": session_id,
        }

    # Fall back to orchestrator
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
        - info: Detailed stream info if active
    """
    stream_manager = get_stream_manager()

    # Check StreamManager first (primary source of truth)
    if stream_manager.has_active_stream(session_id):
        info = stream_manager.get_stream_info(session_id)
        return {
            "active": True,
            "sessionId": session_id,
            "info": info,
        }

    # Fall back to orchestrator (for backwards compatibility)
    orchestrator = get_orchestrator(request)
    if orchestrator.has_active_stream(session_id):
        return {
            "active": True,
            "sessionId": session_id,
            "info": None,
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
        - streams: List of stream info objects
        - count: Number of active streams
    """
    stream_manager = get_stream_manager()
    streams = stream_manager.get_all_active_streams()

    return {
        "streams": streams,
        "count": len(streams),
    }


async def join_stream_generator(request: Request, session_id: str):
    """Generate SSE events for a client joining an existing stream."""
    stream_manager = get_stream_manager()

    logger.info(f"Client joining stream: {session_id[:8]}")

    try:
        # Subscribe to the stream with buffer (to catch up)
        async for event in stream_manager.subscribe(session_id, include_buffer=True):
            # Check if client disconnected
            if await request.is_disconnected():
                logger.info(f"Join client disconnected from {session_id[:8]}")
                return

            yield f"data: {json.dumps(event)}\n\n"

    except KeyError:
        # No active stream for this session
        yield f"data: {json.dumps({'type': 'error', 'error': 'No active stream for this session'})}\n\n"

    except Exception as e:
        logger.error(f"Join stream error: {e}", exc_info=True)
        yield f"data: {json.dumps({'type': 'error', 'error': str(e)})}\n\n"


@router.get("/chat/{session_id}/join")
async def join_stream(request: Request, session_id: str):
    """
    Join an existing active stream.

    Allows clients to reconnect to an in-progress stream and receive:
    1. Buffered events (for catch-up)
    2. Live events as they occur

    Use this when:
    - Reconnecting after a disconnect
    - Opening a chat on another device while stream is active
    - Returning to a chat that has an active stream

    Returns 404 if no active stream exists for this session.
    """
    stream_manager = get_stream_manager()

    if not stream_manager.has_active_stream(session_id):
        raise HTTPException(
            status_code=404,
            detail=f"No active stream for session {session_id}",
        )

    return StreamingResponse(
        join_stream_generator(request, session_id),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*",
        },
    )


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
