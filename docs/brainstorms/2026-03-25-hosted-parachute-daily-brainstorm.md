---
date: 2026-03-25
topic: hosted-parachute-daily
status: brainstorm
priority: P1
module: daily, computer, app
---

# Hosted Parachute Daily

**Issue:** #344

## What We're Building

A hosted version of Parachute Daily — simple AI-integrated voice journaling where your data is yours. Users sign up, open the app, record entries, and get AI-generated reflections. No server to install, no configuration. The hosted backend runs on Cloudflare Workers + Durable Objects, with each user getting isolated storage in their own Durable Object's SQLite database.

Parachute Daily is a standalone product and the entry point to the Parachute ecosystem. It ships as its own app (separate from Parachute Computer) with its own App Store listing. An easy migration path to Parachute Computer exists for users who want the full extended mind experience, but Daily stands on its own.

Builds on #159 (Daily online-first architecture) — the Flutter app already assumes a server-authoritative model.

## Why This Approach

### Cloudflare Workers + Durable Objects

- **Scale to zero**: Idle users cost nothing. Each user's Durable Object hibernates when inactive and wakes on request. No always-on VMs.
- **Per-user isolation**: Each user gets their own DO instance with its own SQLite database. Multi-tenancy is handled by the platform, not our code.
- **Scheduling built in**: Nightly reflection agents use DO alarms — `schedule("0 23 * * *", "processDay")`. No central cron service.
- **Cost at small scale**: Free tier covers 100k requests/day, 5M SQLite reads/day. Early beta costs effectively $0 in infrastructure. Model API costs dominate.

### Cloudflare Agents SDK + Vercel AI SDK

- Cloudflare Agents SDK provides the infrastructure layer — per-user DOs, state sync, scheduling, WebSocket management, auth hooks.
- Vercel AI SDK provides the LLM calling layer — provider abstraction, streaming, tool definitions. Used internally by CF Agents SDK.
- Together they give us a typed agent system with tool calling, streaming, and per-user state in ~100 lines per agent.

### Not Claude Agent SDK

The hosted version uses open-weight models (Nvidia Nemotron Super, Groq/Llama) via OpenAI-compatible APIs. This decouples from Anthropic, dramatically reduces per-request cost, and means we're not running CLI subprocesses. The agent loop is simpler — just `streamText()` with tools — because Daily's agents don't need the full Computer agent capabilities (no filesystem access, no Docker, no MCP ecosystem).

### Two Flutter Apps from Common Package

Daily and Computer are separate App Store apps with different onboarding, settings, and feature surfaces. They share a common Flutter package for widgets, theme, models, and API service layer. This keeps both apps focused while ensuring UI patterns feel familiar for users migrating from Daily to Computer.

## Key Decisions

- **Cloudflare Workers + Durable Objects for backend**: Scale-to-zero, per-user isolation, built-in scheduling. TypeScript runtime.
- **Cloudflare Agents SDK for agent infrastructure**: Wraps DO lifecycle, provides scheduling, auth hooks, WebSocket management. Uses Vercel AI SDK for LLM calls.
- **SQLite on DO for storage**: Same schema shape as Kuzu (notes, agents, agent_runs, cards) but in SQLite tables. Sufficient for Daily's usage — no deep graph traversal needed.
- **Nemotron Super / Groq as model backend**: OpenAI-compatible APIs via Vercel AI SDK's `createOpenAICompatible()`. Cheap, fast, not tied to any one provider.
- **External transcription API**: Deepgram, AssemblyAI, or similar. No bundled Sherpa-ONNX/Parakeet. Audio uploaded to R2, transcribed via API.
- **R2 for audio storage**: Voice recordings stored in Cloudflare R2, keyed by user/date. Free egress, cheap storage.
- **Magic link auth**: Email-based magic links for sign up/sign in. No passwords. Cloudflare Turnstile for bot protection.
- **Two Flutter apps, common package**: Separate apps for Daily and Computer. Shared package for common widgets, theme, models, API layer.
- **Codebases drift naturally**: The Python Computer server and TypeScript Workers don't need to stay in lock-step. What matters is migration ease and shared data schemas, not identical implementations.
- **Agent tools have common interface, different implementations**: Tools like `read_days_notes`, `write_card`, `read_this_note` have the same names and parameter shapes across both systems. Implementations differ (Python+Kuzu vs TypeScript+SQLite) but the contract is the same.

## Architecture

```
┌──────────────────────────────────────────────┐
│           Cloudflare Workers                  │
│                                               │
│  ┌─────────────┐    ┌───────────────────┐    │
│  │ Hono Router  │    │ CF Agents SDK      │    │
│  │ (REST API)   │    │ + Vercel AI SDK    │    │
│  └──────┬──────┘    └────────┬──────────┘    │
│         │                    │                │
│         └────────┬───────────┘                │
│                  ▼                             │
│  ┌────────────────────────┐                   │
│  │ Durable Object per user │                  │
│  │ (CF Agents SDK Agent)   │                  │
│  │                          │                  │
│  │ SQLite: notes, agents,   │                  │
│  │ agent_runs, cards, tags  │                  │
│  │                          │                  │
│  │ Scheduled: process-day   │                  │
│  └────────────────────────┘                   │
│         │                                     │
│  ┌──────┴──────┐    ┌──────────────────┐     │
│  │ R2 Storage   │    │ External APIs     │     │
│  │ (audio)      │    │ - Nemotron/Groq   │     │
│  │              │    │ - Deepgram (STT)   │     │
│  └─────────────┘    └──────────────────┘     │
└──────────────────────────────────────────────┘
```

## V1 Scope

**Core journaling:**
- Sign up via magic link, sign in
- Record voice entry → upload audio to R2 → transcribe via external API → store in DO SQLite
- Text entry creation (no voice)
- Browse entries by date
- View entry detail

**Agent system:**
- Agent configs stored in DO SQLite (seeded with process-note, process-day)
- Event dispatch: note created → matching agents run
- Scheduled agents: nightly process-day reflection
- Cards generated from agent runs (daily reflection, themes)
- View cards in UI

**Flutter app (new `parachute_daily` app):**
- Hosted onboarding: welcome → sign up/sign in → ready
- Journal tab (entry list by date, create entry, view detail)
- Cards/reflections view
- Minimal settings (account, subscription status)
- Common package extracted from existing app (theme, widgets, models, API layer)

## NOT V1

- API token / external MCP access to your data
- Migration tooling from Daily to Computer
- Billing / Stripe integration (free beta first)
- Offline mode / pending queue (start online-only, add offline later)
- Photo/handwriting entries
- Brain integration (entity extraction, graph traversal)
- Import from legacy local vault files

## Migration Path (Daily → Computer)

When a Daily user wants the full Parachute Computer experience:

1. **Data export**: Export from DO SQLite — notes, cards, agent configs, runs, tags — as a portable format (JSON or SQLite dump)
2. **Data import**: Import into Kuzu on their Computer instance (self-hosted or hosted Fly.io VM)
3. **Audio migration**: R2 audio files download to local vault or transfer to Computer's storage
4. **App switch**: Install Parachute Computer app, sign in, data is there

The schemas are intentionally aligned so this is a straightforward ETL, not a lossy transformation.

## Future: Hosted Parachute Computer

For users who want the full Computer experience without self-hosting, a hosted VM approach (likely Fly.io):

- Full Python/FastAPI server with Kuzu, Claude SDK, module system
- Persistent volume per user
- Can scale to zero (Fly machines stop when idle, volumes persist)
- Different infrastructure from Daily — that's fine
- Users who outgrow Daily's agent capabilities graduate to Computer

## Open Questions

- **Transcription provider**: Deepgram vs AssemblyAI vs Cloudflare Workers AI whisper models? Cost vs quality tradeoffs at different volumes.
- **Model selection**: Start with one provider (Groq?) or offer choice? How do we evaluate Nemotron Super quality for our specific agent tasks?
- **Common Flutter package scope**: What exactly gets extracted? Theme + widgets + models + API service? Or more?
- **Magic link implementation**: Cloudflare Workers + Resend for email delivery? Or a managed auth service?
- **Pricing model**: Free tier limits? What triggers paid? Storage-based? Entry count? Agent run count?
- **Domain**: `daily.parachute.computer`? `app.parachute.daily`? Something else?

## Next Steps

→ Issue #1: Hosted Parachute Daily v1 (this brainstorm)
→ Issue #2: Parachute Daily future roadmap (API access, migration tooling, billing)
→ `/plan` the v1 when ready to implement
