"""
Event-driven hooks system for Parachute.

Discovers and executes lifecycle hooks from vault/.parachute/hooks/.
Coexists with the existing SDK-level activity_hook.py.
"""

from parachute.core.hooks.events import HookEvent
from parachute.core.hooks.models import HookConfig
from parachute.core.hooks.runner import HookRunner

__all__ = ["HookEvent", "HookConfig", "HookRunner"]
