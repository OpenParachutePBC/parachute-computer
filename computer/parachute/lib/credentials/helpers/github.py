"""
GitHub credential helper — supports Personal Access Token and GitHub App.

PAT (recommended):
  - User pastes a token, broker returns it on every mint_token() call
  - Works across all orgs/repos the user has access to
  - No per-session scoping, but simplest setup

GitHub App (advanced):
  - Broker mints short-lived installation tokens per org
  - Requires App registration, private key, per-org installation
  - Per-session scoping possible (read-only vs read-write)

Both methods use the same credential helper scripts — the broker API
response shape is identical regardless of method. The git credential
helper and gh wrapper don't need to know which method is in use.
"""

import datetime
import importlib.resources
import logging
import time
from pathlib import Path
from typing import Any

import httpx
import jwt

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


class GitHubHelper(CredentialProvider):
    """GitHub credential helper with PAT and App methods.

    The active method is determined by config — either 'personal-token'
    or 'github-app'. Both expose the same mint_token() / get_scripts()
    interface so the broker and sandbox don't need to know the difference.
    """

    name = "github"
    provider_type = "github"

    manifest = HelperManifest(
        display_name="GitHub",
        description="Git operations and GitHub API access",
        setup_methods=[
            SetupMethod(
                id="personal-token",
                label="Personal Access Token",
                recommended=True,
                help="Create a fine-grained PAT at github.com/settings/tokens",
                fields=[
                    SetupField(
                        id="token",
                        label="Personal Access Token",
                        type="secret",
                        help="Paste your GitHub PAT (ghp_... or github_pat_...)",
                    ),
                ],
            ),
            SetupMethod(
                id="github-app",
                label="GitHub App (Advanced)",
                help="For teams wanting per-org scoped tokens",
                fields=[
                    SetupField(id="app_id", label="App ID", type="string"),
                    SetupField(
                        id="private_key",
                        label="Private Key (.pem)",
                        type="file",
                        help="RSA private key downloaded from App settings",
                    ),
                ],
            ),
        ],
        provides=ProviderCapabilities(
            env_vars=["GH_TOKEN", "GH_DEFAULT_ORG"],
            scripts=["github-token-helper.sh", "gh-wrapper.sh"],
            git_config={
                "credential.helper": "!/opt/parachute-tools/bin/github-token-helper.sh",
                "credential.useHttpPath": "true",
            },
        ),
        health_check=HealthCheck(
            method="api",
            endpoint="https://api.github.com/user",
            description="Verify token can access GitHub API",
        ),
    )

    def __init__(
        self,
        method: str,
        *,
        # PAT fields
        token: str | None = None,
        # App fields
        app_id: int | None = None,
        private_key_pem: str | None = None,
        installations: dict[str, int] | None = None,
    ):
        self.method = method
        # PAT
        self._token = token
        # App
        self.app_id = app_id
        self.private_key_pem = private_key_pem
        self.installations = installations or {}
        self._app_token_cache: dict[int, dict] = {}
        self._client: httpx.AsyncClient | None = None

    @property
    def active_method(self) -> str:
        """Return the active setup method id."""
        return self.method

    async def _get_client(self) -> httpx.AsyncClient:
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

    async def close(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
            self._client = None

    # ── Factory ──────────────────────────────────────────────────────────────

    @classmethod
    def from_config(
        cls, config: dict, parachute_dir: Path | None = None
    ) -> "GitHubHelper | None":
        """Create from config dict. Handles both PAT and App methods.

        Config formats:
            # PAT (simple)
            type: personal-token
            token: ghp_xxxxxxxxxxxx

            # App (existing format, backward compatible)
            type: github-app
            app_id: 3051015
            installations:
              unforced: 115215642
        """
        provider_type = config.get("type", "")

        if provider_type == "personal-token":
            token = config.get("token")
            if not token:
                logger.warning("GitHub personal-token configured but no token provided")
                return None
            return cls(method="personal-token", token=token)

        elif provider_type == "github-app":
            app_id = config.get("app_id")
            if not app_id:
                return None

            if parachute_dir is None:
                logger.warning("GitHub App requires parachute_dir for PEM file")
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
                method="github-app",
                app_id=app_id,
                private_key_pem=private_key_pem,
                installations=installations,
            )

        else:
            logger.warning(f"Unknown GitHub method type: {provider_type}")
            return None

    # ── Token minting ────────────────────────────────────────────────────────

    async def mint_token(self, scope: dict[str, Any]) -> CredentialToken:
        """Mint a token. Behavior depends on method:

        PAT: Returns the stored token (org is logged but not required).
        App: Looks up installation for org, mints a scoped token.
        """
        if self.method == "personal-token":
            return self._mint_pat(scope)
        else:
            return await self._mint_app_token(scope)

    def _mint_pat(self, scope: dict[str, Any]) -> CredentialToken:
        """Return the stored PAT. Org is informational only."""
        if not self._token:
            raise CredentialProviderError("No GitHub PAT configured")

        org = scope.get("org", "unknown")
        logger.debug(f"Returning GitHub PAT for org context: {org}")

        # PATs don't have a platform-enforced expiry — use a long placeholder.
        # The git credential helper uses this for cache TTL.
        return CredentialToken(
            token=self._token,
            expires_at="2099-01-01T00:00:00Z",
        )

    async def _mint_app_token(self, scope: dict[str, Any]) -> CredentialToken:
        """Mint a GitHub App installation token (existing logic)."""
        org = scope.get("org")
        if not org:
            raise CredentialProviderError("GitHub scope must include 'org'")

        installation_id = self.installations.get(org)
        if installation_id is None:
            raise CredentialProviderError(
                f"No GitHub App installation for org: {org}"
            )

        return await self._get_app_token(installation_id)

    async def _get_app_token(self, installation_id: int) -> CredentialToken:
        """Get an installation token, using cache if valid."""
        cached = self._app_token_cache.get(installation_id)
        if cached and cached["expires_at"] - time.time() > 300:
            return CredentialToken(
                token=cached["token"],
                expires_at=cached["expires_at_iso"],
            )

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
        try:
            token = data["token"]
            expires_at_iso = data["expires_at"]
        except (KeyError, TypeError) as e:
            raise CredentialProviderError(
                f"Unexpected GitHub API response shape: {e}"
            ) from e

        expires_at_unix = datetime.datetime.fromisoformat(
            expires_at_iso.replace("Z", "+00:00")
        ).timestamp()

        self._app_token_cache[installation_id] = {
            "token": token,
            "expires_at": expires_at_unix,
            "expires_at_iso": expires_at_iso,
        }

        logger.info(
            f"Minted GitHub token for installation {installation_id}, "
            f"expires {expires_at_iso}"
        )
        return CredentialToken(token=token, expires_at=expires_at_iso)

    def _make_jwt(self) -> str:
        """Create a signed JWT for GitHub App authentication."""
        if not self.private_key_pem:
            raise CredentialProviderError("No GitHub App private key configured")
        now = int(time.time())
        payload = {
            "iat": now - 60,
            "exp": now + (10 * 60),
            "iss": str(self.app_id),
        }
        return jwt.encode(payload, self.private_key_pem, algorithm="RS256")

    # ── Health check ─────────────────────────────────────────────────────────

    async def verify(self) -> dict:
        """Verify credentials are valid."""
        if self.method == "personal-token":
            return await self._verify_pat()
        else:
            return await self._verify_app()

    async def _verify_pat(self) -> dict:
        """Verify PAT by calling /user endpoint."""
        if not self._token:
            raise CredentialProviderError("No GitHub PAT configured")

        try:
            client = await self._get_client()
            resp = await client.get(
                "/user",
                headers={"Authorization": f"Bearer {self._token}"},
            )
            resp.raise_for_status()
        except httpx.HTTPError as e:
            raise CredentialProviderError(
                f"Failed to verify GitHub PAT: {e}"
            ) from e

        data = resp.json()
        return {
            "method": "personal-token",
            "username": data.get("login", "unknown"),
            "name": data.get("name"),
            "scopes": resp.headers.get("x-oauth-scopes", ""),
        }

    async def _verify_app(self) -> dict:
        """Verify GitHub App by checking the App identity."""
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
            "method": "github-app",
            "app_name": data.get("name", "unknown"),
            "app_slug": data.get("slug", "unknown"),
            "app_id": data.get("id"),
            "installations": self.installations,
        }

    # ── Scripts ──────────────────────────────────────────────────────────────

    _SCRIPT_DEPLOY_NAMES = {
        "github-token-helper.sh": "github-token-helper.sh",
        "gh-wrapper.sh": "gh",
    }

    def get_scripts(self) -> dict[str, str]:
        """Return credential helper scripts for the tools volume."""
        scripts = {}
        try:
            files = importlib.resources.files(_SCRIPTS_PKG)
            for source_name, deploy_name in self._SCRIPT_DEPLOY_NAMES.items():
                resource = files.joinpath(source_name)
                scripts[deploy_name] = resource.read_text(encoding="utf-8")
        except Exception:
            scripts_dir = Path(__file__).parent.parent / "scripts"
            for source_name, deploy_name in self._SCRIPT_DEPLOY_NAMES.items():
                script_path = scripts_dir / source_name
                if script_path.exists():
                    scripts[deploy_name] = script_path.read_text()
        return scripts

    # ── Env vars for sandbox injection ───────────────────────────────────────

    def get_env_vars(self) -> list[str]:
        """Return env var lines for sandbox injection.

        Used by _build_credential_env_vars() in sandbox.py.
        """
        env_lines = [
            "GIT_CONFIG_COUNT=2",
            "GIT_CONFIG_KEY_0=credential.helper",
            "GIT_CONFIG_VALUE_0=!/opt/parachute-tools/bin/github-token-helper.sh",
            "GIT_CONFIG_KEY_1=credential.useHttpPath",
            "GIT_CONFIG_VALUE_1=true",
        ]

        default_org = self.get_default_org()
        if default_org:
            env_lines.append(f"GH_DEFAULT_ORG={default_org}")

        return env_lines

    def get_default_org(self) -> str | None:
        """Return the first configured org as a default fallback."""
        if self.installations:
            return next(iter(self.installations))
        return None

    # ── List installations (App method only) ─────────────────────────────────

    async def list_installations(self) -> list[dict]:
        """List all installations of this GitHub App."""
        if self.method != "github-app":
            return []

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
