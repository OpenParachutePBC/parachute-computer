---
topic: Trust Model Simplification & Unified Vault Path
date: 2026-02-09
status: decided
---

# Trust Model Simplification & Unified Vault Path

## What We're Building

Two major architectural changes to Parachute's execution model:

1. **Simplify trust from 3 levels to 2**: Replace full/vault/sandboxed with **trusted** (bare metal) and **untrusted** (Docker). No middle ground — either you trust the agent or you don't.

2. **Unify vault paths**: Create a `/vault` symlink on the host machine so both bare metal and Docker agents see the same filesystem paths. Eliminates the current inconsistency where bare metal uses `/Users/parachute/Parachute/...` and Docker uses `/vault/...`.

## Why This Approach

### Trust simplification

The current 3-tier model (full/vault/sandboxed) creates confusion:
- "vault" trust runs on bare metal but with directory restrictions — a half-measure that's neither secure nor convenient
- Users have to understand the difference between 3 levels when the real question is binary: do you trust this agent?
- The workspace model already provides directory scoping, making the "vault" restriction redundant

**New model**: Docker IS the permission boundary. Both trusted and untrusted agents bypass SDK permissions. Trusted runs on bare metal, untrusted runs in Docker. Simple.

### Unified vault path

Currently working directories differ between execution contexts:
- **Bare metal**: `/Users/parachute/Parachute/Projects/foo` (absolute, machine-specific)
- **Docker**: `/vault/Projects/foo` (container-relative)

This causes:
- Different SDK transcript paths between execution contexts for the same workspace
- Complex path resolution logic (`resolve_working_directory()` / `make_working_directory_relative()`)
- Agents see different paths depending on trust level, which leaks implementation details

**Solution**: `ln -s ~/Parachute /vault` on the host. Both contexts use `/vault/...` paths.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Trust levels | **Trusted / Untrusted** (drop vault) | Binary is simpler. Docker is the real boundary. |
| Path unification | **Symlink `/vault` on host** | Both bare metal and Docker see `/vault/...`. Consistent SDK transcripts. |
| Symlink setup | **Automated in `install.sh`** | Parachute owns the convention. Sudo prompt during install. |
| Trust scope | **Per-connector + workspace** | Bot connectors default untrusted. Native app defaults trusted. Workspace can override. |
| SDK permissions | **Both bypass, Docker is the boundary** | Simplest model. Trusted = bare metal + bypass. Untrusted = Docker + bypass. |
| Path storage | **Migrate to `/vault/...` format** | Cleaner resolution, no runtime path translation needed. Requires DB migration. |

## Current Architecture (Before)

```
Trust Levels: full (0) → vault (1) → sandboxed (2)

Bare metal (full/vault):
  SDK cwd: /Users/parachute/Parachute/Projects/foo  (absolute, machine-specific)
  Transcript: ~/.claude/projects/-Users-parachute-Parachute-Projects-foo/

Docker (sandboxed):
  SDK cwd: /vault/Projects/foo  (container path)
  Transcript: synthetic JSONL written to host after execution

Path resolution:
  DB stores: "Projects/foo" (vault-relative)
  resolve_working_directory() → absolute path for bare metal
  make_working_directory_relative() → relative path for Docker
```

## Proposed Architecture (After)

```
Trust Levels: trusted → untrusted

Host setup:
  /vault → ~/Parachute  (symlink, created by install.sh)

Bare metal (trusted):
  SDK cwd: /vault/Projects/foo
  Transcript: ~/.claude/projects/-vault-Projects-foo/

Docker (untrusted):
  SDK cwd: /vault/Projects/foo  (same path, mounted volume)
  Transcript: synthetic JSONL written to host after execution

Path resolution:
  DB stores: "/vault/Projects/foo" (absolute, consistent)
  No translation needed — path is the same everywhere
```

## Trust Defaults

| Context | Default Trust | Rationale |
|---------|---------------|-----------|
| Native app sessions | Trusted | User is at their own machine |
| Telegram bot DMs (approved user) | Untrusted | Remote access, isolate by default |
| Telegram bot groups | Untrusted | Multiple users, must isolate |
| Discord bot | Untrusted | Remote access |
| Workspace override | Either | Workspace config can force trusted or untrusted |

## Migration Path

1. **Install changes**: `install.sh` creates `/vault` symlink pointing to configured vault path
2. **Config changes**: Remove `trust_level` enum values, add boolean `trusted` to session/workspace models
3. **Orchestrator changes**: Replace 3-way trust routing with 2-way (bare metal vs Docker)
4. **Path migration**: Update stored `working_directory` values from relative to `/vault/...` format
5. **Remove dead code**: `resolve_working_directory()`, `make_working_directory_relative()`, capability filter trust ranking
6. **App changes**: Replace trust level selector (3 segments) with trusted/untrusted toggle

## Open Questions

- **Linux hosts**: `/vault` symlink works on macOS. On Linux (Lima VM, production), the vault may already be mounted at a fixed path. Need to handle both.
- **Multiple vaults**: If a user has multiple vault paths (unlikely now, possible later), `/vault` can only point to one. Is this a problem?
- **Existing transcripts**: SDK transcripts at old paths (`-Users-parachute-Parachute-...`) won't match new paths (`-vault-...`). Do we migrate those or leave orphaned?
- **Windows**: No `/vault` symlink on Windows. Cross that bridge when we get there (not a priority).

## References

- Current trust implementation: `computer/parachute/core/orchestrator.py` (lines 538-563, 664-777)
- Sandbox config: `computer/parachute/core/sandbox.py` (AgentSandboxConfig dataclass)
- Path resolution: `computer/parachute/core/session_manager.py` (lines 45-109)
- Docker entrypoint: `computer/parachute/docker/entrypoint.py` (lines 46-76)
- Capability filter: `computer/parachute/core/capability_filter.py` (trust ranking)
