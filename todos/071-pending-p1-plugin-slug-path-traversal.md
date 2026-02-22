---
status: pending
priority: p1
issue_id: 75
tags: [code-review, security, python]
dependencies: []
---

# User-Supplied Plugin Slug Allows Path Traversal

## Problem Statement

`InstallPluginInput.slug` from the API body is passed directly to `install_plugin_from_url()` without sanitization. While `_derive_slug()` sanitizes URL-derived slugs via regex, a **user-provided slug** bypasses this entirely. A slug like `../../etc/passwd` would create path traversals in manifest paths, installed file prefixes, and temp directories.

Additionally, `get_plugin_skill` and `get_plugin_agent` use `:path` URL parameters that accept `../` segments, enabling traversal from the plugin directory to read arbitrary files.

## Findings

- **Source**: python-reviewer (P1, confidence 92/88)
- **Location**: `computer/parachute/api/plugins.py:110` (slug passthrough), `plugins.py:245,294` (`:path` params), `core/plugin_installer.py:44,189,409,548` (slug used in paths)
- **Evidence**: `body.slug` is user-controlled and used in `f"{slug}.json"`, `f"plugin-{slug}-"` path constructions without validation

## Proposed Solutions

### Solution A: Validate slug in Pydantic model + resolve-check in endpoints (Recommended)
Add `Field(pattern=r'^[a-zA-Z0-9][a-zA-Z0-9_-]*$')` to `InstallPluginInput.slug`. For `:path` params, validate resolved path stays within expected directory.
- **Pros**: Defense in depth, catches at input boundary
- **Cons**: None
- **Effort**: Small
- **Risk**: None

### Solution B: Apply `_derive_slug()` sanitization to user slugs too
Force all slugs through the regex sanitizer.
- **Pros**: Consistent behavior
- **Cons**: User may not get the slug they expect
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/api/plugins.py`, `computer/parachute/core/plugin_installer.py`

## Acceptance Criteria
- [ ] User-provided slugs are validated against allowlist regex
- [ ] `:path` parameters validated to prevent directory traversal
- [ ] No path construction from unsanitized user input

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | _derive_slug only applied to URL-derived slugs |

## Resources
- PR: #75
