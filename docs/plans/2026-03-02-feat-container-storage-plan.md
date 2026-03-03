---
title: Container Storage — Persistent Scratch Volumes + Tools Installer
type: feat
date: 2026-03-02
issue: 146
---

# Container Storage — Persistent Scratch Volumes + Tools Installer

Named container envs get durable scratch storage that survives restarts, and a CLI command to install shared tools visible in all running containers.

## Problem Statement

Two gaps in the current container architecture:

1. **Scratch is ephemeral.** Every named env (`parachute-env-<slug>`) mounts `/scratch` as a tmpfs — wiped on container restart. Work-in-progress files, pip caches, built artifacts are lost. Private sessions (ephemeral by design) should keep tmpfs. Named envs should persist.

2. **No way to add tools.** The `parachute-tools` volume (`/opt/parachute-tools`) is mounted read-only in all containers. Nothing has been installed into it yet. There's no user-facing way to populate it.

## Proposed Solution

### Part 1 — Persistent scratch volumes

For named container envs, replace the tmpfs at `/scratch` with a named Docker volume `parachute-scratch-<slug>`. Private sessions (auto-UUID slug, ephemeral containers) keep the current tmpfs.

**Volume naming:** `parachute-scratch-<slug>`
**Labels:** `app=parachute,type=scratch,slug=<slug>` (consistent with existing container labels, enables `docker volume ls --filter label=app=parachute`)
**Mount path:** `/scratch` — unchanged, so the entrypoint needs no edits
**Size:** No explicit limit (named volumes = host disk; current tmpfs was 512m)

**Lifecycle:**
- Created (idempotent `docker volume create`) inside `ensure_container()` before the container starts
- Removed in `delete_container()` alongside the container stop/rm and home-dir cleanup
- Orphan cleanup in `reconcile()`: list volumes with `docker volume ls --filter label=type=scratch`, compare slugs against `active_slugs`, remove extras

### Part 2 — Tools installer CLI

`parachute tools install <pip-package>...`

Runs a short-lived helper container with `parachute-tools` mounted **read-write**, installs via pip into `/opt/parachute-tools/python/`, then exits and removes the container.

```
parachute tools install httpx pandas
parachute tools install ./my-local-package
```

**Container path structure (to be initialized):**
```
/opt/parachute-tools/
  bin/       → add to PATH in entrypoint
  python/    → add to PYTHONPATH in entrypoint
```

The entrypoint already sources `/opt/parachute-tools`. The directory structure just needs to exist and the paths added on container start.

**Helper container command:**
```
docker run --rm
  --mount source=parachute-tools,target=/opt/parachute-tools
  <sandbox-image>
  pip install --target /opt/parachute-tools/python <packages>
```

No network isolation flag (pip needs PyPI). No `--cap-drop ALL` (pip install needs standard caps). Runs as the same `sandbox` user.

**`parachute tools list`** — bonus subcommand: runs `pip list --path /opt/parachute-tools/python` in same helper container pattern.

## Implementation

### `computer/parachute/core/sandbox.py`

```python
SCRATCH_VOLUME_PREFIX = "parachute-scratch"
```

**`_is_private_session(slug: str) -> bool`**
Private sessions get auto-assigned UUID slugs (12 hex chars, no hyphens). Named envs have user-chosen display names slugified. We can distinguish by checking DB or by passing a flag. Simpler: add `is_named_env: bool` to `AgentSandboxConfig` (defaults False for auto-created private slugs).

Actually — even simpler: just always create a named volume for any slug. Private sessions are short-lived and their auto-slug volumes get cleaned up on `delete_container`. The volume creates no harm and is small. No distinction needed.

**Changes to `_build_persistent_container_args`:**
```python
# Replace:
"--tmpfs", "/scratch:size=512m,uid=1000,gid=1000",
# With:
"--mount", f"source={SCRATCH_VOLUME_PREFIX}-{slug},target=/scratch",
```

**New `_ensure_scratch_volume(slug: str)`:**
```python
async def _ensure_scratch_volume(self, slug: str) -> None:
    vol = f"{SCRATCH_VOLUME_PREFIX}-{slug}"
    proc = await asyncio.create_subprocess_exec(
        "docker", "volume", "create",
        "--label", "app=parachute",
        "--label", "type=scratch",
        "--label", f"slug={slug}",
        vol,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    await proc.wait()
```

Call from `ensure_container()` before `_ensure_container()`.

**Changes to `delete_container`:**
```python
# After removing home dir:
await self._remove_scratch_volume(slug)
```

**New `_remove_scratch_volume(slug: str)`:** `docker volume rm parachute-scratch-<slug>` (ignore errors — may not exist).

**Changes to `reconcile()`:**
After container orphan cleanup, also clean orphaned scratch volumes:
```python
# list scratch volumes, compare slugs against active_slugs, rm orphans
proc = await asyncio.create_subprocess_exec(
    "docker", "volume", "ls",
    "--filter", "label=type=scratch",
    "--format", "{{.Name}}",
    ...
)
```

### `computer/parachute/docker/entrypoint.py`

Add PATH/PYTHONPATH initialization so tools volume is usable:
```python
import os
tools_bin = "/opt/parachute-tools/bin"
tools_python = "/opt/parachute-tools/python"
os.makedirs(tools_bin, exist_ok=True)
os.makedirs(tools_python, exist_ok=True)
path = os.environ.get("PATH", "")
if tools_bin not in path:
    os.environ["PATH"] = f"{tools_bin}:{path}"
pythonpath = os.environ.get("PYTHONPATH", "")
if tools_python not in pythonpath:
    os.environ["PYTHONPATH"] = f"{tools_python}:{pythonpath}" if pythonpath else tools_python
```

(Currently `mkdir -p` may not be needed since the volume is ro — but for the installer path, the dirs need to exist first. The installer container creates them before pip installs.)

### `computer/parachute/cli.py`

Add `tools` subcommand under main parser:

```
parachute tools install <pkg>...   # pip install into parachute-tools volume
parachute tools list               # pip list from parachute-tools volume
```

**`cmd_tools_install(args)`:**
1. Find sandbox image name (use `SANDBOX_IMAGE` constant from `sandbox.py`)
2. Ensure parachute-tools volume exists (`docker volume create parachute-tools` — idempotent)
3. Run helper: `docker run --rm --mount source=parachute-tools,target=/opt/parachute-tools <image> sh -c "mkdir -p /opt/parachute-tools/python /opt/parachute-tools/bin && pip install --target /opt/parachute-tools/python <pkgs>"`
4. Print output live (don't capture — let pip output stream to terminal)

**`cmd_tools_list(args)`:**
`docker run --rm --mount source=parachute-tools,target=/opt/parachute-tools,readonly <image> pip list --path /opt/parachute-tools/python`

## Acceptance Criteria

- [x] Named container envs mount a named Docker volume at `/scratch`; files survive `docker restart parachute-env-<slug>`
- [x] `delete_container()` removes the scratch volume alongside the container
- [x] `reconcile()` removes orphaned scratch volumes (slugs not in DB)
- [x] `parachute tools install httpx` installs httpx into the shared tools volume; `import httpx` works in a running container without restart
- [x] `parachute tools list` shows installed packages
- [x] Entrypoint exports `/opt/parachute-tools/bin` to PATH and `/opt/parachute-tools/python` to PYTHONPATH
- [x] Private sessions (unnamed containers, if any remain) unaffected

## Files Changed

| File | Change |
|------|--------|
| `computer/parachute/core/sandbox.py` | Add `SCRATCH_VOLUME_PREFIX`, `_ensure_scratch_volume`, `_remove_scratch_volume`; update `_build_persistent_container_args`, `ensure_container`, `delete_container`, `reconcile` |
| `computer/parachute/docker/entrypoint.py` | Add PATH/PYTHONPATH init for `/opt/parachute-tools/bin` and `/opt/parachute-tools/python` |
| `computer/parachute/cli.py` | Add `tools` subcommand with `install` and `list` actions |

No DB changes. No Flutter changes. No API changes.

## Risks

- **Scratch volume disk usage**: Named volumes use host disk. Large or abandoned scratch volumes accumulate. Orphan cleanup in `reconcile()` mitigates this; `parachute sandbox clean-cache` could also prune scratch volumes.
- **pip install network in helper container**: The helper needs PyPI access. This is fine — it's an explicit user-initiated action, not a sandboxed agent.
- **Existing running containers**: Scratch volume mount change only takes effect when a container is recreated (next `ensure_container` after it's stopped). Entrypoint PATH change also only takes effect at next exec. Document this — no restart needed for tools installs (volume is live-shared), but scratch persistence requires a fresh container.
