---
title: Daily online-first — complete migration (update, delete, search, cleanup)
type: feat
date: 2026-03-01
issue: 159
---

# Daily online-first — complete migration

Finish what PR #160 started. Creates are already API-backed. This plan routes the remaining
`JournalService` call sites (update, delete, search, Omi voice capture) through the server API,
then deletes the local-file stack.

## Problem Statement

PR #160 routes journal **creates** through `DailyApiService` but leaves five other operations
file-backed: `updateEntry` (inline edit, transcription update, post-transcription via Omi),
`deleteEntry`, and full-corpus text search. Reads come from the server; writes partially go to
local files. An edit made offline writes to `vault/journals/YYYY-MM-DD.md`; the next API read
ignores it. Merging this split architecture into main is the wrong call.

## Acceptance Criteria

- [x] `PATCH /api/daily/entries/{id}` updates content and/or metadata of an existing entry
- [x] `DELETE /api/daily/entries/{id}` deletes an entry file and its graph node
- [x] `GET /api/daily/entries/search?q=&limit=` returns keyword-matched entries across all dates
- [x] `DailyApiService` exposes `updateEntry()`, `deleteEntry()`, `searchEntries()`
- [x] All `journal_screen.dart` CRUD routes through `DailyApiService` — no `journalServiceFutureProvider`
- [x] `OmiCaptureService` routes voice creates and transcription updates through `DailyApiService`
- [x] `SimpleTextSearchService` sources data from `DailyApiService.searchEntries()`, not files
- [x] `JournalService`, `JournalMergeService`, `ParaIdService` deleted
- [x] `journalServiceFutureProvider` and `journalDatesProvider` deleted from providers
- [x] `ref.invalidate(journalServiceFutureProvider)` removed from vault settings + onboarding
- [x] `flutter analyze --no-fatal-infos` shows 0 errors
- [x] Server unit tests still pass

## Technical Design

### Server — three new endpoints

**`PATCH /entries/{entry_id}`**

Loads the existing `.md` file, updates only the fields provided in the request body, rewrites
the file, updates the graph node. Returns the full updated entry.

```python
class UpdateEntryRequest(BaseModel):
    content: str | None = None
    metadata: dict | None = None  # merged (not replaced) into existing frontmatter

@router.patch("/entries/{entry_id}")
async def update_entry(entry_id: str, body: UpdateEntryRequest):
    ...
```

Graph update: `SET e.content = $content, e.snippet = $snippet` — same lock pattern as create.

**`DELETE /entries/{entry_id}`**

Deletes the `.md` file. Removes the `Journal_Entry` graph node (and its `HAS_ENTRY` edge via
cascade). Returns 204 No Content.

**`GET /entries/search?q=&limit=`**

Iterates all `.md` files (sorted newest-first), loads content, does substring keyword matching.
Returns entries with `snippet`, `match_count`, and full `content`. Keeps scoring simple — same
logic as the current `SimpleTextSearchService` but on the server. Response shape:

```json
{
  "results": [
    { "id": "...", "created_at": "...", "content": "...", "snippet": "...",
      "match_count": 3, "metadata": {...} }
  ],
  "query": "hello world",
  "count": 5
}
```

### Flutter — `DailyApiService` additions

```dart
/// Update content and/or metadata of an existing entry.
/// Returns updated entry on success, null on error/offline.
Future<JournalEntry?> updateEntry(
  String entryId, {
  String? content,
  Map<String, dynamic>? metadata,
}) async { ... }  // PATCH /entries/{id}

/// Delete an entry. Returns true on success (including 404 — already gone).
Future<bool> deleteEntry(String entryId) async { ... }  // DELETE /entries/{id}

/// Keyword search across all entries.
/// Returns empty list on error/offline.
Future<List<SimpleSearchResult>> searchEntries(String query, {int limit = 30}) async { ... }
```

### Flutter — `journal_screen.dart` (5 call sites)

| Method | Currently | After |
|--------|-----------|-------|
| `_updatePendingTranscription` | `service.updateEntry()` | `api.updateEntry(entryId, content: transcript)` |
| `_saveCurrentEdit` | `service.loadDay()` + `service.updateEntry()` | `api.updateEntry(entryId, content: ..., metadata: ...)` — no pre-fetch needed |
| `_handleTranscribe` | `service.updateEntry()` | `api.updateEntry(entryId, content: transcript)` |
| `_showEntryDetail` (modal callback) | `service.updateEntry()` | `api.updateEntry(entry.id, content: ..., metadata: ...)` |
| `_handleDeleteEntry` | `service.deleteEntry()` | `api.deleteEntry(entry.id)` |

`_saveCurrentEdit` currently calls `service.loadDay()` to get the canonical entry before
patching. With the API, we don't need a full day fetch — the `PATCH` endpoint takes only the
fields to change. Use `_cachedJournal?.getEntry(entryId)` for the existing entry if needed
for the optimistic cache update, then fire the PATCH.

### Flutter — `OmiCaptureService`

Omi records audio to a temp WAV file, then calls `journalService.addVoiceEntry()` which
copies the file to the vault and writes the markdown. The file-copy responsibility moves out:

1. **File copy** — do it directly in `OmiCaptureService` via `FileSystemService.daily()`.
   `JournalService.addVoiceEntry()` already uses this internally; call it explicitly:
   ```dart
   final vaultAudioPath = await fileSystem.copyAudioToVault(tempWavPath);
   ```
   If `FileSystemService` doesn't expose `copyAudioToVault`, add it (it's ~5 lines — copy file,
   return vault-relative path).
2. **Entry create** — `api.createEntry(content: '', metadata: {'type': 'voice', 'audio_path': vaultAudioPath, ...})`
3. **Transcription update** — `_transcribeAndUpdateEntry` → `api.updateEntry(entry.id, content: transcript)`

`omiCaptureServiceProvider` swaps `getJournalService` for `getDailyApiService`:
```dart
getApiService: () => ref.read(dailyApiServiceProvider),
```

### Flutter — Search

`SimpleTextSearchService` keeps its scoring + snippet logic. Its data source changes from
`JournalService` to `DailyApiService.searchEntries()`:

```dart
// Before:
final dates = await _journalService.listJournalDates();
// ... load each day, scan entries

// After:
final apiResults = await _apiService.searchEntries(query, limit: limit);
// map to SimpleSearchResult (id, type, title, snippet, fullContent, date, matchCount, entryType)
```

`search_providers.dart`: swap `simpleTextSearchProvider`'s dependency from
`journalServiceFutureProvider` to `dailyApiServiceProvider`.

### Flutter — Cleanup (delete)

| File | Action |
|------|--------|
| `services/journal_service.dart` | Delete |
| `services/journal_merge_service.dart` | Delete |
| `services/para_id_service.dart` | Delete |
| `journal_providers.dart` — `journalServiceFutureProvider` | Delete |
| `journal_providers.dart` — `journalDatesProvider` | Delete |
| `vault_settings_section.dart:108` | Remove `ref.invalidate(journalServiceFutureProvider)` |
| `onboarding_screen.dart:181,214` | Remove `ref.invalidate(journalServiceFutureProvider)` |
| `journal_providers.dart` — `import journal_service.dart` | Remove |
| `journal_providers.dart` — `import para_id_service.dart` | Remove |

### What Stays

- `SyncProvider` / `SyncService` — used by settings sync UI, server settings reinit,
  journal header display, agent output file pulling (`syncNotifier.pullFile`), and app
  lifecycle hooks. Not Daily-specific. Leave untouched.
- `JournalService.dart` imports in `omi_providers.dart`, etc. — gone after OmiCaptureService
  is updated.

## Implementation Order

1. **Server** — `PATCH`, `DELETE`, `GET /search` (unblocks everything else)
2. **`DailyApiService`** — add `updateEntry`, `deleteEntry`, `searchEntries`
3. **`journal_screen.dart`** — route 5 call sites through API
4. **`OmiCaptureService`** — swap to API; add `FileSystemService.copyAudioToVault()` if needed
5. **Search** — rewrite `SimpleTextSearchService` to use `DailyApiService.searchEntries()`
6. **Cleanup** — delete the three service files + dead providers + stale invalidations
7. **Verify** — `flutter analyze`, server tests, then merge PR #160

## Dependencies & Risks

- **Offline edit/delete**: `updateEntry` and `deleteEntry` return `null`/`false` on failure.
  Show an error snackbar (same as the current catch blocks). No pending queue for edits — the
  PR description explicitly scopes that to "MVP: connect to see/edit journal". Acceptable.
- **Omi audio path**: `FileSystemService.daily()` exists and provides `getRecordingTempPath()`.
  Need to verify it also has or can get a `copyAudioToVault()` / `resolveAssetPath()` for the
  post-copy vault path. Check before implementing.
- **Search performance**: Server iterates all `.md` files per query. At personal journal scale
  (hundreds to low thousands of entries) this is fine. No index needed yet.
- **Graph node deletion**: `DELETE` needs to remove the `Journal_Entry` node + `HAS_ENTRY`
  edge. Kuzu relationship deletion may require matching the edge explicitly before deleting
  the node — test this in the unit tests.

## References

- PR #160: `feat/daily-online-first` branch
- Existing plan: `docs/plans/2026-03-01-feat-daily-online-first-plan.md`
- `DailyApiService`: `app/lib/features/daily/journal/services/daily_api_service.dart`
- `OmiCaptureService`: `app/lib/features/daily/recorder/services/omi/omi_capture_service.dart`
- `SimpleTextSearchService`: `app/lib/features/daily/search/services/simple_text_search.dart`
- Server module: `computer/modules/daily/module.py`
- Chat pattern (update/delete reference): `computer/modules/chat/module.py`
