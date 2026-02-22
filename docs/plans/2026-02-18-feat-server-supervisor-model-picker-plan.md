---
title: "feat: Server Supervisor Service & App Model Picker"
type: feat
date: 2026-02-18
issue: 68
modules: computer, app
---

# Server Supervisor Service & App Model Picker

## Overview

Add a lightweight supervisor service (port 3334) that manages the main Parachute Computer server, expose model selection via the Anthropic Models API, and integrate server management + model picking into the app's Settings page.

Three deliverables:
1. **Supervisor service** — independent FastAPI process for server lifecycle management
2. **Model picker backend** — supervisor queries Anthropic `/v1/models`, exposes filtered list
3. **App Settings UI** — enhanced server section with status, controls, model dropdown, and log viewer

## Problem Statement

Two pain points from the brainstorm (#68):

1. **Model configuration is brittle.** `default_model` lives in config.yaml/.env — every new Claude release requires manual editing and restart. No visibility from the app, no way to change it remotely.

2. **Server management requires physical access.** If the main server crashes, its API is unreachable. No way to diagnose, restart, or view logs from the app.

## Proposed Solution

A separate supervisor process that:
- Runs independently of the main server (survives crashes)
- Exposes HTTP endpoints for server lifecycle, config, and log streaming
- Queries Anthropic's Models API for available models
- Writes config changes and triggers restarts

The app's Settings page gains:
- Live server status with restart/stop controls
- Dynamic model dropdown populated from Anthropic's model catalog
- Expandable log viewer with SSE streaming

## Technical Approach

### Architecture

```
┌─────────────────────────────────────┐
│              App (Flutter)          │
│  Settings → SupervisorService       │
│     │                               │
│     ├─ GET  /supervisor/status      │
│     ├─ POST /supervisor/server/restart
│     ├─ GET  /supervisor/models      │
│     ├─ PUT  /supervisor/config      │
│     └─ GET  /supervisor/logs (SSE)  │
└──────────────┬──────────────────────┘
               │ HTTP :3334
┌──────────────▼──────────────────────┐
│       Supervisor (FastAPI)          │
│  io.openparachute.supervisor        │
│                                     │
│  • Process management (start/stop)  │
│  • Config read/write (config.yaml)  │
│  • Log file tailing (SSE)           │
│  • Anthropic Models API proxy       │
└──────────────┬──────────────────────┘
               │ subprocess / signal
┌──────────────▼──────────────────────┐
│     Main Server (FastAPI :3333)     │
│  io.openparachute.server            │
│                                     │
│  • Orchestrator, modules, chat      │
│  • Reads config.yaml on startup     │
└─────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Supervisor port | 3334 | Adjacent to main (3333), easy to discover |
| Auth model | Localhost-only (no API key) | Local-first architecture; supervisor manages the machine it runs on |
| Daemon label | `io.openparachute.supervisor` | Parallel to existing `io.openparachute.server` |
| Model filtering | Latest per family + dated versions | Show clean list by default, allow "show all" |
| Config changes | Write config.yaml + restart | No hot-reload complexity; restart is fast (~2s) |
| Supervisor auto-start | Both plists installed by `install.sh` | Supervisor should always be available |
| Bundled server coexistence | Supervisor is additive | Existing `BareMetalServerService` continues to work; supervisor is an enhancement |

### Implementation Phases

---

#### Phase 1: Supervisor Service (Python)

**Goal:** Standalone FastAPI process that can start/stop/restart the main server and stream logs.

##### 1.1 Supervisor FastAPI App

**New file: `computer/parachute/supervisor.py`**

```python
# Lightweight FastAPI app — NO module loading, no Claude SDK, no orchestrator
# Shares venv with main server, minimal deps (fastapi, uvicorn, httpx, pyyaml)

app = FastAPI(title="Parachute Supervisor", version=__version__)

# Endpoints:
# GET  /supervisor/status       → supervisor + main server health
# POST /supervisor/server/start → start main server
# POST /supervisor/server/stop  → stop main server (SIGTERM → SIGKILL)
# POST /supervisor/server/restart → stop + start
# GET  /supervisor/logs         → SSE stream of server log file
# GET  /supervisor/config       → current config.yaml contents
# PUT  /supervisor/config       → update config values, optionally restart
# GET  /supervisor/models       → filtered Anthropic model list
```

Key implementation details:
- Server process managed via `subprocess.Popen` or by controlling the existing daemon
- Health check: HTTP GET to `http://localhost:3333/api/health` with 2s timeout
- Log streaming: tail the daemon log file (`~/Library/Logs/Parachute/server.log` on macOS) via SSE
- Config: read/write `vault/.parachute/config.yaml` using existing `save_yaml_config()` from `parachute.config`

##### 1.2 Supervisor Daemon Management

**Modified file: `computer/parachute/daemon.py`**

Add supervisor-specific daemon support:
- New label: `SUPERVISOR_LAUNCHD_LABEL = "io.openparachute.supervisor"`
- New plist template for supervisor (port 3334, different log file)
- `SupervisorDaemonManager` or parameterize existing `DaemonManager` to handle both server and supervisor
- Supervisor plist: `RunAtLoad: True`, `KeepAlive: True` (always running)

**Modified file: `computer/parachute/cli.py`**

Add `parachute supervisor` subcommand group:
```
parachute supervisor start     # Start supervisor daemon
parachute supervisor stop      # Stop supervisor daemon
parachute supervisor status    # Check supervisor status
parachute supervisor install   # Install supervisor daemon (launchd/systemd)
parachute supervisor uninstall # Remove supervisor daemon
```

##### 1.3 Install Script Updates

**Modified file: `computer/install.sh`**

- Install supervisor daemon alongside server daemon
- Both share the same venv (no additional `pip install`)
- Supervisor plist points to `python -m parachute.supervisor`

##### 1.4 Supervisor Entry Point

**New file: `computer/parachute/supervisor_main.py`** (or `__main__` pattern)

```python
def main():
    uvicorn.run(
        "parachute.supervisor:app",
        host="127.0.0.1",  # Localhost only — no remote access
        port=3334,
        log_level="info",
    )
```

Add to `pyproject.toml`:
```toml
[project.scripts]
parachute-supervisor = "parachute.supervisor:main"
```

**Acceptance Criteria — Phase 1:**
- [ ] `parachute supervisor install` creates launchd plist / systemd unit
- [ ] `parachute supervisor start/stop/status` work correctly
- [ ] `GET /supervisor/status` returns supervisor uptime + main server health
- [ ] `POST /supervisor/server/restart` restarts main server within 5s
- [ ] `POST /supervisor/server/stop` stops main server cleanly (SIGTERM)
- [ ] `POST /supervisor/server/start` starts main server if stopped
- [ ] `GET /supervisor/logs` streams log lines via SSE
- [ ] `GET /supervisor/config` returns current config.yaml
- [ ] `PUT /supervisor/config` writes config.yaml, returns updated values
- [ ] Supervisor survives main server crash (independent process)
- [ ] `install.sh` installs both daemon plists

---

#### Phase 2: Model Picker Backend

**Goal:** Supervisor queries Anthropic Models API and exposes a curated model list.

##### 2.1 Anthropic Models API Integration

**New file: `computer/parachute/models_api.py`**

```python
async def fetch_available_models(api_key: str) -> list[ModelInfo]:
    """Query Anthropic /v1/models and return filtered model list."""
    # GET https://api.anthropic.com/v1/models
    # Headers: x-api-key, anthropic-version: 2023-06-01
    # Paginate using after_id if has_more is true
    # Filter and sort results
    pass

@dataclass
class ModelInfo:
    id: str              # e.g. "claude-sonnet-4-5-20250929"
    display_name: str    # e.g. "Claude 4.5 Sonnet"
    created_at: str      # ISO 8601
    family: str          # Derived: "opus", "sonnet", "haiku"
    is_latest: bool      # Whether this is the latest in its family
```

**Filtering strategy:**
- Fetch all models (paginate with limit=1000)
- Group by family (extract from model ID: `claude-{family}-*`)
- Mark latest per family based on `created_at`
- Default view: show latest per family (3-5 models)
- "Show all" view: show all Claude models with dated versions

**Caching:**
- Cache model list for 1 hour (models don't change frequently)
- Cache invalidated on manual refresh or supervisor restart
- If Anthropic API is unreachable, return cached list with staleness indicator

##### 2.2 Supervisor Models Endpoint

**In `computer/parachute/supervisor.py`:**

```python
@app.get("/supervisor/models")
async def list_models(show_all: bool = False):
    """Return available Claude models from Anthropic API."""
    # Returns: {models: [...], current_model: str, cached_at: str}
    pass
```

- `show_all=false` (default): returns latest per family
- `show_all=true`: returns all Claude models
- Includes `current_model` from config.yaml for the app to highlight selection
- API key read from config.yaml (`claude_code_oauth_token`) or env var

##### 2.3 Config Update for Model Selection

**In `computer/parachute/supervisor.py`:**

```python
@app.put("/supervisor/config")
async def update_config(body: ConfigUpdate):
    """Update config values and optionally restart server."""
    # body.values: dict of config key → value
    # body.restart: bool (default true for model changes)
    # Writes to vault/.parachute/config.yaml
    # If restart requested, triggers server restart
    pass
```

The `default_model` key is already in `CONFIG_KEYS` and `Settings.default_model` — no schema changes needed on the main server side.

**Acceptance Criteria — Phase 2:**
- [ ] `GET /supervisor/models` returns filtered model list from Anthropic API
- [ ] Models grouped by family with `is_latest` flag
- [ ] `show_all=true` parameter returns full model catalog
- [ ] Model list cached for 1 hour, with staleness indicator
- [ ] Graceful degradation when Anthropic API unreachable (return cache or error)
- [ ] `PUT /supervisor/config` with `default_model` writes config and restarts server
- [ ] Current active model included in models response

---

#### Phase 3: App Settings UI

**Goal:** Enhanced Settings section with server management, model picker, and log viewer.

##### 3.1 Supervisor Service (Dart)

**New file: `app/lib/core/services/supervisor_service.dart`**

```dart
class SupervisorService {
  final String baseUrl; // http://localhost:3334

  Future<SupervisorStatus> getStatus();
  Future<void> startServer();
  Future<void> stopServer();
  Future<void> restartServer();
  Future<List<ModelInfo>> getModels({bool showAll = false});
  Future<void> updateConfig(Map<String, dynamic> values, {bool restart = true});
  Stream<String> streamLogs(); // SSE stream
}
```

Follow `ComputerService` patterns: singleton, HTTP helpers with error handling.

##### 3.2 Riverpod Providers

**New file: `app/lib/core/providers/supervisor_providers.dart`**

```dart
// Supervisor connection status
final supervisorStatusProvider = StreamProvider<SupervisorStatus>((ref) { ... });

// Available models from supervisor
final availableModelsProvider = FutureProvider<List<ModelInfo>>((ref) { ... });

// Current active model (from supervisor config)
final activeModelProvider = FutureProvider<String?>((ref) { ... });

// Log stream
final serverLogStreamProvider = StreamProvider<String>((ref) { ... });
```

##### 3.3 Enhanced Server Settings Section

**Modified file: `app/lib/features/settings/widgets/parachute_computer_section.dart`**

Extend the existing section with:

1. **Status area** (existing pattern, enhanced):
   - Show supervisor status alongside server status
   - Add uptime display when running
   - Keep existing status badge pattern

2. **Server controls** (enhanced):
   - Keep existing Start/Stop buttons
   - Add Restart button (calls supervisor, not bare-metal script)
   - When supervisor is available, route controls through supervisor API
   - Fallback to existing `BareMetalServerService` when supervisor not running

3. **Model picker**:
   - Replace hardcoded `ClaudeModel` dropdown with dynamic list
   - Show model family grouping (Opus, Sonnet, Haiku)
   - Current selection highlighted
   - "Show all versions" toggle for dated model versions
   - On selection: `PUT /supervisor/config` with `default_model` + auto-restart

4. **Log viewer** (new):
   - Expandable section at bottom
   - Shows last 50 lines by default
   - "Stream live" toggle connects to SSE endpoint
   - Monospace font, auto-scroll to bottom

##### 3.4 Model Selection Section Migration

**Modified file: `app/lib/features/settings/widgets/model_selection_section.dart`**

- When supervisor is available: fetch models from `GET /supervisor/models`
- When supervisor not available: fall back to existing hardcoded `ClaudeModel` enum
- Remove `ClaudeModel` enum dependency when supervisor provides the list
- Keep local `SharedPreferences` as fallback for offline/daily-only mode

**Modified file: `app/lib/core/providers/app_state_provider.dart`**

- Keep `ClaudeModel` enum for offline fallback
- Add `serverModelProvider` that prefers supervisor data over local enum
- `ModelPreferenceNotifier` gains a `syncToServer()` method

##### 3.5 Settings Screen Integration

**Modified file: `app/lib/features/settings/screens/settings_screen.dart`**

- No new sections needed — enhance existing `ParachuteComputerSection`
- Model picker moves into the computer section (consolidated view)
- Old standalone `ModelSelectionSection` becomes a thin wrapper or is merged

**Acceptance Criteria — Phase 3:**
- [ ] Supervisor status visible in Settings when supervisor is running
- [ ] Server start/stop/restart work through supervisor API
- [ ] Model dropdown populated from Anthropic API via supervisor
- [ ] Model selection triggers config update + server restart
- [ ] "Show all versions" toggle shows dated model variants
- [ ] Log viewer shows recent lines with live streaming option
- [ ] Graceful fallback when supervisor not available (existing behavior preserved)
- [ ] Existing `BareMetalServerService` flow unchanged when supervisor absent

---

## Alternative Approaches Considered

| Alternative | Why Rejected |
|-------------|-------------|
| Extend launchd only (no HTTP supervisor) | Can't expose logs, config, or models to the app |
| Add endpoints to main server for self-management | Main server can't restart itself; if crashed, unreachable |
| Hardcode model list in app | Requires app update for every new Claude model |
| Hot-reload config without restart | Adds complexity; server restart is fast (~2s) |
| Supervisor on same port as main server | Coupling defeats the purpose — supervisor must be independent |

## Dependencies & Prerequisites

- **Anthropic API key** must be configured (already required for chat)
- **Python venv** shared between supervisor and main server (already the case)
- **launchd/systemd** for daemon management (already used for main server)
- No new Python dependencies — FastAPI, uvicorn, httpx, pyyaml already in venv

## Risk Analysis & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Supervisor itself crashes | Can't manage server remotely | launchd `KeepAlive: True` auto-restarts; supervisor is ultra-lightweight |
| Anthropic API rate limits | Model list unavailable | 1-hour cache; graceful fallback to cached/hardcoded list |
| Port 3334 conflict | Supervisor can't start | Make port configurable via env var `SUPERVISOR_PORT` |
| Config write race condition | Corrupted config.yaml | File locking or atomic write (write to temp, rename) |
| App talks to wrong supervisor | Config mismatch | Supervisor URL derived from server URL (port + 1) |

## File Summary

### New Files

| File | Purpose |
|------|---------|
| `computer/parachute/supervisor.py` | Supervisor FastAPI app with all endpoints |
| `computer/parachute/models_api.py` | Anthropic Models API client with caching and filtering |
| `app/lib/core/services/supervisor_service.dart` | Dart HTTP client for supervisor API |
| `app/lib/core/providers/supervisor_providers.dart` | Riverpod providers for supervisor state |
| `app/lib/core/models/supervisor_models.dart` | Data classes: SupervisorStatus, ModelInfo |

### Modified Files

| File | Changes |
|------|---------|
| `computer/parachute/daemon.py` | Add supervisor daemon label + plist template |
| `computer/parachute/cli.py` | Add `parachute supervisor` subcommand group |
| `computer/install.sh` | Install supervisor daemon alongside server |
| `computer/pyproject.toml` | Add `parachute-supervisor` entry point |
| `app/lib/features/settings/widgets/parachute_computer_section.dart` | Add model picker, log viewer, enhanced controls |
| `app/lib/features/settings/widgets/model_selection_section.dart` | Use supervisor models when available |
| `app/lib/core/providers/app_state_provider.dart` | Add server model provider, keep fallback |
| `app/lib/features/settings/screens/settings_screen.dart` | Consolidate model picker into computer section |

## References

- Brainstorm: `docs/brainstorms/2026-02-18-server-supervisor-model-config-brainstorm.md`
- GitHub Issue: #68
- Anthropic Models API: `GET https://api.anthropic.com/v1/models`
- Existing daemon patterns: `computer/parachute/daemon.py`
- Existing config system: `computer/parachute/config.py`
- Existing server controls: `app/lib/features/settings/widgets/parachute_computer_section.dart`
- Existing model picker: `app/lib/features/settings/widgets/model_selection_section.dart`
- Bare metal service: `app/lib/core/services/bare_metal_server_service.dart`
