"""
Credential broker — provider registry, grant checking, token dispatch.

The broker is the single entry point for all credential operations:
  1. Registers providers from config on startup
  2. Checks per-project grants before minting
  3. Dispatches mint requests to the right provider
  4. Collects scripts from all providers for tools volume deployment
  5. Exposes helper manifests to the app UI
"""

import logging
from pathlib import Path
from typing import Any

from parachute.lib.credentials.base import (
    CredentialProvider,
    CredentialProviderError,
    CredentialToken,
)

logger = logging.getLogger(__name__)

# GitHub config types that route to GitHubHelper
_GITHUB_TYPES = {"github-app", "personal-token"}


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

    def providers(self) -> list[CredentialProvider]:
        """Iterate over all registered providers."""
        return list(self._providers.values())

    async def mint_token(
        self,
        provider_name: str,
        scope: dict[str, Any],
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

    async def close_all(self) -> None:
        """Close all provider resources (called during server shutdown)."""
        for provider in self._providers.values():
            try:
                await provider.close()
            except Exception as e:
                logger.warning(f"Error closing provider {provider.name}: {e}")

    def get_all_scripts(self) -> dict[str, str]:
        """Collect scripts from all providers for tools volume deployment.

        Returns:
            Mapping of filename -> script content.
        """
        scripts: dict[str, str] = {}
        for provider in self._providers.values():
            scripts.update(provider.get_scripts())
        return scripts

    def get_all_env_vars(self) -> list[str]:
        """Collect env var lines from all providers for sandbox injection.

        Returns list of KEY=VALUE strings. Replaces the old isinstance-based
        _build_credential_env_vars() approach in sandbox.py.
        """
        env_lines: list[str] = []
        for provider in self._providers.values():
            if hasattr(provider, "get_env_vars"):
                env_lines.extend(provider.get_env_vars())
        return env_lines

    def get_status(self) -> dict:
        """Return status of all registered providers."""
        status: dict[str, dict] = {}
        for name, p in self._providers.items():
            info: dict[str, Any] = {"type": p.provider_type}
            # Include active method if the provider has one
            if hasattr(p, "active_method"):
                info["method"] = p.active_method
            status[name] = info

        return {
            "providers": status,
            "configured": bool(self._providers),
        }

    def get_manifests(self) -> dict[str, dict]:
        """Return manifest JSON for all registered providers.

        Used by GET /api/credentials/helpers for the app UI.
        """
        manifests: dict[str, dict] = {}
        for name, p in self._providers.items():
            if hasattr(p, "manifest"):
                manifest_dict = p.manifest.to_dict()
                manifest_dict["configured"] = True
                if hasattr(p, "active_method"):
                    manifest_dict["active_method"] = p.active_method
                manifests[name] = manifest_dict
        return manifests

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
                type: github-app           # or personal-token
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

            if provider_type in _GITHUB_TYPES:
                # New unified GitHubHelper handles both PAT and App
                from parachute.lib.credentials.helpers.github import (
                    GitHubHelper,
                )

                provider = GitHubHelper.from_config(config, parachute_dir)
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
_broker: CredentialBroker | None = None


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
