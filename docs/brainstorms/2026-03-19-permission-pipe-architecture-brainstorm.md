# Permission Pipe Architecture Cleanup

**Status:** Brainstorm
**Priority:** P1
**Issue:** #295
**Date:** 2026-03-19
**Module:** computer

---

## What We're Building

A simplified permission architecture that removes unnecessary pipe infrastructure from DIRECT trust sessions, suppresses unwanted Claude Code tools (AskUserQuestion, PlanMode), and hardens the remaining permission pipe for SANDBOXED sessions.

This is phase 1 of a larger effort to align the Claude Code integration with Parachute's own interaction model, eventually replacing the Claude Code preset system prompt with a Parachute-native one.

## Why This Approach

### The Problem

File edit operations intermittently fail with `Tool permission request failed: Error: Stream closed`. Read-only operations survive. The root cause is the permission prompt pipe between the Parachute orchestrator and the Claude Code CLI subprocess — a fragile async pipe that's in the critical path for every tool call, even though DIRECT trust sessions auto-approve everything.

### The Deeper Issue

The current architecture treats every session the same at the CLI level: all sessions use `--permission-prompt-tool stdio`, creating a bidirectional pipe for permission round-trips. For DIRECT trust sessions, the `PermissionHandler` immediately approves — but the pipe infrastructure is still there, adding fragility for zero benefit.

Additionally, Claude Code exposes tools designed for a human developer at a terminal (AskUserQuestion, PlanMode) that don't fit Parachute's orchestrator model. The `can_use_tool` callback is currently the mechanism to intercept these, but it requires the permission pipe to stay alive — coupling tool filtering to permission infrastructure.

### What We Decided

**For DIRECT trust sessions:**
- Skip the permission pipe entirely (use `--dangerously-skip-permissions` or equivalent CLI flag)
- Suppress unwanted tools (AskUserQuestion, PlanMode) via `can_use_tool` callback interception — return deny immediately without any pipe round-trip
- This eliminates the "Stream closed" bug for the common case

**For SANDBOXED sessions:**
- Keep the permission pipe (these sessions genuinely need permission gating)
- Add retry logic with pipe reconnection for transient failures
- Consider reducing the 120-second permission future timeout

**Tool suppression strategy:**
- Use `can_use_tool` callback to hard-deny: AskUserQuestion, PlanMode (EnterPlanMode/ExitPlanMode)
- This is a bridge solution — the longer-term fix is a custom system prompt that removes these tools from the model's vocabulary entirely (see companion brainstorm)

## Key Decisions

1. **DIRECT trust sessions should not use the permission pipe** — the auto-approve pattern adds latency and fragility with no security benefit
2. **AskUserQuestion should be denied at interception** — Parachute's interaction model has the agent communicate directly in its response, not via a separate question tool
3. **PlanMode should be denied at interception** — plan/execute flow is managed by Parachute's orchestrator, not the CLI's built-in plan mode
4. **Retry logic for SANDBOXED pipe failures** — when the pipe does fail for sandboxed sessions, catch and retry rather than failing the whole turn
5. **This is phase 1** — the full solution involves a custom system prompt (separate brainstorm) that makes tool suppression unnecessary by not offering the tools in the first place

## Open Questions

- What's the exact CLI flag or SDK option to skip permissions? Need to verify `--dangerously-skip-permissions` works without side effects on tool execution
- Are there other Claude Code tools beyond AskUserQuestion and PlanMode that should be suppressed?
- When `can_use_tool` denies AskUserQuestion, does the model gracefully fall back to inline communication, or does it error? Need to test
- Does skipping permissions affect the `stdin-must-stay-open` pattern, or is that only needed for the permission pipe?

## Scope

**In scope:**
- Permission pipe bypass for DIRECT trust
- Tool deny-list via `can_use_tool` (AskUserQuestion, PlanMode)
- Retry logic for SANDBOXED pipe failures
- Audit of which tools the callback currently handles

**Out of scope:**
- Custom system prompt (separate brainstorm)
- Changes to SANDBOXED permission model
- New permission UI in the Flutter app
