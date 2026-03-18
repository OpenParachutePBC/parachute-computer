# Credential Layer for Sandboxed AI Agents

**Status:** Brainstorm
**Priority:** P1
**Labels:** computer, app, enhancement
**Issue:** #291

---

## What We're Building

A general-purpose credential layer that connects external service credentials to sandboxed AI agent environments. The system is extensible (pre-bundled helpers for common services, easy to add custom ones), intuitive (permission requests surface in the app UI), and secure (credentials never enter the LLM context window, scoped tokens are minted per-session where possible).

This replaces the current hardcoded GitHub App + Cloudflare parent token injection with a protocol-driven system that works for any service.

## Why This Matters

**Immediate pain:**
- GitHub App bot token (`parachute-development[bot]`) doesn't work across orgs — moving a repo from `unforced` to `unforced-dev` silently breaks push access with a cryptic 403
- Cloudflare parent token is missing permissions wrangler needs for account discovery (`Memberships: Read`), causing confusing errors
- No way for a sandboxed agent to access the user's personal repos outside the GitHub App's installed orgs
- No visibility into what credentials a sandbox session has or why auth is failing

**Systemic gap:**
- The credential broker is hardcoded to two providers with different maturity levels (GitHub has proper helper scripts; Cloudflare just injects the parent token as an env var)
- No runtime consent model — credentials are either fully available or not, decided at container launch
- No audit trail of which agent used which credential when
- No path for community-contributed credential helpers (e.g., Vercel, Supabase, AWS)
- Open-source agent tools (OpenHands, etc.) have this same problem unsolved — OpenHands had a real-world attack where prompt injection exfiltrated a `GITHUB_TOKEN` from the agent's environment

## Why This Approach

### Core Architecture: MCP as Permission Gateway + Out-of-Band Credential Injection

The key insight is splitting two concerns that are currently conflated:

1. **Capability negotiation and consent** (what can this agent do?) — handled by the Parachute MCP using dynamic `tools/list` and elicitation
2. **Credential transmission** (getting tokens into the container) — handled out-of-band via the broker API, env vars, and credential helper scripts

This mirrors how the Parachute MCP already handles graph database permissions: sandboxed sessions get read-only access, with the possibility of per-container scoping. Credentials become another dimension of the same permission model.

**Why MCP for the gateway layer:**
- `tools/list` is dynamic per-session — the server returns different tools based on trust level and available credentials
- `notifications/tools/list_changed` lets the server update available tools when permissions change mid-session
- Elicitation (MCP spec 2025-06-18) provides structured consent flows: "This agent wants to push to `unforced-dev/learnvibe.build`. Grant write access?"
- Unifies with existing Parachute MCP permission model — one system for graph access AND service credentials

**Why credentials must NOT flow through MCP tool responses:**
- Tool responses enter the LLM context window — prompt injection can extract them (OWASP Top 10 for Agentic Applications 2026)
- OpenHands demonstrated this: an agent with `GITHUB_TOKEN` in its env was tricked into base64-encoding and exfiltrating it
- The MCP tool `request_access(service: "github", scope: "write", org: "unforced-dev")` triggers credential resolution, but the actual token is injected directly into the container environment — the LLM never sees it

### Self-Describing Credential Helpers

Each credential helper is a module that declares:

```
name: "github"
display_name: "GitHub"
icon: "github.svg"
description: "Git operations and GitHub API access"

# What the user provides during setup
setup_fields:
  - method: "github-app"        # GitHub App (machine identity)
    fields: [app_id, private_key_pem]
  - method: "personal-token"     # PAT (user identity)
    fields: [token, scopes]

# What gets injected into containers
provides:
  env_vars: [GH_TOKEN, GH_DEFAULT_ORG]
  scripts: [github-token-helper.sh, gh-wrapper.sh]
  git_config: {credential.helper: "...", credential.useHttpPath: "true"}

# Available permission scopes (for UI rendering)
scopes:
  - name: "repo:read"
    description: "Read repository contents"
    default: true
  - name: "repo:write"
    description: "Push commits, create branches"
    default: false
  - name: "issues:write"
    description: "Create and manage issues and PRs"
    default: true

# Capability declaration
capabilities:
  mint_scoped_tokens: true      # Can create per-session tokens
  token_ttl: "1h"               # How long minted tokens last
  supports_org_scoping: true    # Can scope to specific orgs
  credential_helper: true       # Has a CLI credential helper protocol

# Health check
health_check:
  endpoint: "/app"              # API call to verify credentials
  auth_header: "Bearer {jwt}"
```

This self-describing shape is what makes the UI work generically. The Flutter app doesn't need to know what GitHub is — it renders setup fields, scope toggles, and health status from the helper's declaration. A community-contributed Vercel helper gets the same UI treatment automatically.

### Two-Tier CLI Bridge

Research confirms every major CLI tool checks environment variables before config files. But three services have richer credential helper protocols:

**Tier 1: Native credential helpers** (lazy, just-in-time)
- **Git** — `credential.helper` protocol. Script calls broker API, returns token in git credential format. Supports chaining, cache, and `erase` on 401.
- **AWS** — `AWS_CONTAINER_CREDENTIALS_FULL_URI` endpoint. All AWS SDKs natively query this HTTP endpoint, handle caching and refresh internally. Best-in-class.
- **Docker** — `docker-credential-*` binary protocol for registry auth.

**Tier 2: PATH wrapper scripts** (intercept-and-inject)
- Place wrappers in `/opt/parachute-tools/bin/` (already exists as a Docker volume)
- Wrapper calls broker API, gets fresh token, sets env var, execs real tool
- Works for: `gh`, `wrangler`, `vercel`, `flyctl`, `netlify`, `doctl`, `heroku`, `railway`, `npm`, `terraform`
- Fallback: if broker unreachable, proceed without token (tool fails with auth error — honest failure)

**Tier 3: Static env var injection** (services without minting APIs)
- For services that don't support programmatic token creation (Supabase, Netlify, Railway, DigitalOcean)
- User's token from `credentials.yaml` or setup wizard, injected at container launch
- No per-session scoping — the user's full token is what the agent gets

### Runtime Consent Model

Hybrid approach: setup-time defaults with runtime escalation.

1. **Setup time** — User connects GitHub with default scopes (read repos, read/write issues). Stored in config.
2. **Session start** — Broker injects default-scoped credentials. MCP exposes tools matching those scopes.
3. **Runtime escalation** — Agent tries to push, needs write access. MCP tool `request_access()` triggers elicitation: "Grant write access to `unforced-dev/learnvibe.build`?"
4. **If approved** — Broker mints a write-scoped token, injects it into the container env. MCP sends `listChanged`. Agent now has the capability.
5. **If declined** — Agent sees "access denied" and can explain to the user what it needs and why.

This is the mobile app permission model (ask when you need it, not at install time) applied to agent credentials.

### Token Scoping Feasibility

Research across 15 services shows:

| Tier | Services | What Works |
|------|----------|------------|
| **Full minting support** | GitHub Apps, AWS STS, Cloudflare, GCP, npm, Fly.io | Broker holds parent credential, mints scoped short-lived tokens per session |
| **Partial minting** | Azure, Heroku, Vercel, Docker Hub, PyPI (OIDC) | Expiry supported but scoping limited or TTL fixed |
| **No programmatic minting** | Supabase, Netlify, Railway, DigitalOcean | Passthrough only — user's token injected as-is |

~60% of common developer services support programmatic scoped token minting. For the rest, the system falls back gracefully to token passthrough with env var injection.

## Key Decisions

### 1. MCP for negotiation, broker API for transmission
Credentials never appear in MCP tool responses (LLM context). MCP handles capability discovery and consent. The broker API handles actual token resolution and container injection.

### 2. Self-describing helper protocol
Each credential helper declares its setup fields, provided env vars/scripts, available scopes, and health check. The app UI renders generically from these declarations. This is how we avoid hardcoding provider-specific UI.

### 3. Three injection mechanisms
Git credential helper, PATH wrapper scripts, and static env vars — covering 100% of CLI tools. Each helper declares which mechanism(s) it uses.

### 4. Per-session token minting where supported
For services that support it (GitHub, AWS, Cloudflare, GCP, npm, Fly.io), the broker mints scoped short-lived tokens per session. For services that don't, tokens pass through from config.

### 5. Consent via MCP elicitation
Runtime permission escalation uses MCP's elicitation primitive — structured prompts with accept/decline that surface in the app UI. No custom protocol needed.

### 6. File-based caching with flock
Credential helper scripts cache tokens in `/tmp/.broker-cache.json` with file locking to handle concurrent access from parallel git operations. TTL-based expiry with a 30-second buffer before actual expiry.

### 7. Fail open, fail honestly
If the broker is unreachable, credential helpers return empty (git tries next helper) or wrappers proceed without the token (tool fails with auth error). Never silently use stale credentials.

## Open Questions

### How do we handle the GitHub App vs. personal token tension?
The GitHub App model (machine identity, per-org) is right for some use cases. Personal tokens (user identity, cross-org) are right for others. Do we support both simultaneously? Does the broker try the App first and fall back to a PAT? Or does the user choose per-session?

### How dynamic can MCP tool gating be?
Can we add tools mid-session (after a credential is granted) and have Claude actually use them? Or do tools need to be present at session start? Need to test `listChanged` behavior with Claude.

### What's the migration path from the current system?
The current GitHub provider and credential helper scripts are close to the target shape. Cloudflare needs a real helper. The `credentials.yaml` flat file becomes the "static passthrough" tier. What breaks during migration?

### How do credential helpers get distributed?
Pre-bundled helpers ship with Parachute. Community helpers could be... npm packages? Git repos? Python packages? Files dropped into a `~/.parachute/credential-helpers/` directory? What's the right distribution model?

### Per-container credential scoping
Should different containers in the same session have different credentials? (e.g., a "deploy" container gets Cloudflare write, but a "research" container only gets GitHub read). Or is session-level scoping sufficient?

### Audit logging shape
Every credential access should be logged. What's the schema? Session ID, provider, scope, timestamp, result? Does this go in the graph database, SQLite, or a separate log?

### How does this interact with bot sessions?
Current system blocks all credentials for Telegram/Discord/Matrix sessions. With the new model, could a bot session request credentials via elicitation? Or is the block absolute?

## Research Summary

### External Systems Studied
- **OpenHands** — SecretSource protocol for dynamic secrets; suffered real prompt injection → credential exfiltration attack
- **Devcontainers/Codespaces** — SSH agent forwarding (socket proxy, key never enters container), Git credential helper delegation
- **1Password CLI** — `op://` URI reference scheme, resolved at subprocess launch via `op run`
- **HashiCorp Vault** — Sidecar/init-container pattern, shared memory volume, lease-based rotation
- **GitHub Actions** — Env var injection, OIDC federation for secretless cloud access
- **AWS CloudShell** — Container credential endpoint (`AWS_CONTAINER_CREDENTIALS_FULL_URI`) — SDK-native, handles refresh
- **Docker credential helpers** — Simple stdin/stdout binary protocol, registry-scoped

### Standards and Guidance
- **OWASP Top 10 for Agentic Applications (2026)** — agents should not have direct access to raw credential values; interact with credential abstractions that enforce least privilege
- **NIST AI Agent Standards Initiative (Feb 2026)** — cryptographic workload identities for agents, RFC 8693 token exchange, audit and non-repudiation
- **MCP Authorization Spec (2025-03-26)** — OAuth 2.1 for HTTP transport, dynamic `tools/list` for capability gating, elicitation for user consent

### Key Patterns Identified
1. **Credential abstraction > credential injection** — agents should request capabilities, not raw tokens
2. **Dynamic tool exposure** — MCP `tools/list` + `listChanged` = tools appear/disappear based on permissions
3. **Out-of-band injection** — credentials go into container env, not LLM context
4. **Credential helper protocol** — git's protocol is the most reusable; AWS container endpoint is the cleanest for SDK-native tools
5. **File-based caching with flock** — handles concurrent helper invocations from parallel git operations

## Scope

### In Scope
- Credential helper protocol definition (self-describing shape)
- Refactored GitHub helper (support both App and PAT methods)
- New Cloudflare helper (proper child token minting, account ID injection)
- MCP integration for capability gating and consent
- App UI for credential setup, status, and runtime consent
- PATH wrapper deployment to `parachute-tools` volume
- File-based token caching with flock

### Out of Scope (Future)
- Community credential helper distribution/marketplace
- Agent skill for writing credential helpers
- OIDC/workload identity for agent authentication
- Multi-device credential sync
- Terraform/Pulumi infrastructure credential management
