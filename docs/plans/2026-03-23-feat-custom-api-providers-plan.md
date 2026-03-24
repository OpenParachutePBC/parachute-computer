---
title: "Custom API providers — bring your own backend"
type: feat
date: 2026-03-23
issue: 335
---

# Custom API Providers — Bring Your Own Backend

Let users switch Parachute's AI backend between Anthropic (default) and any Anthropic-compatible API endpoint. Enables cost flexibility (e.g., using Kimi K2.5 via Moonshot when Claude usage is low) and provider choice.

## Problem Statement

Parachute currently hardcodes Anthropic as the only AI backend. The Claude Code CLI already supports custom endpoints via `ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY` env vars, and the Agent SDK inherits this through subprocess env. We just need a config/UI layer to let users manage and switch providers.

## Acceptance Criteria

- [x] Users can add named API providers with base_url and api_key via the API
- [x] Users can switch the active provider; all new sessions route through it
- [x] Active provider's env vars are injected into the SDK subprocess
- [x] When using a custom provider, the OAuth token is not sent (mutually exclusive auth)
- [x] Each provider config can include a default_model override
- [x] Provider API keys never appear in API responses or logs
- [x] App settings screen has a provider picker section
- [x] Switching back to "Anthropic (default)" restores normal OAuth token behavior

## Proposed Solution

### Phase 1: Server — Config + Injection (~80 lines)

**`config.py`** — Add two fields to `Settings`:

```python
# Which provider is active (None = Anthropic default via OAuth token)
api_provider: Optional[str] = Field(
    default=None,
    description="Active API provider name. None = Anthropic default.",
)

# Named provider configs
api_providers: dict[str, dict] = Field(
    default_factory=dict,
    description="Named API provider configs: {name: {base_url, api_key, default_model?, label?}}",
)
```

Add `"api_provider"` and `"api_providers"` to `CONFIG_KEYS` set.

Config YAML shape:

```yaml
api_provider: moonshot          # active provider (null = Anthropic default)
api_providers:
  moonshot:
    label: "Kimi K2.5 (Moonshot)"
    base_url: "https://api.moonshot.ai/anthropic"
    api_key: "sk-..."
    default_model: "kimi-k2.5"  # optional: override model when this provider is active
  custom:
    label: "My Proxy"
    base_url: "https://proxy.example.com"
    api_key: "..."
```

**`claude_sdk.py`** — Inject provider env vars in the `sdk_env` block (~line 249-255):

```python
# After existing env setup
# Provider override: inject ANTHROPIC_BASE_URL + ANTHROPIC_API_KEY
# when a non-default provider is active.
if provider_base_url:
    sdk_env["ANTHROPIC_BASE_URL"] = provider_base_url
    sdk_env["ANTHROPIC_API_KEY"] = provider_api_key
    # Don't send OAuth token to third-party endpoints
    sdk_env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
```

Add `provider_base_url` and `provider_api_key` as optional params to `query_streaming()`.

**`orchestrator.py`** — Resolve provider config before calling `query_streaming()` (~line 1091):

```python
# Resolve active provider
provider_base_url = None
provider_api_key = None
provider_model = None
if self.settings.api_provider:
    provider_cfg = self.settings.api_providers.get(self.settings.api_provider)
    if provider_cfg:
        provider_base_url = provider_cfg["base_url"]
        provider_api_key = provider_cfg["api_key"]
        provider_model = provider_cfg.get("default_model")

# Model precedence: per-request > provider default > server default
effective_model = model or provider_model or self.settings.default_model
```

### Phase 2: Server — API Endpoints (~80 lines)

New file: **`parachute/api/providers.py`**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/providers` | GET | List providers + active. Keys redacted (last 4 chars only). |
| `/api/providers` | POST | Add a new provider. Validates base_url is a URL. |
| `/api/providers/{name}` | PUT | Update a provider config. |
| `/api/providers/{name}` | DELETE | Remove a provider. Clears active if it was this one. |
| `/api/providers/active` | PUT | Switch active provider. Body: `{"provider": "moonshot"}` or `{"provider": null}` for default. |

All endpoints use `save_yaml_config_atomic()` for persistence (existing pattern). Mounted on the main router in `server.py`.

**Security**: API key values are never returned in GET responses — only `key_hint: "...k-1234"` (last 4 chars). The app sends provider names, never keys directly.

### Phase 3: App — Provider Picker UI

**New widget**: `app/lib/features/settings/widgets/provider_section.dart`

Shows in settings when server is available (same pattern as model picker):

1. **Provider list** — cards showing label, base_url, active indicator
2. **Add provider** — dialog with fields: label, base_url, api_key, default_model (optional)
3. **Switch active** — tap a provider card to make it active
4. **Edit/delete** — long-press or trailing icon

**State management**: New Riverpod provider that GETs `/api/providers` and exposes:
- `providers` list
- `activeProvider` name (nullable)
- `setActive(name)`, `addProvider(...)`, `removeProvider(name)` methods

**Model picker interaction**: When a provider has `default_model`, the model picker should show that as the current model. The model picker continues to work — it just sends the model name to whatever backend is active.

## Technical Considerations

### Auth is mutually exclusive

When using a custom provider: `ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY` are set, `CLAUDE_CODE_OAUTH_TOKEN` is cleared. When using Anthropic default: only `CLAUDE_CODE_OAUTH_TOKEN` is set, no base URL override. This is handled in `claude_sdk.py`.

### Model names across providers

Different providers support different model identifiers. Moonshot uses `kimi-k2.5`, Anthropic uses `opus`/`sonnet`/`haiku`. The `default_model` per-provider handles this — switching providers also switches to the right model. The per-request model override in `ChatRequest.model` still works and takes highest precedence.

### Relationship to #293 (Simplify Model Selection)

These are complementary. #293 simplifies the Anthropic model picker to Opus/Sonnet/Haiku. This PR adds provider switching underneath. When on Anthropic, the simplified picker works. When on a custom provider, the model is either set by provider config or by the user typing a model name.

Implementation order doesn't matter — they touch different parts of the stack. Provider switching touches config/SDK/API. Model simplification touches API/app UI.

### Sandbox path

Sandboxed sessions (`sandbox.py`) pass model via `PARACHUTE_MODEL` env var to the Docker entrypoint. Provider env vars would need to be passed through similarly. **Defer this** — sandboxed sessions should use the default provider initially. Add a `PARACHUTE_PROVIDER_BASE_URL` / `PARACHUTE_PROVIDER_API_KEY` env injection to sandbox later if needed.

### Settings reload

`config.py` has a `reload_settings()` function. Switching providers via the API endpoint should call this so the orchestrator picks up the change without server restart. The existing `save_yaml_config_atomic` + `reload_settings` pattern handles this.

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `computer/parachute/config.py` | Modify | Add `api_provider` + `api_providers` fields, add to `CONFIG_KEYS` |
| `computer/parachute/core/claude_sdk.py` | Modify | Add `provider_base_url`/`provider_api_key` params, inject env vars |
| `computer/parachute/core/orchestrator.py` | Modify | Resolve provider config, compute effective model |
| `computer/parachute/api/providers.py` | Create | CRUD endpoints for provider management |
| `computer/parachute/server.py` | Modify | Mount providers router |
| `app/lib/features/settings/widgets/provider_section.dart` | Create | Provider picker UI |
| `app/lib/core/providers/provider_providers.dart` | Create | Riverpod state for providers |
| `app/lib/core/services/api_service.dart` | Modify | Add provider API calls |
| `app/lib/features/settings/screens/settings_screen.dart` | Modify | Add provider section |

## Out of Scope

- Per-session provider switching (could add `provider` to `ChatRequest` later)
- Bedrock/Vertex special auth flows (different env var pattern — `CLAUDE_CODE_USE_BEDROCK=1`)
- Usage tracking / cost comparison across providers
- Provider health checking / connectivity test on add
- OpenAI-format providers (Claude CLI requires Anthropic format)

## Dependencies & Risks

- **Low risk**: Server changes are additive — no existing behavior changes when `api_provider` is null
- **Testing**: Need to test with at least one real third-party endpoint (Moonshot) to verify the env var injection works end-to-end
- **API key security**: Keys in config.yaml with 0600 perms. Acceptable for local-first architecture. Never transmitted to app or logged.
