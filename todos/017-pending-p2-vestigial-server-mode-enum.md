---
status: pending
priority: p2
issue_id: "30"
tags: [code-review, app, settings, tech-debt]
dependencies: []
---

# ServerMode enum is vestigial after Lima removal

## Problem Statement

`ServerMode` enum has a single value (`bareMetal`) after Lima VM removal in PR #43. The entire `ServerModeNotifier`/`serverModeProvider`/SharedPreferences machinery remains, and the setup wizard still presents a "choose your mode" screen with exactly one option the user must click through.

## Findings

- Discovered by: architecture-strategist, flutter-reviewer, code-simplicity-reviewer, performance-oracle (6/8 agents flagged this)
- Location: `app/lib/core/providers/app_state_provider.dart:35-60`
- Related UI: `computer_setup_wizard.dart` mode selection step, `_ModeCard` widget (lines 1238-1343)
- `setServerMode()` ignores its parameter and always writes `'bareMetal'`
- ~170 lines of dead ceremony across both files

## Proposed Solutions

### Option A: Remove ServerMode entirely (Recommended)
- Delete `ServerMode` enum, `ServerModeNotifier`, `serverModeProvider`
- Remove mode selection step from setup wizard, auto-advance from vault selection to prerequisites
- Delete `_ModeCard` widget (~106 lines) and `_buildModeSelection()` (~40 lines)
- Effort: Small
- Risk: Low -- single code path already

### Option B: Keep but simplify
- Keep enum for future extensibility (e.g., Docker mode)
- Auto-select `bareMetal` and skip the mode selection UI
- Effort: Small
- Risk: Low but leaves dead abstraction
