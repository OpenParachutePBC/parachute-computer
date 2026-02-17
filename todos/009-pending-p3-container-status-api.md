---
status: pending
priority: p3
issue_id: 33
tags: [code-review, agent-native, api]
dependencies: []
---

# No API to Query Container Status or Manage Containers

## Problem Statement

There's no API endpoint to query the status of a persistent container for a workspace, restart a container, or force-recreate one. The health endpoint also doesn't report persistent container state. This limits agent-native operability.

## Findings

- **Source**: agent-native-reviewer
- **Location**: N/A — missing endpoints
- **Evidence**: No GET endpoint for container status, no POST for restart/recreate

## Proposed Solutions

### Solution A: Add container status to workspace API
Add `GET /api/workspaces/{slug}/container` returning status, uptime, resource usage.
- **Pros**: Agent-accessible, follows REST conventions
- **Cons**: New endpoint to maintain
- **Effort**: Medium
- **Risk**: Low

## Technical Details

- **Affected files**: New endpoint in `computer/parachute/api/workspaces.py` or new router

## Acceptance Criteria

- [ ] API endpoint returns container status (running/stopped/not-created)
- [ ] Health endpoint includes persistent container summary

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
