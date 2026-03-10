# Generalized Credential Broker

**Status:** Brainstorm
**Priority:** P2
**Labels:** computer, app
**Issue:** #222

---

## What We're Building

A generalized credential broker that replaces the current flat `credentials.yaml` and the GitHub-specific broker (PR #214) with a unified, provider-based system. The system supports per-project credential grants with both pre-configuration and just-in-time approval, and deploys credential helper scripts via the shared tools volume instead of baking them into the Docker image.

### Core Concepts

**Three things:**
- **Providers** — what credentials exist and how to mint tokens (GitHub App, Cloudflare parent token, AWS role, static env vars)
- **Grants** — what's allowed per project (stored on project records)
- **Broker** — enforces grants and mints tokens at runtime

### Provider Config

Replaces `credentials.yaml`. Lives in `~/.parachute/config.yaml`:

```yaml
credential_providers:
  github:
    type: github-app
    app_id: 3051015
    # pem at ~/.parachute/github-app.pem

  cloudflare:
    type: cloudflare-parent
    parent_token: cf_xxxx

  aws:
    type: aws-role
    role_arn: arn:aws:iam::123:role/parachute

  # Escape hatch — static env vars, no minting
  static:
    NODE_AUTH_TOKEN: npm_xxxx
```

### Project Grants

Stored on the Project record (Kuzu `Project` node or related table):

```yaml
credential_grants:
  - provider: github
    scope: {org: unforced}
    granted_at: 2026-03-09T22:00:00Z
  - provider: cloudflare
    scope: {account: abc123, permissions: [workers_scripts:write]}
    granted_at: 2026-03-10T14:00:00Z
```

Pre-configured or JIT-approved, both create the same grant shape.

### Inline JIT Approval

When a sandbox agent needs credentials that aren't yet granted, the broker surfaces an approval card inline in the active chat:

```
Agent: I've committed the changes. Pushing to GitHub...

┌──────────────────────────────────────────┐
│ 🔑  Credential Request                  │
│                                          │
│  learnvibe.build needs:                  │
│  GitHub · push to unforced               │
│                                          │
│  [Approve]  [Approve for this project]   │
└──────────────────────────────────────────┘

Agent: Pushed! PR #42 created.
```

Two approval modes:
- **Approve** — one-time, this session only
- **Approve for this project** — durable grant, stored on project record, never asks again

This mirrors the iOS permission model: JIT approval on first use, manageable in settings afterward.

### Two Injection Mechanisms

**Hook-based** (git credential helper, gh wrapper) — intercepts transparently at the tool level. Git has a credential protocol, so this works cleanly for GitHub. Wrappers shadow real binaries via PATH ordering.

**Env-based** (set token as env var at `docker exec` time) — works for Cloudflare, AWS, and everything else. Mint a scoped token, inject via `docker exec -e`. Tools like `wrangler` just read `CLOUDFLARE_API_TOKEN` from env.

Both use the same grant system underneath.

## Why This Approach

### Absorb `credentials.yaml`

The current `credentials.yaml` is a flat bag of env vars injected into every sandbox — no scoping, no approval, no lifecycle. It hasn't been used yet, and the commented-out `workspaces:` section shows per-project scoping was always intended. The provider system replaces it cleanly.

### Deploy via Tools Volume, Not Docker Image

The current GitHub broker (PR #214) bakes credential helper scripts and `gh` CLI into the Docker image. Every provider change requires an image rebuild + container recreation. The shared `parachute-tools` volume (`/opt/parachute-tools/`) is already mounted in every container with `bin/` first in PATH.

Moving credential scripts to the tools volume means:
- **No image rebuild** for provider changes
- **Server syncs scripts on startup** — writes helpers to the volume when providers are configured
- **Immediate availability** — all running containers see new scripts without restart
- **PATH shadowing** — a `gh` wrapper in `/opt/parachute-tools/bin/` naturally shadows `/usr/bin/gh`

The git credential helper can be configured via environment variables (`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0`, `GIT_CONFIG_VALUE_0`) at `docker exec` time instead of `git config --system` in the Dockerfile. This eliminates all image-level dependencies for credential management.

### Generalize the Pattern

GitHub and Cloudflare have different auth models but the broker pattern is the same:

| | GitHub | Cloudflare |
|---|---|---|
| Auth model | App private key → JWT → installation token | Parent token → child token |
| Token minting | JWT signing + API call | Single API call |
| Scoping | Per-org installation | Per-zone/account + permission groups |
| TTL | Fixed 1 hour | Custom (e.g., 8 hours) |
| Injection | Hook-based (credential helper + gh wrapper) | Env-based (`CLOUDFLARE_API_TOKEN`) |

Adding future providers (AWS STS, generic API keys) follows the same pattern: provider config → grant check → token mint → inject.

## Key Decisions

1. **`credentials.yaml` absorbed** — Provider system replaces it entirely. No migration needed (hasn't been used).

2. **Tools volume deployment** — Credential scripts live on shared `parachute-tools` volume, not baked into Docker image. Server syncs on startup. One final image rebuild to remove the baked-in scripts from PR #214, then no more rebuilds for credential changes.

3. **Grants on project records** — Both pre-configured and JIT grants stored in the same shape on the Project record. The grant is the durable artifact regardless of how it was created.

4. **Inline chat approval** — JIT approval surfaces as a card in the active chat, not buried in Settings. Two modes: one-time (session) and durable (project).

5. **Provider backends are pluggable** — Each provider type knows how to mint a token given a scope. Adding a new provider is a new backend class + a script on the tools volume.

6. **Git config via env vars** — Use `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_N`/`GIT_CONFIG_VALUE_N` instead of `git config --system` in the Dockerfile. Requires Git 2.31+ (the sandbox image has 2.43+).

## Scope

### In Scope
- Generalized broker endpoint: `/api/credentials/{provider}/token`
- Provider backend: Cloudflare (parent token → scoped child token)
- Migrate existing GitHub broker into the provider system
- Move credential scripts from Docker image to tools volume
- Server-side script syncing on startup
- Git credential config via environment variables
- `parachute setup cloudflare` CLI command
- Grant storage on Project records
- Broker-side grant checking (return 403 if no grant)

### Out of Scope (Future)
- Flutter UI for inline JIT approval cards (needs event type in streaming protocol)
- Flutter UI for managing grants in project settings
- AWS STS provider
- Static env var provider (replaces credentials.yaml)
- Per-session (non-durable) grants

## Open Questions

1. **Grant storage format** — Add a `credential_grants` column on the Kuzu `Project` node, or create a separate `CredentialGrant` node with relationships? Column is simpler, node is more queryable.

2. **Script syncing trigger** — Sync on server startup only, or also on `parachute setup <provider>`? Startup-only is simpler but means you'd need a restart after setup.

3. **Cloudflare scope model** — Should grants specify individual permissions (`workers_scripts:write`), or use templates (`workers-deploy` = workers + r2 + kv)? Templates are simpler for users.
