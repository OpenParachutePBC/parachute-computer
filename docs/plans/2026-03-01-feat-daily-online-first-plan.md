---
title: Daily module — online-first architecture
type: feat
date: 2026-03-01
issue: 159
---

# Daily module — online-first architecture

Rewrite Flutter Daily to work like Chat: server API is authoritative, the offline sync
infrastructure is removed. Flutter POSTs entries to the server, GETs them from the server.
Offline writes land in a visible pending queue and upload when connectivity returns.

## Problem Statement

Flutter Daily and the server Daily module are two parallel, incompatible systems:

- **Flutter**: reads/writes `vault/journals/YYYY-MM-DD.md` (one file per day, H1-delimited entries)
  via a 1,261-line `JournalService`. Changes are pushed to the server via a 1,282-line
  `SyncService`/`SyncProvider` that handles versioning, tombstones, conflict resolution, and
  60-second merge windows.

- **Server**: reads/writes `vault/Daily/entries/YYYY-MM-DD-HH-MM.md` (one file per entry)
  via a clean `DailyModule` with graph indexing.

These two systems use different file formats and never read each other's output. The sync service
exists entirely to paper over this divergence.

## Proposed Solution

Drop the local-first model. Flutter calls the server API directly, exactly as Chat does. The only
offline accommodation: a `PendingEntryQueue` that saves unsent entries to `SharedPreferences` and
flushes them in order when connectivity returns. Pending entries are shown in the UI with a clear
"not uploaded" indicator so the user always knows what state they're in.

## Acceptance Criteria

- [x] `GET /api/daily/entries?date=YYYY-MM-DD` returns only entries for that date
- [x] Flutter `DailyApiService` wraps `POST` and `GET /entries?date=` (no local file ops)
- [x] Offline writes go into `PendingEntryQueue` (SharedPreferences JSON list)
- [x] Pending entries are visible in the journal UI with a "not uploaded" indicator
- [x] Queue flushes in order when connectivity returns; failed sends stay in queue
- [ ] `JournalService` is deleted; no file reads/writes in the Daily write path (deferred — used by edit/search)
- [ ] `SyncService` and `SyncProvider` are deleted (Daily was the only caller) (deferred — used by settings/main)
- [ ] `JournalMergeService` is deleted (deferred — safe to delete, blocked on above)
- [ ] `ParaIdService` (daily module) is deleted — IDs now come from server (deferred)
- [x] All existing Flutter tests pass; no new broken imports
- [x] Server unit tests still pass (506 passed, 0 failed)

## Technical Design

### Server change (1 file)

`computer/modules/daily/module.py` — add `date` query param to `list_entries()` and the
`GET /entries` route:

```python
def list_entries(self, limit: int = 20, offset: int = 0, date: str | None = None) -> list[dict]:
    files = sorted(self.entries_dir.glob("*.md"), reverse=True)
    if date:
        files = [f for f in files if f.stem.startswith(date)]
    for md_file in files[offset:offset + limit]:
        ...

@router.get("/entries")
async def list_entries(
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    date: str | None = Query(None),
):
    entries = self.list_entries(limit=limit, offset=offset, date=date)
    return {"entries": entries, "count": len(entries), "offset": offset}
```

`entry_id` format is `YYYY-MM-DD-HH-MM`, so `f.stem.startswith(date)` is sufficient. No regex needed.

### Flutter: new `DailyApiService`

`app/lib/features/daily/journal/services/daily_api_service.dart`

Thin HTTP client following the `ChatService` shape — `baseUrl` + optional `apiKey` + `http.Client`.
Two methods:

```dart
Future<List<JournalEntry>> getEntries({required String date})
// GET /api/daily/entries?date=YYYY-MM-DD
// Returns entries sorted newest-first; empty list if offline/error

Future<JournalEntry?> createEntry({
  required String content,
  Map<String, dynamic>? metadata,
})
// POST /api/daily/entries
// Returns the server entry (with entry_id) on success, null on failure
```

Gets its `baseUrl`/`apiKey` from `ComputerService` (same pattern as other services in the app).

### Flutter: `PendingEntryQueue`

`app/lib/features/daily/journal/services/pending_entry_queue.dart`

SharedPreferences-backed JSON list. Each pending entry stores:

```dart
{
  "localId": "<uuid>",        // temporary ID shown in UI until server assigns one
  "content": "...",
  "metadata": {...},          // type, audioPath, etc.
  "queuedAt": "ISO8601",
}
```

API:
- `enqueue(content, metadata)` — append to list, return a `PendingEntry` for immediate UI display
- `flush(DailyApiService)` — try each entry in order; remove successes, leave failures
- `entries` getter — current list (for UI)
- `listenConnectivity()` — subscribe to `connectivity_plus` changes; call `flush()` on reconnect

### Flutter: `JournalEntry` model update

Add `isPending` and `fromServerJson()`:

```dart
// New field
final bool isPending;

// New factory
factory JournalEntry.fromServerJson(Map<String, dynamic> json) {
  final meta = json['metadata'] as Map<String, dynamic>? ?? {};
  final typeStr = meta['type'] as String? ?? 'text';
  return JournalEntry(
    id: json['id'] as String,
    title: meta['title'] as String? ?? '',
    content: json['content'] as String? ?? '',
    type: _parseType(typeStr),
    createdAt: DateTime.parse(json['created_at'] as String),
    audioPath: meta['audio_path'] as String?,
    imagePath: meta['image_path'] as String?,
    durationSeconds: meta['duration_seconds'] as int?,
  );
}

// New factory for pending queue entries
factory JournalEntry.pending({
  required String localId,
  required String content,
  required JournalEntryType type,
  Map<String, dynamic>? metadata,
}) => JournalEntry(
  id: localId,
  title: metadata?['title'] ?? '',
  content: content,
  type: type,
  createdAt: DateTime.now(),
  isPending: true,
  ...
);
```

Remove the `h1Line` getter and `isPlainMarkdown` field (file-format artifacts no longer needed).

### Flutter: Updated `journal_providers.dart`

Replace the file-backed providers with server-backed ones:

```dart
// REMOVE: journalServiceFutureProvider (file-based init chain)
// REMOVE: journalDatesProvider (was reading files to list dates)
// ADD:
final dailyApiServiceProvider = Provider<DailyApiService>((ref) { ... });
final pendingQueueProvider = Provider<PendingEntryQueue>((ref) { ... });

// REWRITE: todayJournalProvider — calls DailyApiService.getEntries(date: today)
// REWRITE: selectedJournalProvider — calls DailyApiService.getEntries(date: selected)
// BOTH: merge server entries + pending queue entries before returning JournalDay
```

`JournalNotifier` changes:
- `addTextEntry` / `addVoiceEntry` / `addLinkedEntry`: call `dailyApiService.createEntry()` first;
  on failure (offline) call `pendingQueue.enqueue()` and add a `isPending` entry to local state
- Remove `_triggerRefresh()` sync push entirely
- Remove `_journalFilePath` tracking

### Flutter: UI — pending indicator

In `journal_entry_card.dart` (or `journal_entry_row.dart`), when `entry.isPending`:
- Show a cloud-with-arrow-up icon (or dashed border) alongside the timestamp
- Tooltip / subtitle: "Not uploaded yet"
- No tap action needed for MVP; entry content is fully readable

When offline with no entries (server unavailable, queue empty):
- Empty state: "Connect to see your journal"

### Flutter: dead code removal

| File | Action |
|------|--------|
| `journal/services/journal_service.dart` | Delete |
| `journal/services/journal_merge_service.dart` | Delete |
| `journal/services/para_id_service.dart` | Delete (daily-specific; chat has its own) |
| `core/providers/sync_provider.dart` | Delete (Daily was only caller) |
| `core/services/sync_service.dart` | Delete |
| `JournalNotifier._triggerRefresh()` | Remove sync push call |
| `journal_providers.dart` `import sync_provider` | Remove |

Check for any remaining imports before deleting; `flutter analyze` will catch stragglers.

## Implementation Order

1. **Server** — date filter (quick, 1 file, lets Flutter testing begin)
2. **`DailyApiService`** — new file, testable in isolation
3. **`PendingEntryQueue`** — new file, testable in isolation
4. **`JournalEntry` model** — add `isPending` + `fromServerJson()`; keep existing shape intact
5. **`journal_providers.dart`** — rewrite providers to use API service + pending queue
6. **UI** — pending indicator
7. **Dead code removal** — delete services, sync provider; fix imports; run `flutter analyze`

## Dependencies & Risks

- **`connectivity_plus`**: likely already in `pubspec.yaml` (check before adding). Used to trigger
  queue flush on reconnect.
- **`JournalDay` model**: currently built from `JournalService.loadDay()`; will need a
  `JournalDay.fromEntries(List<JournalEntry>)` constructor or similar to build from API results.
- **`search_providers.dart`**: Daily search currently reads files locally. After this change,
  it will need to either call the server search endpoint or be deferred. Flag during implementation.
- **Voice/photo metadata round-trip**: The server stores `metadata` in frontmatter but the GET
  response returns it as part of the entry dict. Verify the server `get_entry()` response shape
  includes `metadata` before relying on it in `fromServerJson()`.
- **`JournalDay.filePath`**: some widgets may reference this for sync. After the rewrite `filePath`
  becomes meaningless — set it to `''` or make it nullable and update callers.

## Out of Scope

- Legacy `vault/journals/YYYY-MM-DD.md` import (separate issue)
- Audio asset upload / remote audio file storage (separate issue)
- Offline read history — empty state for now ("Connect to see your journal")
- Entry edit / delete on server (server Daily is append-only; flag if needed)

## File Changes Summary

| File | Change |
|------|--------|
| `computer/modules/daily/module.py` | Add `?date=` filter to `list_entries` + route |
| `app/.../journal/services/daily_api_service.dart` | New — HTTP client |
| `app/.../journal/services/pending_entry_queue.dart` | New — SharedPreferences queue |
| `app/.../journal/models/journal_entry.dart` | Add `isPending`, `fromServerJson()` |
| `app/.../journal/providers/journal_providers.dart` | Rewrite — server-backed providers |
| `app/.../journal/models/journal_day.dart` | Add `fromEntries()` factory |
| `app/.../journal/widgets/journal_entry_card.dart` | Add pending indicator |
| `app/.../journal/services/journal_service.dart` | Delete |
| `app/.../journal/services/journal_merge_service.dart` | Delete |
| `app/.../journal/services/para_id_service.dart` | Delete |
| `app/lib/core/providers/sync_provider.dart` | Delete |
| `app/lib/core/services/sync_service.dart` | Delete (if exists) |

## References

- Chat service pattern: `app/lib/features/chat/services/chat_service.dart`
- ComputerService base URL / API key: `app/lib/core/services/computer_service.dart`
- Server Daily module: `computer/modules/daily/module.py`
- Brainstorm: `docs/brainstorms/2026-03-01-daily-online-first-brainstorm.md`
