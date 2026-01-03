"""
Structured logging for Parachute server.
"""

import logging
import sys
from collections import deque
from datetime import datetime, timezone
from typing import Any, Optional

from parachute.config import get_settings


class LogBuffer:
    """Circular buffer for storing recent log entries."""

    def __init__(self, maxlen: int = 1000):
        self._buffer: deque[dict[str, Any]] = deque(maxlen=maxlen)

    def append(self, entry: dict[str, Any]) -> None:
        """Add a log entry to the buffer."""
        self._buffer.append(entry)

    def get_recent(self, limit: int = 100) -> list[dict[str, Any]]:
        """Get the most recent log entries."""
        entries = list(self._buffer)
        return entries[-limit:] if limit < len(entries) else entries

    def clear(self) -> None:
        """Clear all log entries."""
        self._buffer.clear()


class BufferedHandler(logging.Handler):
    """Logging handler that stores entries in a buffer."""

    def __init__(self, buffer: LogBuffer, level: int = logging.NOTSET):
        super().__init__(level)
        self.buffer = buffer

    def emit(self, record: logging.LogRecord) -> None:
        """Store log record in buffer."""
        try:
            entry = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "level": record.levelname,
                "logger": record.name,
                "message": self.format(record),
                "module": record.module,
                "function": record.funcName,
                "line": record.lineno,
            }

            # Include extra fields if present
            if hasattr(record, "extra") and record.extra:
                entry["extra"] = record.extra

            self.buffer.append(entry)
        except Exception:
            self.handleError(record)


# Global log buffer
_log_buffer = LogBuffer()


def get_log_buffer() -> LogBuffer:
    """Get the global log buffer."""
    return _log_buffer


def setup_logging(
    level: Optional[str] = None,
    format_string: Optional[str] = None,
) -> None:
    """Set up logging configuration."""
    settings = get_settings()

    log_level = getattr(logging, (level or settings.log_level).upper())
    log_format = format_string or settings.log_format

    # Root logger configuration
    root_logger = logging.getLogger()
    root_logger.setLevel(log_level)

    # Clear existing handlers
    root_logger.handlers.clear()

    # Console handler
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(log_level)
    console_handler.setFormatter(logging.Formatter(log_format))
    root_logger.addHandler(console_handler)

    # Buffer handler
    buffer_handler = BufferedHandler(_log_buffer, log_level)
    buffer_handler.setFormatter(logging.Formatter("%(message)s"))
    root_logger.addHandler(buffer_handler)

    # Reduce noise from third-party libraries
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)


def get_logger(name: str) -> logging.Logger:
    """Get a logger with the specified name."""
    return logging.getLogger(name)
