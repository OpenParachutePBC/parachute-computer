---
title: "Versioned Builtin Agents"
type: feat
date: 2026-03-17
issue: 284
---

# Versioned Builtin Agents

Ship prompt and config improvements to existing users without clobbering their customizations.

## Problem

`_seed_builtin_agents()` is write-once — if an Agent node exists, it skips. Improvements to builtin agent prompts, schedules, and tools never reach existing users. The only workaround is manually deleting the node and restarting the server.

## Acceptance Criteria

- [x] `AGENT_TEMPLATES` entries have a `template_version` field (ISO date string)
- [x] Agent graph nodes gain `template_version` and `user_modified` columns
- [x] On startup, `_seed_builtin_agents()` auto-updates unmodified builtins when the template version is newer
- [x] Editing a builtin via `PUT /agents/{name}` sets `user_modified = "true"`
- [x] `GET /agents/{name}/template` returns latest template with comparison info
- [x] `POST /agents/{name}/reset-to-template` restores default config while preserving runtime state
- [x] `GET /agents` response includes `template_version`, `user_modified`, `update_available` for each agent
- [x] Flutter `DailyAgentInfo` model has `templateVersion`, `userModified`, `updateAvailable` fields
- [x] Agent detail sheet shows "Update available" badge + "Reset to default" action for builtins
- [x] Agent detail sheet shows "Delete agent" action with confirmation dialog
- [x] Existing pre-versioned agents are treated conservatively as `user_modified = "true"` on first upgrade

## Solution

### Phase 1: Backend — version tracking + smart seed (Python)

**1a. Add `template_version` to `AGENT_TEMPLATES`**

```python
AGENT_TEMPLATES: list[AgentTemplateDict] = [
    {
        "name": "daily-reflection",
        "template_version": "2026-03-17",
        ...
    },
]
```

Also add `template_version` to `AgentTemplateDict` TypedDict. The `post-process` agent is defined inline in `_seed_builtin_agents()` — add `template_version` there too. All builtin definitions should carry a version.

**1b. New columns on Agent node**

In `_ensure_new_columns()`, add:

```python
"template_version": ("STRING", "''"),
"user_modified": ("STRING", "''"),
```

Empty string = unversioned (pre-existing agent). The first-upgrade path treats these as `user_modified = "true"` — safe, no surprise rewrites.

**1c. Smarter `_seed_builtin_agents()` logic**

Replace the current "skip if exists" with:

```
for each builtin template:
    agent = MATCH (a:Agent {name: template.name})
    if not agent:
        CREATE with template_version, user_modified="false"
    elif agent.template_version == "" (pre-versioned):
        SET template_version = template.template_version, user_modified = "true"
        # Conservative: mark as modified so we don't overwrite unknowingly
    elif agent.user_modified == "true":
        log "update available for {name} but user customized, skipping"
    elif agent.template_version < template.template_version:
        UPDATE all config fields from template
        SET template_version = template.template_version
        log "updated builtin {name} from {old} to {new}"
    else:
        pass  # already current
```

Fields to update on auto-upgrade: `display_name`, `description`, `system_prompt`, `tools`, `schedule_time`, `trust_level`, `trigger_event`, `trigger_filter`, `memory_mode`, `template_version`, `updated_at`. Preserve: `schedule_enabled`, `enabled`, `sdk_session_id`, `last_run_at`, `run_count`, `last_processed_date`.

**1d. Set `user_modified` on PUT `/agents/{name}`**

In `update_agent()`, after the existing SET query, add logic:

```python
# If this is a builtin being edited by the user, mark as modified
if any(t["name"] == name for t in AGENT_TEMPLATES):
    # Also set user_modified in the same Cypher SET
    ...user_modified = "true"
```

Simplest: just always include `a.user_modified = "true"` in the SET for builtins. Non-builtins will have the column but it doesn't affect anything.

Actually, cleaner: always SET `user_modified = "true"` in the update_agent endpoint. It's harmless for user-created agents and correct for builtins.

**1e. New endpoint: `GET /agents/{name}/template`**

Returns the latest template for a builtin agent, with comparison info:

```json
{
    "name": "daily-reflection",
    "is_builtin": true,
    "template_version": "2026-03-17",
    "current_version": "2026-03-10",
    "update_available": true,
    "user_modified": true,
    "template": { ...full template fields... }
}
```

For non-builtin agents, returns `{"is_builtin": false}`.

**1f. New endpoint: `POST /agents/{name}/reset-to-template`**

- Look up template by name in `AGENT_TEMPLATES` (or inline builtins list)
- Replace config fields (same set as auto-upgrade)
- Reset `user_modified = "false"`, set `template_version` to current
- Preserve runtime state: `sdk_session_id`, `last_run_at`, `run_count`, `schedule_enabled`, `enabled`
- Return the updated agent

**1g. Enrich `GET /agents` response**

Add computed fields to each agent in `list_agents()`:

```python
for agent in rows:
    tpl = next((t for t in ALL_BUILTINS if t["name"] == agent["name"]), None)
    agent["is_builtin"] = tpl is not None
    if tpl:
        agent["latest_template_version"] = tpl["template_version"]
        agent["update_available"] = (
            agent.get("user_modified") == "true"
            and agent.get("template_version", "") < tpl["template_version"]
        ) or (
            agent.get("user_modified") != "true"
            and agent.get("template_version", "") < tpl["template_version"]
        )
    else:
        agent["update_available"] = False
```

Note: `update_available` is true whenever the template is newer than what's on the node — regardless of `user_modified`. The app can decide how to surface it (badge for modified, auto-applied for unmodified).

**1h. Backend delete cleanup**

The existing `DELETE /agents/{name}` endpoint works. Add scheduler cleanup:

```python
@router.delete("/agents/{name}", status_code=204)
async def delete_agent(name: str):
    # ... existing delete logic ...
    # Also remove from scheduler if it was scheduled
    if hasattr(self, '_scheduler') and self._scheduler:
        self._scheduler.remove_job(name)  # or however scheduler tracks agents
```

### Phase 2: Flutter — model + UI (Dart)

**2a. Update `DailyAgentInfo` model**

Add fields:

```dart
final String? templateVersion;
final bool userModified;
final bool updateAvailable;
final bool isBuiltin;
```

Parse in `fetchAgents()`:

```dart
templateVersion: j['template_version'] as String?,
userModified: j['user_modified']?.toString().toLowerCase() == 'true',
updateAvailable: j['update_available'] == true,
isBuiltin: j['is_builtin'] == true,
```

**2b. Add `DailyApiService` methods**

```dart
/// Fetch the latest template for a builtin agent.
Future<Map<String, dynamic>?> fetchAgentTemplate(String name) async { ... }

/// Reset a builtin agent to its latest template.
Future<bool> resetAgentToTemplate(String name) async { ... }
```

**2c. Agent detail sheet updates**

In the Actions section of `AgentDetailSheet`, add:

1. **"Update available" badge** — show near the agent name when `agent.updateAvailable && agent.userModified`. Tapping opens a confirmation dialog: "A new default version is available. Reset to default? Your customizations will be replaced."

2. **"Reset to default" action** — visible only for builtin agents (`agent.isBuiltin`). Calls `resetAgentToTemplate()`. Confirmation dialog similar to the existing reset-session one.

3. **"Delete agent" action** — at the bottom of actions list, styled in error/warning color.
   - For **user-created agents**: "Delete [name]? This removes the agent permanently. Run history is preserved."
   - For **builtin agents**: "Delete [name]? This agent is a built-in default and will be recreated on next server restart. Run history is preserved."
   - On confirm: call `deleteAgent()`, pop the sheet, invalidate `agentsProvider`.

**2d. Agent management screen — badges**

In `_AgentCard`, add a small dot/badge indicator when `agent.updateAvailable`. Subtle — not intrusive.

**2e. Agent edit screen — "customized" notice**

When editing a builtin agent, show a subtle info banner at the top: "Saving changes will mark this as customized. You can always reset to the default later."

### Phase 3: Post-process builtin consolidation

Currently `post-process` is defined inline in `_seed_builtin_agents()` rather than in `AGENT_TEMPLATES`. For consistency:

- Move `post-process` template definition to `AGENT_TEMPLATES` (or a parallel `BUILTIN_AGENTS` list that includes triggered agents)
- Alternatively, create an `ALL_BUILTINS` list that combines `AGENT_TEMPLATES` + inline triggered definitions
- The key requirement: every builtin must have a canonical template with `template_version` that the comparison logic can reference

The simplest approach: add a `TRIGGERED_AGENT_TEMPLATES` list alongside `AGENT_TEMPLATES`, or just add `post-process` to `AGENT_TEMPLATES` directly (it already shares the same TypedDict shape minus `schedule_time`).

## Technical Considerations

- **String comparison for versions**: ISO dates (`"2026-03-17"`) sort lexicographically, so `<` comparison works. No need for date parsing.
- **Column migration**: `_ensure_new_columns()` already handles adding new columns with defaults. Empty string default for both new columns.
- **First upgrade path**: Pre-versioned agents get `template_version` set to the current version and `user_modified = "true"`. This means they won't auto-update but will show "update available" = false (versions match). If we later bump the template version, they'll see the badge.
- **Scheduler cleanup on delete**: Need to verify how the scheduler tracks agents. If it reads from the graph each time, deletion is sufficient. If it caches jobs, we need explicit removal.

## Files to Modify

**Python (computer/):**
- `modules/daily/module.py` — `AgentTemplateDict`, `AGENT_TEMPLATES`, `_ensure_new_columns()`, `_seed_builtin_agents()`, `update_agent()`, `delete_agent()`, `list_agents()`, new `get_agent_template()` and `reset_to_template()` endpoints

**Flutter (app/):**
- `lib/core/services/computer_service.dart` — `DailyAgentInfo` model
- `lib/features/daily/journal/services/daily_api_service.dart` — `fetchAgents()` parsing, new `fetchAgentTemplate()`, `resetAgentToTemplate()` methods
- `lib/features/daily/journal/widgets/agent_detail_sheet.dart` — update badge, reset-to-default action, delete action
- `lib/features/daily/journal/screens/agent_management_screen.dart` — update-available badge on cards
- `lib/features/daily/journal/screens/agent_edit_screen.dart` — "customized" notice banner

## Dependencies & Risks

- **Low risk**: All changes are additive. New columns have defaults. Old clients ignore new fields.
- **Migration**: `_ensure_new_columns()` handles schema evolution. No data loss.
- **Backward compat**: Agents without `template_version` are treated as modified — safe default.
