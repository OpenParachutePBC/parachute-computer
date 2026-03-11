---
title: "feat: GitHub credential broker for sandboxed sessions"
type: feat
date: 2026-03-09
issue: 213
---

# GitHub Credential Broker for Sandboxed Sessions

## Overview

Add a credential broker to Parachute Computer that lets sandboxed Docker sessions push to GitHub, create PRs, and clone private repos — without ever exposing tokens to the agent process. The agent uses `git push` and `gh pr create` normally; transparent credential helpers intercept calls, fetch short-lived tokens from the broker, and inject them invisibly.

## Problem

Sandboxed containers have no GitHub credentials. The existing `credentials.yaml` system can inject tokens via stdin → `os.environ`, but those are long-lived PATs visible to the agent process. A compromised or misbehaving agent can read, log, or exfiltrate them.

## Solution

A GitHub App credential broker built into the existing FastAPI server. The user registers a GitHub App (free, 2 minutes), installs it on their repos/orgs, and drops the private key at `~/.parachute/github-app.pem`. Parachute mints short-lived (1-hour) installation tokens on demand via a new API endpoint. Shell scripts in the sandbox image transparently intercept `git` and `gh` operations and authenticate via the broker.

**Prior art:** [lucianHymer/borg](https://github.com/lucianHymer/borg) — battle-tested implementation of this exact pattern.

**v1 security model:** The GitHub App installation is the security boundary. You only install it on repos you want agents to access. Per-project scoping (v2) deferred.

## Acceptance Criteria

- [x] `git push` works from a sandboxed container without any token in `os.environ`
- [x] `gh pr create` works from a sandboxed container
- [x] Tokens are short-lived (1 hour), cached, and never exposed to the agent
- [x] `parachute setup github` CLI command walks through GitHub App creation
- [x] Works with multiple orgs/installations
- [x] Existing `credentials.yaml` flow unchanged (this is additive)

## Implementation

### Phase 1: GitHub App token minting service

New module at `computer/parachute/lib/github_app.py`:
- Read PEM private key from `~/.parachute/github-app.pem`
- Read installation mappings from config (`github_installations` in `config.yaml`)
- Sign JWT (RS256, `iss=app_id`, 10-min expiry, 60s backdated for clock drift)
- Exchange JWT for installation token via `POST /app/installations/{id}/access_tokens`
- Cache tokens in-memory, refresh 5 minutes before expiry
- Dependencies: `PyJWT` + `cryptography` (minimal — no GitHub SDK needed)

```yaml
# ~/.parachute/config.yaml additions
github_app_id: 123456
github_installations:
  OpenParachutePBC: 98765
  personal-username: 11111
```

**Config changes** in `computer/parachute/config.py`:
- Add `github_app_id: Optional[int]` field to `Settings`
- Add `github_installations: dict[str, int]` field (org → installation_id)
- Add `github_app_pem_path` property (defaults to `~/.parachute/github-app.pem`)
- Add these to `CONFIG_KEYS` set

### Phase 2: Broker API endpoint

New route module at `computer/parachute/api/credentials.py`:

```
GET /api/credentials/github/token?installation_id=98765
Authorization: Bearer <broker_secret>
→ {"token": "ghs_...", "expires_at": "2026-03-09T01:00:00Z"}
```

- Register in `api/__init__.py` like other routers
- Bearer token auth: validate against a broker secret generated at first setup and stored in `config.yaml`
- Look up installation_id, mint/return cached token
- 401 for bad auth, 400 for missing installation_id, 404 for unknown installation

Also add a convenience endpoint for the credential helper to resolve org → installation_id:

```
GET /api/credentials/github/installation?org=OpenParachutePBC
Authorization: Bearer <broker_secret>
→ {"installation_id": 98765}
```

This lets the credential helper scripts avoid needing a local copy of the installations mapping.

### Phase 3: Sandbox credential helpers

Two shell scripts added to the Docker image:

**`computer/parachute/docker/github-token-helper.sh`** — git credential helper:
- Called by git when it needs auth for `github.com`
- Parses org from repo path in stdin
- Calls `GET http://host.docker.internal:3333/api/credentials/github/installation?org=X` to resolve installation_id
- Calls `GET http://host.docker.internal:3333/api/credentials/github/token?installation_id=Y`
- Outputs `protocol=https`, `host=github.com`, `username=x-access-token`, `password=<token>`
- Bearer auth using `$BROKER_SECRET` env var

**`computer/parachute/docker/gh-wrapper.sh`** — gh CLI wrapper:
- Auto-detects org from `git remote get-url origin`
- Fetches token from broker (same as credential helper)
- Execs real `gh` with `GH_TOKEN=<token>`

**Dockerfile.sandbox changes:**
- Install GitHub CLI (`gh`) — currently not in the image
- `COPY github-token-helper.sh /usr/local/bin/`
- `COPY gh-wrapper.sh /usr/local/bin/`
- `RUN chmod +x /usr/local/bin/github-token-helper.sh /usr/local/bin/gh-wrapper.sh`
- `RUN git config --system credential.helper '!/usr/local/bin/github-token-helper.sh'`
- `RUN mv /usr/bin/gh /usr/bin/gh-real && ln -sf /usr/local/bin/gh-wrapper.sh /usr/bin/gh`

**Broker secret injection:**
- Generated once during `parachute setup github` (random 32-byte hex)
- Stored in `config.yaml` as `github_broker_secret`
- Passed to container via the existing stdin credential mechanism: `{"credentials": {"BROKER_SECRET": "..."}}`
- Entrypoint applies it to `os.environ` as today — the credential helpers read `$BROKER_SECRET`

### Phase 4: Setup CLI

New CLI command: `parachute setup github`

Interactive flow:
1. Check if GitHub App is already configured (PEM exists + app_id in config)
2. If not, walk the user through:
   - "Create a GitHub App at https://github.com/settings/apps/new"
   - Print recommended settings (name, permissions, no webhook)
   - Prompt for App ID
   - Prompt for PEM file path (or paste contents)
   - Save PEM to `~/.parachute/github-app.pem` (mode 0600)
3. Prompt for installations:
   - "Install the app on your GitHub orgs/accounts, then enter the installation IDs"
   - Link to `https://github.com/settings/installations` to find IDs
   - Save to `config.yaml` as `github_installations: {org: id}`
4. Generate broker secret (random 32-byte hex), save to `config.yaml`
5. Verify: mint a test token for the first installation to confirm everything works
6. Remind user to rebuild sandbox image: `parachute sandbox build`

**Recommended GitHub App permissions** (documented in setup output):
- `contents: write` — push commits, clone private repos
- `pull_requests: write` — create/update PRs
- `issues: write` — create/update issues
- `metadata: read` — required by GitHub
- `workflows: write` — optional, only if agents modify `.github/workflows/`

## Dependencies

- `PyJWT` — JWT signing (RS256). Already has `cryptography` as a dependency for RS256.
- `cryptography` — PEM key loading (comes with PyJWT[crypto])

Add to `computer/requirements.txt`:
```
PyJWT[crypto]>=2.8.0
```

## Files Changed

| File | Change |
|------|--------|
| `computer/parachute/lib/github_app.py` | **New** — Token minting, caching, PEM loading |
| `computer/parachute/api/credentials.py` | **New** — `/api/credentials/github/token` endpoint |
| `computer/parachute/api/__init__.py` | Register credentials router |
| `computer/parachute/config.py` | Add `github_app_id`, `github_installations`, `github_broker_secret` fields |
| `computer/parachute/core/sandbox.py` | Inject `BROKER_SECRET` into container env |
| `computer/parachute/docker/Dockerfile.sandbox` | Install `gh`, add credential helper scripts, configure git |
| `computer/parachute/docker/github-token-helper.sh` | **New** — Git credential helper |
| `computer/parachute/docker/gh-wrapper.sh` | **New** — gh CLI wrapper |
| `computer/parachute/cli/setup.py` | **New** — `parachute setup github` command |
| `computer/requirements.txt` | Add `PyJWT[crypto]` |

## Technical Considerations

- **Networking:** All sandboxed containers have network access via the existing `parachute-sandbox` bridge. Credential helpers reach the broker at `host.docker.internal:3333`. No special network configuration needed.
- **macOS + Docker Desktop:** `host.docker.internal` resolves correctly on Docker Desktop, OrbStack, and Colima. No issues expected.
- **Token caching:** In-memory dict keyed by installation_id. Refresh 5 min before expiry. No persistence needed — tokens are cheap to mint.
- **Broker secret scope:** The broker secret is a shared secret between the host and all containers. Any container with the secret can request tokens for any configured installation. This is acceptable for v1 (single-user system). Per-project scoping is v2.
- **Image rebuild required:** Adding credential helpers to the Dockerfile means users must rebuild: `parachute sandbox build`. The setup CLI should remind them.
- **Fallback:** If GitHub App is not configured, nothing changes. Existing `credentials.yaml` with `GH_TOKEN` still works. This is purely additive.

## Out of Scope (v2)

- Per-project repo scoping (Flutter UI for project settings)
- GitHub App manifest flow (one-click App creation via local web server)
- Other credential types (AWS, npm, etc.)
- Token usage auditing / logging
