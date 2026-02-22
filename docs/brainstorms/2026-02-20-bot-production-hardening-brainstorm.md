---
title: Bot Framework Production Hardening
status: brainstorm
priority: P2
module: computer
tags: [bot-framework, reliability, security]
issue: 89
---

# Bot Framework Production Hardening

## What We're Building

Address production-readiness gaps in the bot connector framework: rate limiting, message retry, state machine strictness, and the pairing request lifecycle. These are the gaps that would bite us as usage scales beyond a single user.

### The Problems

**1. No rate limiting**
- Any user can spam the bot with messages — each triggers an orchestrator call (which calls Claude)
- No per-user or per-chat throttle
- A single misbehaving user could burn through API budget

**2. No message send retry**
- If the platform API rejects a response (network blip, rate limit, message too large), the response is lost
- No dead letter queue or retry logic
- User sent a message, got the ack emoji, but never gets a response

**3. Weak state machine enforcement**
- Invalid state transitions are logged as warnings but silently ignored
- `_set_status()` returns without updating on invalid transition
- Could mask logic bugs where connector thinks it's RUNNING but state says STOPPED

**4. Pairing request lifecycle gaps**
- No timeout on pending pairing requests — they accumulate forever
- No revocation endpoint — approved users can only be removed by editing bots.yaml
- Race condition: multiple threads could approve the same user simultaneously
- `pending_initialization` nudge counter never resets (after 2 nudges, user gets silence forever)

**5. Session state not checked before response**
- If a session is archived while a message is in flight, the response targets an archived session
- No guard against sending to stale/archived sessions

## Why This Approach

These are independent, incremental improvements. Each can be implemented and tested separately. Prioritize by impact:

### Priority Order

1. **Rate limiting** — Biggest risk. Simple token bucket per chat_id in base class. Reject with friendly message when exceeded.
2. **Pairing lifecycle** — Add `DELETE /api/bots/pairing/{user_id}` revocation endpoint. Add TTL on pending requests (auto-expire after 7 days). Reset nudge counter on timeout.
3. **Message send retry** — Wrap `send_message()` with 3-attempt retry and exponential backoff. Log failures.
4. **State machine strictness** — Raise exception on invalid transition instead of silent return. Add transition logging.
5. **Session state guard** — Check session isn't archived before dispatching to orchestrator.

### Scope

- `base.py` for rate limiting, retry, state machine
- `api/bots.py` for revocation endpoint
- Test updates for new behaviors
- No Flutter changes (revocation could reuse existing pairing UI with a "revoke" button later)

## Key Decisions

- **Token bucket rate limiter** — Simple, well-understood, per-chat-id granularity
- **3 retries with 1s/2s/4s backoff** — Enough to handle transient network issues without blocking
- **7-day TTL on pending requests** — Long enough for casual users, short enough to not accumulate

## Open Questions

- What rate limit is appropriate? 10 messages/minute per chat? 5?
- Should rate-limited messages be queued or rejected with a message?
- Should the revocation endpoint also clean up the linked session, or just remove the user from the allowlist?
