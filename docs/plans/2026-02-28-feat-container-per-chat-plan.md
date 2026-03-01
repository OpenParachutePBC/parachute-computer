---
title: Container-Per-Chat Sandbox Architecture
type: feat
date: 2026-02-28
issue: 145
tags: [computer, chat, sandbox, docker]
---

# Container-Per-Chat Sandbox Architecture

Each sandboxed chat session gets its own isolated Docker container. Containers share a
common base image and a shared read-only tools volume — resource overhead stays low while
isolation is genuinely per-session.

Containers can optionally be **named and shared** across multiple sessions, making them
the natural replacement for workspaces as execution environments. This is built bottom-up:
start a session, work in the container, save it when it becomes something worth keeping.
Other sessions can then join it.

This replaces the current model of shared persistent workspace containers and a single
default container for all non-workspace sessions.

## The Core User Flow

A session starts as just a conversation. The container is private, the working space is
`/home/sandbox/`. Files accumulate there — notes, ideas, maybe a cloned repo. At some
point the work solidifies: "okay, let's actually build this." The user saves the container
with a name. Now it's a named env — a shared execution environment that other sessions
and agents can join, all operating in the same directory with the same files.

This is the workspace concept, but created from use rather than configured before you
start. The scratch space is the connective tissue.

## Problem Statement

The current sandbox model:

- `parachute-ws-<slug>` — one persistent container per workspace, shared by all sessions
  in it. Multiple concurrent chats share scratch space and process state.
- `parachute-default` — one persistent container for all sandboxed sessions without a
  workspace.

Workspaces were configured top-down (create workspace → sessions run in it). The concept
is overloaded: capability filter + execution environment + session grouping. The UI
reflects this complexity and it shows.

In practice, the system has been used almost entirely in **direct (bare metal) mode**.
Existing sandboxed sessions are few and disposable — old containers can be cleared out
entirely. No graceful migration needed.

## Proposed Solution

### Two container modes

**Private (default):**
Each session gets its own container. Removed when the session is deleted or archived.

```
First message  → container created: parachute-session-<session_id[:12]>
Each turn      → docker exec into running container
Delete/archive → container removed
```

**Named env (optional):**
User saves a container with a human name. Future sessions can join it, sharing the same
working space, files, and any mounted repos. This is the new workspace — created from a
session, not from a config form.

```
User saves container → parachute-env-<slug>
New session joins it → docker exec into same running container
Named env deleted    → container removed
```

Multiple sessions and background agents in the same named env all see the same
`/home/sandbox/` contents.

### Working Space: `/home/sandbox/`

The home directory is the working space. It lives in the container's writable overlay
layer, which persists as long as the container exists.

```
/home/sandbox/
├── Parachute/          ← vault (read-only bind mount)
├── notes.md            ← files you created — live in writable overlay
├── my-project/         ← could be a cloned repo or a created folder
└── parachute-computer/ ← or a host repo mounted here (bind mount)
```

There is no `/scratch/` subdirectory. `/home/sandbox/` is the scratch space. Vault is
clearly bounded (read-only, at `Parachute/`). Everything else is yours.

For named envs, the writable overlay persists across sessions — files created in one
session are there for the next. This makes named envs genuinely durable project
environments, not just shared isolation.

### Repos: Clone or Mount

Two approaches, both supported:

**Clone inside the container** — run `git clone` inside `/home/sandbox/`. The repo lives
in the writable overlay. Works immediately. Persists with the named env. Accessible from
inside the container only. Fine for most project work, especially when starting fresh.

**Mount from host** — bind-mount an existing host directory into `/home/sandbox/<name>/`.
Multiple named envs can mount the same host repo. Host git tools work on it. Lifecycle
is independent of the container. This is the sharing case.

For v1: both paths are supported but neither has special UI. The user clones repos
inside the container naturally, or specifies a host path to mount when creating/joining
a named env. A "promote to host" flow (copy overlay files to host, switch to bind mount)
is future work.

### Shared Tools Volume

Named Docker volume `parachute-tools`, created at server startup if absent.
Mounted read-only at `/opt/parachute-tools/` in every container.

```
/opt/parachute-tools/
├── bin/        ← CLIs, scripts — in PATH
└── python/     ← pip packages — in PYTHONPATH
```

Anything written into this volume is immediately visible in all running containers.
A future tools installer session or CLI command writes here; for now it's seeded manually
or via `parachute tools install <package>`.

## Acceptance Criteria

- [x] Each sandboxed session gets its own container: `parachute-session-<session_id[:12]>`
- [x] Container created on first turn, `docker exec` on subsequent turns
- [x] Container removed when session is deleted or archived
- [x] User can save a container as a named env: `POST /api/containers {name, slug?}`
  creates a DB record and renames/labels the container as `parachute-env-<slug>`
- [x] Session can join a named env by passing `container_id` at session creation
- [x] Named envs listed via `GET /api/containers`
- [x] Named env deleted via `DELETE /api/containers/<slug>` (stops + removes container)
- [x] Working directory defaults to `/home/sandbox/` (no `/scratch/` subdirectory)
- [x] Vault mounted read-only at `/home/sandbox/Parachute/`
- [x] `parachute-tools` volume created at server startup if absent; mounted read-only
  at `/opt/parachute-tools/` in all containers; `bin/` in PATH, `python/` in PYTHONPATH
- [x] `reconcile()` on startup removes all `parachute-ws-*` and `parachute-default`
  containers immediately; cleans orphaned `parachute-session-*` containers
- [x] SDK transcript persistence: session containers mount
  `vault/.parachute/sandbox/sessions/<session_id[:8]>/.claude/` so transcripts survive
  container recreation
- [x] Named env containers mount `vault/.parachute/sandbox/envs/<slug>/.claude/`

## Technical Design

### Data model

**`ContainerEnv`** — new table in `sessions.db`:

```sql
CREATE TABLE container_envs (
    slug TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL
);
-- docker name is always: parachute-env-<slug>
```

Session record gains optional `container_env_id` (FK → `container_envs.slug`).
`NULL` means private container keyed by session ID.

### sandbox.py

**Add `ensure_session_container(session_id, config) → str`**
Container: `parachute-session-<session_id[:12]>`.
`.claude/` dir: `vault/.parachute/sandbox/sessions/<session_id[:8]>/.claude/`.

**Add `ensure_named_container(slug, config) → str`**
Container: `parachute-env-<slug>`.
`.claude/` dir: `vault/.parachute/sandbox/envs/<slug>/.claude/`.
Creates if absent, starts if stopped.

**Add `run_session(session_id, config, message, resume_session_id, container_name=None)`**
`container_name` provided → exec into named env.
`container_name` None → `ensure_session_container` then exec.

**Add `stop_session_container(session_id)`** — called on private session delete/archive.
Named env containers are not touched when a session ends.

**Add `delete_named_container(slug)`** — stops and removes named env container.

**Update `reconcile()`**:
- Create `parachute-tools` volume if absent
- Remove all `parachute-ws-*` and `parachute-default` containers immediately
- Remove orphaned `parachute-session-*` containers (no matching session in DB)
- Log discovered `parachute-env-*` containers

**Update `_build_persistent_container_args()`**:
Add `--mount source=parachute-tools,target=/opt/parachute-tools,readonly`.
Remove tmpfs at `/scratch` (no longer needed as a separate mount).

**Remove**: `ensure_container`, `run_persistent`, `run_default`,
`ensure_default_container`, `get_sandbox_claude_dir`, `cleanup_workspace_data`.

### orchestrator.py

```python
# Before
if workspace_id:
    sandbox_stream = self._sandbox.run_persistent(workspace_slug=workspace_id, ...)
else:
    sandbox_stream = self._sandbox.run_default(...)

# After
container_name = session.container_env_docker_name  # None for private sessions
sandbox_stream = self._sandbox.run_session(
    session_id=sandbox_sid,
    config=sandbox_config,
    message=sandbox_message,
    resume_session_id=resume_session_id,
    container_name=container_name,
)
```

Remove `stop_workspace_container`, `stop_default_container`.
Wire `stop_session_container(session_id)` to session delete/archive.

### API

```
GET    /api/containers           → list named envs
POST   /api/containers           → create named env {name, slug?}
DELETE /api/containers/<slug>    → delete named env (stops container)
```

`POST /api/chat` gains optional `container_id` param. When set, session runs inside
that named env.

### Dockerfile

```dockerfile
RUN mkdir -p /opt/parachute-tools/bin /opt/parachute-tools/python \
    && chown -R sandbox:sandbox /opt/parachute-tools

ENV PATH="/opt/parachute-tools/bin:${PATH}"
ENV PYTHONPATH="/opt/parachute-tools/python/lib/python3.13/site-packages:${PYTHONPATH}"
```

## Dependencies & Risks

**Shared writable overlay in named envs**: Multiple concurrent sessions in the same named
env share `/home/sandbox/`. File collisions are possible if sessions write the same paths
simultaneously. Acceptable for now — concurrent session use of the same env is uncommon,
and the alternative (per-session subdirectories) adds complexity without clear benefit yet.

**Orphan containers**: Caught by `reconcile()` on server startup.

**Transcript durability**: Host-mounted `.claude/` dirs survive container recreation.
Named envs have a shared `.claude/` dir so all sessions in that env can resume.

**Workspace capability filtering**: `workspace_id` on a session still exists in the DB
and can still carry MCPs/skills/model metadata. It just no longer determines which
container the session runs in. These two concepts are now fully decoupled.
