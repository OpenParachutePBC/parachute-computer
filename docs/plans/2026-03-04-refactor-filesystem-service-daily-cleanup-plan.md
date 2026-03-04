---
title: "refactor(app): Simplify FileSystemService — remove vault path dependency from daily module"
type: refactor
date: 2026-03-04
issue: 177
---

# FileSystemService — Daily Module Cleanup

Remove the remaining vault-path dependency from the daily journal screen and clear stale SharedPreferences keys that accumulated before PR #173 moved audio storage server-side.

## Acceptance Criteria

- [ ] `FileSystemService` is not imported in `journal_screen.dart` or `journal_helpers.dart`
- [ ] `_handleTranscribe` uses `JournalHelpers.getAudioUrl()` — no vault-relative path construction
- [ ] Stale `parachute_daily_*` SharedPreferences keys are cleared on first launch after update
- [ ] No regression in chat log writing, reflection loading, or agent config loading

## Problem Statement

PR #173 moved audio storage server-side (`~/.parachute/daily/assets/`). Audio files are now served via HTTP by the Parachute server. However, two cleanup items remain:

1. **`_handleTranscribe` still constructs a local vault path** (`journal_screen.dart:786-788`) for re-transcription audio. With audio now HTTP-served, this should call `JournalHelpers.getAudioUrl()` like every other audio path in the app.

2. **SharedPreferences retains stale vault keys** from older installs: `parachute_daily_vault_path`, `parachute_daily_root_path`, `parachute_daily_secure_bookmark`, `parachute_daily_user_configured`, `parachute_daily_module_folder`, subfolder keys (`parachute_daily_journals_folder`, etc.). These are never written post-PR #173 but old installs carry them, causing confusing debug output.

## Proposed Solution

### Phase 1 — Fix `_handleTranscribe` (1 file, ~5 lines)

**File:** `app/lib/features/daily/journal/screens/journal_screen.dart`

Replace lines 784–788:
```dart
// Before
if (audioPath.startsWith('/')) {
  fullAudioPath = audioPath;
} else {
  final fileSystemService = ref.read(fileSystemServiceProvider);
  final vaultPath = await fileSystemService.getRootPath();
  fullAudioPath = '$vaultPath/$audioPath';
}

// After
final serverBaseUrl = ref.read(aiServerUrlProvider).valueOrNull ?? 'http://localhost:3333';
fullAudioPath = JournalHelpers.getAudioUrl(audioPath, serverBaseUrl);
```

Remove the `fileSystemServiceProvider` import from `journal_screen.dart`.

### Phase 2 — SharedPreferences one-time migration

**File:** `app/lib/core/services/file_system_service.dart` (or `app/lib/main.dart`)

Add a one-time migration that runs at startup (keyed by a migration version flag):

```dart
static const _migrationKey = 'parachute_fss_migration_v1';
static const _staleKeys = [
  'parachute_daily_vault_path',
  'parachute_daily_root_path',
  'parachute_daily_secure_bookmark',
  'parachute_daily_user_configured',
  'parachute_daily_module_folder',
  'parachute_daily_journals_folder',
  'parachute_daily_assets_folder',
  'parachute_daily_reflections_folder',
  'parachute_daily_chatlog_folder',
];

static Future<void> runMigrations() async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_migrationKey) == true) return;
  for (final key in _staleKeys) {
    await prefs.remove(key);
  }
  await prefs.setBool(_migrationKey, true);
}
```

Call `FileSystemService.runMigrations()` from `main()` before `runApp()`.

## What Stays Unchanged

The following daily services legitimately read/write vault files and **keep their `FileSystemService` dependency**:

| Service | What it writes | Keep? |
|---------|----------------|-------|
| `ChatLogService` | JSONL transcripts to `~/Parachute/Chat/` | Yes |
| `ReflectionService` | Reflection markdown to vault | Yes |
| `AgentOutputService` | Agent output markdown to vault | Yes |
| `LocalAgentConfigService` | Reads agent configs from vault | Yes |

The recorder services (`live_transcription_service.dart`, `transcription_queue.dart`, `streaming_audio_recorder.dart`, `omi_capture_service.dart`) use `FileSystemService.daily()` solely for **temp directory paths** — this doesn't require vault to be configured and is harmless. Migrating these to direct `path_provider` calls is tracked separately as tech debt.

Image path resolution in `journal_entry_row.dart` and `journal_entry_card.dart` also uses `fileSystemService.getRootPath()` for locally-attached images. This is out of scope — behavior for local images is unchanged.

## Technical Considerations

- `JournalHelpers.getAudioUrl()` already handles both HTTP URLs (passthrough) and relative paths (prefixes with server base URL). No new logic needed — just wire it up in `_handleTranscribe`.
- Migration key approach avoids running on every launch. Use a simple boolean flag, not a version integer, since there's only one migration to run at this stage.
- No DB changes, no server changes, no API changes.

## References

- PR #173 — Storage simplification (audio moved server-side)
- `app/lib/features/daily/journal/screens/journal_screen.dart:784` — current FSS usage
- `app/lib/core/services/file_system_service.dart:62` — SharedPreferences key structure
- `app/lib/features/daily/journal/utils/journal_helpers.dart` — `getAudioUrl()` implementation
