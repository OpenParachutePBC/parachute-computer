---
status: pending
priority: p2
issue_id: 67
tags: [code-review, flutter, duplication]
dependencies: []
---

# Duplicated Warning Handler Logic in chat_message_providers.dart

## Problem Statement

The warning-text extraction and formatting logic is copy-pasted identically in two `case StreamEventType.warning` blocks in `chat_message_providers.dart` — the reattach path (lines ~751-761) and the sendMessage path (lines ~1541-1551). Any future change to warning formatting must be made in both places.

## Findings

- **Source**: pattern-recognition-specialist (95), architecture-strategist (92), code-simplicity-reviewer (92), flutter-reviewer (92), parachute-conventions-reviewer (88), git-history-analyzer (95), performance-oracle (88)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart:751-761, 1541-1551`
- **Evidence**: Identical 10-line blocks parsing title, message, details from `event.data` map and formatting into display string.

## Proposed Solutions

### Solution A: Extract `_formatWarningText(StreamEvent)` helper (Recommended)
Private method on the notifier that both switch cases call.
- **Pros**: Single definition, both callers become one-liners
- **Cons**: None
- **Effort**: Small (~15 min)
- **Risk**: None

### Solution B: Add accessors on StreamEvent
Add `warningTitle`, `warningMessage`, `warningDetails`, `formattedWarning` getters to `StreamEvent`, matching the pattern used for other event types.
- **Pros**: Consistent with existing accessor pattern, also fixes "no accessors" finding
- **Cons**: More code in stream_event.dart
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

**Affected files:**
- `app/lib/features/chat/providers/chat_message_providers.dart`
- Optionally: `app/lib/features/chat/models/stream_event.dart` (if adding accessors)

## Acceptance Criteria

- [ ] Warning text formatting logic exists in exactly one place
- [ ] Both reattach and sendMessage paths produce identical output

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #67 review | Dual-path processing in providers is a structural pattern — all new event types face this |

## Resources

- PR: #67
- Issue: #49
