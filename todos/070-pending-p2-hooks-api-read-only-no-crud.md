---
status: pending
priority: p2
issue_id: 75
tags: [code-review, agent-native, python]
dependencies: []
---

# Hooks API is Read-Only — No Create/Update/Delete Endpoints

## Problem Statement

The hooks API exposes only `GET /api/hooks` and `GET /api/hooks/errors`. There is no way to create, update, or delete SDK hooks via API. The Flutter UI tells users "Add hooks to .claude/settings.json" — directing them to manually edit JSON. This is an agent-native action parity gap: an agent wanting to configure a hook has no API to do so.

## Findings

- **Source**: agent-native-reviewer (P2, confidence 92)
- **Location**: `computer/parachute/api/hooks.py` (entire file — only two `@router.get` decorators)
- **Evidence**: No POST/PUT/DELETE routes. Hooks are now entries in `.claude/settings.json` which is easier to provide CRUD for than the old file-based system, but no write endpoints were added.

## Proposed Solutions

### Solution A: Add hooks CRUD endpoints (Recommended)
Add `POST /api/hooks` (add hook to event), `DELETE /api/hooks/{event}/{index}` (remove hook), reading/modifying the `hooks` key in `.claude/settings.json` atomically.
- **Pros**: Full agent-native parity, enables UI-driven hook management
- **Cons**: Needs atomic JSON read-modify-write
- **Effort**: Medium
- **Risk**: Low

### Solution B: Defer — document as known limitation
Add a note that hooks are SDK-managed and require manual config.
- **Pros**: No code changes
- **Cons**: Leaves action parity gap
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/api/hooks.py`, `app/lib/features/settings/widgets/hooks_section.dart`

## Acceptance Criteria
- [ ] Hooks can be created via API
- [ ] Hooks can be deleted via API
- [ ] Flutter UI offers hook management (or at least a link to the API)

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | JSON config files are easier to CRUD than file-based hooks |

## Resources
- PR: #75
