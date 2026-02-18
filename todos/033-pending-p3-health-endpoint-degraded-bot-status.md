---
status: pending
priority: p3
issue_id: 55
tags: [code-review, python, bot-connector, agent-native]
dependencies: []
---

# Health Endpoint Reports Minimal Bot Status (Only _running Bool)

## Problem Statement

The health endpoint at `health.py:95` checks `connector._running` (a deprecated compatibility boolean) rather than using the rich `connector.status` property that now includes state, uptime, reconnect attempts, and last error. Agents querying `/api/health` get less information than the `/api/bots/status` endpoint provides.

## Findings

- **Source**: agent-native-reviewer (F1, confidence 90), code-simplicity-reviewer (F2, confidence 85)
- **Location**: `computer/parachute/api/health.py:95`
- **Evidence**: `_running` is a simple bool; `status` property returns a dict with 6 fields including state, uptime, errors

## Proposed Solutions

### Solution A: Use status property in health endpoint (Recommended)
Replace `connector._running` with `connector.status["state"]` or include the full status dict.
- **Pros**: Consistent, agent-native, richer information
- **Cons**: Minor — health response shape changes
- **Effort**: Small
- **Risk**: Low

### Solution B: Remove _running boolean entirely
Remove the compatibility shim and update all consumers.
- **Pros**: Cleaner, single source of truth
- **Cons**: Must audit all _running references
- **Effort**: Small-Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/api/health.py`, `computer/parachute/connectors/base.py`
- **Database changes**: None

## Acceptance Criteria

- [ ] Health endpoint includes rich connector status
- [ ] Agents can determine connector state from health response

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from /para-review | |

## Resources

- PR branch: `feat/bot-connector-resilience`
- Issue: #55
