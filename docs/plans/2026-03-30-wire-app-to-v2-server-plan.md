---
title: "Wire Flutter app to v2 graph server"
type: feat
date: 2026-03-30
issue: 359
---

# Wire Flutter App to v2 Graph Server

The daily/app Flutter app compiles but still talks to the old Python server's API (`/api/daily/entries`, `/api/daily/tools/*`). The new TypeScript server at `daily/local/` serves a graph API (`/api/things`, `/api/tags`, `/api/edges`, `/api/tools`, `/api/search`, `/api/storage`). A `GraphApiService` exists but nothing uses it. This plan wires the app to the new server.

## Problem Statement

17 files import or reference `DailyApiService` and its old-server endpoints. The new server has a fundamentally different data model: journal entries are "things" tagged with `daily-note`, agent outputs are "things" tagged with `card`, and agent definitions are "tools" — all in a graph with edges. The app's providers, screens, and services need to speak this new API.

## Proposed Solution

**Strategy: Rewrite `DailyApiService` to call the new endpoints.** Rather than changing 17 import sites to use `GraphApiService`, keep `DailyApiService` as the app's service layer but rewrite its internals to call the v2 graph API. This means:

- Same method signatures (or close) so providers/screens need minimal changes
- Internally translates between `JournalEntry`/`JournalDay` and `Thing` models
- `GraphApiService` provides the HTTP layer; `DailyApiService` provides the domain translation

### Data Model Mapping

| Old concept | New v2 concept |
|-------------|----------------|
| Journal entry | Thing with `daily-note` tag |
| Entry metadata (type, audio_path, etc.) | `daily-note` tag field values |
| Agent card | Thing with `card` tag |
| Agent/tool definition | Tool (in `tools` table) |
| Entry date | `daily-note` tag `date` field |
| Entry search | FTS5 via `/api/search?q=...&tag=daily-note` |

## Implementation Phases

### Phase A: Plumbing — GraphApiService provider + health check

1. Create `graphApiServiceProvider` in `journal_providers.dart` (same pattern as `dailyApiServiceProvider` but constructs `GraphApiService` targeting port 3334)
2. Verify health check works — the new server has `/api/health` returning `{status, version, schema_version}`. The existing `BackendHealthService` already hits `/api/health`, so this should work as-is once the URL points to 3334
3. On app startup, call `/api/register` to ensure `daily-note` and `card` tags exist with their schemas

**Files:** `journal_providers.dart`, `app_config.dart` (already points to 3334)

### Phase B: Journal CRUD — rewrite DailyApiService core methods

Rewrite these `DailyApiService` methods to use `GraphApiService` internally:

| Method | Old endpoint | New endpoint | Translation |
|--------|-------------|-------------|-------------|
| `getEntries(date:)` | `GET /api/daily/entries?date=` | `GET /api/things?tag=daily-note&date=YYYY-MM-DD` | Thing → JournalEntry via tag fields |
| `createEntry(content, metadata)` | `POST /api/daily/entries` | `POST /api/things` with `tags: {daily-note: {date, entry_type, ...}}` | Build tag fields from metadata |
| `updateEntry(id, content)` | `PATCH /api/daily/entries/:id` | `PATCH /api/things/:id` | Direct mapping |
| `deleteEntry(id)` | `DELETE /api/daily/entries/:id` | `DELETE /api/things/:id` | Direct mapping |
| `uploadAudio(file)` | `POST /api/daily/upload` | `POST /api/storage/upload` | Same multipart pattern |

Add a `_thingToEntry(Thing)` helper that reads `daily-note` tag fields to construct a `JournalEntry`. The `Thing` model already has convenience getters (`entryType`, `audioUrl`, `noteDate`, etc.) that map to these fields.

**Files:** `daily_api_service.dart`

### Phase C: Search — rewrite search service

| Method | Old | New |
|--------|-----|-----|
| `searchEntries(query)` | `GET /api/daily/search?q=` | `GET /api/search?q=...&tag=daily-note` |

**Files:** `daily_api_service.dart`, `simple_text_search.dart`, `search_providers.dart`

### Phase D: Cards (agent outputs)

| Method | Old | New |
|--------|-----|-----|
| `fetchCards(date)` | `GET /api/daily/cards?date=` | `GET /api/things?tag=card&date=YYYY-MM-DD` |
| `fetchUnreadCards()` | `GET /api/daily/cards/unread` | `GET /api/things?tag=card&read_at=` (empty = unread) |
| `markCardRead(id)` | `POST /api/daily/cards/:id/read` | `PATCH /api/things/:id` with `tags: {card: {read_at: now}}` |

Need a `_thingToCard(Thing)` helper for `AgentCard` construction.

**Files:** `daily_api_service.dart`, `agent_card.dart`

### Phase E: Tools/agents — rewrite agent management

The old API had a custom `/api/daily/tools/*` surface. The new server has generic `/api/tools`:

| Method | Old | New |
|--------|-----|-----|
| `fetchAgents()` | `GET /api/daily/tools` | `GET /api/tools?published_by=daily` |
| `createAgent(body)` | `POST /api/daily/tools` | `POST /api/tools` |
| `updateAgent(name, fields)` | `PUT /api/daily/tools/:name` | Not directly supported — need to add PATCH to tools route |
| `deleteAgent(name)` | `DELETE /api/daily/tools/:name` | Need to add DELETE to tools route |
| `triggerAgentRun(name)` | `POST /api/daily/tools/:name/run` | `POST /api/tools/:name/execute` |

**Gap:** The new tools route only has GET, POST (register), GET/:name, POST/:name/execute. Missing PATCH and DELETE. These need to be added to `daily/local/src/routes/tools.ts`.

**Gap:** Agent scheduling, templates, reset, transcript — these concepts don't exist in the v2 server yet. Options:
- **Defer:** Strip agent management screens for now, ship journal CRUD first
- **Add endpoints:** Extend the tools route with schedule/template/run-history support

**Recommendation: Defer agent management to a follow-up.** The core value is journal CRUD + cards working. Agent management can remain as placeholder screens.

**Files:** `daily_api_service.dart`, `daily/local/src/routes/tools.ts` (add PATCH/DELETE)

### Phase F: Offline cache compatibility

The `JournalLocalCache` (SQLite) and `PendingEntryQueue` (SharedPreferences) work with `JournalEntry` objects. Since we're keeping the `JournalEntry` model and just changing how `DailyApiService` talks to the server, the cache layer should work unchanged. Verify:

- `cache.putEntries()` / `cache.getEntries()` still work with entries produced by `_thingToEntry()`
- `PendingEntryQueue.flush()` calls `createEntry()` which we're rewriting — make sure the body shape matches

**Files:** `journal_local_cache.dart`, `pending_entry_queue.dart` (verify, likely no changes)

## Acceptance Criteria

- [x] App connects to `localhost:3334` (already configured)
- [x] Health check passes against v2 server
- [x] App registers `daily-note` and `card` tags on startup
- [x] Create journal entry → creates Thing with `daily-note` tag
- [x] List entries by date → queries things by tag + date
- [x] Edit entry → patches thing content
- [x] Delete entry → deletes thing
- [x] Voice entry with audio upload → uploads via `/api/storage/upload`
- [x] Search entries → uses FTS5 via `/api/search`
- [x] Agent cards display (read-only at minimum)
- [x] Offline cache still works (write offline, sync when online)
- [x] Agent management screens deferred (show placeholder)

## Technical Considerations

- The v2 server uses camelCase JSON keys (`createdAt`, `createdBy`) while the old server used snake_case (`created_at`). The `Thing.fromJson` already handles camelCase. `JournalEntry.fromServerJson` expects snake_case — the `_thingToEntry` translation layer handles this.
- The `daily-note` tag schema defines fields: `entry_type`, `audio_url`, `duration_seconds`, `transcription_status`, `cleanup_status`, `date`. These map 1:1 to `JournalEntry` fields.
- The new server has no auth layer yet — `X-API-Key` headers will be ignored. Fine for local dev.

## Dependencies & Risks

- **Risk:** The v2 server may not have the `daily-note` tag schema seeded. Mitigation: `/api/register` endpoint handles this.
- **Risk:** Offline queue assumes old entry creation body shape. Mitigation: `PendingEntryQueue.flush` goes through `createEntry()` which we control.
- **Deferred:** Agent scheduling, templates, transcripts — these need server-side support that doesn't exist yet in v2.

## References

- PR #360: feat(daily): v2 core library + self-hosted server
- Issue #359: Parachute Daily v2 plan
- `daily/local/src/routes/` — all server endpoints
- `daily/app/lib/core/services/graph_api_service.dart` — v2 HTTP client
- `daily/app/lib/core/models/thing.dart` — Thing/ThingTag/ThingEdge models
