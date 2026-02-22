---
status: pending
priority: p2
issue_id: 75
tags: [code-review, performance, python]
dependencies: []
---

# Plugin Endpoints Scan All Plugins to Find One

## Problem Statement

`GET /plugins/{slug}` and `DELETE /plugins/{slug}` call `discover_plugins()` which reads every manifest + legacy + CLI plugin, when a direct manifest lookup via `get_install_manifest(vault_path, slug)` would be O(1).

## Findings

- **Source**: performance-oracle (P2, confidence 90)
- **Location**: `computer/parachute/api/plugins.py:85-95, 127`
- **Evidence**: `discover_plugins(settings.vault_path)` reads all manifests. Manifest-based lookup is O(1) file read.

## Proposed Solutions

### Solution A: Direct manifest lookup with legacy fallback (Recommended)
```python
manifest = get_install_manifest(settings.vault_path, slug)
if manifest:
    return _manifest_to_dict(manifest)
# fallback to discover_plugins for legacy/CLI
```
- **Pros**: O(1) for common case
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/api/plugins.py`

## Acceptance Criteria
- [ ] Single-plugin endpoints use direct manifest lookup first
- [ ] Legacy/CLI fallback preserved

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | O(N) scan when O(1) lookup available |

## Resources
- PR: #75
