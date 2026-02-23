---
date: 2026-02-22
topic: sandbox-credential-injection
status: brainstorm
priority: P2
issue: #62
---

# Sandbox Credential Injection

## What We're Building

A mechanism for sandboxed agents to use authenticated host tools — `gh`, `aws`, `gcloud`, `npm`, etc. — without requiring interactive `auth login` flows that don't work inside containers.

The approach: store tokens in vault config (`vault/.parachute/credentials.yaml`). At container launch, inject them as environment variables — exactly like `CLAUDE_CODE_OAUTH_TOKEN` is already injected today via env file. Tools pick them up transparently.

This slots in as **Chunk 6** of the sandbox rework (issue #62), building on the Docker hardening and container launch infrastructure in Chunks 1–5.

## Why This Approach

Three options were considered:

### Option A: Credential Store + Env Var Injection ✅ (chosen)

Store tokens in vault config. At container launch, inject them as env vars via the existing env-file mechanism.

```
vault/.parachute/credentials.yaml
  github:
    token: ghp_xxxxx        → GH_TOKEN
  aws:
    access_key: AKIA...     → AWS_ACCESS_KEY_ID
    secret: ...             → AWS_SECRET_ACCESS_KEY
  npm:
    token: npm_xxx          → NPM_TOKEN
```

`gh`, `aws`, `npm publish` all pick these up transparently — no `auth login` needed.

**Pros:**
- Minimal — extends an already-designed pattern (`CLAUDE_CODE_OAUTH_TOKEN` env file)
- Tools work naturally inside the container; agent experience unchanged
- Generalizes cleanly to any env-var–capable tool
- Trust level is the safety gate: bots don't get credentials, direct sessions do

**Cons:**
- Container holds the raw token; if compromised, token is exposed
- Mitigated by: fine-grained tokens with limited scopes, trust-level gating

### Option B: Host-Side MCP Tool Proxying

MCP servers wrap tool operations; container calls them via HTTP. Credentials stay on host.

**Pros:** Credentials never touch container; fine-grained operation allowlist
**Cons:** Agent must learn a new API per tool; massive build effort; `gh` alone has hundreds of subcommands — you'd never fully wrap it

### Option C: Credential File Mounts

Mount `~/.config/gh/`, `~/.aws/`, etc. read-only into the container.

**Pros:** Zero code
**Cons:** Exposes entire credential file (not scoped tokens); couples container to host FS layout; security antipattern

**Option A wins:** natural extension of the existing pattern, trust level is the safety mechanism.

## Key Decisions

- **Storage:** `vault/.parachute/credentials.yaml` — alongside the existing token file (`.token`), config (`config.yaml`), and hooks. Vault-level credentials apply to all sandboxed sessions; workspace configs can override per-workspace.
- **Injection:** Appended to the existing env file at container launch (ephemeral mode) or passed in the stdin JSON payload (persistent/exec mode). Same code path, just more entries.
- **Trust gating:**
  - `direct` sessions — agent runs on host as the user, already has access to all credentials natively
  - `sandboxed` app sessions — get workspace-level or vault-level credentials from `credentials.yaml`
  - `sandboxed` bot sessions (Telegram, Discord) — get no credentials by default; optionally a read-only public token if explicitly configured
- **Scoped tokens over full credentials:** Documentation and UI encourage fine-grained tokens (GitHub fine-grained PATs, AWS IAM least-privilege keys) rather than broad ones. This is the primary security mitigation.
- **No plaintext in DB:** Credentials read from vault file at launch time, not stored in `sessions.db`.

## Scope (v1)

Core credential types to support first:

| Tool | Env Var | Notes |
|------|---------|-------|
| `gh` | `GH_TOKEN` | Fine-grained PAT; `gh` respects this over `~/.config/gh` |
| `git` (HTTPS) | `GIT_TOKEN` via credential helper | Optional; SSH key mount may be simpler |
| `aws` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` | |
| `npm` | `NPM_TOKEN` | Used via `.npmrc` or env |

The `credentials.yaml` format is the same for all — just a mapping of `service → {env_var: value}` entries. The launch code loops over them.

## Open Questions

- **UI for managing credentials:** How does the user add/update tokens? CLI command (`parachute credentials set github.token ghp_xxx`)? Vault file editor? Settings in the Flutter app?
- **Workspace-level credentials:** Does a workspace config carry its own credentials that override vault-level? Useful for multi-project setups with different GitHub accounts.
- **Credential rotation:** If a token expires, how does the user know? Should Parachute pre-validate tokens on launch and warn?
- **SSH keys for git:** A separate concern — env var injection doesn't cover SSH auth. Could mount `~/.ssh/id_ed25519` read-only as a separate mechanism, or just recommend HTTPS + token for v1.

## Relationship to Issue #62

- Extends Chunk 4 (Server-default MCP config) — `credentials.yaml` is loaded alongside `default_capabilities` in the server config system
- Extends Chunk 2 (Default sandbox container) — credential env vars appended to the existing env-file launch path
- The trust-level gating model maps directly onto the `sandboxed`/`direct` rename from Chunk 1

## Next Steps

→ `/para-plan #62` — fold as Chunk 6 when planning the sandbox rework implementation
