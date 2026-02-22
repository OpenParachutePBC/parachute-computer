---
status: pending
priority: p2
issue_id: 75
tags: [code-review, security, python]
dependencies: []
---

# Manifest-Based Uninstall Missing Path Confinement Check

## Problem Statement

`uninstall_plugin()` reads `installed_files` from the manifest JSON and deletes files at `vault_path / rel_path` without verifying the resolved path stays within the vault. A tampered manifest could delete files outside the vault. The legacy uninstall path correctly uses `resolve().relative_to()` but the manifest path does not.

## Findings

- **Source**: security-sentinel (P2, confidence 85)
- **Location**: `computer/parachute/core/plugin_installer.py:520-530`
- **Evidence**: `full = vault_path / rel_path` with no `resolve().relative_to()` check. Legacy path at lines 509-511 has the correct pattern.

## Proposed Solutions

### Solution A: Add confinement check (Recommended)
Copy the `resolve().relative_to()` pattern from the legacy codepath.
- **Pros**: Consistent security, prevents directory traversal via tampered manifests
- **Cons**: None
- **Effort**: Small (5 lines)
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/plugin_installer.py`

## Acceptance Criteria
- [ ] Manifest-based uninstall validates paths stay within vault
- [ ] Paths outside vault are logged and skipped

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | Legacy path has the fix, new path missed it |

## Resources
- PR: #75
