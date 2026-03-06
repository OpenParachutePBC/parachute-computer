---
title: Model Selection & Display — Coherent End-to-End Flow
type: feat
date: 2026-03-03
issue: 168
---

# Model Selection & Display — Coherent End-to-End Flow

Server `config.yaml` becomes the single source of truth for model selection. The broken `ModelPickerDropdown` gets wired up to real supervisor API calls. The old SharedPreferences path and hardcoded `ClaudeModel` enum are removed. The active model is shown in the chat UI.

## Problem

Three things are broken:

1. **Model picker is disabled** — `ModelPickerDropdown` has `onChanged: null` (literally can't select anything). The fallback `_buildFallbackPicker` shows a snackbar but saves nothing.
2. **Settings don't reach the server** — `ModelSelectionSection` saves to `SharedPreferences` only, never touching `config.yaml`. The server has `default_model: claude-sonnet-4-6` hardcoded and ignores app preferences.
3. **Model is hidden** — `ChatMessagesState.model` receives the actual model from the SSE stream but nothing displays it. Users see "Sonnet" (or nothing) instead of "Sonnet 4.6".

## Solution

**Source of truth:** `config.yaml` → `default_model`, managed via `PUT /supervisor/config`.

**Write path:** Settings UI → `SupervisorService.updateConfig()` → supervisor API → config.yaml updated atomically.

**Read path:** App reads `GET /supervisor/config` on startup, caches result in `supervisorConfigProvider`. Chat requests send the cached model ID explicitly. SSE stream confirms actual model used → displayed in chat.

**Removed:** `ClaudeModel` enum, `modelPreferenceProvider`, `ModelSelectionSection`.

## Acceptance Criteria

- [ ] Selecting a model in settings updates `config.yaml` via `PUT /supervisor/config`
- [ ] Settings dropdown shows the currently configured model as selected (reads from `GET /supervisor/config`)
- [ ] Chat requests send the full model ID (e.g., `claude-opus-4-6`) read from supervisor config
- [ ] Active model is shown in the chat UI (usage bar chip): "Sonnet 4.6", "Opus 4.6", etc.
- [ ] Model name formats correctly from ID: `claude-opus-4-6` → `Opus 4.6`
- [ ] `ClaudeModel` enum, `modelPreferenceProvider`, and `ModelSelectionSection` are deleted
- [ ] When supervisor is not running, settings show a clear message instead of a broken picker
- [ ] Changing model shows a snackbar confirmation: "Model set to Claude Opus 4.6"

## Implementation

### Step 1 — Add config read/write to `SupervisorService`

**File:** `app/lib/core/services/supervisor_service.dart`

Add two methods:

```dart
/// Read current server config (secrets redacted by server).
Future<Map<String, dynamic>> getConfig() async {
  final response = await _dio.get('/supervisor/config');
  return (response.data['config'] as Map<String, dynamic>?) ?? {};
}

/// Update config values. Does NOT restart server.
Future<void> updateConfig(Map<String, dynamic> values) async {
  await _dio.put('/supervisor/config', data: {'values': values, 'restart': false});
}
```

### Step 2 — Add `supervisorConfigProvider`

**File:** `app/lib/core/providers/supervisor_providers.dart`

New provider that reads and caches the server config. Notifier exposes `setModel()` which writes via supervisor and updates local state.

```dart
@riverpod
class SupervisorConfig extends _$SupervisorConfig {
  @override
  Future<Map<String, dynamic>> build() async {
    final service = ref.watch(supervisorServiceProvider);
    return service.getConfig();
  }

  /// Persist model change to server config and update local state.
  Future<void> setModel(String modelId) async {
    final service = ref.read(supervisorServiceProvider);
    await service.updateConfig({'default_model': modelId});
    // Update local state optimistically
    state = AsyncData({...?state.valueOrNull, 'default_model': modelId});
  }
}
```

Expose a convenience getter:
```dart
// Reads current default_model from cached supervisor config
String? supervisorConfigCurrentModel(SupervisorConfigRef ref) =>
    ref.watch(supervisorConfigProvider).valueOrNull?['default_model'] as String?;
```

### Step 3 — Fix `ModelPickerDropdown`

**File:** `app/lib/features/settings/widgets/model_picker_dropdown.dart`

Three changes:

**a) Read current model from supervisor config** (replaces the broken `statusAsync.maybeWhen(...)` that always returns null):
```dart
final currentModelId = ref.watch(supervisorConfigProvider).valueOrNull?['default_model'] as String?;
```

**b) Enable `onChanged`** and wire to supervisor config:
```dart
onChanged: (ModelInfo? model) async {
  if (model == null) return;
  try {
    await ref.read(supervisorConfigProvider.notifier).setModel(model.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Model set to ${model.displayName}')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update model')),
      );
    }
  }
},
```

**c) Remove `_buildFallbackPicker`** — replace with a simple error state message. The supervisor is always available when this widget is shown (settings_screen.dart already guards this).

### Step 4 — Simplify `settings_screen.dart`

**File:** `app/lib/features/settings/screens/settings_screen.dart`

Replace `_buildModelSection()`:
```dart
Widget _buildModelSection() {
  final supervisorStatusAsync = ref.watch(supervisorStatusNotifierProvider);
  return supervisorStatusAsync.when(
    data: (status) => status.supervisorUptimeSeconds > 0
        ? const ModelPickerDropdown()
        : _buildNoSupervisorModelMessage(),
    loading: () => _buildNoSupervisorModelMessage(),
    error: (_, __) => _buildNoSupervisorModelMessage(),
  );
}

Widget _buildNoSupervisorModelMessage() {
  // Simple informational text — no broken dropdown
  return Text('Start the Parachute server to configure the model.',
      style: ...);
}
```

### Step 5 — Update chat to read model from supervisor config

**File:** `app/lib/features/chat/providers/chat_message_providers.dart`

Replace the `modelPreferenceProvider` read (around line 1272):
```dart
// Before:
final modelPref = _ref.read(modelPreferenceProvider).valueOrNull;
final modelApiValue = modelPref?.apiValue;

// After:
final modelApiValue = _ref.read(supervisorConfigProvider).valueOrNull?['default_model'] as String?;
```

The rest of the send path stays the same — it passes `model: modelApiValue` to `streamChat()`. If `modelApiValue` is null (supervisor not running), the server falls back to its own configured default.

### Step 6 — Add model chip to usage bar

**File:** `app/lib/features/chat/widgets/usage_bar.dart`

In `_UsageContent.build()`, watch `chatMessagesProvider` for the active session model. Show a small model chip on the right side of the usage bar row:

```dart
// Add to end of Row children in _UsageContent:
Consumer(builder: (context, ref, _) {
  final model = ref.watch(chatMessagesProvider.select((s) => s.model));
  if (model == null) return const SizedBox.shrink();
  return _ModelChip(modelId: model, isDark: isDark);
}),
```

New `_ModelChip` private widget:
```dart
class _ModelChip extends StatelessWidget {
  final String modelId;
  final bool isDark;

  // Format "claude-opus-4-6" → "Opus 4.6"
  String get label {
    final parts = modelId.replaceFirst('claude-', '').split('-');
    if (parts.length < 2) return modelId;
    final family = parts[0][0].toUpperCase() + parts[0].substring(1);
    final version = parts.skip(1).join('.');
    return '$family $version';
  }

  @override
  Widget build(BuildContext context) {
    // Small pill chip showing e.g. "Opus 4.6"
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? ... : ...,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, ...)),
    );
  }
}
```

Note: `chatMessagesProvider` will need to be checked — it may need to be watched as a family or global. If no active session model, chip is hidden.

### Step 7 — Delete the old model system

- Delete `app/lib/features/settings/widgets/model_selection_section.dart`
- Remove `ClaudeModel` enum from `app_state_provider.dart` (lines 431–446)
- Remove `ModelPreferenceNotifier` + `modelPreferenceProvider` from `app_state_provider.dart` (lines 450–471)
- Remove any imports of `modelPreferenceProvider` / `ClaudeModel` from consuming files

## File Inventory

| File | Change |
|------|--------|
| `app/lib/core/services/supervisor_service.dart` | Add `getConfig()`, `updateConfig()` |
| `app/lib/core/providers/supervisor_providers.dart` | Add `SupervisorConfig` notifier |
| `app/lib/features/settings/widgets/model_picker_dropdown.dart` | Wire read/write, remove fallback picker |
| `app/lib/features/settings/screens/settings_screen.dart` | Simplify `_buildModelSection()` |
| `app/lib/features/chat/providers/chat_message_providers.dart` | Read model from supervisor config |
| `app/lib/features/chat/widgets/usage_bar.dart` | Add `_ModelChip` |
| `app/lib/core/providers/app_state_provider.dart` | Remove `ClaudeModel` enum + `modelPreferenceProvider` |
| `app/lib/features/settings/widgets/model_selection_section.dart` | **Delete** |

## Dependencies & Risks

- **`supervisorConfigProvider` failing** — If supervisor is down, model is null. Chat falls back to server default (no model sent). Graceful.
- **Model ID validation** — Server already validates `^claude-[a-z0-9\-]+$` on `PUT /supervisor/config`. Client doesn't need to re-validate.
- **Codegen** — `supervisor_providers.dart` uses `@riverpod` annotation + codegen (`part 'supervisor_providers.g.dart'`). New `SupervisorConfig` notifier must be annotated correctly and `flutter pub run build_runner build` run.
- **`chatMessagesProvider` scope** — Usage bar needs to watch the correct provider family key for the active session. Verify how the chat screen exposes the current session's messages state.

## References

- Brainstorm: `docs/brainstorms/2026-03-03-model-selection-display-brainstorm.md`
- Supervisor config endpoint: `computer/parachute/supervisor.py:315` (GET) and `:349` (PUT)
- Broken picker: `app/lib/features/settings/widgets/model_picker_dropdown.dart:194`
- Old model system: `app/lib/core/providers/app_state_provider.dart:431–471`
