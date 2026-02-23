---
status: pending
priority: p3
issue_id: 107
tags: [code-review, architecture, credentials, caching]
dependencies: []
---

# Credential Cache Key Should Include vault_path

## Problem Statement

**What's broken/missing:**
`credentials.py` uses `mtime` alone as the cache key, ignoring `vault_path`. If `load_credentials` is called with two different vault paths in the same process (test suite, future multi-vault config), the cache returns the first vault's credentials for any subsequent vault. One-vault-per-process is a current invariant but it's undocumented and fragile.

**Why it matters:**
- Tests that call `load_credentials` with different `tmp_path` values will get stale results from the first call
- The architectural assumption (one vault) should be explicit, not implicit in the cache design
- `mcp_loader.py` (the nearest sibling module) exposes `invalidate_mcp_cache()` — credentials.py has no equivalent

## Findings

**From architecture-strategist (Confidence: 88):**
> Cache key is mtime alone. vault_path is ignored for cache invalidation. Two different vault paths silently cross-contaminate.

**From pattern-recognition-specialist (Confidence: 85):**
> `credentials.py` cache lacks `invalidate_credentials_cache()` peer function present in `mcp_loader.py`

## Proposed Solutions

**Solution A: Include vault_path in cache key (Recommended)**
```python
_cache: dict[str, tuple[dict[str, str], float]] = {}  # vault_path_str -> (creds, mtime)

def load_credentials(vault_path: Path) -> dict[str, str]:
    key = str(vault_path)
    path = vault_path / ".parachute" / "credentials.yaml"
    ...
    cached = _cache.get(key)
    if cached is not None and mtime == cached[1]:
        return cached[0]
    ...
    _cache[key] = (result, mtime)
```

**Solution B: Add `invalidate_credentials_cache()` for test isolation**
Keep current design, add a function for tests to call.

**Effort:** Small
**Risk:** Very low — pure caching change, no behavior change for single-vault use

## Acceptance Criteria
- [ ] Two different vault_paths return independent results (no cross-contamination)
- [ ] Single-vault use case unchanged in behavior
- [ ] Tests that create temp vault dirs get correct credential isolation

## Resources
- File: `computer/parachute/lib/credentials.py`
- Reference: `computer/parachute/lib/mcp_loader.py` (invalidate pattern)
