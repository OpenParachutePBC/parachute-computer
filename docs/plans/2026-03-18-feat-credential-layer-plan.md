---
title: "Credential Layer for Sandboxed AI Agents"
type: feat
date: 2026-03-18
issue: 291
supersedes: [225, 226]
---

# Credential Layer for Sandboxed AI Agents

A protocol-driven credential system that replaces the hardcoded GitHub App + Cloudflare token injection with an extensible layer supporting any service.

## Problem Statement

The current credential broker has two hardcoded providers at different maturity levels:
- **GitHub**: Full credential helper architecture (scripts call broker API, broker mints App installation tokens) — but breaks across orgs (moving a repo from `unforced` to `unforced-dev` causes silent 403s) and requires complex App setup
- **Cloudflare**: Raw parent token injected as env var — no scoping, no child token minting, missing discovery permissions confuse wrangler

There's no path for adding new services, no UI for credential management, no runtime consent model, and no audit trail.

## Proposed Solution

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Flutter App                                                │
│  ┌─────────────────┐  ┌──────────────────────────────────┐  │
│  │ Credential Setup │  │ Runtime Consent (from SSE/MCP)   │  │
│  │ (generic from    │  │ "Grant write access to           │  │
│  │  helper manifest)│  │  unforced-dev/repo?" [Allow]     │  │
│  └────────┬────────┘  └──────────────┬───────────────────┘  │
└───────────┼──────────────────────────┼──────────────────────┘
            │ POST /api/credentials     │ POST /api/credentials
            │      /setup               │      /consent
            ▼                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Parachute Server                                           │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Credential Broker (refactored)                       │   │
│  │  ├─ HelperRegistry  (loads helper manifests)         │   │
│  │  ├─ TokenStore      (minted tokens per session)      │   │
│  │  └─ AuditLog        (who used what when)             │   │
│  ├──────────────────────────────────────────────────────┤   │
│  │ Credential Helpers (self-describing)                 │   │
│  │  ├─ GitHubHelper    (PAT default, App advanced)      │   │
│  │  ├─ CloudflareHelper (child token minting)           │   │
│  │  └─ GenericEnvHelper (any KEY=VALUE passthrough)     │   │
│  ├──────────────────────────────────────────────────────┤   │
│  │ Injection Layer                                      │   │
│  │  ├─ Git credential helper script                     │   │
│  │  ├─ PATH wrapper scripts (gh, wrangler, etc.)        │   │
│  │  └─ Static env var injection                         │   │
│  └──────────────────────────────────────────────────────┘   │
│                           │                                  │
│                    docker exec -e / stdin / env-file         │
│                           ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Sandbox Container                                    │   │
│  │  /opt/parachute-tools/bin/  (credential scripts)     │   │
│  │  $GH_TOKEN, $CLOUDFLARE_API_TOKEN, etc. (env vars)  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**Key principle**: Credentials never enter the LLM context window. MCP handles capability negotiation; the broker API handles credential transmission out-of-band.

### Self-Describing Helper Protocol

Each credential helper is a Python class that extends `CredentialProvider` with a manifest:

```python
class GitHubHelper(CredentialProvider):
    name = "github"
    manifest = HelperManifest(
        display_name="GitHub",
        description="Git operations and GitHub API access",
        setup_methods=[
            SetupMethod(
                id="personal-token",
                label="Personal Access Token",
                recommended=True,
                fields=[
                    SetupField(id="token", label="Token", type="secret",
                               help="Create at github.com/settings/tokens"),
                ],
            ),
            SetupMethod(
                id="github-app",
                label="GitHub App (Advanced)",
                fields=[
                    SetupField(id="app_id", label="App ID", type="string"),
                    SetupField(id="private_key", label="Private Key (.pem)", type="file"),
                ],
            ),
        ],
        provides=ProviderCapabilities(
            env_vars=["GH_TOKEN", "GH_DEFAULT_ORG"],
            scripts=["github-token-helper.sh", "gh-wrapper.sh"],
            git_config={"credential.helper": "...", "credential.useHttpPath": "true"},
        ),
        health_check=HealthCheck(
            method="api",  # or "token_verify"
            endpoint="https://api.github.com/user",
        ),
    )
```

The manifest is serializable to JSON for the Flutter app to consume via API.

### Three Injection Mechanisms

Every CLI tool checks env vars first. The system uses three mechanisms:

| Mechanism | Tools | How It Works |
|-----------|-------|-------------|
| **Git credential helper** | `git` | Script in `/opt/parachute-tools/bin/` calls broker API, returns token in git credential format |
| **PATH wrapper scripts** | `gh`, `wrangler`, `vercel`, etc. | Wrapper calls broker API, sets env var, execs real binary |
| **Static env var injection** | Any CLI | Token set in container env at launch via `--env-file` or `docker exec -e` |

Each helper declares which mechanism(s) it uses. The injection layer builds the right env vars and scripts automatically.

## Acceptance Criteria

### Phase 1: Protocol + PAT Support
- [x] `HelperManifest` dataclass defined with setup methods, capabilities, health check
- [x] `GitHubHelper` supports both `personal-token` (new) and `github-app` (existing) methods
- [x] PAT method: stores token in config, returns it from`mint_token()`, git credential helper and gh wrapper work unchanged
- [x] `GET /api/credentials/helpers` returns manifest JSON for all registered helpers
- [x] `POST /api/credentials/setup` accepts helper name + method + fields, validates, saves to config
- [x] `GET /api/credentials/status` returns per-helper health check results
- [x] Existing GitHub App flow continues to work (backward compatible)
- [x] `parachute setup github` CLI wizard offers PAT as default, App as advanced option

### Phase 2: Cloudflare + Generic Helpers
- [x] `CloudflareHelper` mints scoped child tokens (existing `mint_token()` logic) instead of injecting parent token
- [x] `CloudflareHelper` injects `CLOUDFLARE_ACCOUNT_ID` alongside the token
- [x] `CloudflareHelper` has a PATH wrapper for `wrangler` that calls broker API (instead of reading env var directly)
- [x] `GenericEnvHelper` for arbitrary `KEY=VALUE` credentials (replaces `credentials.yaml` flat file)
- [x] Each `GenericEnvHelper` entry declares its env var name and optional health check URL
- [x] Sandbox `_build_credential_env_vars()` refactored to iterate helpers generically (no `isinstance` checks)

### Phase 3: App UI
- [x] Settings screen: "Credentials" section showing all configured helpers with status indicators
- [x] Setup flow: renders fields from helper manifest (generic, not hardcoded per service)
- [x] Health indicators: green/red/yellow per helper based on `verify()` results
- [x] Add/remove credential helpers from the UI
- [x] Token visibility: show what env vars / scripts each helper injects (for transparency)

### Phase 4: Runtime Consent (Future)
- [ ] MCP tool `request_access()` for credential escalation requests
- [ ] Consent notification surfaced in Flutter app via SSE
- [ ] Broker mints scoped token on approval, injects into running container
- [ ] Audit log: session ID, helper, scope, timestamp, result

## Technical Considerations

### Backward Compatibility

The current config format must continue to work:

```yaml
# OLD — still works
credential_providers:
  github:
    type: github-app
    app_id: 3051015
    installations:
      unforced: 115215642
  cloudflare:
    type: cloudflare-parent
    parent_token: cf_xxxx

# NEW — also works
credential_providers:
  github:
    type: personal-token          # new method
    token: ghp_xxxxxxxxxxxx
  cloudflare:
    type: cloudflare-parent
    parent_token: cf_xxxx
    account_id: abc123            # now required for wrangler discovery
```

`from_config()` in the broker maps `type` to the appropriate helper + method.

### GitHub PAT vs App Token in the Credential Helper

The git credential helper (`github-token-helper.sh`) currently calls `GET /api/credentials/github/token?org=ORG`. With PAT support, the broker endpoint behavior changes:

- **App method**: Broker looks up installation ID for the org, mints an App token (current behavior)
- **PAT method**: Broker returns the stored PAT regardless of org (org is logged for audit but not used for lookup)

The helper script and gh wrapper don't need to change — the broker API response shape is identical.

### Cloudflare Child Token Minting

The existing `CloudflareProvider.mint_token()` already works but is never called. The fix:

1. Add a wrangler PATH wrapper script (`/opt/parachute-tools/bin/wrangler`) that calls the broker API
2. Broker calls `CloudflareProvider.mint_token()` to get a scoped child token
3. Wrapper injects the child token as `CLOUDFLARE_API_TOKEN` and execs real wrangler
4. Also inject `CLOUDFLARE_ACCOUNT_ID` to skip the `/memberships` discovery call

### GenericEnvHelper for credentials.yaml Migration

The current `credentials.yaml` flat file becomes the backing store for `GenericEnvHelper` entries. Each entry is a helper instance:

```yaml
# OLD
# ~/.parachute/credentials.yaml
VERCEL_TOKEN: ver_xxxxxxxx
FLY_API_TOKEN: fo1_xxxxxxxx

# NEW — auto-migrated to credential_providers
credential_providers:
  vercel:
    type: env-passthrough
    env_var: VERCEL_TOKEN
    token: ver_xxxxxxxx
  fly:
    type: env-passthrough
    env_var: FLY_API_TOKEN
    token: fo1_xxxxxxxx
```

Migration: on startup, if `credentials.yaml` exists, load entries as `env-passthrough` helpers. Write to new config format. Delete the flat file (or keep as fallback).

### Sandbox Injection Refactor

`_build_credential_env_vars()` currently has `isinstance` checks for `GitHubProvider` and `CloudflareProvider`. Refactor to:

```python
def _build_credential_env_vars(self, include_secret: bool = True) -> list[str]:
    broker = get_credential_broker()
    env_lines = []
    if include_secret and broker_secret:
        env_lines.append(f"BROKER_SECRET={broker_secret}")

    for helper in broker.helpers():
        env_lines.extend(helper.get_env_vars())

    return env_lines
```

Each helper's `get_env_vars()` returns the appropriate lines based on its method (git config, env vars, etc.).

### API Endpoints

New/modified endpoints:

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/credentials/helpers` | List all helper manifests (for app UI) |
| `POST` | `/api/credentials/setup` | Configure a helper (name, method, fields) |
| `DELETE` | `/api/credentials/{name}` | Remove a configured helper |
| `GET` | `/api/credentials/status` | Health check all configured helpers |
| `GET` | `/api/credentials/{provider}/token` | Mint/return token (existing, unchanged) |

### File Structure

```
parachute/lib/credentials/
├── base.py                    # CredentialProvider (unchanged)
├── manifest.py                # NEW: HelperManifest, SetupMethod, SetupField, etc.
├── broker.py                  # Refactored: generic helper loading, no isinstance
├── helpers/                   # NEW: directory for built-in helpers
│   ├── __init__.py
│   ├── github.py              # GitHubHelper (PAT + App methods)
│   ├── cloudflare.py          # CloudflareHelper (child token minting)
│   └── generic_env.py         # GenericEnvHelper (KEY=VALUE passthrough)
├── scripts/                   # Existing: shell scripts for tools volume
│   ├── github-token-helper.sh
│   ├── gh-wrapper.sh
│   └── wrangler-wrapper.sh    # NEW
├── credential_loader.py       # Existing: credentials.yaml (deprecated, migration)
└── setup_wizard.py            # Existing: CLI setup commands
```

## Implementation Phases

### Phase 1: Protocol + GitHub PAT (1-2 days)

**Goal**: Define the helper protocol, add PAT support for GitHub, fix the immediate cross-org problem.

1. Create `manifest.py` with `HelperManifest`, `SetupMethod`, `SetupField`, `ProviderCapabilities`, `HealthCheck` dataclasses
2. Create `helpers/github.py` — `GitHubHelper` extending `CredentialProvider` with manifest, supporting both `personal-token` and `github-app` methods
3. Update `broker.py` `from_config()` to recognize `type: personal-token` and create the PAT variant
4. Update `parachute setup github` CLI to offer PAT as default choice
5. Add `GET /api/credentials/helpers` endpoint returning manifest JSON
6. Add `POST /api/credentials/setup` endpoint for programmatic configuration
7. Tests for PAT method, manifest serialization, broker config loading

### Phase 2: Cloudflare + Generic + Refactor (1-2 days)

**Goal**: Cloudflare gets proper child tokens, generic passthrough replaces credentials.yaml, sandbox injection becomes generic.

1. Create `helpers/cloudflare.py` — move existing `CloudflareProvider` logic, add wrangler wrapper script
2. Create `helpers/generic_env.py` — `GenericEnvHelper` for arbitrary env vars
3. Add `scripts/wrangler-wrapper.sh` — calls broker API, injects token, execs real wrangler
4. Refactor `_build_credential_env_vars()` to iterate helpers generically
5. Add `credentials.yaml` → `credential_providers` migration path
6. Tests for Cloudflare child token minting, wrapper scripts, migration

### Phase 3: App UI (2-3 days)

**Goal**: Credential management in the Flutter settings screen.

1. Add `CredentialService` in Flutter — talks to `/api/credentials/helpers`, `/setup`, `/status`
2. Create `CredentialSection` widget in settings — lists configured helpers with health status
3. Create `CredentialSetupDialog` — renders setup fields from manifest JSON generically
4. Wire up add/remove/configure flows
5. Status indicators: green check for healthy, red X for failed, yellow warning for expiring

### Phase 4: Runtime Consent (future, not in this plan)

Tracked separately — requires MCP `listChanged` testing with Claude SDK, elicitation support in the Flutter MCP client, and consent-to-injection pipeline.

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| Breaking existing GitHub App users | Backward-compatible config parsing; `github-app` type still works |
| Cloudflare child token minting may fail without permission group IDs | `parachute setup cloudflare` must guide users to configure groups; fall back to parent token with warning |
| PATH wrapper latency for wrangler | Cache tokens in file with flock, 2s HTTP timeout, fail-open to proceed without token |
| `credentials.yaml` migration | Keep old loader as fallback during transition; warn but don't break |

## References

- Brainstorm: `docs/brainstorms/2026-03-18-credential-layer-brainstorm.md`
- Existing code: `computer/parachute/lib/credentials/`
- Related issues: #225 (credential UI), #226 (Cloudflare scoped tokens) — both superseded by this plan
- Current config: `~/.parachute/config.yaml` under `credential_providers`
