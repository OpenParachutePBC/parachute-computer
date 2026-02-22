---
status: pending
priority: p2
issue_id: 75
tags: [code-review, performance, python]
dependencies: []
---

# Blocking Synchronous I/O in Async Plugin Install

## Problem Statement

`install_plugin_from_url` is async but performs `shutil.copy2()`, `shutil.copytree()`, `os.fsync()`, and file reads directly on the event loop, blocking all other requests during plugin installation.

## Findings

- **Source**: performance-oracle (P2, confidence 88)
- **Location**: `computer/parachute/core/plugin_installer.py:460-475`
- **Evidence**: `_install_files()`, `_write_manifest()`, `_scan_plugin_content()` all do synchronous I/O in async context.

## Proposed Solutions

### Solution A: Wrap in asyncio.to_thread (Recommended)
```python
installed = await asyncio.to_thread(_install_files, vault_path, slug, clone_dir, content)
```
- **Pros**: Unblocks event loop, simple wrapper
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/plugin_installer.py`

## Acceptance Criteria
- [ ] Blocking file I/O wrapped in asyncio.to_thread()
- [ ] Event loop not blocked during plugin install

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | git clone is async but file ops are sync |

## Resources
- PR: #75
