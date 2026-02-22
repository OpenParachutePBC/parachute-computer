---
status: pending
priority: p2
issue_id: 96
tags: [code-review, security, docker]
dependencies: []
---

# Dockerfile Node.js Install Uses `curl|bash` Without Integrity Verification

## Problem Statement

The Dockerfile installs Node.js by fetching and executing a shell script directly from a third-party domain (`deb.nodesource.com`) without verifying its integrity:

```dockerfile
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
```

This executes with `root` privileges inside the Docker build context. A supply chain attack on nodesource.com, a MITM attack on the build host's network, or DNS hijacking would cause an untrusted script to run during image construction. Additionally, `@anthropic-ai/claude-code` is installed with no version pin (`npm install -g @anthropic-ai/claude-code`), making builds non-reproducible and vulnerable to a compromised future version being pulled silently. The code's own `TODO` comment acknowledges this gap.

## Findings

- **Sources**: security-sentinel (confidence 85), parachute-conventions-reviewer (confidence 81)
- **Location**: `computer/parachute/docker/Dockerfile.sandbox`, lines 20 and 29
- **Evidence**:
  ```dockerfile
  # Node.js 22 (TODO: Add checksum verification in production)
  RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
      && apt-get install -y --no-install-recommends nodejs \
      && rm -rf /var/lib/apt/lists/*

  RUN npm install -g @anthropic-ai/claude-code  # No version pin
  ```
- **Impact scope**: Build-time only (not runtime). An attacker needs to compromise the build pipeline or build host network. The resulting image would then be used for all sandboxed agent sessions.

## Proposed Solutions

### Solution A: Use GPG-signed apt repository for Node.js (Recommended)
Replace `curl|bash` with the GPG-verified apt repository setup:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends gnupg curl \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
       > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
```

- **Pros**: Cryptographic integrity check on all downloaded packages; documented NodeSource best practice
- **Cons**: Slightly more complex
- **Effort**: Small
- **Risk**: Low

### Solution B: Pin `@anthropic-ai/claude-code` to a specific version
```dockerfile
RUN npm install -g @anthropic-ai/claude-code@0.2.109  # pin to known-good version
```
- **Pros**: Reproducible builds; known version audit trail
- **Cons**: Requires manual version bumps to update
- **Effort**: Small
- **Risk**: Low

Both A and B should be applied together.

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/docker/Dockerfile.sandbox`
- **Build context only**: This is a build-time risk, not a runtime risk. The sandbox image is built by operators, not by end users.

## Acceptance Criteria

- [ ] Node.js installation uses GPG-verified apt repository (or equivalent integrity check)
- [ ] `@anthropic-ai/claude-code` has a pinned version in the npm install command
- [ ] TODO comment about checksum verification is resolved or updated

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created from PR #96 code review | curl|bash is a build-time supply chain risk even if contained to Docker build context |

## Resources

- PR #96: https://github.com/OpenParachutePBC/parachute-computer/pull/96
- [NodeSource GPG-signed repository setup](https://github.com/nodesource/distributions?tab=readme-ov-file#debian-and-ubuntu-based-distributions)
