---
status: pending
priority: p2
issue_id: 91
tags: [code-review, security, python, matrix]
dependencies: []
---

# Ghost patterns match any homeserver domain

## Problem Statement

`BRIDGE_GHOST_PATTERNS` use `.+` for the homeserver portion (e.g., `r"^@meta_\d+:.+$"`). This means any user ID matching the `@meta_12345:*` pattern on any homeserver — including federated servers — will be classified as a bridge ghost. A malicious federated user could create an account like `@meta_999:evil.com` and join a room to trigger false bridge detection.

## Findings

- **Source**: security-sentinel (P2, confidence: 85)
- **Location**: `computer/parachute/connectors/matrix_bot.py:41-48` (`BRIDGE_GHOST_PATTERNS`)
- **Evidence**: All patterns use `.+$` for the homeserver suffix. In a federated Matrix deployment, user IDs from any server would match.

## Proposed Solutions

### Solution A: Restrict to local homeserver (Recommended)
At connector initialization, compile patterns using the configured homeserver domain:
```python
def _compile_ghost_patterns(self):
    domain = re.escape(self._homeserver_domain)
    prefixes = ["meta_", "telegram_", "discord_", "signal_"]
    return [re.compile(rf"^@{p}\d+:{domain}$") for p in prefixes]
```

- **Pros**: Only matches ghosts from the local bridge, prevents federated spoofing
- **Cons**: Slightly more setup; needs homeserver domain parsed from URL
- **Effort**: Small
- **Risk**: Low

### Solution B: Keep `.+` but document the assumption
If federation is disabled (localhost-only deployment), the current patterns are safe.

- **Pros**: No change needed
- **Cons**: Fragile if federation is ever enabled
- **Effort**: None
- **Risk**: Medium — assumption may not hold long-term

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/matrix_bot.py`
- **Lines**: 41-48

## Acceptance Criteria

- [ ] Ghost patterns only match user IDs from the local homeserver
- [ ] Federated user IDs with bridge-like prefixes are not misclassified as ghosts
- [ ] Tests updated to verify homeserver-scoped matching

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
