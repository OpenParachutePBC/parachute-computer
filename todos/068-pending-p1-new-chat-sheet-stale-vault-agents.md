---
status: pending
priority: p1
issue_id: 75
tags: [code-review, flutter, quality]
dependencies: []
---

# new_chat_sheet.dart Still References Removed `vault_agents` Source

## Problem Statement

The source consolidation in this PR renamed agent sources from `custom_agents`/`vault_agents` to `sdk` in `capabilities_screen.dart`, but `new_chat_sheet.dart` was not updated. Since the server now returns `'sdk'` instead of `'vault_agents'`, the ternary condition on line 432 can never be true. Also, `agent_info.dart` line 8 has a stale doc comment listing the old source values.

## Findings

- **Source**: flutter-reviewer (P1, confidence 95)
- **Location**: `app/lib/features/chat/widgets/new_chat_sheet.dart:432`, `app/lib/features/chat/models/agent_info.dart:8`
- **Evidence**: `agent.source == 'vault_agents'` — server no longer emits this value after this PR

## Proposed Solutions

### Solution A: Update source checks to 'sdk' (Recommended)
Change the ternary in `new_chat_sheet.dart:432` to check for `'sdk'` instead of `'vault_agents'`. Update the doc comment in `agent_info.dart` to list `"builtin", "sdk", "plugin"`.
- **Pros**: Complete migration, consistent with capabilities_screen.dart changes
- **Cons**: None
- **Effort**: Small (2 lines)
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/chat/widgets/new_chat_sheet.dart`, `app/lib/features/chat/models/agent_info.dart`

## Acceptance Criteria
- [ ] No references to `vault_agents` or `custom_agents` in Flutter codebase
- [ ] `agent_info.dart` doc comment reflects current source values

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | Incomplete migration — sibling file missed |

## Resources
- PR: #75
