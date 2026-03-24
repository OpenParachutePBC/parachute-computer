---
title: "Custom API providers — bring your own backend"
date: 2026-03-23
issue: 335
---

# Custom API Providers — Bring Your Own Backend

## The Idea

Let users switch Parachute's AI backend between Anthropic (default), third-party Anthropic-compatible providers (Moonshot/Kimi, Synthetic.new, etc.), or any custom endpoint that speaks the Anthropic Messages API format. Primary motivation: cost flexibility and usage management — use a cheaper provider when Claude subscription usage is running low.

## How Claude Code Does It

The Claude Code CLI already supports this via environment variables:

```bash
ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic
ANTHROPIC_API_KEY=sk-...
```

The endpoint **must speak the Anthropic Messages API format** — not OpenAI. The CLI resolves model short names (`opus`, `sonnet`, `haiku`) against whatever endpoint it's pointed at, so the model picker still works.

The Claude Agent SDK inherits this because it spawns the CLI as a subprocess. Parachute already builds a custom `sdk_env` dict in `claude_sdk.py` (line ~249), so the injection point is clean.

## What Changes

### Server (`computer/`)

**config.py** — New settings:

```python
# Active provider name (matches a key in api_providers dict)
api_provider: Optional[str] = Field(
    default=None,
    description="Active API provider. None = Anthropic default (OAuth token).",
)

# Provider configurations
api_providers: dict[str, dict] = Field(
    default_factory=dict,
    description="Named API provider configs. Each has base_url and api_key.",
)
```

Config YAML example:

```yaml
api_provider: moonshot
api_providers:
  moonshot:
    name: Kimi K2.5 (Moonshot)
    base_url: https://api.moonshot.ai/anthropic
    api_key: sk-...
  synthetic:
    name: Synthetic
    base_url: https://api.synthetic.new/anthropic
    api_key: ...
  custom:
    name: My Endpoint
    base_url: https://my-proxy.example.com
    api_key: ...
```

**claude_sdk.py** — Inject provider env vars into `sdk_env`:

```python
# After existing env setup (~line 255)
if provider_config:
    sdk_env["ANTHROPIC_BASE_URL"] = provider_config["base_url"]
    sdk_env["ANTHROPIC_API_KEY"] = provider_config["api_key"]
    # Clear OAuth token — we're using API key auth to a different endpoint
    sdk_env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
```

**New API endpoints:**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/providers` | GET | List configured providers + which is active |
| `/api/providers` | PUT | Add/update a provider config |
| `/api/providers/{name}` | DELETE | Remove a provider |
| `/api/providers/active` | PUT | Switch active provider |

### App (`app/`)

- Settings screen gets a "Provider" section
- List saved providers, add/edit/remove
- Active provider indicator in chat (subtle — maybe the model chip shows provider name)
- Per-chat override? (stretch goal — lets you pin a conversation to a provider)

## Relationship to #293 (Simplify Model Selection)

The model picker (#293) simplifies to Opus/Sonnet/Haiku short names. This works well with custom providers because the Claude CLI sends the short name to whatever endpoint it's pointed at. The provider resolves the model name on their end.

One consideration: when using a non-Anthropic provider, the model list might differ. Kimi K2.5 has its own model identifier (`kimi-k2.5`). Options:

1. **Simple**: Let users type/select a model name per provider config
2. **Simpler**: Just pass whatever model name is selected — if the provider doesn't support it, they'll get a clear error
3. **Later**: Provider config includes an optional `models` list for the picker to show

Start with option 2. The provider either handles the model name or returns an error.

## Security Considerations

- API keys stored in `~/.parachute/config.yaml` with 0600 permissions (already the case for the file)
- Keys never sent to the app — the app sends provider *names*, the server resolves to credentials
- Never log API keys (already have patterns for this with OAuth tokens)
- Provider config changes require server-side auth (existing `auth_mode` applies)

## What Doesn't Change

- `orchestrator.py` — still passes model through, doesn't care about provider
- Session management — provider is a server-level or per-request config, not stored per-session
- Daily module agents — they use the same SDK path, so they'd automatically use the active provider
- Trust levels — orthogonal concern, works the same regardless of provider

## Open Questions

- **Per-session vs global switching?** Start global (server setting), add per-request later if needed.
- **Provider health checking?** Could ping the provider's endpoint on add/switch to verify credentials. Nice-to-have.
- **Pricing/usage tracking?** Different providers have different pricing. Out of scope for now — just enable the switching. Usage tracking could come later.
- **What about providers that need OpenAI format?** Out of scope. Claude CLI requires Anthropic format. If someone wants an OpenAI-format provider, they'd need a proxy that translates. Not our problem.

## Known Anthropic-Compatible Providers

| Provider | Base URL | Notes |
|----------|----------|-------|
| Anthropic (default) | (uses OAuth token) | Default, no config needed |
| Moonshot (Kimi K2.5) | `https://api.moonshot.ai/anthropic` | 256K context, MoE 1T params |
| AWS Bedrock | (uses `CLAUDE_CODE_USE_BEDROCK=1`) | Different auth flow — stretch goal |
| Google Vertex AI | (uses `CLAUDE_CODE_USE_VERTEX=1`) | Different auth flow — stretch goal |
| Synthetic.new | TBD | Anthropic-compatible endpoint |

## Implementation Complexity

This is pretty lightweight:

- **Config**: ~30 lines in `config.py` for the new fields
- **SDK injection**: ~10 lines in `claude_sdk.py`
- **API endpoints**: ~80 lines for CRUD on providers
- **App UI**: Settings screen addition, moderate Flutter work

The hard part isn't implementation — it's testing against multiple providers and handling their quirks gracefully.
