---
title: Hosted Parachute Daily v1
type: feat
date: 2026-03-25
issue: 344
---

# Hosted Parachute Daily v1

Build a hosted version of Parachute Daily on Cloudflare Workers + Durable Objects. Users sign up, journal, and get AI reflections. No server to install.

## Acceptance Criteria

- [ ] User can sign up / sign in via magic link email
- [ ] User can create text entries
- [ ] User can record voice entries → audio stored in R2 → transcribed via external API
- [ ] User can browse entries by date
- [ ] User can view entry detail
- [ ] Agent system runs `process-note` on transcription complete
- [ ] Agent system runs `process-day` on nightly schedule
- [ ] Cards generated from agent runs are viewable in UI
- [ ] Flutter app (`parachute_daily`) connects to hosted backend
- [ ] Scale to zero — idle users cost nothing

## Overview

Three workstreams that can proceed largely in parallel:

1. **Cloudflare Workers backend** — new TypeScript project in `hosted/daily/`
2. **Flutter app extraction** — new `parachute_daily` app from common package
3. **Integration** — wire the Flutter app to the hosted backend

## Phase 1: Cloudflare Workers Backend

### 1.1 Project Scaffold

Create `hosted/daily/` in the monorepo root.

```
hosted/
  daily/
    src/
      server.ts          # Hono router + routeAgentRequest fallback
      agents/
        daily-vault.ts   # Agent DO class — per-user storage + agent runner
      routes/
        auth.ts          # Magic link endpoints
        entries.ts       # Journal CRUD (proxied to user's DO)
        cards.ts         # Card endpoints (proxied to user's DO)
        agents.ts        # Agent config endpoints (proxied to user's DO)
        storage.ts       # R2 presigned URL generation
      auth/
        middleware.ts    # Session validation middleware
        session.ts       # KV-based session management
      ai/
        agent-runner.ts  # Vercel AI SDK agent loop + tool definitions
        providers.ts     # Model provider config (Groq, Nemotron)
      db/
        schema.sql       # SQLite schema for DO initialization
        queries.ts       # Typed query helpers
    wrangler.jsonc
    package.json
    tsconfig.json
```

**wrangler.jsonc bindings:**
- `DailyVault` Durable Object (SQLite-backed via `new_sqlite_classes`)
- `AUTH_KV` — KV namespace for magic link tokens + sessions
- `AUDIO_BUCKET` — R2 bucket for voice recordings
- Secrets: `RESEND_API_KEY`, `GROQ_API_KEY`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `CLOUDFLARE_ACCOUNT_ID`

### 1.2 DailyVault Agent (Durable Object)

One `DailyVault` instance per user. Extends `Agent<Env>` from CF Agents SDK.

**SQLite schema** (created in `onStart()`):

```sql
CREATE TABLE IF NOT EXISTS notes (
  entry_id TEXT PRIMARY KEY,
  note_type TEXT DEFAULT 'journal',
  date TEXT NOT NULL,
  content TEXT DEFAULT '',
  snippet TEXT DEFAULT '',
  title TEXT DEFAULT '',
  entry_type TEXT DEFAULT 'text',
  audio_key TEXT,
  status TEXT DEFAULT 'active',
  metadata_json TEXT DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS cards (
  card_id TEXT PRIMARY KEY,
  agent_name TEXT NOT NULL,
  card_type TEXT DEFAULT 'default',
  display_name TEXT DEFAULT '',
  content TEXT DEFAULT '',
  generated_at TEXT,
  status TEXT DEFAULT 'running',
  date TEXT NOT NULL,
  read_at TEXT
);

CREATE TABLE IF NOT EXISTS agents (
  name TEXT PRIMARY KEY,
  display_name TEXT DEFAULT '',
  description TEXT DEFAULT '',
  system_prompt TEXT DEFAULT '',
  tools TEXT DEFAULT '[]',
  schedule_enabled TEXT DEFAULT 'false',
  schedule_time TEXT DEFAULT '23:00',
  enabled TEXT DEFAULT 'true',
  trigger_event TEXT DEFAULT '',
  trigger_filter TEXT DEFAULT '{}',
  memory_mode TEXT DEFAULT 'fresh',
  created_at TEXT NOT NULL,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS agent_runs (
  run_id TEXT PRIMARY KEY,
  agent_name TEXT NOT NULL,
  display_name TEXT DEFAULT '',
  entry_id TEXT,
  date TEXT NOT NULL,
  trigger TEXT DEFAULT 'manual',
  status TEXT DEFAULT 'running',
  error TEXT,
  card_id TEXT,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  duration_seconds REAL
);

CREATE INDEX IF NOT EXISTS idx_notes_date ON notes(date);
CREATE INDEX IF NOT EXISTS idx_cards_date ON cards(date);
CREATE INDEX IF NOT EXISTS idx_cards_agent ON cards(agent_name);
CREATE INDEX IF NOT EXISTS idx_runs_agent ON agent_runs(agent_name);
```

This schema mirrors the Kuzu Node tables field-for-field. All string types (matching Kuzu's string-everything pattern). Same entry_id format (`YYYY-MM-DD-HH-MM-SS-ffffff`). Same card_id format (`{agent_name}:{card_type}:{date}`).

**Seeded agents** (inserted on first `onStart` if agents table is empty):

- `process-note`: trigger_event=`note.transcription_complete`, tools=`["read_this_note","update_this_note"]`, memory_mode=`fresh`
- `process-day`: schedule_enabled=`true`, schedule_time=`23:00`, tools=`["read_days_notes","write_card"]`, memory_mode=`fresh`

**`onStart()` also sets up scheduling:**
- Query agents with `schedule_enabled='true'`
- Call `this.schedule(cronExpression, "runScheduledAgent", { agentName })` for each

**Key methods exposed via `@callable()` or `onRequest()`:**

| Method | Purpose |
|--------|---------|
| `createEntry(content, metadata)` | Insert note, dispatch `note.created` |
| `getEntries(date)` | Query notes by date |
| `getEntry(entryId)` | Single note lookup |
| `updateEntry(entryId, content, metadata)` | Patch note |
| `deleteEntry(entryId)` | Remove note |
| `searchEntries(query)` | Full-text search (LIKE-based for v1) |
| `getCards(date?)` | List cards, optionally by date |
| `getUnreadCards()` | Cards with read_at IS NULL from last 7 days |
| `markCardRead(cardId)` | Set read_at timestamp |
| `getAgents()` | List all agents |
| `updateAgent(name, fields)` | Update agent config |
| `runAgent(agentName, scope)` | Execute agent with Vercel AI SDK |
| `dispatchEvent(event, data)` | Find matching agents, run them |
| `runScheduledAgent(agentName)` | Called by DO alarm for scheduled agents |
| `onTranscriptionComplete(entryId, transcript)` | Update note + dispatch event |

### 1.3 REST API Routes (Hono)

The Hono router proxies requests to the user's DailyVault DO. Auth middleware extracts userId from session, then uses `getAgentByName(env.DailyVault, userId)` to reach the right DO.

**Match the existing Python API surface** where the Flutter app already calls it. The v1 subset:

```
POST   /auth/magic                    # Send magic link
GET    /auth/verify?token=xxx         # Verify + create session
POST   /auth/signout                  # Clear session

GET    /api/daily/entries?date=YYYY-MM-DD&limit=20
POST   /api/daily/entries             # { content, metadata? }
GET    /api/daily/entries/:id
PATCH  /api/daily/entries/:id         # { content?, metadata? }
DELETE /api/daily/entries/:id
POST   /api/daily/entries/voice       # multipart: file + date + duration
POST   /api/daily/entries/:id/cleanup
GET    /api/daily/entries/search?q=...&limit=30
GET    /api/daily/entries/:id/agent-activity

POST   /api/storage/presigned-upload  # { filename, contentType } → { uploadUrl, objectKey }

GET    /api/daily/cards?date=YYYY-MM-DD
GET    /api/daily/cards/unread
POST   /api/daily/cards/:id/read
POST   /api/daily/cards/:agentName/run

GET    /api/daily/agents
PUT    /api/daily/agents/:name
GET    /api/daily/agents/:name/runs/latest
```

**Voice entry flow:**
1. Flutter calls `POST /api/storage/presigned-upload` → gets R2 presigned PUT URL
2. Flutter PUTs audio directly to R2 (no Worker in the middle)
3. Flutter calls `POST /api/daily/entries/voice` with `{ objectKey, date, durationSeconds }`
4. Worker creates note in DO with `transcription_status=processing`
5. Worker calls external transcription API (Deepgram) with R2 object URL
6. On completion, Worker calls DO's `onTranscriptionComplete(entryId, transcript)`
7. DO updates note, dispatches `note.transcription_complete` event
8. Event triggers `process-note` agent

### 1.4 Agent Runner (Vercel AI SDK)

Inside the DailyVault DO, the agent runner:

1. Loads agent config from SQLite
2. Builds tools from the agent's `tools` JSON array
3. Calls `generateText()` (not `streamText` — agents run in background, no streaming needed)
4. Processes tool calls in the agent loop
5. Writes results (Card) to SQLite
6. Records AgentRun

```typescript
import { generateText, tool } from "ai";
import { createGroq } from "@ai-sdk/groq";

async runAgent(agentName: string, scope: { date?: string; entryId?: string; event?: string }) {
  const agent = this.getAgent(agentName);
  const tools = this.bindTools(agent.tools, scope);
  const systemPrompt = this.interpolatePrompt(agent.system_prompt, scope);
  const userPrompt = this.buildUserPrompt(scope);

  const groq = createGroq({ apiKey: this.env.GROQ_API_KEY });

  const runId = crypto.randomUUID();
  this.insertAgentRun(runId, agentName, scope, "running");

  try {
    const result = await generateText({
      model: groq("llama-3.3-70b-versatile"),
      system: systemPrompt,
      prompt: userPrompt,
      tools,
      maxSteps: 5,
    });

    this.insertAgentRun(runId, agentName, scope, "completed", result);
  } catch (err) {
    this.insertAgentRun(runId, agentName, scope, "error", null, err.message);
  }
}
```

**Tool definitions** (matching Python interface):

| Tool | Params | Implementation |
|------|--------|----------------|
| `read_days_notes` | `{ date? }` | Query notes table by date |
| `read_this_note` | `{}` | Read note by scope.entryId |
| `update_this_note` | `{ content }` | Update note content by scope.entryId |
| `write_card` | `{ date, content, card_type? }` | Insert/update card in cards table |
| `read_recent_journals` | `{ days? }` | Query notes from last N days |

Same names, same param shapes as Python. Different implementation (SQLite queries vs Kuzu Cypher).

### 1.5 Auth (Magic Link)

- `POST /auth/magic` — validate email, generate token, store in KV (5min TTL), send via Resend
- `GET /auth/verify?token=xxx` — validate token, delete from KV, find-or-create user, create session in KV (7-day TTL), set HttpOnly cookie, redirect
- `POST /auth/signout` — delete session from KV, clear cookie

User records: store in a separate KV or in a "users" DO. For v1, KV is simpler — `user:{email}` → `{ userId, email, createdAt }`.

Session validation middleware on all `/api/*` routes: read cookie → lookup `session:{sessionId}` in KV → inject userId into context → use userId as DO instance name.

### 1.6 Transcription Integration

For v1, use **Deepgram** — best price/quality ratio for voice journal entries:
- Nova-2 model: $0.0043/minute
- REST API: POST audio bytes → get transcript JSON
- Supports async (webhook callback) and sync modes

Flow: Worker receives `objectKey` → fetch audio from R2 → POST to Deepgram → receive transcript → call DO's `onTranscriptionComplete`.

**Alternative**: Cloudflare Workers AI has `@cf/openai/whisper` — free on Workers AI free tier. Lower quality but $0 cost. Could be a fallback or the v1 default with Deepgram as upgrade.

## Phase 2: Flutter App Extraction

### 2.1 Common Package (`packages/parachute_common/`)

Extract from existing `app/` into a shared Dart package:

**Include:**
- `core/theme/` — BrandColors, AppTheme, design tokens
- `core/config/app_config.dart` — server URL management
- `core/services/logging_service.dart`
- `core/services/para_id_service.dart`
- `core/services/tag_service.dart`
- `core/services/file_system_service.dart`
- `core/services/transcription/` — Sherpa-ONNX, streaming voice (for on-device option)
- `core/services/vad/` — voice activity detection
- `core/services/audio_processing/` — filters, noise reduction
- `core/widgets/error_boundary.dart`
- `core/widgets/error_snackbar.dart`
- `features/daily/journal/models/` — JournalEntry, AgentCard, etc.
- `features/daily/journal/services/daily_api_service.dart` — HTTP client

**Do NOT include:** Chat, Brain, Vault, bot connectors, Docker/sandbox, computer-specific settings.

### 2.2 New Flutter App (`apps/parachute_daily/`)

New Flutter project depending on `parachute_common`.

```
apps/
  parachute_daily/
    lib/
      main.dart                    # Simplified entry, no tab bar (single screen)
      app.dart                     # MaterialApp with theme from common
      features/
        auth/
          screens/
            magic_link_screen.dart  # Email input → "check your email"
            verify_screen.dart      # Deep link handler for magic link callback
          providers/
            auth_provider.dart      # Session state, token management
          services/
            auth_service.dart       # HTTP calls to /auth/* endpoints
        journal/                    # Reuse from common, minimal modifications
          screens/
            journal_screen.dart     # Entry list by date (from common)
            entry_detail_screen.dart
          providers/
            journal_providers.dart  # Backed by DailyApiService pointing at hosted URL
        cards/
          screens/
            cards_screen.dart       # View agent-generated cards/reflections
          providers/
            cards_provider.dart
        recorder/                   # Reuse from common
        settings/
          screens/
            settings_screen.dart    # Account, agents config only
            account_screen.dart     # Email, sign out, delete account
        onboarding/
          screens/
            onboarding_screen.dart  # Welcome → Magic link → Ready
    pubspec.yaml                   # Depends on parachute_common
    ios/
    android/
    macos/
    web/
```

**Key differences from current `FLAVOR=daily`:**
- Auth flow instead of local-only mode
- `DailyApiService.baseUrl` hardcoded to hosted URL (e.g. `https://daily.parachute.computer`)
- No vault path selection
- No server connection settings
- No transcription model download (server handles it)
- Cards/reflections as a first-class screen (not buried in settings)
- Settings: account management + agent config only

### 2.3 Navigation

Single-screen app with tabs within the Daily experience:

```
Bottom nav: [Journal] [Cards] [Settings]
```

Or no bottom nav — just the journal with cards as an expandable section at the top of the day view. Keep it simple. The current Daily screen already shows cards inline.

### 2.4 Voice Recording Flow (Hosted)

1. User taps record → existing recorder widget captures audio locally
2. On stop → Flutter calls `POST /api/storage/presigned-upload` to get R2 upload URL
3. Flutter PUTs audio to R2 directly (fast, no server bottleneck)
4. Flutter calls `POST /api/daily/entries/voice` with objectKey + duration
5. Server transcribes async → entry appears with "processing" status
6. Flutter polls or receives push when transcription completes
7. Entry updates with transcript text

## Phase 3: Integration & Polish

### 3.1 Deep Links

Register `parachute-daily://` scheme for magic link verification:
- `parachute-daily://auth/verify?token=xxx` → opens app, verifies session
- Fallback: if app not installed, redirect to web signup page

### 3.2 Domain & DNS

- Backend: `daily-api.parachute.computer` (CF Workers custom domain)
- Web: `daily.parachute.computer` (landing page, could be same Worker serving static assets)

### 3.3 Testing

- Worker: Vitest with Miniflare (CF's local dev environment) for DO + KV + R2 tests
- Flutter: existing test patterns from the main app
- Integration: curl-based smoke tests against the live Worker

## Technical Considerations

**30-second CPU limit on DOs**: Agent runs that involve multiple LLM round-trips may approach this. Wall-clock time waiting on Groq API doesn't count (only CPU time). If an agent needs >30s of CPU, split into multiple alarm-chained steps.

**SQLite row size limit**: 2MB per row. Journal entries are text — unlikely to hit this. Cards might get long but 2MB is generous.

**Hibernation**: DOs hibernate when idle. `onStart()` fires on wake — schema creation uses `IF NOT EXISTS` so it's idempotent. Scheduled alarms survive hibernation.

**Model choice**: Start with Groq (Llama 3.3 70B) — fast, cheap ($0.59/M input, $0.79/M output), reliable function calling. Evaluate Nemotron Super quality in parallel. The Vercel AI SDK makes switching a one-line change.

**Transcription**: Start with Workers AI whisper (free) for v1. Upgrade to Deepgram if quality isn't sufficient. The transcription call is isolated in one function — easy to swap.

## Dependencies & Risks

| Risk | Mitigation |
|------|------------|
| Groq function calling reliability | Vercel AI SDK makes provider swapping trivial. Fallback to Workers AI or Nemotron. |
| CF Agents SDK still pre-1.0 (v0.8.x) | Core DO primitives are GA. SDK is a thin wrapper — could drop down to raw DO if needed. |
| Magic link email deliverability | Resend has good deliverability. Add SPF/DKIM for custom domain. |
| Flutter common package extraction | The app is already modular by feature. Extraction is mechanical, not architectural. |
| R2 presigned URL CORS issues | Well-documented pattern. Configure CORS on bucket creation. |

## References

- Brainstorm: #344
- Prior art: #159 (Daily online-first architecture)
- [Cloudflare Agents SDK docs](https://developers.cloudflare.com/agents/)
- [Cloudflare agents-starter template](https://github.com/cloudflare/agents-starter)
- [Vercel AI SDK](https://ai-sdk.dev/)
- [Hono on CF Workers](https://hono.dev/docs/getting-started/cloudflare-workers)
- [R2 presigned URLs](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)
- [Resend + CF Workers](https://developers.cloudflare.com/workers/tutorials/send-emails-with-resend/)
