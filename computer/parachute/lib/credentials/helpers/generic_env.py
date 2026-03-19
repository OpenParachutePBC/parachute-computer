"""
Generic environment variable credential helper.

Simple KEY=VALUE passthrough for services that don't have dedicated helpers.
Replaces the flat credentials.yaml file with structured config entries that
get the same manifest-driven UI treatment as GitHub and Cloudflare.

Examples:
    credential_providers:
      vercel:
        type: env-passthrough
        env_var: VERCEL_TOKEN
        token: ver_xxxxxxxx
        display_name: Vercel        # optional
        health_url: https://api.vercel.com/v2/user  # optional
"""

import logging
from typing import Any

import httpx

from parachute.lib.credentials.base import (
    CredentialProvider,
    CredentialProviderError,
    CredentialToken,
)
from parachute.lib.credentials.manifest import (
    HealthCheck,
    HelperManifest,
    ProviderCapabilities,
    SetupField,
    SetupMethod,
)

logger = logging.getLogger(__name__)


class GenericEnvHelper(CredentialProvider):
    """Generic env var passthrough credential helper.

    Each instance represents a single env var credential (e.g., VERCEL_TOKEN).
    The manifest is generated dynamically based on the env var name.
    """

    provider_type = "env-passthrough"

    def __init__(
        self,
        name: str,
        env_var: str,
        token: str,
        display_name: str | None = None,
        health_url: str | None = None,
    ):
        self._name = name
        self.env_var = env_var
        self._token = token
        self._display_name = display_name or name.title()
        self._health_url = health_url

        # Dynamic manifest based on env var
        self.manifest = HelperManifest(
            display_name=self._display_name,
            description=f"Injects {env_var} into sandbox environments",
            setup_methods=[
                SetupMethod(
                    id="env-passthrough",
                    label="API Token",
                    recommended=True,
                    fields=[
                        SetupField(
                            id="token",
                            label="Token",
                            type="secret",
                            help=f"Value for {env_var}",
                        ),
                        SetupField(
                            id="env_var",
                            label="Environment Variable",
                            type="string",
                            help="The env var name to inject",
                        ),
                    ],
                ),
            ],
            provides=ProviderCapabilities(
                env_vars=[env_var],
            ),
            health_check=HealthCheck(
                method="api" if health_url else "none",
                endpoint=health_url or "",
                description=f"Verify {self._display_name} token",
            ),
        )

    @property
    def name(self) -> str:
        return self._name

    @property
    def active_method(self) -> str:
        return "env-passthrough"

    @classmethod
    def from_config(cls, name: str, config: dict) -> "GenericEnvHelper | None":
        """Create from config dict. Returns None if not configured.

        Config format:
            type: env-passthrough
            env_var: VERCEL_TOKEN
            token: ver_xxxxxxxx
            display_name: Vercel      # optional
            health_url: https://...   # optional
        """
        env_var = config.get("env_var")
        token = config.get("token")
        if not env_var or not token:
            return None

        return cls(
            name=name,
            env_var=env_var,
            token=token,
            display_name=config.get("display_name"),
            health_url=config.get("health_url"),
        )

    @classmethod
    def from_credentials_yaml(
        cls, key: str, value: str
    ) -> "GenericEnvHelper":
        """Create from a credentials.yaml key-value pair.

        Used for migration from the flat credentials.yaml format.
        """
        # Derive a name from the env var (e.g., VERCEL_TOKEN -> vercel)
        name = key.lower().removesuffix("_token").removesuffix("_api_key").removesuffix("_key")
        return cls(
            name=name,
            env_var=key,
            token=value,
            display_name=name.replace("_", " ").title(),
        )

    async def mint_token(self, scope: dict[str, Any]) -> CredentialToken:
        """Return the stored token (no minting, just passthrough)."""
        return CredentialToken(
            token=self._token,
            expires_at="",  # No expiry for passthrough
        )

    async def verify(self) -> dict:
        """Verify the token if a health URL is configured."""
        result: dict[str, Any] = {
            "method": "env-passthrough",
            "env_var": self.env_var,
            "display_name": self._display_name,
        }

        if not self._health_url:
            result["status"] = "unchecked"
            return result

        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.get(
                    self._health_url,
                    headers={"Authorization": f"Bearer {self._token}"},
                )
                resp.raise_for_status()
            result["status"] = "active"
        except httpx.HTTPError as e:
            raise CredentialProviderError(
                f"Failed to verify {self._display_name} token: {e}"
            ) from e

        return result

    def get_scripts(self) -> dict[str, str]:
        """No scripts needed for env passthrough."""
        return {}

    def get_env_vars(self) -> list[str]:
        """Return the single env var line."""
        return [f"{self.env_var}={self._token}"]
