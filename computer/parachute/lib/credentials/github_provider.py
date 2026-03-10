"""
GitHub App credential provider.

Mints short-lived GitHub App installation tokens on demand.
Transparent credential helpers in the sandbox call the broker endpoint,
which dispatches to this provider.

Flow:
  1. Read PEM private key from ~/.parachute/github-app.pem
  2. Sign a JWT (RS256, iss=app_id, 10-min expiry)
  3. Exchange JWT for installation token via GitHub API
  4. Cache tokens in-memory, refresh 5 min before expiry

Dependencies: PyJWT[crypto] (JWT signing with RS256)
"""

import datetime
import importlib.resources
import logging
import time
from pathlib import Path

import httpx
import jwt

from parachute.lib.credentials.base import (
    CredentialProvider,
    CredentialProviderError,
    CredentialToken,
)

logger = logging.getLogger(__name__)

# Script templates are loaded from the scripts/ directory
_SCRIPTS_PKG = "parachute.lib.credentials.scripts"


class GitHubProvider(CredentialProvider):
    """GitHub App credential provider.

    Mints and caches GitHub App installation tokens. Provides hook-based
    injection via a git credential helper and gh CLI wrapper.
    """

    name = "github"
    provider_type = "github-app"

    def __init__(
        self,
        app_id: int,
        private_key_pem: str,
        installations: dict[str, int],
    ):
        """
        Args:
            app_id: GitHub App ID
            private_key_pem: PEM-encoded RSA private key contents
            installations: Mapping of org/account name -> installation ID
        """
        self.app_id = app_id
        self.private_key_pem = private_key_pem
        self.installations = installations  # org_name -> installation_id
        self._token_cache: dict[int, dict] = {}
        self._client: httpx.AsyncClient | None = None

    async def _get_client(self) -> httpx.AsyncClient:
        """Get or create a shared httpx client for GitHub API calls."""
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                base_url="https://api.github.com",
                headers={
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                },
                timeout=10.0,
            )
        return self._client

    @classmethod
    def from_config(cls, config: dict, parachute_dir: Path) -> "GitHubProvider | None":
        """Create provider from config dict. Returns None if not configured.

        Config format:
            type: github-app
            app_id: 3051015
            installations:
              unforced: 115215642
        """
        app_id = config.get("app_id")
        if not app_id:
            return None

        pem_path = parachute_dir / "github-app.pem"
        if not pem_path.exists():
            logger.warning(f"GitHub App PEM not found at {pem_path}")
            return None

        installations = config.get("installations")
        if not installations:
            logger.warning("GitHub App configured but no installations mapped")
            return None

        try:
            private_key_pem = pem_path.read_text()
        except Exception as e:
            logger.error(f"Failed to read GitHub App PEM: {e}")
            return None

        return cls(
            app_id=app_id,
            private_key_pem=private_key_pem,
            installations=installations,
        )

    def _make_jwt(self) -> str:
        """Create a signed JWT for GitHub App authentication.

        JWTs are valid for 10 minutes max. We backdate `iat` by 60 seconds
        to account for clock drift between our server and GitHub's.
        """
        now = int(time.time())
        payload = {
            "iat": now - 60,  # Backdated for clock drift
            "exp": now + (10 * 60),  # 10 minute max
            "iss": str(self.app_id),
        }
        return jwt.encode(payload, self.private_key_pem, algorithm="RS256")

    async def mint_token(self, scope: dict) -> CredentialToken:
        """Mint an installation token for a GitHub org.

        Args:
            scope: {"org": "unforced"} — the org name to mint a token for.

        Raises:
            CredentialProviderError: If the org is unknown or minting fails.
        """
        org = scope.get("org")
        if not org:
            raise CredentialProviderError("GitHub scope must include 'org'")

        installation_id = self.installations.get(org)
        if installation_id is None:
            raise CredentialProviderError(
                f"No GitHub App installation for org: {org}"
            )

        return await self._get_token(installation_id)

    async def _get_token(self, installation_id: int) -> CredentialToken:
        """Get an installation token, using cache if valid."""
        # Check cache — refresh if less than 5 minutes until expiry
        cached = self._token_cache.get(installation_id)
        if cached and cached["expires_at"] - time.time() > 300:
            return CredentialToken(
                token=cached["token"],
                expires_at=cached["expires_at_iso"],
            )

        # Mint a new token
        app_jwt = self._make_jwt()
        url = f"/app/installations/{installation_id}/access_tokens"

        try:
            client = await self._get_client()
            resp = await client.post(
                url,
                headers={"Authorization": f"Bearer {app_jwt}"},
            )
            resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            logger.error(
                f"GitHub API error minting token for installation "
                f"{installation_id}: {e.response.status_code} {e.response.text}"
            )
            raise CredentialProviderError(
                f"Failed to mint token: {e.response.status_code}"
            ) from e
        except httpx.HTTPError as e:
            logger.error(
                f"Network error minting token for installation {installation_id}: {e}"
            )
            raise CredentialProviderError(f"Network error: {e}") from e

        data = resp.json()
        token = data["token"]
        expires_at_iso = data["expires_at"]  # e.g. "2026-03-09T01:00:00Z"

        # Parse expiry to unix timestamp for cache comparison
        expires_at_unix = datetime.datetime.fromisoformat(
            expires_at_iso.replace("Z", "+00:00")
        ).timestamp()

        # Cache it
        self._token_cache[installation_id] = {
            "token": token,
            "expires_at": expires_at_unix,
            "expires_at_iso": expires_at_iso,
        }

        logger.info(
            f"Minted GitHub token for installation {installation_id}, "
            f"expires {expires_at_iso}"
        )
        return CredentialToken(token=token, expires_at=expires_at_iso)

    async def verify(self) -> dict:
        """Verify the GitHub App configuration by checking the App identity."""
        app_jwt = self._make_jwt()
        try:
            client = await self._get_client()
            resp = await client.get(
                "/app",
                headers={"Authorization": f"Bearer {app_jwt}"},
            )
            resp.raise_for_status()
        except httpx.HTTPError as e:
            raise CredentialProviderError(
                f"Failed to verify GitHub App: {e}"
            ) from e

        data = resp.json()
        return {
            "app_name": data.get("name", "unknown"),
            "app_slug": data.get("slug", "unknown"),
            "app_id": data.get("id"),
            "installations": self.installations,
        }

    async def list_installations(self) -> list[dict]:
        """List all installations of this GitHub App."""
        app_jwt = self._make_jwt()
        try:
            client = await self._get_client()
            resp = await client.get(
                "/app/installations",
                headers={"Authorization": f"Bearer {app_jwt}"},
            )
            resp.raise_for_status()
        except httpx.HTTPError as e:
            raise CredentialProviderError(
                f"Failed to list installations: {e}"
            ) from e

        results = []
        for item in resp.json():
            results.append({
                "id": item["id"],
                "account_login": item.get("account", {}).get("login", "unknown"),
                "account_type": item.get("account", {}).get("type", "unknown"),
                "target_type": item.get("target_type", "unknown"),
            })
        return results

    # Source filename -> deployment filename on tools volume.
    # gh-wrapper.sh is deployed as "gh" to shadow /usr/bin/gh via PATH ordering.
    _SCRIPT_DEPLOY_NAMES = {
        "github-token-helper.sh": "github-token-helper.sh",
        "gh-wrapper.sh": "gh",
    }

    def get_scripts(self) -> dict[str, str]:
        """Return GitHub credential helper scripts for the tools volume.

        Returns scripts keyed by their deployment filename (not source filename).
        gh-wrapper.sh is deployed as "gh" so it shadows /usr/bin/gh via PATH.
        """
        scripts = {}
        try:
            files = importlib.resources.files(_SCRIPTS_PKG)
            for source_name, deploy_name in self._SCRIPT_DEPLOY_NAMES.items():
                resource = files.joinpath(source_name)
                scripts[deploy_name] = resource.read_text(encoding="utf-8")
        except Exception:
            # Fall back to reading from docker/ directory (development)
            scripts_dir = Path(__file__).parent.parent.parent / "docker"
            for source_name, deploy_name in self._SCRIPT_DEPLOY_NAMES.items():
                script_path = scripts_dir / source_name
                if script_path.exists():
                    scripts[deploy_name] = script_path.read_text()
        return scripts

    def get_default_org(self) -> str | None:
        """Return the first configured org as a default fallback."""
        if self.installations:
            return next(iter(self.installations))
        return None
