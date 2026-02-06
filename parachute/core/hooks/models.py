"""
Hook configuration models.
"""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class HookConfig:
    """Configuration for a single hook script."""

    name: str
    path: Path
    events: list[str] = field(default_factory=list)
    blocking: bool = False
    timeout: float = 30.0  # seconds
    enabled: bool = True
    description: str = ""

    def to_dict(self) -> dict:
        """Serialize for API responses."""
        return {
            "name": self.name,
            "path": str(self.path),
            "events": self.events,
            "blocking": self.blocking,
            "timeout": self.timeout,
            "enabled": self.enabled,
            "description": self.description,
        }


@dataclass
class HookError:
    """Record of a hook execution error."""

    hook_name: str
    event: str
    error: str
    timestamp: str

    def to_dict(self) -> dict:
        return {
            "hook_name": self.hook_name,
            "event": self.event,
            "error": self.error,
            "timestamp": self.timestamp,
        }
