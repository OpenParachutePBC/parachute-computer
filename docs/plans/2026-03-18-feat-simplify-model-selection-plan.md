---
title: "Simplify model selection + 1M context window"
type: feat
date: 2026-03-18
issue: 293
---

# Simplify Model Selection + 1M Context Window

Replace dynamic Anthropic API model fetching with a static Opus/Sonnet/Haiku picker and add a 1M context window toggle. The Claude Code CLI resolves short names to the latest version — lean on that instead of maintaining model list infrastructure.

## Problem

- ~200 lines of `models_api.py` (API fetching, pagination, caching, sorting) for a 3-model choice
- Supervisor regex `^claude-[a-z0-9\-]+$` blocks `[1m]` suffix — no path to enable 1M context from app
- Users hit frequent context compaction because 200K window fills fast; 1M is available but unreachable

## Acceptance Criteria

- [x] Model picker shows 3 options: Opus ("Most capable"), Sonnet ("Balanced"), Haiku ("Fastest")
- [x] "Extended context" toggle (default ON) appends `[1m]` to stored model
- [x] Config stores short names like `opus[1m]`, `sonnet`, `haiku[1m]`
- [x] Existing config values (e.g., `claude-sonnet-4-6`) migrate to short names on startup
- [x] `models_api.py` deleted — no Anthropic API calls for model listing
- [x] No "Show all versions" toggle, no "Latest" badges, no refresh button
- [x] Chat sessions use the configured model with 1M context when toggled

## Implementation

### Step 1: Server — Static models endpoint + relaxed validation

**Files:**
- `computer/parachute/supervisor.py` — Replace `/supervisor/models` with static list, relax config regex
- `computer/parachute/api/models.py` — Replace with static list
- `computer/parachute/models_api.py` — **Delete**

**Static model list** (returned by both endpoints):
```python
AVAILABLE_MODELS = [
    {"id": "opus", "display_name": "Opus", "family": "opus"},
    {"id": "sonnet", "display_name": "Sonnet", "family": "sonnet"},
    {"id": "haiku", "display_name": "Haiku", "family": "haiku"},
]
```

**New regex** for config validation:
```python
# Accept: opus, sonnet, haiku, opus[1m], sonnet[1m], haiku[1m]
# Also accept legacy full IDs for migration: claude-opus-4-6, claude-sonnet-4-6[1m]
r'^(opus|sonnet|haiku|claude-[a-z0-9\-]+)(\[\d+[km]\])?$'
```

**Remove**: `show_all` parameter, caching logic, API key requirement from models endpoint.

### Step 2: Server — Config migration on startup

**File:** `computer/parachute/config.py` (in the model_validator)

Add a migration step: if `default_model` matches a legacy full ID, map it to short name:
```python
MODEL_MIGRATION = {
    # Map any claude-{family}-* to just the family name
    # e.g., "claude-opus-4-6" → "opus", "claude-sonnet-4-6" → "sonnet"
}
```

Extract family from `claude-{family}-*` pattern. Preserve `[1m]` suffix if present. Write migrated value back to config.yaml.

### Step 3: Flutter — Simplified model picker

**Files:**
- `app/lib/features/settings/widgets/model_picker_dropdown.dart` — Rewrite
- `app/lib/core/models/supervisor_models.dart` — Simplify `ModelInfo`
- `app/lib/core/services/models_service.dart` — Simplify
- `app/lib/core/providers/supervisor_providers.dart` — Remove `showAll` param

**New ModelInfo:**
```dart
class ModelInfo {
  final String id;          // "opus", "sonnet", "haiku"
  final String displayName; // "Opus", "Sonnet", "Haiku"
  final String family;      // "opus", "sonnet", "haiku"
  // Remove: createdAt, isLatest
}
```

**New widget structure:**
- SegmentedButton or radio group with 3 options (not a dropdown)
- Toggle switch below: "Extended context (1M tokens)" — ON by default
- When model selected or toggle changed: combine into `opus[1m]` or `sonnet` and call `setModel()`
- Read current config and parse: split on `[` to get base model and whether `[1m]` is present

**Remove**: "Show all versions" checkbox, "Latest" badges, refresh button, error state for API failures.

### Step 4: Server — Clean up bridge agent

**File:** `computer/parachute/core/bridge_agent.py`

Change hardcoded `"claude-haiku-4-5-20251001"` → `"haiku"` (lines 108, 462). This is a nice-to-have for consistency — the CLI resolves it either way.

### Step 5: Update ChatRequest description

**File:** `computer/parachute/models/requests.py`

Update the `model` field description example from `'claude-sonnet-4-5-20250929'` to `'opus'` or `'sonnet[1m]'`.

### Step 6: Regenerate providers

```bash
cd app && dart run build_runner build --delete-conflicting-outputs
```

The `AvailableModels` provider changes signature (drops `showAll`), so the generated `.g.dart` must be rebuilt.

## Technical Considerations

- **The CLI resolves short names** — `opus` → latest Opus, `sonnet` → latest Sonnet. This is documented Claude Code behavior. The `[1m]` suffix is also a CLI feature for extended context.
- **Daily agents** have their own model field — separate concern, not changed here. They could adopt short names later.
- **No API key needed** for the models endpoint anymore — it returns a static list. Removes a failure mode (expired/missing token blocking model selection).
- **Migration is one-time** — once config.yaml is rewritten with short names, no further migration needed.

## Dependencies & Risks

- **Risk**: If Anthropic deprecates the short name aliases or `[1m]` syntax, this breaks. Mitigation: these are documented, stable Claude Code features.
- **Risk**: Users who want to pin a specific dated model version lose that ability. Mitigation: they can still manually edit config.yaml — just not via the app UI.
