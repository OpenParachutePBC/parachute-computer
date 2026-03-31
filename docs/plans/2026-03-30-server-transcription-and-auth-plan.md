---
title: "Server-side transcription + API key auth for v2 server"
type: feat
date: 2026-03-30
issue: 359
---

# Server-side Transcription + API Key Auth

Two features for `daily/local/` — server-side audio transcription using sherpa-onnx-node, and optional API key authentication using Hono middleware.

## 1. Server-side Transcription

### Problem

The Flutter app can transcribe locally (Sherpa-ONNX / Parakeet), but server-side transcription is faster and frees the device. The old Python server used `parakeet-mlx` (macOS-only). The v2 TypeScript server has no transcription — `uploadVoiceEntry` in the app creates a Thing with empty content and `transcription_status: processing`, but nothing ever processes it.

### Approach

Use `sherpa-onnx-node` (native NAPI bindings) with Parakeet ONNX models. Same model family the Flutter app uses, cross-platform (macOS + Linux), ~640 MB model size.

**Flow:**
1. App uploads audio via `POST /api/storage/upload` (already works)
2. App creates Thing with `daily-note` tag: `{transcription_status: "processing", audio_url: path}`
3. New endpoint `POST /api/transcribe` accepts `{thing_id, audio_path}` 
4. Server loads audio, runs sherpa-onnx, updates Thing content + status
5. App polls for status changes (already does 5s polling)

**Files to create:**
- `daily/local/src/transcription.ts` — singleton service: model download, load, transcribe
- Add route in `daily/local/src/routes/` or extend existing routes

**Model management:**
- Auto-download Parakeet v3 INT8 ONNX models from HuggingFace on first use
- Cache in `~/.cache/parachute/models/parakeet-v3/`
- Lazy init — don't block server startup if model not yet downloaded

**Status lifecycle** (matches existing tag schema):
```
processing → transcribed → complete (after optional cleanup)
         └→ failed (on error)
```

### Acceptance Criteria

- [x] ~~`npm install sherpa-onnx-node`~~ → pluggable backend instead (no bundled dep)
- [x] Transcription service: parakeet-mlx local backend + API backend
- [x] `POST /api/transcribe` endpoint: `{thing_id, audio_path}` → transcribes and updates Thing
- [x] Thing's `daily-note` tag updated: `transcription_status` → `transcribed`, content filled
- [x] Model auto-downloads on first transcription request (parakeet-mlx handles this)
- [x] Errors set `transcription_status: failed` with error info
- [x] Health endpoint reports `transcription_available: true/false`
- [x] Auto-transcription: voice entries with processing status trigger transcription on creation

---

## 2. API Key Auth

### Problem

The v2 server has no authentication. Fine for localhost, but unsafe if accessed over the network (tailnet, LAN). The old server had `auth_mode` (remote/always/disabled) with hashed API keys in YAML.

### Approach

Hono middleware with three modes matching the old server. The Flutter app already sends `Authorization: Bearer <key>` headers.

**Modes:**
- `remote` (default) — localhost bypasses auth, remote requires key
- `always` — all requests require key
- `disabled` — no auth (dev only)

**Key format:** `para_<32 random chars>` (reuse old format)
**Key storage:** Hashed (SHA256) in `~/.parachute/server.yaml`
**Validation:** constant-time comparison via `crypto.timingSafeEqual`

**Files to create:**
- `daily/local/src/auth.ts` — middleware + key management functions

**Bootstrap:** `POST /api/auth/keys` from localhost creates first key (no auth required). Returns plaintext exactly once.

**Skip auth for:** `GET /api/health`, `POST /api/auth/keys` (localhost only)

### Config format

```yaml
# ~/.parachute/server.yaml
security:
  auth_mode: remote
  api_keys:
    - id: k_xY9zAbCdEf
      label: my-macbook
      key_hash: sha256:abcdef...
      created_at: 2026-03-30T00:00:00Z
```

### Acceptance Criteria

- [x] Auth middleware checks `Authorization: Bearer` and `X-API-Key` headers
- [x] Three modes: remote (default), always, disabled
- [x] Localhost bypass in `remote` mode
- [x] Keys stored hashed in `~/.parachute/server.yaml`
- [x] `POST /api/auth/keys` — create key (localhost only, returns plaintext once)
- [x] `GET /api/auth/keys` — list keys (metadata only)
- [x] `DELETE /api/auth/keys/:id` — revoke key
- [x] Constant-time comparison for key validation
- [x] Health endpoint skips auth
- [x] `GET /api/auth/settings` + `PUT /api/auth/settings` — view/change auth mode

## Technical Considerations

- `sherpa-onnx-node` has native binaries — may need platform-specific install
- Model download is ~640 MB — first transcription will be slow
- Auth config file created on first key creation (doesn't need to exist at startup)
- The Flutter app's `DailyApiService` already sends `Authorization: Bearer` — no app changes needed for auth

## Implementation Order

1. Auth first (simpler, unblocks network access)
2. Transcription second (depends on model download working)
