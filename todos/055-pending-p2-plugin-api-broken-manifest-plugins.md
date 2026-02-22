---
status: pending
priority: p2
issue_id: 75
tags: [code-review, architecture, python]
dependencies: []
---

# Plugin Detail API Endpoints Broken for Manifest-Based Plugins

## Problem Statement

`_find_plugin_path()` returns `Path(plugin.path)` which for manifest-based plugins points to a `.json` file. Downstream endpoints (`GET /plugins/{slug}/skills/{name}`, `GET /plugins/{slug}/agents/{name}`) try to traverse `plugin_path / "skills"` which becomes `foo.json/skills` — a nonsensical path that always 404s.

## Findings

- **Source**: architecture-strategist (P2, confidence 88)
- **Location**: `computer/parachute/api/plugins.py:170-177, 245-321`
- **Evidence**: `_find_plugin_path(slug)` returns the manifest JSON path for manifest-based plugins. `get_plugin_skill()` and `get_plugin_agent()` then do `plugin_path / "skills" / name` which can't work.

## Proposed Solutions

### Solution A: Resolve from vault standard locations (Recommended)
For manifest-based plugins, resolve skill/agent content from `vault/.skills/plugin-{slug}-*` and `vault/.claude/agents/plugin-{slug}-*`.
- **Pros**: Works with the new architecture
- **Cons**: Requires reading the manifest to know installed file paths
- **Effort**: Medium
- **Risk**: Low

### Solution B: Add manifest-aware path resolution in `_find_plugin_path`
If path ends in `.json`, read the manifest and return the vault path + installed paths dict.
- **Pros**: Centralizes the logic
- **Cons**: Changes return type
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/api/plugins.py`

## Acceptance Criteria
- [ ] `GET /plugins/{slug}/skills/{name}` works for manifest-based plugins
- [ ] `GET /plugins/{slug}/agents/{name}` works for manifest-based plugins

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | manifest path != directory path |

## Resources
- PR: #75
