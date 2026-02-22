---
status: pending
priority: p2
issue_id: 35
tags: [code-review, architecture, completeness]
dependencies: []
---

# Incomplete send_message Implementation Returns Success

## Problem Statement

The `send_message` MCP tool validates messages but doesn't actually deliver them. It returns `success: True` with a note field explaining that "SDK message injection not yet implemented." This creates a broken contract where tools return success for incomplete operations.

**Why it matters:** Agents rely on MCP tool results. Returning success when the operation doesn't complete causes agent confusion and incorrect behavior.

## Findings

**Source:** parachute-conventions-reviewer agent (confidence: 95%)

**Location:** `computer/parachute/mcp_server.py:677-693`

```python
# TODO: Implement actual message injection into SDK session
# This requires extending the SDK to support mid-stream message injection
# For now, return success with a note
return {
    "success": True,
    "sender_session_id": sender_session_id,
    "recipient_session_id": session_id,
    "message_length": len(message),
    "workspace_id": sender_workspace_id,
    "note": "Message validated and logged. SDK message injection not yet implemented.",
}
```

**Problem:** The `success: True` field indicates completion, but the message was never delivered.

**Impact:**
- Agents believe messages were sent
- Coordination workflows fail silently
- Testing is difficult (success doesn't mean delivery)

## Proposed Solutions

### Option 1: Return Error Until Implemented (Recommended)
**Effort:** Small (5 minutes)
**Risk:** None (makes contract explicit)

```python
return {
    "error": "Message delivery not yet implemented. Validation passed, but delivery requires SDK mid-stream message injection support.",
    "validation_passed": True,
    "sender_session_id": sender_session_id,
    "recipient_session_id": session_id,
    "workspace_id": sender_workspace_id,
}
```

**Pros:**
- Honest contract: tool doesn't work yet
- Agents fail fast instead of silently
- Tests can detect incomplete implementation

**Cons:**
- Breaks existing code that checks `success` field

### Option 2: Implement Message Delivery Queue
**Effort:** Medium (2-3 hours)
**Risk:** Medium (requires orchestrator integration)

Write messages to a delivery queue that the orchestrator polls.

**Pros:**
- Actual delivery
- Complete feature

**Cons:**
- Larger scope
- Requires SDK changes

### Option 3: Remove Tool Until Complete
**Effort:** Small (10 minutes)
**Risk:** Low

Remove `send_message` from TOOLS list until SDK supports mid-stream injection.

**Pros:**
- No broken contracts
- Clear that feature isn't ready

**Cons:**
- Reduces multi-agent capabilities

## Recommended Action

**Return error until implemented** (Option 1) — makes the incomplete state explicit.

## Technical Details

**Affected files:**
- `computer/parachute/mcp_server.py` — send_message() function

**Current behavior:**
```json
{
  "success": true,
  "note": "Message validated and logged. SDK message injection not yet implemented."
}
```

**Proposed behavior:**
```json
{
  "error": "Message delivery not yet implemented. Validation passed.",
  "validation_passed": true
}
```

**Acceptance criteria for full implementation:**
- Message actually appears in recipient's session transcript
- Recipient sees message in their UI/agent context
- Delivery is transactional (all-or-nothing)

## Acceptance Criteria

**For interim fix (Option 1):**
- [ ] `send_message()` returns error response
- [ ] Response includes `validation_passed: true` field
- [ ] Tests updated to expect error
- [ ] Documentation notes incomplete implementation

**For full implementation (Option 2):**
- [ ] Messages delivered to recipient SDK session
- [ ] Delivery confirmed via integration tests
- [ ] Error handling for delivery failures
- [ ] Response returns `success: true` only after delivery

## Work Log

- 2026-02-22: Identified during code review by parachute-conventions-reviewer agent
- Deferred to Phase 2: SDK mid-stream message injection support

## Resources

- **Related TODO:** Line 683 in mcp_server.py
- **SDK issue:** Requires Claude SDK enhancement for mid-stream message injection
- **Source PR:** feat/multi-agent-workspace-teams branch
- **Issue:** #35 (Multi-Agent Workspace Teams)
