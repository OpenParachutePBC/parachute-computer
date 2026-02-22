---
status: pending
priority: p2
issue_id: 96
tags: [code-review, performance, docker, sandbox]
dependencies: []
---

# Read-Only Cache Volumes Are Non-Functional (PIP_CACHE_DIR Not Set)

## Problem Statement

The PR mounts named Docker volumes as read-only caches (`parachute-pip-cache:/cache/pip:ro`, `parachute-npm-cache:/cache/npm:ro`) but never sets `PIP_CACHE_DIR=/cache/pip` or `NPM_CONFIG_CACHE=/cache/npm` environment variables in the container. By default, pip writes to `~/.cache/pip` (the running user's home) and npm writes to `/root/.npm` or `~/.npm`. The containers will never use the mounted volumes — every `pip install` inside the sandbox will hit PyPI fresh. The cache volumes exist but are empty and never read.

## Findings

- **Sources**: architecture-strategist (confidence 88), performance-oracle (confidence 90), parachute-conventions-reviewer (confidence 83)
- **Location**:
  - `computer/parachute/core/sandbox.py`, `_build_persistent_container_args()` — adds volume mounts
  - `computer/parachute/docker/Dockerfile.sandbox` — no `PIP_CACHE_DIR` env var set
- **Evidence**:
  ```python
  # sandbox.py: adds mounts but no env vars
  args.extend([
      "-v", "parachute-pip-cache:/cache/pip:ro",
      "-v", "parachute-npm-cache:/cache/npm:ro",
  ])
  # Missing:
  # args.extend(["-e", "PIP_CACHE_DIR=/cache/pip"])
  # args.extend(["-e", "NPM_CONFIG_CACHE=/cache/npm"])
  ```
  Also: even if env vars were set, the volumes are `:ro` (read-only), so pip can read cached packages from the volume but would fail to write new packages. The cache needs to be populated by a build step or a separate container that writes to the volume.

## Proposed Solutions

### Solution A: Add env vars but keep read-only (requires pre-population strategy)
Add `PIP_CACHE_DIR` and `NPM_CONFIG_CACHE` to container env, keep volumes as `:ro`.
- **Pros**: Cache poisoning is prevented by `:ro`; pre-populated caches would be used
- **Cons**: Cache volumes start empty; need a separate cache-warming step or Dockerfile that writes to named volumes
- **Effort**: Small for env var addition; Medium for cache-warming strategy
- **Risk**: Low

### Solution B: Use read-write cache volumes with no env vars change (Recommended for now)
Change `:ro` to `:rw` and add env vars. Let sandbox agents write to and read from the cache. Accept that a compromised agent could poison the cache (but the cache only affects other sandbox sessions, not the host).
- **Pros**: Cache actually works — pip installs are faster after first run
- **Cons**: Cache poisoning possible (sandbox agent writes malicious package to cache, future sessions use it). However: sandbox agents are already trusted to run arbitrary code — this is not a new capability.
- **Effort**: Small
- **Risk**: Low (within existing sandbox threat model)

### Solution C: Remove cache volumes entirely until properly designed (simplest)
Remove the non-functional cache volume mounts. They add complexity but provide zero value in current state.
- **Pros**: No false sense of caching, simpler code
- **Cons**: Performance benefit deferred
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**:
  - `computer/parachute/core/sandbox.py` — `_build_persistent_container_args()` method
- **Components**: DockerSandbox

## Acceptance Criteria

- [ ] Either: `PIP_CACHE_DIR` env var is set AND cache volumes work as intended
- [ ] Or: Cache volume mounts are removed until properly designed
- [ ] `pip install` inside the sandbox actually uses the cache volume (verifiable by timing two installs of the same package)

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created from PR #96 code review | Docker named volumes are inert unless the process inside the container is directed to write there via env vars or CLI flags |

## Resources

- PR #96: https://github.com/OpenParachutePBC/parachute-computer/pull/96
