---
title: Versioned Builtin Agents
issue: 284
date: 2026-03-17
status: brainstorm
labels: [enhancement, daily, computer, app, P2]
---

# Versioned Builtin Agents

## The Problem We Hit

We shipped a better prompt for daily-reflection (changed "today's journal entries" to "yesterday's", fixed schedule from 21:00 to 4:00). The user's device still had the old version because `_seed_builtin_agents()` is write-once — if an Agent node exists, it skips it. The only fix was manually deleting the node and restarting the server.

This will keep happening. Every time we improve a builtin agent's prompt, tools, or configuration, existing users won't get it. The gap between "what we ship" and "what they have" grows with each release.

## Core Tension

Builtins should improve over time, but users should be able to customize without getting clobbered. This is the same problem `dpkg` has with config files, or how VS Code handles default settings vs user overrides.

## Proposed Design

### Version tracking

Add `template_version` (ISO date like `"2026-03-17"`) to both `AGENT_TEMPLATES` and the Agent graph node. On startup, compare versions to decide whether to update.

Add `user_modified` (boolean-as-string) to the Agent node. Flips to `"true"` when the user edits a builtin via the API. This is the signal that they've intentionally diverged.

### Startup logic

```
agent doesn't exist       → create, set template_version, user_modified="false"
exists, not modified, old → update in place to latest template
exists, modified          → log "update available but user customized, skipping"
exists, already current   → skip
```

### API additions

**GET `/agents/{name}/template`** — returns the latest template with comparison info (current version, update available, user modified status, full template body). Lets the app show update UI without embedding template knowledge.

**POST `/agents/{name}/reset-to-template`** — replaces config with latest template. Resets `user_modified` to `"false"`. Preserves runtime state (run history, session ID, counts).

### Flutter UI

- "Update available" badge on agent detail sheet when template is newer
- "Reset to default" action in detail/edit screens
- Subtle version display: "Default v2026-03-17" or "Customized"
- When editing a builtin, note that saving marks it as customized

## Design Decisions

### Whole-agent vs field-level updates

Start with whole-agent replacement. `user_modified` is binary — any edit blocks all template updates. Field-level tracking (only update fields the user didn't touch) is smarter but much more complex. The reset-to-template escape hatch covers the gap.

Could revisit if users frequently customize one thing (schedule_time) but want updates to another (system_prompt).

### Conservative first upgrade

Existing agents (pre-versioning) should be treated as `user_modified = "true"`. This avoids surprise changes on upgrade. Users opt in to the latest template via reset-to-template if they want it.

### Boolean flag vs hash-based detection

A boolean `user_modified` flag is simpler and covers the common case. Hash-based detection (store hash of template prompt at seed time, compare on startup) would catch the case where a user opens the edit screen, saves without changes, and still gets flagged as "modified" — but that's an edge case not worth the complexity right now.

### What counts as "modified"

The boolean flag treats all edits equally — toggling schedule_enabled counts the same as rewriting the system_prompt. This is the right default. If we had field-level tracking, we could be more selective, but that's future work.

## Edge Cases

- **New tools in template updates**: Agent gets the tool name in its tools JSON. It works once the module loads and provides the tool.
- **New builtin agents in future releases**: Existing logic handles this — doesn't exist, so it gets created. No version comparison needed.
- **Non-builtin (user-created) agents**: Completely unaffected. No `template_version` field.
- **Re-adopting after customizing**: That's what reset-to-template does. After reset, `user_modified` goes back to `"false"` and future template updates apply automatically.
- **Template removes a tool**: The agent's tools list gets updated on reset. Existing runs with the old tool are unaffected (AgentRun history is preserved).
- **Deleting a builtin agent**: Re-seeded on next startup. User should be informed of this.
- **Deleting an agent mid-run**: Current run completes (holds its own references), but no new runs will be scheduled/triggered.

## Agent Deletion (UI Gap)

Currently there's no way to delete agents from the Flutter UI. The `DELETE /agents/{name}` endpoint exists on the backend, but nothing in the app exposes it.

- **Delete action** in agent detail sheet or edit screen (button or menu item)
- **Confirmation dialog** — explain what happens, note that run history is preserved
- **Builtin vs user-created distinction**: Deleting a builtin should warn it'll be re-created on next restart (or offer "disable" as alternative). Deleting a user-created agent is permanent.
- **Backend**: Existing DELETE removes the Agent node. AgentRun nodes are orphaned by design (historical records). Should also clean up scheduled jobs.

## Open Questions

1. **Template changelog**: Should we maintain human-readable notes per version? ("v2026-03-17: Fixed reflection timing, improved prompt clarity.") Would help users decide whether to accept an update.

2. **Surfacing in GET `/agents` response**: Simplest approach is adding `update_available` and `template_version` to the existing agents list response. The app already fetches this on load — no new polling needed.

3. **Notification for modified agents**: When a user has customized a builtin and we ship an update, should the app show a one-time notification? Or just the badge in the agent list? Leaning toward just the badge — less intrusive.

4. **Automatic vs manual updates for unmodified builtins**: The proposed design auto-updates unmodified builtins on startup. This is the right default — if you haven't touched it, you want the latest. But should there be a preference to disable auto-updates? Probably not for now (YAGNI).

## References

- `AGENT_TEMPLATES` — `computer/modules/daily/module.py:75`
- `_seed_builtin_agents()` — `computer/modules/daily/module.py:704`
- `update_agent` PUT — `computer/modules/daily/module.py:2431`
- `DailyAgentInfo` — `app/lib/core/services/computer_service.dart:306`
- `AgentDetailSheet` — `app/lib/features/daily/journal/widgets/agent_detail_sheet.dart`
- #280 — Agent primitive rename (introduced current seed system)
