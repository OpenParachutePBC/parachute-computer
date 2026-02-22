---
status: pending
priority: p2
issue_id: 75
tags: [code-review, security, python]
dependencies: []
---

# No URL Scheme Validation Before `git clone`

## Problem Statement

`install_plugin_from_url` accepts an arbitrary URL string and passes it directly to `git clone`. No validation that the URL uses `https://`. Accepts `file://` URLs (could clone local filesystem paths), `ssh://`, and any protocol git supports.

## Findings

- **Source**: parachute-conventions-reviewer (P2, confidence 85)
- **Location**: `computer/parachute/core/plugin_installer.py:414-417`
- **Evidence**: `"git", "clone", "--depth", "1", url, str(clone_dir)` — url is unsanitized

## Proposed Solutions

### Solution A: Validate URL scheme is https:// (Recommended)
```python
from urllib.parse import urlparse
parsed = urlparse(url)
if parsed.scheme not in ("https", "http"):
    raise ValueError(f"Only HTTPS URLs supported, got: {parsed.scheme}")
```
- **Pros**: Simple, prevents file:// and ssh:// attacks
- **Cons**: Blocks legitimate ssh:// use (unlikely for plugin installs)
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/plugin_installer.py`

## Acceptance Criteria
- [ ] Only https:// (and optionally http://) URLs accepted for plugin install
- [ ] file://, ssh://, and other schemes rejected with clear error

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | git clone accepts many URL schemes |

## Resources
- PR: #75
