---
date: 2026-03-01
topic: daily-online-first
status: ready-to-plan
priority: P1
module: daily, app
---

# Daily: Online-First Architecture

**Issue:** #159

## What We're Building

Rewrite the Flutter Daily module to work like Chat — server API is authoritative, offline sync infrastructure is dropped. Today Daily writes to local markdown files and uses a 1,282-line bidirectional sync service to push them to the server. The result is two parallel systems (Flutter file format ≠ server file format), complex conflict resolution, and a hard-to-reason-about data flow.

The new architecture: Flutter POSTs entries to the server, Flutter GETs entries from the server. If the user is offline when they submit, the entry goes into a visible pending queue and uploads when connectivity is restored. That's it.

## Why This Approach

Chat already works this way and it's clean. The complexity of the sync service (versioning, tombstones, conflict resolution, 60-second merge windows) exists entirely to support Daily's local-first model. Dropping that model drops all that complexity. The offline edge case is handled minimally and honestly: you can see what hasn't uploaded yet, and it will send when you're back online. Offline read history can be added back later with fresh thinking, without the weight of the current system.

## Key Decisions

- **Server is authoritative**: All reads and writes go through the server API. No local file reads in the normal path.
- **Pending queue for offline writes**: SharedPreferences JSON list. Entries in the queue are displayed in the UI with a clear "not uploaded" indicator. Flushed in order when connectivity returns. Failed sends stay in the queue.
- **Sync service dropped for Daily**: `SyncService`/`SyncProvider` are only used by Daily. With this change they can be removed entirely or left dormant.
- **Server API needs a date filter**: `GET /api/daily/entries` currently lists all entries with offset/limit. Flutter needs `?date=YYYY-MM-DD` to load a day's entries.
- **Entry format simplifies**: New entries use the server's `entry_id` format (`YYYY-MM-DD-HH-MM`). No more `para:ID` generation on the Flutter side for new entries.
- **Voice/photo/handwriting entries**: `content` carries the transcript or description; `metadata` carries asset paths. Same shape as current server API — no format change needed.
- **Legacy local files**: Old `vault/journals/YYYY-MM-DD.md` files are left as archive. A separate import issue covers ingesting them into the graph DB via a Flutter import action (see Open Questions).

## What Gets Removed (Flutter)

- `JournalService` surgical file operations (append, replace block, delete block, frontmatter parsing)
- `SyncService` and `SyncProvider` (Daily was the only caller)
- `JournalNotifier._triggerRefresh()` sync push
- `ParaIdService` (daily module) — IDs now come from server
- `journalMergeService` — no more merge logic needed
- Most of `journal_providers.dart` local file providers

## What Gets Built (Flutter)

- `DailyApiService` — thin HTTP client wrapping `GET /api/daily/entries`, `POST /api/daily/entries`
- `PendingEntryQueue` — SharedPreferences-backed list of unsent entries; flush on connectivity
- Updated `journal_providers.dart` — providers backed by server responses + pending queue
- "Pending" UI state — visual indicator on entries not yet uploaded (cloud icon, badge, etc.)

## What Gets Built (Server)

- `GET /api/daily/entries?date=YYYY-MM-DD` — date filter on existing list endpoint
- (Existing `POST /api/daily/entries` is already correct)

## Open Questions

- **Import tool scope**: The legacy file import is explicitly a separate issue. Shape: Flutter reads old `vault/journals/*.md` files from the file system, POSTs entries to server, server ingests into graph. Should this be a settings screen action or a server-side CLI command? Likely both.
- **Offline read history**: Not in scope. When offline you see the pending queue and nothing else. What's the right empty state message? ("Connect to see your journal" vs showing the last-fetched state?)
- **Entry update/delete**: The current server Daily module is append-only. If the user needs to edit or delete entries, the server API needs to support it. Out of scope for this issue — flag if needed.
- **Audio assets**: Voice entries reference audio file paths. Where do those live? Currently local vault assets. The audio file upload story needs a separate look.

## Next Steps

→ `/plan #NN` — focus on the Flutter side first (remove sync, add API client, add pending queue)
→ Separate issue for legacy file import
→ Separate issue for audio asset handling
