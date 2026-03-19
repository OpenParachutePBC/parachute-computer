"""
Cloudflare credential helper — wraps existing CloudflareProvider with manifest.

Supports parent token passthrough (simple) and scoped child token minting
(when default_permissions are configured). Provides a wrangler PATH wrapper
script that calls the broker API for token injection.

Key improvement over raw CloudflareProvider:
- Self-describing manifest for app UI
- CLOUDFLARE_ACCOUNT_ID always injected (no Memberships:Read needed)
- Wrangler wrapper script for scoped token injection
"""

import importlib.resources
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

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

_SCRIPTS_PKG = "parachute.lib.credentials.scripts"

# Default TTL for child tokens
DEFAULT_TTL_HOURS = 8
MAX_TTL_HOURS = 24


class CloudflareHelper(CredentialProvider):
    """Cloudflare credential helper with parent token passthrough.

    When default_permissions are configured, mint_token() creates scoped
    child tokens via the Cloudflare API. Otherwise, the parent token is
    passed through directly (with a warning logged).
    """

    name = "cloudflare"
    provider_type = "cloudflare"

    manifest = HelperManifest(
        display_name="Cloudflare",
        description="Cloudflare Workers, Pages, and API access",
        setup_methods=[
            SetupMethod(
                id="cloudflare-parent",
                label="API Token",
                recommended=True,
                help="Create at dash.cloudflare.com/profile/api-tokens",
                fields=[
                    SetupField(
                        id="parent_token",
                        label="API Token",
                        type="secret",
                        help="Cloudflare API token with permission to create child tokens",
                    ),
                    SetupField(
                        id="account_id",
                        label="Account ID",
                        type="string",
                        help="Found in the Cloudflare dashboard sidebar",
                        required=False,
                    ),
                ],
            ),
        ],
        provides=ProviderCapabilities(
            env_vars=["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"],
            scripts=["wrangler-wrapper.sh"],
        ),
        health_check=HealthCheck(
            method="api",
            endpoint="https://api.cloudflare.com/client/v4/user/tokens/verify",
            description="Verify API token is valid",
        ),
    )

    def __init__(
        self,
        parent_token: str,
        account_id: str | None = None,
        default_permissions: list | None = None,
    ):
        self.parent_token = parent_token
        self.account_id = account_id
        self.default_permissions = default_permissions or []
        self._client: httpx.AsyncClient | None = None

    @property
    def active_method(self) -> str:
        return "cloudflare-parent"

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                base_url="https://api.cloudflare.com/client/v4",
                headers={
                    "Authorization": f"Bearer {self.parent_token}",
                    "Content-Type": "application/json",
                },
                timeout=15.0,
            )
        return self._client

    async def close(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
            self._client = None

    @classmethod
    def from_config(cls, config: dict) -> "CloudflareHelper | None":
        """Create from config dict. Returns None if not configured.

        Config format:
            type: cloudflare-parent
            parent_token: cf_xxxx
            account_id: abc123  # optional
            default_permissions:  # optional
              - "some-permission-group-id"
        """
        parent_token = config.get("parent_token")
        if not parent_token:
            return None

        return cls(
            parent_token=parent_token,
            account_id=config.get("account_id"),
            default_permissions=config.get("default_permissions"),
        )

    async def mint_token(self, scope: dict[str, Any]) -> CredentialToken:
        """Mint a scoped child token or return parent token.

        If default_permissions are configured, mints a short-lived child
        token via the Cloudflare API. Otherwise, returns the parent token
        directly (passthrough mode).
        """
        if not self.default_permissions:
            # Passthrough mode — no scoping available
            logger.info(
                "Cloudflare passthrough mode (no default_permissions configured)"
            )
            return CredentialToken(
                token=self.parent_token,
                expires_at="",  # No expiry for passthrough
            )

        # Scoped child token minting
        ttl_hours = min(
            scope.get("ttl_hours", DEFAULT_TTL_HOURS),
            MAX_TTL_HOURS,
        )
        now = datetime.now(timezone.utc)
        expires = now + timedelta(hours=ttl_hours)
        token_name = f"parachute-{self.account_id or 'default'}-{uuid4().hex[:6]}"

        policies = self._build_policies(self.default_permissions, self.account_id)

        body: dict = {
            "name": token_name,
            "not_before": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "expires_on": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "policies": policies,
        }

        try:
            client = await self._get_client()
            resp = await client.post("/user/tokens", json=body)
            resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            logger.error(
                f"Cloudflare API error minting token: "
                f"{e.response.status_code} {e.response.text}"
            )
            raise CredentialProviderError(
                f"Failed to mint Cloudflare token: {e.response.status_code}"
            ) from e
        except httpx.HTTPError as e:
            raise CredentialProviderError(f"Network error: {e}") from e

        data = resp.json()
        if not data.get("success"):
            errors = data.get("errors", [])
            raise CredentialProviderError(f"Cloudflare API error: {errors}")

        try:
            token_value = data["result"]["value"]
        except (KeyError, TypeError) as e:
            raise CredentialProviderError(
                f"Unexpected Cloudflare API response shape: {e}"
            ) from e

        logger.info(
            f"Minted Cloudflare child token '{token_name}', "
            f"expires {expires.isoformat()}"
        )
        return CredentialToken(
            token=token_value, expires_at=expires.isoformat()
        )

    async def verify(self) -> dict:
        """Verify the parent token via Cloudflare API."""
        try:
            client = await self._get_client()
            resp = await client.get("/user/tokens/verify")
            resp.raise_for_status()
        except httpx.HTTPError as e:
            raise CredentialProviderError(
                f"Failed to verify Cloudflare token: {e}"
            ) from e

        data = resp.json()
        result = data.get("result", {})
        return {
            "method": "cloudflare-parent",
            "status": result.get("status", "unknown"),
            "expires_on": result.get("expires_on"),
            "account_id": self.account_id,
            "has_permissions": bool(self.default_permissions),
        }

    def _build_policies(
        self, permissions: list, account_id: str | None
    ) -> list[dict]:
        """Build Cloudflare token policies from permission list."""
        if not permissions:
            return []

        resources = {}
        if account_id:
            resources[f"com.cloudflare.api.account.{account_id}"] = "*"
        else:
            resources["com.cloudflare.api.account.*"] = "*"

        return [{
            "effect": "allow",
            "resources": resources,
            "permission_groups": [
                {"id": p} if isinstance(p, str) else p
                for p in permissions
            ],
        }]

    # ── Scripts ──────────────────────────────────────────────────────────

    def get_scripts(self) -> dict[str, str]:
        """Return wrangler wrapper script for the tools volume."""
        scripts = {}
        try:
            files = importlib.resources.files(_SCRIPTS_PKG)
            resource = files.joinpath("wrangler-wrapper.sh")
            scripts["wrangler"] = resource.read_text(encoding="utf-8")
        except Exception:
            scripts_dir = Path(__file__).parent.parent / "scripts"
            script_path = scripts_dir / "wrangler-wrapper.sh"
            if script_path.exists():
                scripts["wrangler"] = script_path.read_text()
        return scripts

    # ── Env vars ─────────────────────────────────────────────────────────

    def get_env_vars(self) -> list[str]:
        """Return env var lines for sandbox injection.

        Injects parent token directly. The wrangler wrapper script can
        optionally call the broker for scoped child tokens.
        """
        env_lines = [f"CLOUDFLARE_API_TOKEN={self.parent_token}"]
        if self.account_id:
            env_lines.append(f"CLOUDFLARE_ACCOUNT_ID={self.account_id}")
        return env_lines
