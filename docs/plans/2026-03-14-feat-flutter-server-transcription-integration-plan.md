---
title: "Flutter App: Server-Side Transcription Integration"
type: feat
date: 2026-03-14
issue: 262
---

# Flutter App: Server-Side Transcription Integration

Wire the Flutter app to use the new server-side transcription pipeline (`POST /api/daily/entries/voice`) when connected to a Parachute Computer server. Local transcription remains as the offline fallback. Companion to #260 / PR #261.

## Problem Statement

The server now has a voice entry endpoint that accepts audio, transcribes via Parakeet MLX (Metal GPU), and runs LLM cleanup — but the app still always transcribes locally and uploads text. Users don't need instant text; they want to record and move on. The server does a better job (GPU + cleanup) and the app should hand off when possible.

## Acceptance Criteria

- [x] Voice entries use server transcription when connected (auto mode default)
- [x] Settings toggle: auto / server / local transcription mode
- [x] App discovers server transcription capability via health endpoint
- [x] In-flight entries show progress and poll until resolved
- [x] `transcribed` intermediate state displays raw text with indicator
- [x] Server upload failure in auto mode falls back to local transcription
- [x] Local transcription path is completely unchanged when selected
- [x] No regression in offline-first behavior

## Proposed Solution

### Phase 1: Server Capability Discovery

**Goal:** The app knows whether the server can transcribe.

#### 1a. Server: Add `transcription_available` to health response

**File:** `computer/parachute/api/health.py`

Add `transcription_available: bool` to the basic health response (not just detailed). The app already calls `GET /api/health` on connect via `BackendHealthService`. Check `request.app.state` for the transcription service:

```python
basic = {
    "status": "ok",
    "timestamp": int(time.time() * 1000),
    "version": __version__,
    "transcription_available": bool(
        getattr(request.app.state, "transcribe_audio", None)
    ),
    ...
}
```

#### 1b. Flutter: Parse capability in BackendHealthService

**File:** `app/lib/core/services/backend_health_service.dart`

Add `transcriptionAvailable` field to `ServerHealthStatus`. Parse from health JSON:

```dart
class ServerHealthStatus {
  // ... existing fields ...
  final bool transcriptionAvailable;  // NEW
}
```

In `checkHealth()`, extract:
```dart
final transcriptionAvailable = data['transcription_available'] == true;
```

#### 1c. Flutter: Expose as Riverpod provider

**File:** `app/lib/core/providers/app_state_provider.dart` (or new provider file)

Create a `serverTranscriptionAvailableProvider` that derives from the existing health check state. This is the single boolean other providers read to decide the path.

### Phase 2: Transcription Mode Setting

**Goal:** User can choose auto / server / local.

#### 2a. Add setting persistence

**File:** `app/lib/features/daily/recorder/providers/service_providers.dart`

Follow existing pattern (`_autoEnhanceKey` / `autoEnhanceProvider` / `setAutoEnhance`):

```dart
enum TranscriptionMode { auto, server, local }

const String _transcriptionModeKey = 'transcription_mode';

final transcriptionModeProvider = FutureProvider<TranscriptionMode>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final value = prefs.getString(_transcriptionModeKey);
  return TranscriptionMode.values.firstWhere(
    (m) => m.name == value,
    orElse: () => TranscriptionMode.auto,
  );
});

Future<void> setTranscriptionMode(TranscriptionMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_transcriptionModeKey, mode.name);
}
```

#### 2b. Add settings UI

**File:** New `app/lib/features/settings/widgets/transcription_settings_section.dart`

A section in the settings screen with a segmented control or dropdown: Auto (recommended) / Server only / Local only. Include a subtitle showing current status ("Server transcription available" / "Using local transcription").

**File:** `app/lib/features/settings/screens/settings_screen.dart`

Add `TranscriptionSettingsSection()` to the settings list, near the existing Daily-related sections.

### Phase 3: Server Upload Path

**Goal:** When in server mode, voice entries upload audio to `POST /api/daily/entries/voice` and let the server handle everything.

#### 3a. Add `uploadVoiceEntry()` to DailyApiService

**File:** `app/lib/features/daily/journal/services/daily_api_service.dart`

New method matching the server's multipart endpoint:

```dart
/// Upload audio for server-side transcription + cleanup.
/// Returns the created entry (with transcription_status: processing).
Future<JournalEntry?> uploadVoiceEntry({
  required File audioFile,
  required int durationSeconds,
  String? date,
}) async {
  final uri = Uri.parse('$baseUrl/api/daily/entries/voice');
  final request = http.MultipartRequest('POST', uri)
    ..files.add(await http.MultipartFile.fromPath('file', audioFile.path))
    ..fields['date'] = date ?? _dateStr(DateTime.now())
    ..fields['duration_seconds'] = durationSeconds.toString();
  if (apiKey != null && apiKey!.isNotEmpty) {
    request.headers['X-API-Key'] = apiKey!;
  }
  // ... send, parse response as JournalEntry.fromServerJson
}
```

#### 3b. Add `getEntry()` to DailyApiService

**File:** `app/lib/features/daily/journal/services/daily_api_service.dart`

The server has `GET /api/daily/entries/{id}` but the app has no client method for it. Needed for polling:

```dart
Future<JournalEntry?> getEntry(String entryId) async {
  final uri = Uri.parse('$baseUrl/api/daily/entries/$entryId');
  final response = await _client.get(uri, headers: _headers).timeout(_timeout);
  if (response.statusCode == 200) {
    return JournalEntry.fromServerJson(jsonDecode(response.body));
  }
  return null;
}
```

#### 3c. Branch the recording flow in journal_screen.dart

**File:** `app/lib/features/daily/journal/screens/journal_screen.dart`

`_addVoiceEntry()` (line ~487) is the integration point. Branch based on resolved transcription mode:

```dart
Future<void> _addVoiceEntry(String transcript, String localAudioPath, int duration) async {
  final useServer = await _shouldUseServerTranscription();

  if (useServer) {
    await _addVoiceEntryViaServer(localAudioPath, duration);
  } else {
    await _addVoiceEntryLocally(transcript, localAudioPath, duration);
  }
}
```

**`_shouldUseServerTranscription()`** resolves mode:
- `local` → false
- `server` → true (fail if not available)
- `auto` → true if server connected AND transcription available, else false

**`_addVoiceEntryViaServer()`**: Calls `api.uploadVoiceEntry()`, caches the entry with `transcription_status: processing`, deletes local audio. No local transcription queued.

**`_addVoiceEntryLocally()`**: Existing flow (upload audio, create entry, queue PostHocTranscription).

**Error handling in auto mode:** If `uploadVoiceEntry()` fails, fall back to local path. Log the failure. Don't lose the recording.

### Phase 4: Entry Status Model Updates

**Goal:** The app understands the server's transcription status lifecycle.

#### 4a. Add `transcribed` to TranscriptionStatus enum

**File:** `app/lib/features/daily/journal/models/entry_metadata.dart`

```dart
enum TranscriptionStatus {
  pending,
  transcribing,
  transcribed,  // NEW: raw text ready, cleanup running
  complete,
  failed,
}
```

The `fromYaml` parser already handles unknown values gracefully (falls back to `complete`), so this is backwards-compatible.

#### 4b. Parse `transcription_status` in JournalEntry.fromServerJson

**File:** `app/lib/features/daily/journal/models/journal_entry.dart`

Currently `fromServerJson` doesn't extract transcription status from metadata. Add:

```dart
factory JournalEntry.fromServerJson(Map<String, dynamic> json) {
  final meta = (json['metadata'] as Map<String, dynamic>?) ?? {};
  // ... existing parsing ...

  // Parse transcription status
  final statusStr = meta['transcription_status'] as String?;
  final isPending = statusStr == 'processing' || statusStr == 'transcribed';

  return JournalEntry(
    // ... existing fields ...
    isPendingTranscription: isPending,
  );
}
```

Consider also storing the raw status string so the UI can distinguish `processing` (no text yet) from `transcribed` (raw text visible, cleanup running).

### Phase 5: In-Flight Entry Polling

**Goal:** Entries in `processing` or `transcribed` state auto-update when the server finishes.

#### 5a. Create TranscriptionPollingService

**File:** New `app/lib/features/daily/journal/services/transcription_polling_service.dart`

Light polling service — not a full state machine, just a timer:

```dart
class TranscriptionPollingService {
  final DailyApiService _api;
  final Set<String> _pollingEntryIds= {};
  Timer? _pollTimer;
  final void Function(JournalEntry updatedEntry) onEntryUpdated;

  void startPolling(String entryId) {
    _pollingEntryIds.add(entryId);
    _pollTimer ??= Timer.periodic(Duration(seconds: 5), (_) => _poll());
  }

  Future<void> _poll() async {
    for (final id in Set.of(_pollingEntryIds)) {
      final entry = await _api.getEntry(id);
      if (entry != null && !entry.isPendingTranscription) {
        _pollingEntryIds.remove(id);
        onEntryUpdated(entry);
      }
    }
    if (_pollingEntryIds.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }
}
```

**Timeout:** Stop polling individual entries after 5 minutes. Show "Taking longer than expected — tap to retry" state.

#### 5b. Wire polling into journal screen

After `_addVoiceEntryViaServer()` creates an entry, register its ID with the polling service. When `onEntryUpdated` fires, update the cached entry in the journal list and invalidate the provider.

#### 5c. Restart polling on screen load

When `JournalScreen` loads and there are entries with `processing` or `transcribed` status in today's journal, start polling them. Handles the case where the user navigated away and came back.

### Phase 6: UI for Transcription States

**Goal:** Voice entries show appropriate state in the journal list.

#### 6a. Processing state (no text yet)

Show in `JournalEntryCard`: shimmer/skeleton placeholder + "Transcribing..." label. Already partially implemented for local transcription via `isPendingTranscription` — extend to also cover server-side processing.

#### 6b. Transcribed state (raw text, cleanup running)

Show the raw transcription text (it's readable) with a subtle indicator: small text below or a chip saying "Cleaning up..." Use `BrandColors.driftwood` for the indicator text, not red — this isn't an error, it's progress.

#### 6c. Failed state

Show error with a "Retry" button. For server failures: retry sends the audio again via `uploadVoiceEntry()`. If audio file was already deleted, show "Audio unavailable" with no retry option.

## Implementation Order

1. **Phase 1** (server capability) — small, unblocks everything
2. **Phase 4** (status model) — model changes needed before UI work
3. **Phase 3** (server upload) — the core feature
4. **Phase 2** (settings) — can default to auto without UI initially
5. **Phase 5** (polling) — makes the flow complete
6. **Phase 6** (UI states) — polish

Phases 1+4 can be done together. Phase 3 is the bulk. Phase 2 settings UI can be deferred if needed (hardcode `auto` mode initially and add the toggle in a fast follow).

## Technical Considerations

### Files Modified

| File | Change |
|------|--------|
| `computer/parachute/api/health.py` | Add `transcription_available` to response |
| `app/lib/core/services/backend_health_service.dart` | Parse `transcription_available` |
| `app/lib/features/daily/journal/services/daily_api_service.dart` | Add `uploadVoiceEntry()`, `getEntry()` |
| `app/lib/features/daily/journal/models/entry_metadata.dart` | Add `transcribed` enum value |
| `app/lib/features/daily/journal/models/journal_entry.dart` | Parse `transcription_status` in `fromServerJson` |
| `app/lib/features/daily/journal/screens/journal_screen.dart` | Branch `_addVoiceEntry()` |
| `app/lib/features/daily/recorder/providers/service_providers.dart` | Add `TranscriptionMode` + provider |

### Files Created

| File | Purpose |
|------|---------|
| `app/lib/features/daily/journal/services/transcription_polling_service.dart` | Polls in-flight entries |
| `app/lib/features/settings/widgets/transcription_settings_section.dart` | Settings UI for mode toggle |

### Patterns to Follow

- **SharedPreferences for settings**: Key constant + `FutureProvider` + standalone setter (see `autoEnhanceProvider` in `service_providers.dart`)
- **API methods**: Match `DailyApiService` style — try/catch, timeout, debugPrint status, return null on failure
- **State updates**: Use `_ref.invalidate(selectedJournalProvider)` to refresh journal after polling updates an entry
- **Error fallback**: In auto mode, catch server errors and fall through to local. Never lose audio.

### Dependencies & Risks

- **PR #261 must merge first** — the server `POST /api/daily/entries/voice` endpoint doesn't exist on main yet
- **Audio file lifecycle** — in server mode, local audio is deleted after successful upload. If upload succeeds but server transcription fails, audio is gone. The server stores its own copy, so this is fine — but the app can't retry from local audio after deletion. Acceptable tradeoff.
- **Polling load** — 5-second interval for a handful of entries is negligible. But don't poll entries from old dates that were left in `processing` state — cap at today's entries or entries < 1 hour old.

## References

- Server transcription pipeline: #260 / PR #261
- Brainstorm: `docs/brainstorms/2026-03-14-flutter-server-transcription-integration-brainstorm.md`
- Server voice endpoint: `POST /api/daily/entries/voice` in `computer/modules/daily/module.py`
- Existing local transcription: `PostHocTranscriptionProvider` in `app/lib/features/daily/recorder/providers/`
