"""
Cloudflare credential provider.

Mints short-lived, scoped Cloudflare API tokens from a parent token.
Uses the Cloudflare API to create child tokens with specific permissions
and expiry times.

Flow:
  1. Parent token stored in config (long-lived, broad permissions)
  2. On request, mint a child token via POST /user/tokens
  3. Child token has scoped permissions + TTL (default 8 hours, max 24)
  4. Inject as CLOUDFLARE_API_TOKEN env var at docker exec time
"""

import logging
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import httpx

from parachute.lib.credentials.base import (
    CredentialProvider,
    CredentialProviderError,
    CredentialToken,
)

logger = logging.getLogger(__name__)

# Default TTL for child tokens
DEFAULT_TTL_HOURS = 8
# Hard cap on TTL — prevents sandbox from requesting arbitrarily long-lived tokens
MAX_TTL_HOURS = 24


class CloudflareProvider(CredentialProvider):
    """Cloudflare credential provider.

    Mints scoped child API tokens from a parent token. Uses env-based
    injection (CLOUDFLARE_API_TOKEN) — no scripts needed.
    """

    name = "cloudflare"
    provider_type = "cloudflare-parent"

    def __init__(
        self,
        parent_token: str,
        account_id: str | None = None,
        default_permissions: list | None = None,
    ):
        """
        Args:
            parent_token: Long-lived Cloudflare API token with permission
                          to create child tokens.
            account_id: Optional default account ID.
            default_permissions: Default permission group IDs for child tokens.
                                 Required — empty permissions would inherit parent's
                                 full permission set.
        """
        self.parent_token = parent_token
        self.account_id = account_id
        self.default_permissions = default_permissions or []
        self._client: httpx.AsyncClient | None = None

    async def _get_client(self) -> httpx.AsyncClient:
        """Get or create a shared httpx client."""
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

    @classmethod
    def from_config(cls, config: dict) -> "CloudflareProvider | None":
        """Create provider from config dict. Returns None if not configured.

        Config format:
            type: cloudflare-parent
            parent_token: cf_xxxx
            account_id: abc123  # optional
            default_permissions:  # optional but recommended
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

    async def mint_token(self, scope: dict) -> CredentialToken:
        """Mint a scoped child API token via Cloudflare API.

        Args:
            scope: {
                "account": "abc123",  # optional, falls back to default
                "permissions": [{"id": "...", "effect": "allow"}],  # optional
                "ttl_hours": 8,  # optional, capped at MAX_TTL_HOURS
            }

        Raises:
            CredentialProviderError: If minting fails or no permissions configured.
        """
        account_id = scope.get("account") or self.account_id
        ttl_hours = min(
            scope.get("ttl_hours", DEFAULT_TTL_HOURS),
            MAX_TTL_HOURS,
        )
        permissions = scope.get("permissions") or self.default_permissions

        if not permissions:
            raise CredentialProviderError(
                "Cloudflare token minting requires explicit permissions — "
                "configure default_permissions in credential_providers.cloudflare "
                "or pass permissions in scope. Without explicit permissions, child "
                "tokens would inherit the parent token's full permission set."
            )

        now = datetime.now(timezone.utc)
        expires = now + timedelta(hours=ttl_hours)
        token_name = f"parachute-{account_id or 'default'}-{uuid4().hex[:6]}"

        # Build policies from permissions
        policies = self._build_policies(permissions, account_id)

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
            logger.error(f"Network error minting Cloudflare token: {e}")
            raise CredentialProviderError(f"Network error: {e}") from e

        data = resp.json()
        if not data.get("success"):
            errors = data.get("errors", [])
            raise CredentialProviderError(
                f"Cloudflare API error: {errors}"
            )

        token_value = data["result"]["value"]
        expires_iso = expires.isoformat()

        logger.info(
            f"Minted Cloudflare child token '{token_name}', "
            f"expires {expires_iso}"
        )
        return CredentialToken(token=token_value, expires_at=expires_iso)

    async def verify(self) -> dict:
        """Verify the parent token by checking token status."""
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
            "status": result.get("status", "unknown"),
            "expires_on": result.get("expires_on"),
            "account_id": self.account_id,
        }

    def _build_policies(
        self, permissions: list, account_id: str | None
    ) -> list[dict]:
        """Build Cloudflare token policies from permission list.

        Permissions must be explicitly provided — never mint tokens without
        policies, as that would inherit the parent token's full permissions.
        """
        if not permissions:
            return []

        # Build a single policy with all permission groups
        resources = {}
        if account_id:
            resources[f"com.cloudflare.api.account.{account_id}"] = "*"
        else:
            # All accounts the parent token has access to
            resources["com.cloudflare.api.account.*"] = "*"

        return [{
            "effect": "allow",
            "resources": resources,
            "permission_groups": [
                {"id": p} if isinstance(p, str) else p
                for p in permissions
            ],
        }]
