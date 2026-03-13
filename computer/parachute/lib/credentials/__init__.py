"""
Credential broker system — provider-based credential management.

Provides short-lived, scoped credentials to sandboxed containers via
transparent credential helpers. Agents never see raw credentials.

Architecture:
  - Providers: know how to mint tokens (GitHub App, Cloudflare, etc.)
  - Broker: registry of providers, grant checking, token dispatch
  - Scripts: credential helper scripts deployed to the tools volume
"""

from parachute.lib.credentials.base import (
    CredentialProvider,
    CredentialProviderError,
    CredentialToken,
)
from parachute.lib.credentials.broker import CredentialBroker, get_broker, reset_broker
from parachute.lib.credentials.credential_loader import load_credentials

__all__ = [
    "CredentialBroker",
    "CredentialProvider",
    "CredentialProviderError",
    "CredentialToken",
    "get_broker",
    "load_credentials",
    "reset_broker",
]
