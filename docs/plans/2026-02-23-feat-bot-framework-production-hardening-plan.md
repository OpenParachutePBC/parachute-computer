---
title: Bot Framework Production Hardening
type: feat
date: 2026-02-23
issue: 89
---

# Bot Framework Production Hardening

## Overview

Five independent, incremental improvements to the bot connector framework that address production-readiness gaps: rate limiting, message send retry, state machine strictness, pairing lifecycle cleanup, and session state guarding. Each can be implemented and tested separately with no Flutter changes required.

## Problem Statement

The bot connector framework works for single-user usage but has gaps that compound at scale:

1. **No rate limiting** — Any user can spam messages; each triggers an orchestrator + Claude call. A single bad actor can exhaust API budget.
2. **No message send retry** — Platform API failures (network blips, 429s, message too large) silently drop the response. User sees the ack emoji but never gets a reply.
3. **Weak state machine** — `_set_status()` at `base.py:203` logs a warning on invalid transitions and returns silently. Logic bugs where the connector believes it's RUNNING but state says STOPPED go undetected.
4. **Pairing lifecycle gaps** — Pending requests accumulate forever (no TTL), approved users can't be removed without editing `bots.yaml` by hand, and the nudge counter never resets after expiry.
5. **No session state guard** — If a session is archived while a message is in flight, the response targets a stale session.

## Proposed Solution

All changes are in `computer/parachute/connectors/` and `computer/parachute/api/`. No app or schema changes.

### Fix 1 — Token Bucket Rate Limiter (base.py)

Add a per-`chat_id` token bucket in the base class. 10 messages per 60-second window. Reject over-limit messages with a friendly platform message; do not queue.

**Decision rationale:** Rejection is simpler than queuing and appropriate here — the typical interaction is question → answer, not burst. 10/min is generous for normal use and protective against spam.

**Key fields to add to `BotConnector.__init__`:**
```
_rate_buckets: dict[str, tuple[float, int]]  # chat_id → (last_refill_time, tokens)
_rate_limit: int = 10        # tokens per window
_rate_window: float = 60.0   # seconds
_rate_limit_message: str     # user-facing rejection text
```

**New method:** `_check_rate_limit(chat_id: str) -> bool` — returns `True` if allowed, `False` if exceeded. Callers (Telegram's `_handle_message`, Discord's `on_message`, Matrix's `on_event`) check before dispatching to orchestrator.

### Fix 2 — Message Send Retry (base.py)

Wrap `send_message()` with a 3-attempt exponential backoff helper. The base class provides a `_send_with_retry(coro, chat_id)` method that subclasses call instead of calling the platform library directly.

**Backoff:** 1s → 2s → 4s (matching the brainstorm spec). Log attempt count on each retry. Log failure with `chat_id` (never message content) on final failure.

**Subclass changes:** Telegram's `send_message` (line ~740), Discord's `send_message` (line ~465), Matrix's `send_message` (line ~837) each delegate to `_send_with_retry`. Matrix already has a bare `try/except` that can be replaced.

### Fix 3 — State Machine Strictness (base.py)

Change `_set_status()` at `base.py:203` from:
```
if new not in valid: logger.warning(...); return
```
to:
```
if new not in valid: raise RuntimeError(f"Invalid connector state transition: {old} → {new}")
```

Add structured log on every *valid* transition at DEBUG level for traceability. This surfaces logic bugs instead of silently masking them.

### Fix 4 — Pairing Lifecycle (api/bots.py + database.py + base.py)

Four sub-changes, all independent:

**4a. 7-day TTL on pending requests**
In `db/database.py`, add `get_expired_pairing_requests(ttl_days: int) -> list[PairingRequest]` and `expire_pairing_request(request_id: str)`. Call on startup (or lazily at first check) to mark stale pending requests as `expired`.

**4b. Reset nudge counter on TTL expiry**
In `base.py`, the `_nudge_counts: dict[str, int]` counter should be cleared for a `chat_id` when its pairing request expires, so the user can try again without hitting silence.

**4c. Revocation endpoint**
Add `DELETE /api/bots/pairing/{platform}/{user_id}` to `api/bots.py`. Removes user from `bots.yaml` allowlist (using the existing `_config_lock` + `_write_bots_config` pattern). Clears `_trust_overrides` cache entry on the live connector. Does **not** touch the linked session — keep it simple.

**4d. Race condition guard on approval**
The `approve` endpoint at `bots.py:451` should check `status == "pending"` inside the lock before updating. Currently the `UNIQUE(platform, platform_user_id, status)` constraint on the DB provides some protection, but an explicit early-return check makes intent clear.

### Fix 5 — Session State Guard (base.py)

In `BotConnector._dispatch_to_orchestrator()` (or equivalent dispatch point), look up the session via `db.get_session(session_id)` before calling the orchestrator. If `session.status == "archived"`, log and send a user-facing message ("Your session has ended — start a new one with /new") instead of dispatching.

## Files

| File | Change |
|------|--------|
| `computer/parachute/connectors/base.py` | Fixes 1, 2, 3, 4b, 5 |
| `computer/parachute/api/bots.py` | Fix 4c (revocation endpoint), 4d (race guard) |
| `computer/parachute/db/database.py` | Fix 4a (TTL query + expiry method) |
| `computer/tests/connectors/test_base.py` | Tests for rate limiter, retry, state machine |
| `computer/tests/api/test_bots.py` | Tests for revocation endpoint |

## Acceptance Criteria

- [ ] Rate limiter rejects the 11th message within 60 seconds with a friendly reply
- [ ] Rate limiter allows messages after the window resets
- [ ] `send_message()` retries up to 3 times with 1s/2s/4s backoff before logging failure
- [ ] Invalid `_set_status()` transition raises `RuntimeError` (not silent return)
- [ ] Pending pairing requests older than 7 days are marked `expired` on next query
- [ ] Nudge counter resets for expired requests so users can re-pair
- [ ] `DELETE /api/bots/pairing/{platform}/{user_id}` removes from YAML allowlist and in-memory cache
- [ ] Dispatching to an archived session sends a user-facing message instead of calling the orchestrator
- [ ] All existing bot connector tests continue to pass
- [ ] New tests cover each of the five fixes

## Dependencies & Risks

**No external dependencies.** All changes use the existing async patterns, `asyncio.Lock`, the database helpers, and the YAML config writer.

**Risk — state machine strictness:** Raising on invalid transitions could surface latent bugs that previously went undetected. The tests in `test_base.py` should cover all valid transitions first; run the full test suite before merging Fix 3.

**Risk — revocation + in-flight messages:** If a message is mid-flight when a user is revoked, the orchestrator call completes normally. This is acceptable — revocation takes effect for the *next* message, not the current one.

## References

- Brainstorm: `docs/brainstorms/2026-02-20-bot-production-hardening-brainstorm.md`
- Related: #88 (bot cross-platform consistency), #86 (shared command registry)
- Prior resilience work: `docs/plans/2026-02-17-feat-bot-connector-resilience-plan.md`
- Base class: `computer/parachute/connectors/base.py:196` (state machine), `base.py:483` (send_message)
- API: `computer/parachute/api/bots.py:451` (approve endpoint)
- DB: `computer/parachute/db/database.py:109` (pairing_requests table)
