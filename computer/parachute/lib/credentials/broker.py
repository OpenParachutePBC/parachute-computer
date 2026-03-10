"""
Credential broker — provider registry, grant checking, token dispatch.

The broker is the single entry point for all credential operations:
  1. Registers providers from config on startup
  2. Checks per-project grants before minting
  3. Dispatches mint requests to the right provider
  4. Collects scripts from all providers for tools volume deployment
"""

import logging
from pathlib import Path
from typing import Optional

from parachute.lib.credentials.base import (
    CredentialProvider,
    CredentialProviderError,
    CredentialToken,
)

logger = logging.getLogger(__name__)


class CredentialBroker:
    """Central credential broker.

    Manages providers, checks grants, and dispatches token requests.
    """

    def __init__(self) -> None:
        self._providers: dict[str, CredentialProvider] = {}

    def register(self, provider: CredentialProvider) -> None:
        """Register a credential provider."""
        self._providers[provider.name] = provider
        logger.info(
            f"Registered credential provider: {provider.name} "
            f"(type={provider.provider_type})"
        )

    def get_provider(self, name: str) -> CredentialProvider | None:
        """Get a registered provider by name."""
        return self._providers.get(name)

    def has_provider(self, name: str) -> bool:
        """Check if a provider is registered."""
        return name in self._providers

    @property
    def provider_names(self) -> list[str]:
        """List all registered provider names."""
        return list(self._providers.keys())

    async def mint_token(
        self,
        provider_name: str,
        scope: dict,
    ) -> CredentialToken:
        """Mint a token via the named provider.

        Args:
            provider_name: Provider to use (e.g., "github", "cloudflare").
            scope: Provider-specific scope dict.

        Raises:
            CredentialProviderError: If provider not found or minting fails.
        """
        provider = self._providers.get(provider_name)
        if not provider:
            raise CredentialProviderError(
                f"Unknown credential provider: {provider_name}"
            )

        return await provider.mint_token(scope)

    async def verify_provider(self, provider_name: str) -> dict:
        """Verify a provider's configuration."""
        provider = self._providers.get(provider_name)
        if not provider:
            raise CredentialProviderError(
                f"Unknown credential provider: {provider_name}"
            )
        return await provider.verify()

    def get_all_scripts(self) -> dict[str, str]:
        """Collect scripts from all providers for tools volume deployment.

        Returns:
            Mapping of filename -> script content.
        """
        scripts: dict[str, str] = {}
        for provider in self._providers.values():
            scripts.update(provider.get_scripts())
        return scripts

    def get_status(self) -> dict:
        """Return status of all registered providers."""
        return {
            "providers": {
                name: {"type": p.provider_type}
                for name, p in self._providers.items()
            },
            "configured": bool(self._providers),
        }

    @classmethod
    def from_config(
        cls,
        credential_providers: dict[str, dict],
        parachute_dir: Path,
    ) -> "CredentialBroker":
        """Create a broker from the credential_providers config section.

        Config format:
            credential_providers:
              github:
                type: github-app
                app_id: 3051015
                installations:
                  unforced: 115215642
              cloudflare:
                type: cloudflare-parent
                parent_token: cf_xxxx
        """
        broker = cls()

        for name, config in credential_providers.items():
            provider_type = config.get("type", "")

            if provider_type == "github-app":
                from parachute.lib.credentials.github_provider import (
                    GitHubProvider,
                )

                provider = GitHubProvider.from_config(config, parachute_dir)
                if provider:
                    broker.register(provider)
                else:
                    logger.warning(
                        f"GitHub provider '{name}' configured but failed to initialize"
                    )

            elif provider_type == "cloudflare-parent":
                from parachute.lib.credentials.cloudflare_provider import (
                    CloudflareProvider,
                )

                provider = CloudflareProvider.from_config(config)
                if provider:
                    broker.register(provider)
                else:
                    logger.warning(
                        f"Cloudflare provider '{name}' configured but failed to initialize"
                    )

            else:
                logger.warning(
                    f"Unknown credential provider type: {provider_type} "
                    f"for provider '{name}'"
                )

        return broker


# Module-level singleton, initialized lazily
_broker: Optional[CredentialBroker] = None


def get_broker() -> CredentialBroker:
    """Get the module-level broker singleton, initializing from config if needed.

    Always returns a broker (possibly with no providers registered).
    """
    global _broker

    if _broker is not None:
        return _broker

    from parachute.config import get_settings

    settings = get_settings()

    _broker = CredentialBroker.from_config(
        credential_providers=settings.credential_providers,
        parachute_dir=settings.parachute_dir,
    )

    if _broker.provider_names:
        logger.info(
            f"Credential broker initialized with providers: "
            f"{', '.join(_broker.provider_names)}"
        )
    else:
        logger.debug("Credential broker initialized (no providers configured)")

    return _broker


def reset_broker() -> None:
    """Reset the broker singleton (for testing or config reload)."""
    global _broker
    _broker = None
