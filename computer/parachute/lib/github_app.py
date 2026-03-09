"""
GitHub App credential broker.

Mints short-lived GitHub App installation tokens on demand.
Agents never see credentials — transparent credential helpers
in the sandbox image call the broker endpoint, which calls this module.

Flow:
  1. Read PEM private key from ~/.parachute/github-app.pem
  2. Sign a JWT (RS256, iss=app_id, 10-min expiry)
  3. Exchange JWT for installation token via GitHub API
  4. Cache tokens in-memory, refresh 5 min before expiry

Dependencies: PyJWT[crypto] (JWT signing with RS256)
"""

import datetime
import logging
import time
from dataclasses import dataclass
from pathlib import Path

import httpx
import jwt

logger = logging.getLogger(__name__)


class GitHubAppError(Exception):
    """Raised when GitHub App operations fail."""


@dataclass(slots=True)
class InstallationToken:
    """A short-lived GitHub App installation token."""

    token: str
    expires_at: str  # ISO 8601


class GitHubAppBroker:
    """Mints and caches GitHub App installation tokens."""

    def __init__(self, app_id: int, private_key_pem: str, installations: dict[str, int]):
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

    @classmethod
    def from_config(
        cls,
        app_id: int | None,
        pem_path: Path,
        installations: dict[str, int] | None,
    ) -> "GitHubAppBroker | None":
        """Create a broker from config values. Returns None if not configured."""
        if not app_id:
            return None
        if not pem_path.exists():
            logger.warning(f"GitHub App PEM not found at {pem_path}")
            return None
        if not installations:
            logger.warning("GitHub App configured but no installations mapped")
            return None

        try:
            private_key_pem = pem_path.read_text()
        except Exception as e:
            logger.error(f"Failed to read GitHub App PEM: {e}")
            return None

        return cls(app_id=app_id, private_key_pem=private_key_pem, installations=installations)

    def _make_jwt(self) -> str:
        """Create a signed JWT for GitHub App authentication.

        JWTs are valid for 10 minutes max. We backdate `iat` by 60 seconds
        to account for clock drift between our server and GitHub's.
        """
        now = int(time.time())
        payload = {
            "iat": now - 60,           # Backdated for clock drift
            "exp": now + (10 * 60),    # 10 minute max
            "iss": str(self.app_id),
        }
        return jwt.encode(payload, self.private_key_pem, algorithm="RS256")

    async def get_token_for_org(self, org: str) -> InstallationToken:
        """Get an installation token for an org, using cache if valid.

        Resolves the org name to an installation ID internally,
        then mints or returns a cached token.

        Raises:
            GitHubAppError: If the org is unknown or token minting fails.
        """
        installation_id = self.installations.get(org)
        if installation_id is None:
            raise GitHubAppError(f"No GitHub App installation for org: {org}")
        return await self._get_token(installation_id)

    async def _get_token(self, installation_id: int) -> InstallationToken:
        """Get an installation token, using cache if valid.

        Raises:
            GitHubAppError: If token minting fails.
        """
        # Check cache — refresh if less than 5 minutes until expiry
        cached = self._token_cache.get(installation_id)
        if cached and cached["expires_at"] - time.time() > 300:
            return InstallationToken(
                token=cached["token"],
                expires_at=cached["expires_at_iso"],
            )

        # Mint a new token
        app_jwt = self._make_jwt()
        url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"

        try:
            async with httpx.AsyncClient() as client:
                resp = await client.post(
                    url,
                    headers={
                        "Authorization": f"Bearer {app_jwt}",
                        "Accept": "application/vnd.github+json",
                        "X-GitHub-Api-Version": "2022-11-28",
                    },
                    timeout=10.0,
                )
                resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            logger.error(f"GitHub API error minting token for installation {installation_id}: {e.response.status_code} {e.response.text}")
            raise GitHubAppError(f"Failed to mint token: {e.response.status_code}") from e
        except httpx.HTTPError as e:
            logger.error(f"Network error minting token for installation {installation_id}: {e}")
            raise GitHubAppError(f"Network error: {e}") from e

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

        logger.info(f"Minted GitHub token for installation {installation_id}, expires {expires_at_iso}")
        return InstallationToken(token=token, expires_at=expires_at_iso)

    async def verify(self) -> dict:
        """Verify the GitHub App configuration by checking the App identity.

        Returns:
            {"app_name": str, "app_id": int, "installations": dict}

        Raises:
            GitHubAppError: If verification fails.
        """
        app_jwt = self._make_jwt()
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.get(
                    "https://api.github.com/app",
                    headers={
                        "Authorization": f"Bearer {app_jwt}",
                        "Accept": "application/vnd.github+json",
                        "X-GitHub-Api-Version": "2022-11-28",
                    },
                    timeout=10.0,
)
                resp.raise_for_status()
        except httpx.HTTPError as e:
            raise GitHubAppError(f"Failed to verify GitHub App: {e}") from e

        data = resp.json()
        return {
            "app_name": data.get("name", "unknown"),
            "app_id": data.get("id"),
            "installations": self.installations,
        }


# Module-level singleton, initialized lazily
_UNSET = object()
_broker: "GitHubAppBroker | None | object" = _UNSET


def get_broker() -> GitHubAppBroker | None:
    """Get the module-level broker singleton, initializing from config if needed."""
    global _broker

    if _broker is not _UNSET:
        return _broker  # type: ignore[return-value]

    from parachute.config import get_settings
    settings = get_settings()

    _broker = GitHubAppBroker.from_config(
        app_id=settings.github_app_id,
        pem_path=settings.github_app_pem_path,
        installations=settings.github_installations,
    )

    if _broker:
        logger.info(f"GitHub App broker initialized (app_id={settings.github_app_id}, {len(_broker.installations)} installations)")
    else:
        logger.debug("GitHub App broker not configured — credential broker disabled")

    return _broker


def reset_broker() -> None:
    """Reset the broker singleton (for testing or config reload)."""
    global _broker
    _broker = _UNSET
