# Simplify Model Selection + 1M Context Window

- **Status:** Brainstorm
- **Priority:** P2
- **Labels:** computer, app, enhancement
- **Issue:** #293

---

## What We're Building

Replace the dynamic Anthropic API model fetching with a simple static picker (Opus / Sonnet / Haiku) and add a 1M context window toggle. The Claude Code CLI resolves short names like `opus`, `sonnet`, `haiku` to the latest version — we should lean on that instead of maintaining our own model list infrastructure.

### The Problem

- The current model picker fetches the full model list from Anthropic's `/v1/models` API, caches it with a 1-hour TTL, handles pagination, sorts by family, marks "latest" — ~200 lines of infrastructure for a choice between 3 models.
- The `[1m]` context window suffix (e.g., `opus[1m]`) can't pass through the supervisor's regex validation (`^claude-[a-z0-9\-]+$`), so there's no way to enable the 1M context window from the app.
- Users see frequent context compaction because the default 200K window fills up fast. The 1M window is available on both Opus 4.6 and Sonnet 4.6 but there's no path to enable it.

### What Changes

| Layer | Current | Simplified |
|-------|---------|------------|
| `models_api.py` | ~200 lines: API fetch, pagination, caching, sorting | **Delete** |
| `/supervisor/models` endpoint | Calls Anthropic API, returns filtered list | Returns static 3 models |
| `/api/models` endpoint | Cached API proxy | Returns static 3 models |
| Supervisor config regex | `^claude-[a-z0-9\-]+$` | Accept short names + `[1m]` suffix |
| `ModelPickerDropdown` (Flutter) | Dropdown with dated versions, "Show all" toggle, "Latest" badges | 3-option picker + 1M context toggle |
| `ModelInfo` (Dart) | id, displayName, createdAt, family, isLatest | id, displayName, family |
| Bridge agent model | Hardcoded `claude-haiku-4-5-20251001` | Change to `haiku` (nice-to-have) |
| `ChatRequest.model` description | Example shows dated version | Update example to short name |

### What Doesn't Change

- `config.py` / `default_model` field — still stores a string, just simpler ones now
- `orchestrator.py` — still passes model string through to SDK
- Daily module agents — they have their own model picker (separate concern)
- Per-message model override in ChatRequest — still works, just accepts short names too

## Why This Approach

- **YAGNI** — We don't need dated version pinning. The CLI resolves `opus` to the latest automatically.
- **Precedent** — The Daily module already uses `model="haiku"` (short name). This aligns the rest of the codebase.
- **Unblocks 1M context** — The real motivator. Can't use `opus[1m]` today because the regex blocks it.
- **Less infrastructure** — No API calls, no caching, no pagination, no stale-cache fallback. Fewer failure modes.
- **Future-proof** — When Opus 4.7 ships, `opus` just works. No config changes needed.

## Key Decisions

1. **Short names, not full IDs** — Store `opus`, `sonnet`, `haiku` (not `claude-opus-4-6`). CLI resolves to latest.
2. **1M context as a toggle** — Global switch in settings, stored as `[1m]` suffix (e.g., `opus[1m]`). On by default.
3. **Static model list** — Server returns hardcoded list. No Anthropic API dependency for model discovery.
4. **Delete models_api.py** — No tests to clean up. Clean removal.

## Open Questions

1. **Should 1M just be the default with no toggle?** Both Opus and Sonnet support it now. Could argue it should always be on. Decided: expose a toggle but default it to ON.
2. **Migration** — Users with existing `claude-opus-4-6` in config need a one-time migration to `opus`. Server startup could handle this.
3. **Daily agent model picker** — Should it also use short names? Separate concern but worth aligning later.
