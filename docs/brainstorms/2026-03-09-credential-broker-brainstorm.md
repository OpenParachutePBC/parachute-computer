# Credential Broker for Sandboxed Sessions

**Status:** Brainstorm
**Priority:** P1
**Labels:** computer, enhancement
**Issue:** #213

---

## What We're Building

A credential broker built into Parachute Computer that lets sandboxed (Docker) sessions use GitHub — push, create PRs, clone private repos — without ever seeing a token. The agent runs `git push` or `gh pr create` normally; transparent credential helpers intercept the call, fetch a short-lived token from the broker, and inject it invisibly.

Starting with GitHub (the most common friction point), but designed as a general pattern that extends to other credential types later.

## Why This Approach

**The problem:** Sandboxed containers default to `--network none` and don't have the user's GitHub credentials. The existing `credentials.yaml` system can inject tokens, but they're long-lived PATs visible in `os.environ` — the agent can read, log, or leak them.

**The broker pattern (inspired by [lucianHymer/borg](https://github.com/lucianHymer/borg)):**
- User registers a **GitHub App** and drops the private key in `~/.parachute/`
- Parachute Computer mints **short-lived installation tokens** (1-hour expiry) on demand
- Sandbox containers connect to the broker via an **internal Docker network** (no internet)
- **Git credential helper** and **gh CLI wrapper** make auth invisible to the agent
- Agent never sees credentials; if the container is compromised, the attacker gets a token that expires in <1 hour and is scoped to specific repos

**Why build it into Parachute Computer (not a sidecar):**
- Server is already running at `:3333` — no new infrastructure
- Establishes Parachute Computer as the credential authority
- Generalizable: add `/api/credentials/aws/session`, `/api/credentials/npm/token`, etc. later
- Credential lifecycle (minting, caching, expiry) managed centrally

## Key Decisions

1. **Broker endpoint lives in Parachute Computer** — new `/api/credentials/github/token` route on the existing FastAPI server, not a separate service.

2. **GitHub App model** — user creates a GitHub App (free, takes 2 minutes), installs it on their repos/orgs, puts the private key at `~/.parachute/github-app.pem`. Parachute mints installation tokens via the GitHub API.

3. **Internal Docker network** — a `parachute-credentials` bridge network connects sandbox containers to the host. No internet access, just broker connectivity. This is a middle ground between `--network none` (no credential access) and full network (too permissive).

4. **Transparent credential helpers in sandbox image** — a git credential helper script and gh CLI wrapper installed at image build time. The agent doesn't configure anything; `git push` and `gh pr create` just work.

5. **Generalizable pattern** — the broker API, internal network, and helper-script approach are designed to extend to other credential types without architectural changes.

6. **Security scoping via GitHub App installation (v1)** — the GitHub App itself is the security boundary. You only install it on repos/orgs you want agents to access. Any sandbox container can request tokens for any installed org, but the token only works on repos the App is installed on. This is sufficient for a single-user system where you trust all your own sandboxes equally.

7. **Per-project repo scoping is v2** — a tighter model where each Parachute project specifies which orgs/repos it can access, and the broker enforces it. This would need a Flutter UI for configuring per-project repo access. Deferred — the App installation boundary is already meaningful for v1.

## How It Works

```
Agent runs `git push`
       |
       v
Git credential helper (shell script)
       |
       | Parses org from repo URL
       | Looks up installation_id from config
       |
       v
GET http://host.docker.internal:3333/api/credentials/github/token?installation_id=X
       |
       | Bearer token auth (broker secret)
       |
       v
Parachute Computer
       |
       | Reads ~/.parachute/github-app.pem
       | Mints installation token via GitHub API
       | Caches until 5 min before expiry
       |
       v
Returns short-lived token
       |
       v
Credential helper outputs token to git
       |
       v
Git push succeeds. Agent never saw the token.
```

## What's Needed

### Server side (Parachute Computer)
- `/api/credentials/github/token` endpoint
- GitHub App auth: read PEM, mint installation tokens, cache with expiry
- Configuration in `~/.parachute/credentials.yaml` or dedicated config for GitHub App ID + PEM path
- Installation ID mapping (org → installation_id)

### Sandbox side (Docker image)
- `github-token-helper.sh` — git credential helper script
- `gh-wrapper.sh` — gh CLI wrapper that fetches token before exec
- Git system config: `credential.helper = !/usr/local/bin/github-token-helper.sh`
- gh binary swap: rename real gh, symlink wrapper

### Docker networking
- Create `parachute-credentials` bridge network
- Connect sandbox containers to this network (in addition to or instead of `--network none`)
- Ensure containers can reach `host.docker.internal:3333` but not the public internet

### Setup experience
- Guide user through GitHub App creation (or automate via `gh` CLI)
- `parachute setup github` command to walk through it
- Store config in `~/.parachute/github-app.yaml` or similar

## Scoping Model

### v1: GitHub App installation = security boundary
- User installs the GitHub App on specific orgs/repos
- Any sandbox container can request a token for any installed org
- The token only works on repos the App has access to
- Sufficient for single-user: you control what you install the App on
- **No frontend changes needed** — setup is CLI/config only

### v2: Per-project repo scoping
- Each Parachute project (named sandbox environment) specifies allowed orgs/repos
- Broker checks project authorization before minting tokens
- Requires Flutter UI for project settings (repo access configuration)
- Enables multi-user scenarios and tighter least-privilege

## Open Questions

1. **Network isolation granularity** — Can we create a Docker network that only allows traffic to the host (broker) but blocks internet? Or do we need iptables rules in the container? Need to verify Docker network capabilities.

2. **Broker authentication** — The internal network isn't enough; any container on the network could call the endpoint. Lucian uses a shared bearer secret. We should too — but how is it injected? Via the existing stdin credential mechanism?

3. **GitHub App permissions** — What's the minimal permission set? Probably: `contents: write`, `pull_requests: write`, `metadata: read`. Should we document recommended vs. minimal?

4. **Setup UX** — `parachute setup github` walks through App creation, but how much can we automate? Can we create the App via API, or does the user need to do it in GitHub's UI?

5. **Credential type registry (future)** — When we add more credential types, should there be a formal registry/plugin system, or just more endpoints?

## Prior Art

- **[lucianHymer/borg](https://github.com/lucianHymer/borg)** — Full implementation of this pattern. Token broker (~60 LOC Node.js), git credential helper, gh CLI wrapper. Battle-tested with multi-org support.
- **GitHub App installation tokens** — [GitHub docs](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app). 1-hour expiry, repo-scoped, org-scoped permissions.
- **Parachute's existing credential injection** — `credentials.yaml` → stdin → `os.environ`. Works but credentials visible to agent process. This broker pattern supersedes it for GitHub specifically.
