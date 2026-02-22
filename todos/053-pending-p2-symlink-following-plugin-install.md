---
status: pending
priority: p2
issue_id: 75
tags: [code-review, security, python]
dependencies: []
---

# Plugin Install Follows Symlinks — File Exfiltration Risk

## Problem Statement

`_install_files()` uses `shutil.copy2()` and `shutil.copytree()` which follow symlinks by default. A malicious plugin repo could contain symlinks pointing to sensitive host files, which would be copied into vault-accessible locations.

## Findings

- **Source**: security-sentinel (P2, confidence 82)
- **Location**: `computer/parachute/core/plugin_installer.py:247-275`
- **Evidence**: `shutil.copy2(src, dst)` and `shutil.copytree(src_dir, dst)` follow symlinks. `_scan_plugin_content` uses `rglob("*.md")` which also follows symlinks.

## Proposed Solutions

### Solution A: Add symlink rejection after clone (Recommended)
Add `_reject_symlinks(clone_dir)` check after git clone succeeds.
- **Pros**: Catches all symlinks in one check, blocks malicious repos
- **Cons**: Rejects plugins that legitimately use symlinks (unlikely)
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/plugin_installer.py`

## Acceptance Criteria
- [ ] Symlinks in cloned plugin repos are detected and rejected before file copy
- [ ] Error message explains the symlink was found

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | shutil defaults follow symlinks |

## Resources
- PR: #75
