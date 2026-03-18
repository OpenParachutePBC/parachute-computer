"""
Self-describing credential helper manifest.

Each credential helper declares what it needs (setup fields), what it
provides (env vars, scripts), and how to check its health. The manifest
is serializable to JSON for the Flutter app to consume via API — the
app renders setup forms, scope toggles, and health indicators generically.

This is the protocol that makes the credential system extensible without
hardcoding provider-specific UI or logic.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(slots=True)
class SetupField:
    """A single field in a credential helper's setup form.

    Rendered by the app as a text input, secret input, file picker, etc.
    """

    id: str
    label: str
    type: str = "string"  # "string", "secret", "file", "select"
    help: str = ""
    required: bool = True
    options: list[str] | None = None  # For "select" type


@dataclass(slots=True)
class SetupMethod:
    """One way to configure a credential helper.

    A helper may offer multiple methods (e.g., GitHub supports both
    Personal Access Token and GitHub App). The UI shows all methods
    and lets the user pick one.
    """

    id: str
    label: str
    fields: list[SetupField] = field(default_factory=list)
    recommended: bool = False
    help: str = ""


@dataclass(slots=True)
class ProviderCapabilities:
    """What the helper injects into sandbox containers."""

    env_vars: list[str] = field(default_factory=list)
    scripts: list[str] = field(default_factory=list)
    git_config: dict[str, str] = field(default_factory=dict)


@dataclass(slots=True)
class HealthCheck:
    """How to verify the helper's credentials are valid."""

    method: str = "api"  # "api", "token_verify", "none"
    endpoint: str = ""
    description: str = ""


@dataclass(slots=True)
class HelperManifest:
    """Complete self-description of a credential helper.

    The app UI renders entirely from this manifest — no per-provider
    hardcoding needed. A community-contributed Vercel helper gets the
    same UI treatment as the built-in GitHub helper.
    """

    display_name: str
    description: str
    setup_methods: list[SetupMethod] = field(default_factory=list)
    provides: ProviderCapabilities = field(default_factory=ProviderCapabilities)
    health_check: HealthCheck = field(default_factory=HealthCheck)

    def to_dict(self) -> dict[str, Any]:
        """Serialize to JSON-compatible dict for the API."""
        return {
            "display_name": self.display_name,
            "description": self.description,
            "setup_methods": [
                {
                    "id": m.id,
                    "label": m.label,
                    "recommended": m.recommended,
                    "help": m.help,
                    "fields": [
                        {
                            "id": f.id,
                            "label": f.label,
                            "type": f.type,
                            "help": f.help,
                            "required": f.required,
                            **({"options": f.options} if f.options else {}),
                        }
                        for f in m.fields
                    ],
                }
                for m in self.setup_methods
            ],
            "provides": {
                "env_vars": self.provides.env_vars,
                "scripts": self.provides.scripts,
                "git_config": self.provides.git_config,
            },
            "health_check": {
                "method": self.health_check.method,
                "endpoint": self.health_check.endpoint,
                "description": self.health_check.description,
            },
        }
