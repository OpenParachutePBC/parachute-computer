"""
Interface registry for cross-module communication.

Modules publish interfaces they provide, and other modules
can look up those interfaces to communicate across boundaries.
"""

from typing import Any, Optional


class InterfaceRegistry:
    """Registry for module interfaces."""

    def __init__(self):
        self._providers: dict[str, Any] = {}

    def publish(self, interface_name: str, provider: Any):
        """Module publishes an interface it provides."""
        self._providers[interface_name] = provider

    def get(self, interface_name: str) -> Optional[Any]:
        """Get a module that provides this interface."""
        return self._providers.get(interface_name)

    def list_interfaces(self) -> list[str]:
        return list(self._providers.keys())


# Global registry
_registry: Optional[InterfaceRegistry] = None


def get_registry() -> InterfaceRegistry:
    global _registry
    if _registry is None:
        _registry = InterfaceRegistry()
    return _registry
