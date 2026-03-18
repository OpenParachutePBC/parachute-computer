---
date: 2026-03-18
topic: daily-offline-resilience
status: brainstorm
priority: P1
issue: 288
---

# Daily Offline Resilience

## What We're Building

Make the Daily journal work seamlessly when the device is offline or the server is unreachable. Three concrete improvements:

1. **Connectivity-aware network gating** — When the app knows it's offline, skip all server calls immediately instead of waiting for 15-second timeouts. Uses the existing `BackendHealthService` as the source of truth, enhanced with fast-fail: any API failure immediately flips the state to offline.

2. **Instant offline entry creation** — When offline, write entries to the local cache and pending queue immediately with no network attempt. The existing `PendingEntryQueue` and `JournalLocalCache` infrastructure handles this already; we just need to gate on connectivity state before attempting the API call.

3. **Pending sync banner** — A subtle, dismissible banner at the top of the journal that appears only when entries are waiting to sync (e.g., "2 entries pending sync"). Tappable to force a sync attempt. No per-entry icons — keeps the UI clean since this is an infrequent state.

## Why This Approach

### Approaches Considered

**A. Enhanced health service with fast-fail (chosen):** Use the existing `BackendHealthService` (30s polling) as the connectivity source of truth. Add fast-fail: any API call failure immediately marks offline state. Any success immediately marks online. This covers the primary use case (opening the app while already offline) with zero new dependencies.

**B. OS-level detection via `connectivity_plus`:** Adds instant wifi/cellular change events. More responsive for the moment connectivity drops, but adds a dependency and only detects interface state — not server reachability. The 15-30 second window for detecting the *first* loss of connectivity is acceptable since the main pain point is opening the app while already offline, not the moment you lose signal.

**C. Both A + B combined:** Maximum responsiveness but more complexity. Deferred — can add `connectivity_plus` later if the first-failure window becomes a user complaint.

### Why A

The primary pain point is opening Daily while offline and waiting through timeouts. With approach A, the first health check on app launch (which already happens) will fail fast, and from that point forward all calls are gated. The fast-fail optimization means even if the health check hasn't run yet, the first failed API call triggers offline mode immediately.

## Key Decisions

- **Single source of truth**: `BackendHealthService` / `periodicServerHealthProvider` — no new connectivity package
- **Fast-fail on any API error**: Don't wait for the next 30s poll; flip to offline immediately when a call fails
- **Fast-recover on any API success**: Flip back to online immediately when a call succeeds
- **Gate server-dependent calls**: Cards, agents, templates, and the server phase of journal loading should check connectivity before attempting the call
- **Entry creation offline path**: Skip the API call entirely when offline — go straight to pending queue. No 15-second wait.
- **Banner over badges**: Show "N entries pending sync" banner rather than per-entry sync icons. Less visual noise, appears only when relevant.
- **Tappable banner**: Tapping the pending sync banner forces a sync attempt (calls `pendingQueue.flush()`)
- **Existing infrastructure**: `JournalLocalCache` (SQLite with `sync_state`), `PendingEntryQueue` (SharedPreferences), and the two-phase load pattern (cache then server) are all already built — this is mostly wiring them together with connectivity awareness

## Scope

### In Scope
- Connectivity-aware gating for all Daily API calls
- Fast-fail / fast-recover health state transitions
- Offline-instant entry creation (text, voice with local transcription, compose)
- Pending sync banner in journal UI
- Auto-flush pending queue on reconnection (already partially implemented)

### Out of Scope (for now)
- `connectivity_plus` package — defer unless the first-failure window is a problem
- Offline card/agent caching — cards and agents are dynamic; showing empty is fine offline
- Offline voice-to-server transcription — requires server; local transcription is the offline path
- Conflict resolution for edits — existing upsert logic preserves local state, good enough for now
- Vault file sync offline handling — separate system (`SyncProvider`), separate issue

## Open Questions

- Should the pending sync banner show in the journal header (near the existing sync indicator) or as a separate element below the app bar?
- When entries flush successfully on reconnect, should we show a brief success toast ("3 entries synced") or just silently update?
- Should we reduce the health check interval when the app is in the foreground and offline (e.g., poll every 10s instead of 30s to detect reconnection faster)?

## Next Steps

-> `/plan` for implementation details
