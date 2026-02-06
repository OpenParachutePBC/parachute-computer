"""
Hook event taxonomy.

All lifecycle events that can trigger hooks in Parachute.
"""

from enum import Enum


class HookEvent(str, Enum):
    """Lifecycle events that can trigger hooks."""

    # Server lifecycle
    SERVER_STARTED = "server.started"
    SERVER_STOPPING = "server.stopping"

    # Session lifecycle
    SESSION_CREATED = "session.created"
    SESSION_COMPLETED = "session.completed"
    SESSION_RESUMED = "session.resumed"

    # Message events
    MESSAGE_RECEIVED = "message.received"
    MESSAGE_SENT = "message.sent"

    # Daily events
    DAILY_ENTRY_CREATED = "daily.entry.created"
    DAILY_ENTRY_UPDATED = "daily.entry.updated"

    # Bot events
    BOT_MESSAGE_RECEIVED = "bot.message.received"
    BOT_MESSAGE_SENT = "bot.message.sent"

    # Module events
    MODULE_LOADED = "module.loaded"
    MODULE_UNLOADED = "module.unloaded"

    # Context events (blocking)
    CONTEXT_APPROACHING_LIMIT = "context.approaching_limit"


# Events that should fire as blocking (caller waits for hook completion)
BLOCKING_EVENTS = {
    HookEvent.CONTEXT_APPROACHING_LIMIT,
    HookEvent.SERVER_STOPPING,
}
