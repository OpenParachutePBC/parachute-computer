# Model Selection & Display — Coherent End-to-End Flow

**Date:** 2026-03-03
**Status:** Brainstorm
**Priority:** P2
**Labels:** app, chat, computer
**Issue:** #168

---

## What We're Building

A coherent, end-to-end model selection and display system where:
1. The server config (`config.yaml`) is the single source of truth for which model to use
2. The settings UI actually works (currently broken — `onChanged: null`)
3. The correct model name is displayed consistently everywhere ("Claude Sonnet 4.6" not "Sonnet 4")
4. Users can see which model is active during a chat session

## Why Now

The current system is fragmented in a way that makes model selection silently broken:
- `ModelPickerDropdown` (shown when supervisor is running) has `onChanged: null` — literally can't change anything
- `ModelSelectionSection` (fallback) saves to `SharedPreferences` only, never reaches the server
- `config.yaml` has `default_model: claude-sonnet-4-6` hardcoded and wins regardless of UI changes
- Model displayed as "Sonnet" (generic enum label) instead of "Claude Sonnet 4.6" (from Anthropic API)
- `ChatMessagesState.model` tracks the actual model used (from SSE stream) but nothing displays it

## The Design

**Single source of truth:** `~/Parachute/.parachute/config.yaml` → `default_model` field, managed via `PUT /supervisor/config`.

### Write path (settings → server)
```
User picks model in ModelPickerDropdown
  → PUT /supervisor/config { values: { default_model: "claude-opus-4-6" } }
  → config.yaml updated atomically
  → UI refreshes to show newly selected model
```
No server restart required — since the app will send the model explicitly in each request (see below).

### Chat request path
The app reads the currently configured model from supervisor at startup (or on settings load) and caches it. Each chat request sends the model explicitly:
```
GET /supervisor/config → { default_model: "claude-opus-4-6" }
  ↓ cache locally in supervisorConfigProvider
  ↓ on chat: streamChat(model: "claude-opus-4-6", ...)
  ↓ server SSE emits: { type: "model", model: "claude-opus-4-6" }
  ↓ ChatMessagesState.model updated
  ↓ shown in chat UI
```

### Display everywhere
- **Settings:** `ModelPickerDropdown` reads `GET /supervisor/config` for current selection + `GET /supervisor/models` for list
- **Chat UI:** Format `state.model` ("claude-opus-4-6" → "Opus 4.6") and show it — usage bar or subtle header chip
- **Model label formatting:** strip "claude-" prefix, capitalize family, keep version number

### What gets removed
- `ClaudeModel` enum (hardcoded 3-option enum, no version info)
- `modelPreferenceProvider` (SharedPreferences-based)
- `ModelSelectionSection` (replaced by `ModelPickerDropdown` working correctly)

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Source of truth | Server `config.yaml` | Survives restarts, shared across clients, user's explicit choice |
| Write mechanism | `PUT /supervisor/config` | Already implemented + validated on backend |
| Read mechanism | `GET /supervisor/config` cached at startup | Avoid re-reading config on every chat |
| Model in request | Send explicitly (from cached config) | Server doesn't need to re-read its own config; explicit is clearer |
| Server restart on model change | No | App sends model in request, restart not needed for this |
| ModelPickerDropdown | Keep + fix | Already has the right UI skeleton (live list from Anthropic API, "Latest" badges) |
| Model display format | "Opus 4.6" (family + version) | Clean, recognizable, version-accurate |
| Where to show model in chat | Usage bar or subtle chip in chat header | Non-intrusive, useful for confirmation |

## What's In Scope

- Fix `ModelPickerDropdown`: enable selection, wire to `PUT /supervisor/config`, show current model from `GET /supervisor/config`
- Add `supervisorConfigProvider` (or extend existing supervisor providers) to cache current config
- Update `chat_message_providers.dart`: read model from supervisor config instead of `modelPreferenceProvider`
- Add model display in chat UI (usage bar chip or header)
- Fix model label formatting everywhere ("Claude Sonnet 4.6" not "Sonnet")
- Remove `ClaudeModel` enum + `modelPreferenceProvider` + `ModelSelectionSection`

## What's Out of Scope

- Per-session model override (different model for one chat without changing global config) — YAGNI
- Model change notifications / upgrade alerts
- Model selector in the chat compose area
- Persisting model to session database record

## Open Questions

- Should changing the model in settings require a snackbar confirmation ("Model changed to Claude Opus 4.6") or just update silently?
- When the supervisor is NOT running (offline/bundled mode), what model selection do we offer? Probably just a read-only display saying "Server not running — model determined by server config."
- Is there a `GET /supervisor/config` endpoint that returns `default_model` clearly? (Yes — exists at `supervisor.py:315`)

## Rough Scope

Small-medium. The backend API already exists. This is primarily:
1. Wiring `ModelPickerDropdown` to real read/write calls (~50 lines)
2. Adding a `supervisorConfigProvider` (reads config, caches it)
3. Updating chat provider to use supervisor config instead of SharedPreferences (~20 lines)
4. Adding model chip to usage bar or chat header (~30 lines)
5. Removing the old enum/SharedPreferences path
