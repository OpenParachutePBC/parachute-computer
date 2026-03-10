"""
Base classes for credential providers.

Each provider knows how to:
  1. Verify its configuration is valid
  2. Mint a scoped, short-lived token
  3. Optionally provide scripts for the tools volume
"""

import logging
from abc import ABC, abstractmethod
from typing import Any
from dataclasses import dataclass

logger = logging.getLogger(__name__)


class CredentialProviderError(Exception):
    """Raised when a credential provider operation fails."""


@dataclass(slots=True)
class CredentialToken:
    """A short-lived credential token minted by a provider."""

    token: str
    expires_at: str  # ISO 8601


class CredentialProvider(ABC):
    """Base class for credential providers.

    Each provider type (GitHub App, Cloudflare, AWS, etc.) implements this
    interface. The broker dispatches to providers by name.
    """

    @property
    @abstractmethod
    def name(self) -> str:
        """Provider name used in config and API (e.g., 'github', 'cloudflare')."""
        ...

    @property
    @abstractmethod
    def provider_type(self) -> str:
        """Provider type identifier (e.g., 'github-app', 'cloudflare-parent')."""
        ...

    @abstractmethod
    async def mint_token(self, scope: dict[str, Any]) -> CredentialToken:
        """Mint a scoped, short-lived token.

        Args:
            scope: Provider-specific scope (e.g., {"org": "unforced"} for GitHub).

        Returns:
            CredentialToken with token string and ISO 8601 expiry.

        Raises:
            CredentialProviderError: If minting fails.
        """
        ...

    @abstractmethod
    async def verify(self) -> dict:
        """Verify provider configuration is valid.

        Returns:
            Provider-specific status dict (e.g., app name, account info).

        Raises:
            CredentialProviderError: If verification fails.
        """
        ...

    async def close(self) -> None:
        """Release resources (HTTP connections, etc.).

        Called during server shutdown. Override if the provider holds
        long-lived connections.
        """

    def get_scripts(self) -> dict[str, str]:
        """Return scripts to deploy to the tools volume.

        Returns:
            Mapping of filename -> script content. Files are written to
            /opt/parachute-tools/bin/ and made executable.
        """
        return {}
