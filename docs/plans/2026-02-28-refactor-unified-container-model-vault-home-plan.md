---
title: Unified Container Model — Vault-Backed Home Dirs for Portability
type: refactor
date: 2026-02-28
issue: 149
status: planned
tags: [computer, sandbox, docker, portability]
---

# Unified Container Model — Vault-Backed Home Dirs for Portability

Right now there are two kinds of sandboxed containers with different structures:
`parachute-session-*` (private, overlay home) and `parachute-env-*` (named, partially
host-mounted). This PR collapses them into one unified model.

**Key insight**: a "named env" is just a private session container with a name. They are
technically identical. The distinction should be purely social: does the container have a
user-readable slug, and can other sessions join it?

## Problem Statement

1. **Not portable.** Private session container home dirs live in Docker's overlay —
   inside Docker Desktop's LinuxKit VM, invisible to the host filesystem. Moving the
   vault to a new machine loses all session working state and SDK transcripts. A chat
   from months ago cannot be resumed on a new machine.

2. **Artificial split.** Two code paths for the same thing (`ensure_session_container` vs
   `ensure_named_container`, `parachute-session-*` vs `parachute-env-*`) with redundant
   logic and different data persistence stories.

3. **SDK transcripts lost on container recreation.** Private session containers don't
   mount `.claude/`, so if Docker kills or recreates a container, the SDK session history
   is gone (even though LadybugDB has message content, `--resume` can't pick up mid-session).

## Proposed Solution

Every sandboxed session — private or shared — gets:

- A `container_envs` DB record (auto-created with UUID slug if not user-specified)
- A container named `parachute-env-<slug>`
- A home directory bind-mounted from `vault/.parachute/sandbox/envs/<slug>/home/`

```
vault/.parachute/sandbox/envs/
  f3a9b2c1/         ← auto-slug (private session, not visible in UI)
    home/
      .claude/      ← SDK transcripts — portable, resumable
      notes.md      ← files the agent created
      my-project/
  my-project/       ← user-named (multi-session, shown in UI as "my-project")
    home/
      .claude/
      workspace/
```

"Naming" a container means: update `display_name` on the container_env record, and
optionally promote it to be joinable by other sessions. The underlying structure is
identical.

### Vault = Source of Truth

```
Copy vault to new machine
  → docker pull parachute-sandbox:latest
  → Start server — reconcile() recreates containers pointing at existing home/ dirs
  → All sessions resume exactly where they left off
```

## Acceptance Criteria

- [x] All sandboxed sessions always have a `container_env_id` (never NULL for sandboxed)
- [x] Auto-slug container_env created on first turn if session has no container_env_id
- [x] Container always named `parachute-env-<slug>` (no more `parachute-session-*`)
- [x] Home dir always bind-mounted: `vault/.parachute/sandbox/envs/<slug>/home/` → `/home/sandbox/`
- [x] `.claude/` persistence covered by home bind mount (no separate `.claude/` mount)
- [x] Session deleted → container_env deleted (if no other sessions reference it) → container + home dir removed
- [x] Named env deleted → container_env deleted → container + home dir removed
- [x] `reconcile()` removes orphaned `parachute-env-*` containers (slug has no container_env record)
- [x] `reconcile()` removes legacy `parachute-session-*` containers on startup
- [ ] Vault portability: moving vault to new machine and restarting server recreates containers against existing home/ dirs, allowing resume

## Technical Design

### Phase 1: sandbox.py — unified container args

**Remove** `ensure_session_container()`. All containers go through `ensure_named_container()`.

**`_build_persistent_container_args()`**: always bind-mount home dir. Remove `claude_dir`
param entirely — it's subsumed by the home mount.

```python
home_dir = self._get_container_home_dir(slug)
home_dir.mkdir(parents=True, exist_ok=True)
args.extend(["-v", f"{home_dir}:/home/sandbox:rw"])
# Vault overlaid read-only inside home (nested bind mount, supported by Docker)
args.extend(["-v", f"{self.vault_path}:/home/sandbox/Parachute:ro"])
```

**`_get_container_home_dir(slug) → Path`**:

```python
def _get_container_home_dir(self, slug: str) -> Path:
    return self.vault_path / SANDBOX_DATA_DIR / "envs" / slug / "home"
```

**`reconcile()`**: remove orphaned `parachute-env-*` containers (check against active
slugs from DB). Remove `parachute-session-*` as legacy cleanup on first boot.

**Remove**: `_get_named_env_claude_dir()`, `stop_session_container()` (replaced by
container_env deletion), `parachute-session-*` naming logic.

### Phase 2: orchestrator.py — auto-create container_env

When `run_session()` is called for a sandboxed session with no `container_env_id`:

```python
# Auto-create private container env
slug = str(uuid.uuid4())[:8]
await self.db.create_container_env(slug=slug, display_name=f"Session {session_id[:8]}")
await self.db.update_session(session_id, container_env_id=slug)
session.container_env_id = slug
```

Then pass `container_env_slug=session.container_env_id` to `sandbox.run_session()` for
all sandboxed sessions (currently only when container_env_id is set).

`delete_session()` cleanup:

```python
container_env_id = session.container_env_id
# Delete session first
await self.db.delete_session(session_id)
# If container_env was private (no other sessions reference it), delete it
if container_env_id:
    referencing = await self.db.count_sessions_for_container_env(container_env_id)
    if referencing == 0:
        await self.db.delete_container_env(container_env_id)  # nullifies sessions, removes record
        await self._sandbox.delete_named_container(container_env_id)
        self._cleanup_container_home_dir(container_env_id)
```

### Phase 3: database.py — helpers

Add `count_sessions_for_container_env(slug) → int` for delete-session cascade check.

Add migration v23 (no schema changes needed — `container_envs` table and
`container_env_id` column already exist from v22).

### Phase 4: home dir permissions on macOS

Docker Desktop with VirtioFS handles UID mapping transparently on macOS — files created
by the `sandbox` user (uid=1000) inside the container appear as the host user's files.
No chown required. Verify on Linux (may need `chown 1000:1000` of host dir).

If nested bind mount (`/home/sandbox/` then `/home/sandbox/Parachute/`) causes issues
on any platform, fall back to: bind-mount home at `/home/sandbox/workspace/` and keep
vault at `/home/sandbox/Parachute/`. Users work in `/workspace/` and this becomes the
default working directory.

### Phase 5: tests

- Update `test_trust_levels.py`: remove session-container tests, add unified container tests
- Add `test_container_home_dir_created_on_ensure()`
- Add `test_delete_session_removes_private_container_env()`
- Add `test_delete_session_keeps_shared_container_env()`

## Migration

**Existing sessions with `container_env_id = NULL` (old private sessions)**:
- Their `parachute-session-*` containers are removed by `reconcile()` on first boot
- On their next turn, a new auto-slug container_env is created
- Home dir starts fresh (overlay state was unrecoverable anyway — it lived in Docker VM)

**Existing named env sessions**: unchanged — already have `container_env_id` set.
Their containers just get a home dir added on next recreation.

## Dependencies & Risks

**Nested bind mounts**: Docker supports mounting `/home/sandbox/` (rw) and then
`/home/sandbox/Parachute/` (ro overlay). Both paths must be specified in `docker run` —
the inner mount takes precedence at that path. Tested on macOS Docker Desktop.

**Disk growth**: every sandboxed session now creates a host directory. reconcile() should
log total sandbox disk usage. Future: `parachute sandbox prune` CLI command.

**Concurrent sessions in named env**: all share `/home/sandbox/`. Same risk as before —
file collisions possible. Unchanged from #147.

**UID on Linux**: The `sandbox` user (uid=1000) in the container must be able to write
to the host-created directory. On Linux without userns-remap, the host dir must be owned
by uid=1000. `mkdir + chmod 700` from Python works; `chown` requires the host user to
be uid=1000 or to use `sudo`. May need to run `docker run --rm ... chown 1000:1000 /home/sandbox`
after creating the dir, or use `--user root` for the chown step. Document in install.sh.
