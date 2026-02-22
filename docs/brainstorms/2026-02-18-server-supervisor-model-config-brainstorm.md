# Server Supervisor & Model Configuration

**Date:** 2026-02-18
**Status:** Brainstorm
**Modules:** computer, app

---

## Problem

Two pain points surfaced while upgrading to Claude Sonnet 4.6:

1. **Model configuration is brittle.** We hardcoded `DEFAULT_MODEL=claude-sonnet-4-6` in a `.env` file. Every new model release requires manually editing server config and restarting. There's no visibility into which model is active and no way to change it from the app.

2. **Server management requires physical access.** Restarting the Parachute Computer server meant going to the machine and running CLI commands. When restarts failed, there was no way to retry or diagnose from the app. The main server can't restart itself — if it's down, its API is unreachable.

## What We're Building

### 1. Supervisor Service (port 3334)

A separate lightweight Python/FastAPI process that manages the main Parachute Computer server. Always running, independent of the main server.

**Responsibilities:**
- Start / stop / restart the main server (port 3333)
- Stream server logs to connected clients
- Report server health and resource usage
- Survive main server crashes — the whole point is independent lifecycle

**Key endpoints:**
- `GET /supervisor/status` — supervisor + main server health
- `POST /supervisor/server/restart` — restart main server
- `POST /supervisor/server/stop` — stop main server
- `GET /supervisor/logs` — SSE stream of server logs
- `GET /supervisor/config` — current server configuration (including active model)
- `PUT /supervisor/config` — update config values (model, etc.) and optionally restart

**Deployment:**
- Separate launchd plist (macOS) / systemd unit (Linux)
- Shares the Python venv with the main server
- Ultra-lightweight — no module loading, no Claude SDK, just process management + HTTP

### 2. Model Picker (App Settings)

Server-provided model list with user selection, synced to the server.

**Flow:**
1. Server queries Anthropic's `GET /v1/models` endpoint to discover available models
2. Supervisor exposes this list via `GET /supervisor/models`
3. App settings page shows a dropdown with available models
4. User selects a model, app sends `PUT /supervisor/config` with `default_model`
5. Supervisor writes config and optionally restarts the main server

**Anthropic Models API:**
- Endpoint: `GET https://api.anthropic.com/v1/models`
- Returns model objects with `id`, `display_name`, `created_at`
- Paginated (up to 1000 per page)
- Requires `x-api-key` and `anthropic-version` headers

### 3. Server Section in App Settings

New section in the existing Settings page:

- **Server Status** — running/stopped indicator with uptime
- **Model** — dropdown picker showing available models, current selection highlighted
- **Controls** — restart button, stop button
- **Logs** — expandable log viewer (recent lines, with option to stream live)

## Why This Approach

- **Supervisor is independently deployable** — if the main server crashes, the supervisor is still reachable for diagnosis and restart
- **Model list from Anthropic API** — no hardcoded model names to maintain; new models appear automatically
- **Settings page integration** — no new navigation concepts; server management lives where users expect configuration
- **Shared venv** — supervisor is trivial to install alongside the main server; no separate dependency management

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Supervisor vs. extend launchd | Separate Python process | Need HTTP API for app communication; launchd alone can't expose logs or config |
| Supervisor port | 3334 | Adjacent to main server (3333), easy to remember |
| Model list source | Anthropic `/v1/models` API | Automatically includes new models; single source of truth |
| UI location | Settings page section | Consistent with existing patterns; no new navigation |
| Config persistence | Server-side (config.yaml or .env) | Supervisor writes config, main server reads on start |

## Open Questions

1. **Auth for supervisor** — Should the supervisor require the same API key auth as the main server? Or is localhost-only sufficient since it's local-first?
2. **Bundled server mode** — The app already has bundled server detection. Should the supervisor replace that logic, or coexist with it?
3. **Model filtering** — The Anthropic API returns many models (dated versions, legacy). Should we filter to just the latest of each family (opus, sonnet, haiku)?
4. **Config hot-reload** — Can the main server pick up model changes without a full restart? Or is restart required?
5. **Supervisor auto-start** — Should `install.sh` set up both launchd plists, or is the supervisor opt-in?
