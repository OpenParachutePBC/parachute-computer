---
title: "Generalized Credential Broker"
type: feat
date: 2026-03-10
issue: 222
---

# Generalized Credential Broker

A provider-based credential system that replaces the flat `credentials.yaml` and the image-baked GitHub broker (PR #214) with a unified broker supporting multiple providers, per-project grants, and tools-volume deployment.

## Problem Statement

The current credential infrastructure has two problems:

1. **PR #214 bakes scripts into the Docker image** — Every credential change requires `docker build` + container recreation. The `gh` CLI, credential helper scripts, and `git config --system` are all in the Dockerfile.

2. **`credentials.yaml` is a flat bag** — No scoping, no per-project grants, no approval workflow. It injects the same env vars into every sandbox session regardless of project.

The tools volume (`/opt/parachute-tools/bin/`) is already mounted in every container with `bin/` first in PATH. Moving credential scripts there means no image rebuilds and immediate propagation to all running containers.

## Proposed Solution

### Architecture

```
~/.parachute/config.yaml          Server reads provider configs on startup
        │
        ▼
┌─────────────────┐
│  CredentialBroker │  ── registers providers, checks grants, mints tokens
│                   │
│  providers:       │
│    github:  GitHubAppProvider     (JWT → installation token)
│    cloudflare: CloudflareProvider (parent → child token)
└────────┬──────────┘
         │
         ▼
POST /api/credentials/{provider}/token?scope=...
         │
         ├── Check grant on Project record (403 if no grant)
         ├── Mint scoped token via provider backend
         └── Return token + expiry
```

### Provider System

Each provider implements a common interface:

```python
class CredentialProvider(ABC):
    """Base class for credential providers."""
    name: str           # e.g., "github", "cloudflare"
    provider_type: str  # e.g., "github-app", "cloudflare-parent"

    @abstractmethod
    async def mint_token(self, scope: dict) -> CredentialToken: ...

    @abstractmethod
    async def verify(self) -> dict: ...

    def get_scripts(self) -> dict[str, str]:
        """Return {filename: content} for scripts to deploy to tools volume."""
        return {}
```

### Grant Storage

Add `credential_grants_json` column to the `Project` Kuzu node table. Stores a JSON array:

```json
[
  {"provider": "github", "scope": {"org": "unforced"}, "granted_at": "2026-03-09T22:00:00Z"},
  {"provider": "cloudflare", "scope": {"account": "abc123"}, "granted_at": "2026-03-10T14:00:00Z"}
]
```

Column on the node (not a separate table) — this is a personal-scale tool, queryability isn't critical, and it keeps the schema simple.

### Tools Volume Script Deployment

On server startup (and after `parachute setup <provider>`), the server writes credential helper scripts to the `parachute-tools` Docker volume. All running containers see them immediately via the shared mount.

Scripts deployed:
- `/opt/parachute-tools/bin/github-token-helper.sh` — git credential helper
- `/opt/parachute-tools/bin/gh` — gh CLI wrapper (shadows `/usr/bin/gh`)

### Git Config via Environment Variables

Instead of `git config --system` in the Dockerfile, inject at `docker exec` time:

```python
exec_args.extend([
    "-e", "GIT_CONFIG_COUNT=2",
    "-e", "GIT_CONFIG_KEY_0=credential.helper",
    "-e", "GIT_CONFIG_VALUE_0=!/opt/parachute-tools/bin/github-token-helper.sh",
    "-e", "GIT_CONFIG_KEY_1=credential.useHttpPath",
    "-e", "GIT_CONFIG_VALUE_1=true",
])
```

Requires Git 2.31+ (sandbox image has 2.43+).

## Acceptance Criteria

- [x] Provider base class and registry in `parachute/lib/credentials/`
- [x] GitHub provider migrated from `github_app.py` into provider system
- [x] Cloudflare provider: parent token → scoped child token
- [x] Generalized broker endpoint: `POST /api/credentials/{provider}/token`
- [x] Grant storage on Project records (`credential_grants_json` column)
- [ ] Broker checks grants before minting (403 if no grant)
- [x] Credential helper scripts deployed to tools volume on startup
- [x] Git config injected via env vars (not `git config --system`)
- [ ] `gh` CLI installed via tools volume (not Dockerfile)
- [x] `parachute setup github` CLI command (interactive wizard)
- [x] `parachute setup cloudflare` CLI command (interactive wizard)
- [x] Dockerfile cleaned: no credential scripts, no git config --system
- [x] Config: `credential_providers` section in `~/.parachute/config.yaml`
- [x] Env injection: `BROKER_SECRET`, `GH_DEFAULT_ORG`, `CREDENTIAL_BROKER_URL` into containers
- [ ] One final image rebuild, then no more rebuilds for credential changes

## Implementation Phases

### Phase 1: Provider System & Generalized Broker

Refactor the GitHub broker from PR #214 into a provider-based system. This is pure backend restructuring — the existing GitHub flow keeps working.

**Files:**

| File | Action | Purpose |
|------|--------|---------|
| `parachute/lib/credentials/` | New directory | Provider system |
| `parachute/lib/credentials/__init__.py` | New | Exports |
| `parachute/lib/credentials/base.py` | New | `CredentialProvider` ABC, `CredentialToken` model |
| `parachute/lib/credentials/broker.py` | New | `CredentialBroker` — registry, grant check, dispatch |
| `parachute/lib/credentials/github_provider.py` | New | Migrate `GitHubAppBroker` → `GitHubProvider` |
| `parachute/lib/credentials/cloudflare_provider.py` | New | `CloudflareProvider` — parent → child token |
| `parachute/lib/github_app.py` | Delete | Absorbed into `github_provider.py` |
| `parachute/lib/credentials.py` | Delete | Replaced by provider system |
| `parachute/api/credentials.py` | Rewrite | Generalized `/{provider}/token` endpoint |
| `parachute/config.py` | Modify | Add `credential_providers` config section |

**Key changes:**

```python
# config.py — new fields
credential_providers: dict[str, dict] = Field(
    default_factory=dict,
    description="Provider configurations (github, cloudflare, etc.)",
)
credential_broker_secret: Optional[str] = Field(
    default=None,
    description="Bearer token for broker endpoint auth",
)

# Backward compat: if github_app_id exists in config, auto-migrate to
# credential_providers.github format on Settings load.
```

```python
# api/credentials.py — generalized endpoint
@router.post("/{provider}/token")
async def mint_token(request: Request, provider: str, scope: dict = Body(...)):
    _validate_broker_secret(request)
    broker = get_broker()
    grant = await broker.check_grant(project_slug, provider, scope)
    if not grant:
        raise HTTPException(403, "No credential grant for this project/provider")
    token = await broker.mint_token(provider, scope)
    return {"token": token.token, "expires_at": token.expires_at}
```

### Phase 2: Tools Volume Deployment

Move credential scripts from Docker image to the tools volume. One final image rebuild to remove baked-in scripts.

**Files:**

| File | Action | Purpose |
|------|--------|---------|
| `parachute/core/sandbox.py` | Modify | Add `_sync_credential_scripts()`, call from `reconcile()` |
| `parachute/docker/Dockerfile.sandbox` | Modify | Remove gh CLI install, credential scripts, git config --system |
| `parachute/docker/gh-wrapper.sh` | Move | To `parachute/lib/credentials/scripts/gh-wrapper.sh` |
| `parachute/docker/github-token-helper.sh` | Move | To `parachute/lib/credentials/scripts/github-token-helper.sh` |

**Script sync logic (sandbox.py):**

```python
async def _sync_credential_scripts(self) -> None:
    """Deploy credential helper scripts to the tools volume.

    Runs a temporary container with the volume mounted read-write,
    writes scripts, then removes the container.
    """
    scripts = self.broker.get_all_scripts()  # {filename: content}
    if not scripts:
        return

    # Use a temp container to write to the volume
    # (volume is mounted read-only in persistent containers)
    container = f"parachute-tools-sync-{uuid4().hex[:8]}"
    await _run([
        "docker", "run", "--rm", "--name", container,
        "--mount", f"source={TOOLS_VOLUME_NAME},target=/opt/parachute-tools",
        "alpine:3.19", "sh", "-c",
        # Write scripts and set permissions
        " && ".join(
            f"cat > /opt/parachute-tools/bin/{name} << 'SCRIPT_EOF'\n{content}\nSCRIPT_EOF\nchmod +x /opt/parachute-tools/bin/{name}"
            for name, content in scripts.items()
        ),
    ])
```

**Env injection (sandbox.py — both paths):**

```python
# Git config via env vars (replaces git config --system in Dockerfile)
if broker.has_provider("github"):
    exec_args.extend([
        "-e", "GIT_CONFIG_COUNT=2",
        "-e", "GIT_CONFIG_KEY_0=credential.helper",
        "-e", "GIT_CONFIG_VALUE_0=!/opt/parachute-tools/bin/github-token-helper.sh",
        "-e", "GIT_CONFIG_KEY_1=credential.useHttpPath",
        "-e", "GIT_CONFIG_VALUE_1=true",
    ])

# Broker auth
if broker_secret:
    exec_args.extend(["-e", f"BROKER_SECRET={broker_secret}"])
    exec_args.extend(["-e", f"GH_DEFAULT_ORG={default_org}"])
```

**gh CLI install via tools volume:**

The `gh` binary gets installed to the tools volume during sync instead of being baked into the Dockerfile. The gh wrapper script at `/opt/parachute-tools/bin/gh` naturally shadows it via PATH.

### Phase 3: Cloudflare Provider & Grants

Add the Cloudflare provider and wire up per-project grant checking.

**Files:**

| File | Action | Purpose |
|------|--------|---------|
| `parachute/lib/credentials/cloudflare_provider.py` | New | Parent token → child token minting |
| `parachute/db/brain_sessions.py` | Modify | Add `credential_grants_json` to Project schema |
| `parachute/models/session.py` | Modify | Add `credential_grants` to Project model |
| `parachute/api/projects.py` | Modify | Add grant management endpoints |

**Cloudflare provider:**

```python
class CloudflareProvider(CredentialProvider):
    name = "cloudflare"
    provider_type = "cloudflare-parent"

    def __init__(self, parent_token: str):
        self.parent_token = parent_token

    async def mint_token(self, scope: dict) -> CredentialToken:
        """Mint a scoped child API token via Cloudflare API."""
        # POST https://api.cloudflare.com/client/v4/user/tokens
        policies = self._build_policies(scope)
        expires = datetime.utcnow() + timedelta(hours=8)
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                "https://api.cloudflare.com/client/v4/user/tokens",
                headers={"Authorization": f"Bearer {self.parent_token}"},
                json={
                    "name": f"parachute-{scope.get('account', 'default')}-{uuid4().hex[:6]}",
                    "policies": policies,
                    "not_before": datetime.utcnow().isoformat() + "Z",
                    "expires_on": expires.isoformat() + "Z",
                },
            )
            resp.raise_for_status()
        data = resp.json()["result"]
        return CredentialToken(token=data["value"], expires_at=expires.isoformat())
```

**Grant checking in broker:**

```python
async def check_grant(self, project_slug: str, provider: str, scope: dict) -> bool:
    """Check if a project has a grant for this provider+scope."""
    project = await self.db.get_project(project_slug)
    if not project or not project.credential_grants:
        return False
    return any(
        g["provider"] == provider and self._scope_matches(g["scope"], scope)
        for g in project.credential_grants
    )
```

### Phase 4: CLI Setup Commands

Interactive wizards for configuring providers.

**Files:**

| File | Action | Purpose |
|------|--------|---------|
| `parachute/cli.py` | Modify | Add `setup` subcommand with `github` and `cloudflare` subcommands |

**`parachute setup github`:**
1. Prompt for App ID
2. Prompt for PEM file path (copy to `~/.parachute/github-app.pem`)
3. Verify app (get slug, show name)
4. Show install URL: `https://github.com/apps/{slug}/installations/new`
5. Auto-discover installations via API
6. Generate broker secret (random hex)
7. Write to `~/.parachute/config.yaml`
8. Sync scripts to tools volume
9. Mint test token to verify

**`parachute setup cloudflare`:**
1. Prompt for parent API token
2. Verify token (list accounts via API)
3. Show accounts found
4. Write to `~/.parachute/config.yaml`
5. Sync scripts (none needed for env-based injection)

## Technical Considerations

### Backward Compatibility

The `feat/credential-broker` branch (PR #214) has GitHub-specific config fields (`github_app_id`, `github_installations`, `github_broker_secret`). These get absorbed into the `credential_providers` section:

```yaml
# Old (PR #214):
github_app_id: 3051015
github_installations:
  unforced: 115215642
github_broker_secret: abc123

# New:
credential_providers:
  github:
    type: github-app
    app_id: 3051015
    installations:
      unforced: 115215642
credential_broker_secret: abc123
```

The Settings class should accept both formats during transition.

### Security

- Broker secret uses constant-time comparison (existing from PR #214)
- Credential scripts never log token values
- Parent tokens stored in `~/.parachute/config.yaml` with `0600` permissions
- PEM files stored separately at `~/.parachute/github-app.pem` (not in config)
- Bot sessions (Telegram/Discord) never receive credentials (existing gate)
- Cloudflare child tokens are scoped + time-limited (8h default)

### Tools Volume Write Strategy

The tools volume is mounted **read-only** in persistent containers. To write scripts:
1. Run a temporary `alpine` container with the volume mounted **read-write**
2. Write scripts via `docker run --rm`
3. All persistent containers see changes immediately (shared volume)

This runs during `reconcile()` (server startup) and after `parachute setup <provider>`.

### Injection Paths

| Injection | Mechanism | When |
|-----------|-----------|------|
| Git credential helper | `GIT_CONFIG_COUNT` env vars at `docker exec` | Every session |
| `gh` CLI auth | gh wrapper script on tools volume reads `BROKER_SECRET` | Every `gh` invocation |
| Cloudflare | `CLOUDFLARE_API_TOKEN` env var at `docker exec` | Sessions with CF grant |
| Broker secret |`BROKER_SECRET` env var at `docker exec` | Every session |
| Default org | `GH_DEFAULT_ORG` env var at `docker exec` | Every session |

## Dependencies & Risks

- **PyJWT[crypto]** — Already in PR #214 for GitHub JWT signing. Needs to be added to `pyproject.toml`.
- **httpx** — Already a dependency.
- **Cloudflare API stability** — The `POST /user/tokens` endpoint for creating child tokens is stable. The permission group names may change (use exact IDs when possible).
- **One-time image rebuild** — After Phase 2, the Dockerfile is slimmed down. All existing containers will need recreation (config hash bump handles this).

## Open Questions (Resolved)

1. **Grant storage format** → Column on Project node (`credential_grants_json: STRING`). Simpler, adequate for personal-scale.

2. **Script syncing trigger** → Both on server startup (`reconcile()`) and after `parachute setup <provider>`. Setup calls sync directly.

3. **Cloudflare scope model** → Start with raw permission IDs from Cloudflare API. Add templates later if needed — the grant just stores what was approved.

## References

- Brainstorm: `docs/brainstorms/2026-03-10-credential-broker-v2-brainstorm.md`
- PR #214: GitHub-specific broker (to be absorbed)
- [Cloudflare API: Create Token](https://developers.cloudflare.com/api/resources/user/subresources/tokens/methods/create/)
- [GitHub Apps: Installation Tokens](https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app)
- [Git `GIT_CONFIG_*` env vars](https://git-scm.com/docs/git-config#_environment)
