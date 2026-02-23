---
status: pending
priority: p3
issue_id: "219"
tags: [code-review, agent-native, python, chat]
dependencies: []
---

# transcribe_audio capability has no REST API surface (agent-native gap)

## Problem Statement

When `transcribe_audio` is wired to a real service, Discord and Matrix users will be able to submit voice messages and receive AI responses. An agent or API caller consuming the REST API will have no equivalent: there is no `POST /api/transcribe` endpoint and `transcribe_audio` is not on `server_ref`. The capability will be exclusively accessible via the bot UI, violating Parachute's agent-native parity principle.

Currently, `transcribe_audio` returns `None` for all connectors (not on `server_ref`), so no one can use voice today. This todo tracks adding the REST surface before the feature goes live, not after.

## Findings

- `server.py:256-261` — `server_ref = SimpleNamespace(...)` — no `transcribe_audio` field
- `discord_bot.py:287`, `matrix_bot.py:534` — both check `getattr(self.server, "transcribe_audio", None)` and gracefully skip if absent
- No `POST /api/transcribe` route exists in the FastAPI app
- agent-native-reviewer confidence: 92

## Proposed Solutions

### Option 1: Add POST /api/transcribe endpoint before wiring up transcribe_audio
When implementing the real transcription service, simultaneously add:
1. `transcribe_audio` function on `server_ref`
2. `POST /api/transcribe` endpoint accepting multipart form data (audio bytes + optional format)
   - Returns `{"transcript": "..."}` on success
   - Same service as used by bot connectors

**Pros:** Agents and humans gain the capability at the same time.
**Effort:** Medium (part of the transcription feature work)
**Risk:** Low

### Option 2: Add the endpoint stub now (returns 501 Not Implemented)
Add the route today so the API surface exists; implement the handler when transcription is built.

**Pros:** API contract is defined early.
**Effort:** Small

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/server.py` (server_ref + route registration)
- New file: `computer/parachute/routes/transcribe.py` (or similar)

## Acceptance Criteria

- [ ] `POST /api/transcribe` endpoint exists when `transcribe_audio` is wired to a service
- [ ] Endpoint accepts audio bytes (multipart) and returns transcript
- [ ] Agent can achieve "voice → AI response" without going through the Discord/Matrix gateway

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by agent-native-reviewer (confidence 92)
- Currently moot (transcription not wired), but should be addressed before the feature goes live

## Resources

- **PR:** #117
- **Issue:** #88
