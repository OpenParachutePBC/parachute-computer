"""
Stream Manager

Manages long-running SDK streams that can survive client disconnections.
Enables multi-client streaming where any device can connect to an active stream.

Key concepts:
- StreamState: Holds a running stream task, event buffer, and subscriber queues
- Streams continue running even when no clients are connected
- Multiple clients can subscribe to the same stream
- Late-joining clients receive buffered events to catch up

Usage:
    stream_manager = StreamManager()

    # Start a new stream (returns immediately, runs in background)
    await stream_manager.start_stream(session_id, event_generator)

    # Subscribe to a stream (new or existing)
    async for event in stream_manager.subscribe(session_id):
        yield event  # to client
"""

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Any, AsyncGenerator, Callable, Optional
from collections import deque

logger = logging.getLogger(__name__)


@dataclass
class StreamState:
    """State for an active stream."""

    session_id: str

    # The background task running the SDK query
    task: asyncio.Task

    # Circular buffer of recent events (for catch-up on reconnect)
    # Default to last 100 events - enough for context, not too much memory
    event_buffer: deque = field(default_factory=lambda: deque(maxlen=100))

    # Active subscriber queues - each connected client gets one
    subscribers: list[asyncio.Queue] = field(default_factory=list)

    # Timing info
    started_at: float = field(default_factory=time.time)
    last_event_at: Optional[float] = None

    # Stream status
    is_complete: bool = False
    final_event: Optional[dict] = None  # done/error/aborted event

    # For abort functionality
    interrupt_callback: Optional[Callable[[], None]] = None

    def add_event(self, event: dict) -> None:
        """Add event to buffer and broadcast to all subscribers."""
        self.last_event_at = time.time()
        self.event_buffer.append(event)

        # Broadcast to all active subscribers
        for queue in self.subscribers:
            try:
                queue.put_nowait(event)
            except asyncio.QueueFull:
                logger.warning(f"Subscriber queue full for {self.session_id[:8]}, dropping event")

    def mark_complete(self, final_event: dict) -> None:
        """Mark stream as complete with final event."""
        self.is_complete = True
        self.final_event = final_event
        self.add_event(final_event)

        # Signal all subscribers that stream is done
        for queue in self.subscribers:
            try:
                queue.put_nowait(None)  # None signals end of stream
            except asyncio.QueueFull:
                pass


class StreamManager:
    """
    Manages long-running streams that can survive client disconnections.

    Provides:
    - Background execution of SDK queries
    - Event buffering for reconnection
    - Multi-client subscription to same stream
    """

    def __init__(self, buffer_size: int = 100, cleanup_delay: float = 300.0):
        """
        Initialize stream manager.

        Args:
            buffer_size: Number of events to buffer for catch-up
            cleanup_delay: Seconds to keep completed streams before cleanup
        """
        self.streams: dict[str, StreamState] = {}
        self.buffer_size = buffer_size
        self.cleanup_delay = cleanup_delay
        self._cleanup_task: Optional[asyncio.Task] = None

    async def start_stream(
        self,
        session_id: str,
        event_generator: AsyncGenerator[dict, None],
        interrupt_callback: Optional[Callable[[], None]] = None,
    ) -> bool:
        """
        Start a new background stream.

        Args:
            session_id: Session ID for this stream
            event_generator: Async generator yielding events
            interrupt_callback: Optional callback to interrupt the stream

        Returns:
            True if stream was started, False if already running
        """
        if session_id in self.streams and not self.streams[session_id].is_complete:
            logger.info(f"Stream already active for {session_id[:8]}")
            return False

        # Create stream state
        state = StreamState(
            session_id=session_id,
            task=asyncio.current_task(),  # Placeholder, will be replaced
            event_buffer=deque(maxlen=self.buffer_size),
            interrupt_callback=interrupt_callback,
        )

        # Create and start background task
        task = asyncio.create_task(
            self._run_stream(session_id, event_generator, state)
        )
        state.task = task

        self.streams[session_id] = state
        logger.info(f"Started background stream for {session_id[:8]}")

        # Start cleanup task if not running
        if self._cleanup_task is None or self._cleanup_task.done():
            self._cleanup_task = asyncio.create_task(self._cleanup_loop())

        return True

    async def _run_stream(
        self,
        session_id: str,
        event_generator: AsyncGenerator[dict, None],
        state: StreamState,
    ) -> None:
        """Run the stream in background, buffering events."""
        try:
            async for event in event_generator:
                # Check for terminal events
                event_type = event.get("type", "")

                if event_type in ("done", "error", "aborted"):
                    state.mark_complete(event)
                    break
                else:
                    state.add_event(event)

        except asyncio.CancelledError:
            logger.info(f"Stream cancelled for {session_id[:8]}")
            state.mark_complete({
                "type": "aborted",
                "message": "Stream cancelled",
                "sessionId": session_id,
            })

        except Exception as e:
            logger.error(f"Stream error for {session_id[:8]}: {e}")
            state.mark_complete({
                "type": "error",
                "error": str(e),
                "sessionId": session_id,
            })

        finally:
            logger.info(f"Stream ended for {session_id[:8]}, complete={state.is_complete}")

    async def subscribe(
        self,
        session_id: str,
        include_buffer: bool = True,
    ) -> AsyncGenerator[dict, None]:
        """
        Subscribe to an active stream.

        Args:
            session_id: Session ID to subscribe to
            include_buffer: Whether to receive buffered events first

        Yields:
            Events from the stream

        Raises:
            KeyError: If no stream exists for session_id
        """
        state = self.streams.get(session_id)
        if state is None:
            raise KeyError(f"No active stream for session {session_id}")

        # Create subscriber queue
        queue: asyncio.Queue = asyncio.Queue(maxsize=200)
        state.subscribers.append(queue)

        logger.info(f"New subscriber for {session_id[:8]}, total={len(state.subscribers)}")

        try:
            # First, yield buffered events for catch-up
            if include_buffer:
                for event in state.event_buffer:
                    yield event

            # If stream already complete, we're done
            if state.is_complete:
                if state.final_event:
                    yield state.final_event
                return

            # Listen for new events
            while True:
                event = await queue.get()

                # None signals end of stream
                if event is None:
                    break

                yield event

                # Check for terminal events
                if event.get("type") in ("done", "error", "aborted"):
                    break

        finally:
            # Remove subscriber
            if queue in state.subscribers:
                state.subscribers.remove(queue)
            logger.info(f"Subscriber left {session_id[:8]}, remaining={len(state.subscribers)}")

    def has_active_stream(self, session_id: str) -> bool:
        """Check if a session has an active (non-complete) stream."""
        state = self.streams.get(session_id)
        return state is not None and not state.is_complete

    def get_stream_info(self, session_id: str) -> Optional[dict]:
        """Get information about a stream."""
        state = self.streams.get(session_id)
        if state is None:
            return None

        return {
            "session_id": session_id,
            "is_complete": state.is_complete,
            "started_at": state.started_at,
            "last_event_at": state.last_event_at,
            "subscriber_count": len(state.subscribers),
            "buffer_size": len(state.event_buffer),
            "duration_seconds": time.time() - state.started_at,
        }

    def get_all_active_streams(self) -> list[dict]:
        """Get info about all active streams."""
        return [
            self.get_stream_info(sid)
            for sid, state in self.streams.items()
            if not state.is_complete
        ]

    def abort_stream(self, session_id: str) -> bool:
        """Abort an active stream."""
        state = self.streams.get(session_id)
        if state is None or state.is_complete:
            return False

        # Call interrupt callback if available
        if state.interrupt_callback:
            state.interrupt_callback()

        # Cancel the task
        if not state.task.done():
            state.task.cancel()

        return True

    async def _cleanup_loop(self) -> None:
        """Periodically clean up completed streams."""
        while True:
            await asyncio.sleep(60)  # Check every minute

            now = time.time()
            to_remove = []

            for session_id, state in self.streams.items():
                if state.is_complete:
                    # Remove completed streams after cleanup_delay
                    if state.last_event_at and (now - state.last_event_at) > self.cleanup_delay:
                        to_remove.append(session_id)

            for session_id in to_remove:
                del self.streams[session_id]
                logger.info(f"Cleaned up completed stream: {session_id[:8]}")

            # Stop if no streams left
            if not self.streams:
                logger.info("No streams remaining, stopping cleanup loop")
                break


# Singleton instance
_stream_manager: Optional[StreamManager] = None


def get_stream_manager() -> StreamManager:
    """Get the global stream manager instance."""
    global _stream_manager
    if _stream_manager is None:
        _stream_manager = StreamManager()
    return _stream_manager
