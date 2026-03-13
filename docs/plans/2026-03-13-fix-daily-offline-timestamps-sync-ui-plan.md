---
title: "Fix Daily offline timestamps & sync status UI"
type: fix
date: 2026-03-13
issue: 256
---

# Fix Daily offline timestamps & sync status UI

Two concrete problems to fix before beta, plus a lightweight audit of the remaining offline→online transition items from issue #256.

## Problem Statement

### 1. Offline entries get wrong timestamps

When a user journals offline, the entry is queued in `PendingEntryQueue` with a `queuedAt` timestamp. But when the queue flushes, the client calls `POST /api/daily/entries` without passing that timestamp. The server generates all timestamps from `datetime.now()`:

```python
# computer/modules/daily/module.py:645-650
now = datetime.now(timezone.utc)
entry_id = now.strftime("%Y-%m-%d-%H-%M-%S-%f")   # ← sync time, not write time
date = datetime.now().strftime("%Y-%m-%d")          # ← wrong day if synced next morning
created_at = now.isoformat()                        # ← sync time
```

Result: An 8pm journal entry synced the next morning shows under the wrong day with the wrong time.

### 2. Sync status UI is too subtle

- Pending entries show a small 12px "Not uploaded yet" chip — easy to miss
- `pending_edit` entries (edited offline) have NO visual indicator at all
- `pending_delete` entries are silently hidden — no feedback that deletion is queued
- No global indicator showing how many entries are waiting to sync

## Proposed Solution

### Fix 1: Client-originated timestamps

Pass `created_at` and `date` from the client when creating entries. The server should honor client-provided timestamps when present, falling back to `datetime.now()` for direct API calls.

**Client side (Flutter):**
- `PendingEntryQueue._flush()` → pass `queuedAt` as `created_at` in metadata
- `DailyApiService.createEntry()` → always pass client `created_at` and `date` in metadata (covers both online and offline creation — the client always knows when the user actually wrote the entry)

**Server side (Python):**
- `create_entry()` → check `metadata` for `created_at` and `date`; use them for entry timestamps if present, fall back to `datetime.now()` if not
- Derive `entry_id` from the provided `created_at` (or generate from `now` as before)
- Validate client-provided timestamps (reject future dates, unreasonable past dates)

### Fix 2: Better sync status UI

**Entry-level indicators:**
- Replace the subtle "Not uploaded yet" chip with a more visible indicator (cloud icon in the card header area, consistent positioning)
- Add indicator for `pending_edit` state — show that local edits haven't synced
- Add indicator for `pending_delete` — instead of silently hiding, show a faded/struck-through card with "Deleting..." until confirmed

**Global sync banner (stretch):**
- When entries are pending, show a subtle banner/chip at the top of the journal day view: "2 entries waiting to sync"
- Dismiss automatically when flush completes

## Acceptance Criteria

- [x] Offline entries preserve their original write time when synced to server
- [x] Entries created at 8pm offline and synced next morning appear under the correct day
- [x] `entry_id` reflects authoring time, not sync time
- [x] `pending_edit` entries show a visible sync indicator
- [x] The existing "Not uploaded yet" indicator is more prominent / consistently positioned
- [x] Server validates client-provided timestamps (no future dates)

## Audit Checklist (from #256)

Items verified during implementation:

### Offline-First Guarantees
- [x] App works fully without server connection — cache-first load, graceful null handling
- [x] All entries persist in local SQLite with no server dependency — sync_state tracking, in-memory fallback
- [x] On-device transcription works without network — Parakeet/Sherpa, fully local
- [x] No UI references sync features that don't exist yet — no user-facing "sync" text

### Online Transition Path
- [x] SQLite schema compatible with future sync (timestamps, sync_state column, redo log)
- [x] Entry IDs don't assume single-device — **FLAG**: microsecond collision low risk for single-device beta, add device UUID before multi-device sync
- [x] Transcription swappable between on-device and server without changing entry format
- [x] Clean separation between local storage and sync layer — cache, API, queue layers distinct
- [x] No hard-coded assumptions about where data lives — uses Flutter abstractions

## Technical Considerations

**Entry ID format:** Currently `YYYY-MM-DD-HH-MM-SS-ffffff` based on server time. With client-originated timestamps, the ID should derive from the client's `created_at` instead. For beta (single-device), this is safe. For future multi-device, UUIDs would be better — but that's a separate migration, not needed now.

**Timezone handling:** The `date` field uses server's local wall-clock time. When the client provides `date`, it should be the client's local date (matching the user's experience). The server should accept it as-is rather than re-deriving from UTC.

**Security:** Client-provided timestamps should be validated — reject timestamps in the future or unreasonably far in the past (e.g., >30 days). This prevents accidental or malicious backdating.

## Key Files

| File | Change |
|------|--------|
| `computer/modules/daily/module.py` | `create_entry()` — honor client timestamps |
| `app/lib/features/daily/journal/services/pending_entry_queue.dart` | Pass `queuedAt` as `created_at` in metadata |
| `app/lib/features/daily/journal/services/daily_api_service.dart` | Pass client `created_at`/`date` on all creates |
| `app/lib/features/daily/journal/widgets/journal_entry_card.dart` | Improve sync indicators |
| `app/lib/features/daily/journal/services/journal_local_cache.dart` | May need `sync_state` reflected in UI queries |

## Dependencies & Risks

- **Low risk:** Timestamp change is additive — server falls back to current behavior when metadata lacks timestamps
- **No migration needed:** Existing entries keep their (server-generated) timestamps; only new entries benefit
- **UI changes are cosmetic:** No data model changes needed for sync indicators (already tracked via `isPending`, `sync_state`)

## Open Questions

- Should `pending_delete` show a faded card, or is silent hiding acceptable for beta? (Leaning toward: keep hidden for beta, revisit for sync)
- Global sync banner — worth doing now or defer? (Leaning toward: defer, entry-level indicators are sufficient for beta)
