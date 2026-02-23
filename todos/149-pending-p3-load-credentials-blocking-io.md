---
status: pending
priority: p3
issue_id: 107
tags: [code-review, performance, async, credentials]
dependencies: []
---

# Wrap `load_credentials()` in `asyncio.to_thread` to Avoid Event Loop Blocking

## Problem Statement

**What's broken/missing:**
`load_credentials()` calls `path.stat()` (always) and `path.read_text()` (on cache miss) — both synchronous blocking filesystem operations. It's called from `run_streaming()` which is `async def`. This freezes the event loop for the duration of the file I/O on cache misses.

**Why it matters:**
- Synchronous I/O in async code is the classic FastAPI event loop freeze pattern
- At current call frequency (once per session message on non-bot sessions) and with small YAML files, the practical impact is <1ms — but it's a correctness concern
- Will matter more as concurrent sessions increase

## Findings

**From python-reviewer (Confidence: 90):**
> `load_credentials()` calls `path.stat()` and `path.read_text()` — blocking I/O — directly in `async def _build_system_prompt`. Freezes event loop on cache miss.

## Proposed Solutions

**Solution A: Wrap call site with `asyncio.to_thread` (Recommended)**
```python
prompt_cred_keys = (
    set((await asyncio.to_thread(load_credentials, self.vault_path)).keys())
    if session.source not in BOT_SOURCES
    else set()
)
```

**Solution B: Preload at orchestrator construction, refresh on background interval**
Load credentials once at startup, periodically refresh. Eliminates per-request I/O entirely.

**Effort:** Small (Solution A) / Medium (Solution B)
**Risk:** Very low

## Acceptance Criteria
- [ ] No synchronous filesystem I/O in async hot path
- [ ] Credential loading still reflects file changes (mtime caching preserved)

## Resources
- File: `computer/parachute/core/orchestrator.py` (around line 379, `run_streaming`)
- File: `computer/parachute/lib/credentials.py`
