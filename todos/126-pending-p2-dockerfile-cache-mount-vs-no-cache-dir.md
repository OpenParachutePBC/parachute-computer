---
status: pending
priority: p2
issue_id: 96
tags: [code-review, docker, performance]
dependencies: []
---

# Dockerfile `--mount=type=cache` and `--no-cache-dir` Are Contradictory

## Problem Statement

The Dockerfile uses BuildKit's `--mount=type=cache,target=/root/.cache/pip` to speed up builds by preserving pip's build-time download cache between `docker build` invocations. However, every `pip install` call also includes `--no-cache-dir`, which explicitly tells pip to ignore the cache. The two flags cancel each other out: `--mount=type=cache` sets up a BuildKit cache directory, and `--no-cache-dir` instructs pip to not use it. The result is that every `docker build` re-downloads all packages from PyPI with zero benefit from the BuildKit cache.

## Findings

- **Sources**: pattern-recognition-specialist (confidence 83), architecture-strategist (confidence 82), python-reviewer (confidence 80)
- **Location**: `computer/parachute/docker/Dockerfile.sandbox`, lines 32-48
- **Evidence**:
  ```dockerfile
  # This cache mount is immediately negated by --no-cache-dir
  RUN --mount=type=cache,target=/root/.cache/pip \
      pip install --no-cache-dir \        # <-- cancels the mount above
      numpy==2.1.3 \
      pandas==2.2.3 \
      ...

  RUN --mount=type=cache,target=/root/.cache/pip \
      pip install --no-cache-dir \        # <-- same contradiction
      claude-agent-sdk
  ```

## Proposed Solutions

### Solution A: Remove `--no-cache-dir` (Recommended)
Keep the `--mount=type=cache` and remove `--no-cache-dir`. This is the correct pattern for BuildKit-accelerated builds.

```dockerfile
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install \
    numpy==2.1.3 \
    pandas==2.2.3 \
    ...
```

- **Pros**: Builds actually use the BuildKit cache; subsequent builds are much faster
- **Cons**: Build-time cache uses disk space (managed by BuildKit, bounded automatically)
- **Effort**: Small
- **Risk**: Low

### Solution B: Remove `--mount=type=cache` (alternative)
Keep `--no-cache-dir` and remove the `--mount=type=cache` mounts. Accept slower builds.
- **Pros**: Simpler Dockerfile, no BuildKit dependency
- **Cons**: Slower builds — every build downloads all packages
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/docker/Dockerfile.sandbox`
- **BuildKit cache behavior**: `--mount=type=cache` creates a persisted build-time overlay at the target path for the duration of the `RUN` command. Pip reads from and writes to `~/.cache/pip` by default. Without `--no-cache-dir`, pip checks this path for cached wheels before downloading.

## Acceptance Criteria

- [ ] `--mount=type=cache` and `--no-cache-dir` are not used together on the same `RUN` instruction
- [ ] Running `docker build` twice does not re-download packages (verifiable via build timing)

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created from PR #96 code review | --no-cache-dir and --mount=type=cache are mutually exclusive |

## Resources

- PR #96: https://github.com/OpenParachutePBC/parachute-computer/pull/96
- [Docker BuildKit cache mounts docs](https://docs.docker.com/build/cache/optimize/#use-cache-mounts)
