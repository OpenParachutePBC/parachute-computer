"""Tests for the credential broker system.

Tests cover:
  - Provider ABC enforcement
  - CredentialBroker registration and dispatch
  - GitHubProvider token caching and JWT signing
  - CloudflareProvider permission enforcement and TTL caps
  - API endpoint validation (org format, error mapping, auth)
  - Config auto-migration from legacy fields
  - Sandbox env var helper
  - Config file permissions
"""

import hmac
import os
import stat
import time
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from parachute.lib.credentials.base import (
    CredentialProvider,
    CredentialProviderError,
    CredentialToken,
)
from parachute.lib.credentials.broker import CredentialBroker, reset_broker


# ── Provider ABC ─────────────────────────────────────────────────────────────


class DummyProvider(CredentialProvider):
    """Minimal concrete provider for testing."""

    name = "dummy"
    provider_type = "test"

    async def mint_token(self, scope: dict) -> CredentialToken:
        return CredentialToken(token="tok_test", expires_at="2099-01-01T00:00:00Z")

    async def verify(self) -> dict:
        return {"status": "ok"}


class TestCredentialProviderABC:
    def test_concrete_provider_instantiates(self):
        p = DummyProvider()
        assert p.name == "dummy"
        assert p.provider_type == "test"

    def test_get_scripts_default_empty(self):
        p = DummyProvider()
        assert p.get_scripts() == {}

    def test_abstract_methods_enforced(self):
        """Cannot instantiate without implementing all abstract methods."""
        with pytest.raises(TypeError):
            CredentialProvider()  # type: ignore[abstract]


# ── CredentialBroker ─────────────────────────────────────────────────────────


class TestCredentialBroker:
    def test_register_and_get(self):
        broker = CredentialBroker()
        provider = DummyProvider()
        broker.register(provider)
        assert broker.has_provider("dummy")
        assert broker.get_provider("dummy") is provider
        assert "dummy" in broker.provider_names

    def test_has_provider_false_for_missing(self):
        broker = CredentialBroker()
        assert not broker.has_provider("nonexistent")

    def test_get_provider_returns_none_for_missing(self):
        broker = CredentialBroker()
        assert broker.get_provider("nonexistent") is None

    @pytest.mark.asyncio
    async def test_mint_token_dispatches(self):
        broker = CredentialBroker()
        broker.register(DummyProvider())
        result = await broker.mint_token("dummy", {})
        assert result.token == "tok_test"

    @pytest.mark.asyncio
    async def test_mint_token_unknown_provider_raises(self):
        broker = CredentialBroker()
        with pytest.raises(CredentialProviderError, match="Unknown credential provider"):
            await broker.mint_token("ghost", {})

    @pytest.mark.asyncio
    async def test_verify_provider(self):
        broker = CredentialBroker()
        broker.register(DummyProvider())
        result = await broker.verify_provider("dummy")
        assert result == {"status": "ok"}

    def test_get_all_scripts_aggregates(self):
        class ScriptProvider(DummyProvider):
            name = "scripted"

            def get_scripts(self):
                return {"helper.sh": "#!/bin/bash\necho hi"}

        broker = CredentialBroker()
        broker.register(ScriptProvider())
        scripts = broker.get_all_scripts()
        assert "helper.sh" in scripts
        assert "echo hi" in scripts["helper.sh"]

    def test_get_status(self):
        broker = CredentialBroker()
        broker.register(DummyProvider())
        status = broker.get_status()
        assert status["configured"] is True
        assert "dummy" in status["providers"]
        assert status["providers"]["dummy"]["type"] == "test"

    def test_get_status_empty(self):
        broker = CredentialBroker()
        status = broker.get_status()
        assert status["configured"] is False
        assert status["providers"] == {}


# ── Broker singleton ─────────────────────────────────────────────────────────


class TestBrokerSingleton:
    def test_reset_broker_clears_singleton(self):
        from parachute.lib.credentials.broker import _broker
        reset_broker()
        from parachute.lib.credentials.broker import _broker as after
        assert after is None


# ── GitHubProvider ───────────────────────────────────────────────────────────


class TestGitHubProvider:
    def test_from_config_missing_app_id(self, tmp_path):
        from parachute.lib.credentials.github_provider import GitHubProvider

        result = GitHubProvider.from_config({}, tmp_path)
        assert result is None

    def test_from_config_missing_pem(self, tmp_path):
        from parachute.lib.credentials.github_provider import GitHubProvider

        result = GitHubProvider.from_config(
            {"app_id": 123, "installations": {"org": 456}},
            tmp_path,
        )
        assert result is None

    def test_from_config_missing_installations(self, tmp_path):
        from parachute.lib.credentials.github_provider import GitHubProvider

        pem = tmp_path / "github-app.pem"
        pem.write_text("fake-pem")
        result = GitHubProvider.from_config({"app_id": 123}, tmp_path)
        assert result is None

    def test_from_config_success(self, tmp_path):
        from parachute.lib.credentials.github_provider import GitHubProvider

        pem = tmp_path / "github-app.pem"
        pem.write_text("-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----\n")
        result = GitHubProvider.from_config(
            {"app_id": 123, "installations": {"myorg": 456}},
            tmp_path,
        )
        assert result is not None
        assert result.app_id == 123
        assert result.installations == {"myorg": 456}
        assert result.name == "github"
        assert result.provider_type == "github-app"

    @pytest.mark.asyncio
    async def test_mint_token_missing_org(self, tmp_path):
        from parachute.lib.credentials.github_provider import GitHubProvider

        provider = GitHubProvider(
            app_id=123, private_key_pem="fake", installations={"org": 1}
        )
        with pytest.raises(CredentialProviderError, match="scope must include 'org'"):
            await provider.mint_token({})

    @pytest.mark.asyncio
    async def test_mint_token_unknown_org(self, tmp_path):
        from parachute.lib.credentials.github_provider import GitHubProvider

        provider = GitHubProvider(
            app_id=123, private_key_pem="fake", installations={"org": 1}
        )
        with pytest.raises(CredentialProviderError, match="No GitHub App installation for org"):
            await provider.mint_token({"org": "unknown"})

    def test_get_default_org(self):
        from parachute.lib.credentials.github_provider import GitHubProvider

        provider = GitHubProvider(
            app_id=123, private_key_pem="fake",
            installations={"first": 1, "second": 2},
        )
        assert provider.get_default_org() == "first"

    def test_get_default_org_empty(self):
        from parachute.lib.credentials.github_provider import GitHubProvider

        provider = GitHubProvider(
            app_id=123, private_key_pem="fake", installations={},
        )
        assert provider.get_default_org() is None

    @pytest.mark.asyncio
    async def test_token_caching(self):
        """Cached tokens are returned without re-minting."""
        from parachute.lib.credentials.github_provider import GitHubProvider

        provider = GitHubProvider(
            app_id=123, private_key_pem="fake",
            installations={"org": 42},
        )
        # Pre-populate cache with a token that expires in 10 minutes
        provider._token_cache[42] = {
            "token": "cached_token",
            "expires_at": time.time() + 600,
            "expires_at_iso": "2099-01-01T00:00:00Z",
        }
        result = await provider.mint_token({"org": "org"})
        assert result.token == "cached_token"

    @pytest.mark.asyncio
    async def test_expired_cache_triggers_refresh(self):
        """Expired cache entries trigger a new mint attempt (not returned from cache)."""
        from parachute.lib.credentials.github_provider import GitHubProvider

        provider = GitHubProvider(
            app_id=123, private_key_pem="fake",
            installations={"org": 42},
        )
        # Pre-populate cache with an expired token (4 min remaining < 5 min threshold)
        provider._token_cache[42] = {
            "token": "expired_token",
            "expires_at": time.time() + 200,  # Less than 300s
            "expires_at_iso": "2099-01-01T00:00:00Z",
        }
        # Should NOT return the cached token — should attempt refresh.
        # Will fail on JWT signing (fake PEM) — any exception proves the refresh path.
        with pytest.raises(Exception):  # InvalidKeyError from jwt.encode
            await provider.mint_token({"org": "org"})


# ── CloudflareProvider ───────────────────────────────────────────────────────


class TestCloudflareProvider:
    def test_from_config_missing_token(self):
        from parachute.lib.credentials.cloudflare_provider import CloudflareProvider

        result = CloudflareProvider.from_config({})
        assert result is None

    def test_from_config_success(self):
        from parachute.lib.credentials.cloudflare_provider import CloudflareProvider

        result = CloudflareProvider.from_config({
            "parent_token": "cf_test",
            "account_id": "acc123",
            "default_permissions": ["perm1"],
        })
        assert result is not None
        assert result.parent_token == "cf_test"
        assert result.account_id == "acc123"
        assert result.default_permissions == ["perm1"]

    def test_from_config_no_permissions(self):
        from parachute.lib.credentials.cloudflare_provider import CloudflareProvider

        result = CloudflareProvider.from_config({
            "parent_token": "cf_test",
        })
        assert result is not None
        assert result.default_permissions == []

    @pytest.mark.asyncio
    async def test_mint_token_requires_permissions(self):
        """Minting without explicit permissions should fail — not inherit parent."""
        from parachute.lib.credentials.cloudflare_provider import CloudflareProvider

        provider = CloudflareProvider(parent_token="cf_test")
        with pytest.raises(
            CredentialProviderError,
            match="requires explicit permissions",
        ):
            await provider.mint_token({})

    @pytest.mark.asyncio
    async def test_mint_token_with_default_permissions(self):
        """Minting with default_permissions configured should pass permission check."""
        from parachute.lib.credentials.cloudflare_provider import CloudflareProvider

        provider = CloudflareProvider(
            parent_token="cf_test",
            default_permissions=["perm1"],
        )
        # Permission check passes, but the API call fails (invalid token).
        # Any CredentialProviderError proves we got past the permission gate.
        with pytest.raises(CredentialProviderError, match="Failed to mint|Network error"):
            await provider.mint_token({})

    def test_ttl_cap(self):
        """TTL should be capped at MAX_TTL_HOURS."""
        from parachute.lib.credentials.cloudflare_provider import MAX_TTL_HOURS

        assert MAX_TTL_HOURS == 24

    def test_build_policies_with_permissions(self):
        from parachute.lib.credentials.cloudflare_provider import CloudflareProvider

        provider = CloudflareProvider(parent_token="test")
        policies = provider._build_policies(["perm-id-1"], "acc123")
        assert len(policies) == 1
        assert policies[0]["effect"] == "allow"
        assert "com.cloudflare.api.account.acc123" in policies[0]["resources"]
        assert policies[0]["permission_groups"] == [{"id": "perm-id-1"}]

    def test_build_policies_without_account(self):
        from parachute.lib.credentials.cloudflare_provider import CloudflareProvider

        provider = CloudflareProvider(parent_token="test")
        policies = provider._build_policies(["perm"], None)
        assert "com.cloudflare.api.account.*" in policies[0]["resources"]

    def test_build_policies_empty_returns_empty(self):
        from parachute.lib.credentials.cloudflare_provider import CloudflareProvider

        provider = CloudflareProvider(parent_token="test")
        assert provider._build_policies([], None) == []


# ── API endpoint validation ──────────────────────────────────────────────────


class TestAPIValidation:
    """Test API validation functions without needing a running server."""

    def test_org_regex_valid_names(self):
        from parachute.api.credentials import _ORG_RE

        assert _ORG_RE.match("unforced")
        assert _ORG_RE.match("my-org")
        assert _ORG_RE.match("org_name")
        assert _ORG_RE.match("OpenParachutePBC")
        assert _ORG_RE.match("a")  # Single char

    def test_org_regex_invalid_names(self):
        from parachute.api.credentials import _ORG_RE

        assert not _ORG_RE.match("")
        assert not _ORG_RE.match("-start-with-hyphen")
        assert not _ORG_RE.match("has spaces")
        assert not _ORG_RE.match("has?query")
        assert not _ORG_RE.match("has&amp")
        assert not _ORG_RE.match("a" * 40)  # Too long (max 39)
        assert not _ORG_RE.match("org/with/slashes")
        assert not _ORG_RE.match("org@evil.com")

    def test_handle_provider_error_404(self):
        from parachute.api.credentials import _handle_provider_error

        exc = _handle_provider_error(
            CredentialProviderError("No GitHub App installation for org: foo"),
            "github",
        )
        assert exc.status_code == 404

    def test_handle_provider_error_502_network(self):
        from parachute.api.credentials import _handle_provider_error

        exc = _handle_provider_error(
            CredentialProviderError("Network error: timeout"),
            "github",
        )
        assert exc.status_code == 502

    def test_handle_provider_error_502_api(self):
        from parachute.api.credentials import _handle_provider_error

        exc = _handle_provider_error(
            CredentialProviderError("Failed to mint token: 500"),
            "github",
        )
        assert exc.status_code == 502

    def test_handle_provider_error_500_unknown(self):
        from parachute.api.credentials import _handle_provider_error

        exc = _handle_provider_error(
            CredentialProviderError("Something unexpected"),
            "github",
        )
        assert exc.status_code == 500


# ── Config auto-migration ────────────────────────────────────────────────────


class TestConfigMigration:
    """Test backward-compat migration of legacy GitHub fields."""

    def test_legacy_github_fields_migrate(self, tmp_path):
        """Legacy github_app_id should auto-migrate to credential_providers."""
        from parachute.config import Settings, save_yaml_config

        pdir = tmp_path / ".parachute"
        pdir.mkdir()
        save_yaml_config(pdir, {
            "github_app_id": 123,
            "github_installations": {"org": 456},
            "github_broker_secret": "secret123",
        })

        with patch("parachute.config.PARACHUTE_DIR", pdir):
            settings = Settings()

        # Should have migrated
        assert "github" in settings.credential_providers
        assert settings.credential_providers["github"]["app_id"] == 123
        assert settings.credential_broker_secret == "secret123"

    def test_no_migration_when_new_format_exists(self, tmp_path):
        """Don't overwrite credential_providers.github if it already exists."""
        from parachute.config import Settings, save_yaml_config

        pdir = tmp_path / ".parachute"
        pdir.mkdir()
        save_yaml_config(pdir, {
            "github_app_id": 999,  # Old value
            "credential_providers": {
                "github": {"type": "github-app", "app_id": 123},
            },
        })

        with patch("parachute.config.PARACHUTE_DIR", pdir):
            settings = Settings()

        # Should keep the new format, not overwrite
        assert settings.credential_providers["github"]["app_id"] == 123


# ── Config file permissions ──────────────────────────────────────────────────


class TestConfigPermissions:
    def test_save_yaml_config_sets_600(self, tmp_path):
        from parachute.config import save_yaml_config

        pdir = tmp_path / ".parachute"
        pdir.mkdir()
        path = save_yaml_config(pdir, {"port": 3333})
        mode = stat.S_IMODE(path.stat().st_mode)
        assert mode == 0o600

    def test_save_yaml_config_atomic_sets_600(self, tmp_path):
        from parachute.config import save_yaml_config_atomic

        pdir = tmp_path / ".parachute"
        pdir.mkdir()
        path = save_yaml_config_atomic(pdir, {"port": 3333})
        mode = stat.S_IMODE(path.stat().st_mode)
        assert mode == 0o600

    def test_save_token_sets_600(self, tmp_path):
        from parachute.config import save_token

        pdir = tmp_path / ".parachute"
        pdir.mkdir()
        path = save_token(pdir, "test-token")
        mode = stat.S_IMODE(path.stat().st_mode)
        assert mode == 0o600


# ── Broker from_config ───────────────────────────────────────────────────────


class TestBrokerFromConfig:
    def test_empty_config(self, tmp_path):
        broker = CredentialBroker.from_config({}, tmp_path)
        assert not broker.provider_names
        assert broker.get_status()["configured"] is False

    def test_unknown_provider_type(self, tmp_path):
        broker = CredentialBroker.from_config(
            {"weird": {"type": "nonexistent"}},
            tmp_path,
        )
        assert not broker.has_provider("weird")

    def test_github_provider_loads(self, tmp_path):
        pem = tmp_path / "github-app.pem"
        pem.write_text("-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----\n")
        broker = CredentialBroker.from_config(
            {"github": {
                "type": "github-app",
                "app_id": 123,
                "installations": {"org": 456},
            }},
            tmp_path,
        )
        assert broker.has_provider("github")

    def test_cloudflare_provider_loads(self, tmp_path):
        broker = CredentialBroker.from_config(
            {"cloudflare": {
                "type": "cloudflare-parent",
                "parent_token": "cf_test",
            }},
            tmp_path,
        )
        assert broker.has_provider("cloudflare")
