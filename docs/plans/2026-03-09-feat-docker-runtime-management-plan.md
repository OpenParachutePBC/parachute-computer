---
title: "Docker Runtime Management from the App"
type: feat
date: 2026-03-09
issue: 209
---

# Docker Runtime Management from the App

Parachute Computer manages Docker as a dependency — detect what's installed, start it when needed, show progress, and never silently degrade the sandbox.

## Problem Statement

When Docker isn't running and a user sends a sandboxed chat message, the orchestrator emits a `WarningEvent` and silently falls back to direct (trusted) execution. The user sees a warning banner but can't do anything about it. Worse, mixing sandboxed and unsandboxed messages in the same session creates correctness issues: different file access, different working directories, different security boundaries.

The sandbox is the security commitment, not a suggestion. The system should either run sandboxed or tell you how to fix it — never quietly downgrade.

## Proposed Solution

1. **Runtime detection** — Discover which Docker provider is installed (OrbStack, Colima, Docker Desktop, Rancher Desktop)
2. **Supervisor Docker endpoints** — Start/stop/status following the existing server lifecycle pattern
3. **Remove silent fallback** — Sandboxed sessions block with an actionable error, not a warning
4. **App chat UI** — Block send when Docker is down, show "Start Docker" action, auto-send on readiness
5. **App settings UI** — "Start Docker" button, detected runtime display
6. **Auto-start on server boot** — Opt-in config for fully managed Docker lifecycle

## Design Decisions

**Block, don't degrade.** Sandboxed sessions return a blocking `TypedErrorEvent` (not a `WarningEvent`) when Docker is down. The app handles recovery — start Docker, queue the message, send on readiness. No "continue without sandbox" escape hatch.

**Supervisor owns Docker lifecycle.** The supervisor already manages the main server (start/stop/restart on port 3334). Docker management follows the same pattern — lightweight, defensive, no module loading. The main server never starts Docker itself.

**Runtime detection is a registry.** Multiple Docker runtimes exist on macOS. Rather than hardcoding OrbStack, we detect what's installed and support starting any of them, with a configurable preference order.

**No runtime installation.** Out of scope. Users install their own Docker runtime. If none is detected, we link to OrbStack (lightest option).

## Implementation Phases

### Phase 1: Runtime Detection + Supervisor Endpoints

**New file:** `computer/parachute/docker_runtime.py`

Detect installed Docker runtimes and expose start/stop commands:

| Runtime | Detection | Start Command | Typical Startup |
|---------|-----------|---------------|-----------------|
| OrbStack | `shutil.which("orb")` | `orb start` | ~2s |
| Colima | `shutil.which("colima")` | `colima start` | ~10-20s |
| Docker Desktop | app bundle check | `open -a Docker` | ~15-30s |
| Rancher Desktop | app bundle check | `open -a "Rancher Desktop"` | ~15-30s |

Default preference: OrbStack > Colima > Docker Desktop > Rancher Desktop. Overridable via `docker_runtime` in config.yaml.

```python
class DockerRuntime(BaseModel):
    name: str           # "orbstack", "colima", "docker_desktop", "rancher_desktop"
    display_name: str   # "OrbStack", "Colima", etc.
    available: bool     # Binary/app exists on disk
    running: bool       # Daemon is responding to `docker info`

class DockerRuntimeRegistry:
    async def detect_all(self) -> list[DockerRuntime]
    async def detect_preferred(self, config_override: str | None = None) -> DockerRuntime | None
    async def start(self, runtime: DockerRuntime) -> bool
    async def stop(self, runtime: DockerRuntime) -> bool
    async def poll_ready(self, timeout: float = 45.0, interval: float = 1.0) -> bool
```

**Supervisor endpoints** (in `computer/parachute/supervisor.py`):

```
GET  /supervisor/docker/status  →  DockerStatusResponse
POST /supervisor/docker/start   →  ServerActionResponse (reuse existing model)
POST /supervisor/docker/stop    →  ServerActionResponse
```

`DockerStatusResponse`:
```python
class DockerStatusResponse(BaseModel):
    daemon_running: bool            # Can docker commands execute?
    runtime: str | None             # "orbstack", "colima", etc.
    runtime_display: str | None     # "OrbStack", "Colima", etc.
    detected_runtimes: list[str]    # All installed runtimes
    image_exists: bool              # Sandbox image built?
    auto_start_enabled: bool        # Config setting
```

Follow existing supervisor patterns:
- Pydantic models for request/response
- `asyncio.to_thread()` for blocking subprocess calls
- Defensive error handling (Docker commands can hang — enforce timeouts)
- TTL cache on status (5s, same as server health cache)

**Config addition** (`config.yaml`):
```yaml
docker_runtime: null       # Override auto-detection (e.g. "orbstack")
docker_auto_start: false   # Start Docker automatically on server boot
```

**Files to create:**
- `computer/parachute/docker_runtime.py` — Runtime detection registry

**Files to modify:**
- `computer/parachute/supervisor.py` — Add 3 Docker endpoints
- `computer/parachute/config.py` — Add `docker_runtime`, `docker_auto_start` to known keys

**Tests:**
- `computer/tests/unit/test_docker_runtime.py` — Runtime detection with mocked `shutil.which`, mocked subprocess

### Phase 2: Remove Silent Fallback from Orchestrator

Replace the `WarningEvent` fallback path (orchestrator.py lines 593-604) with a blocking `TypedErrorEvent` that tells the app "Docker is required and unavailable."

**New error code:** `DOCKER_UNAVAILABLE` in `ErrorCode` enum (typed_errors.py). Distinct from generic `SERVICE_UNAVAILABLE` so the app can match on it and offer the "Start Docker" action.

**Orchestrator change** (orchestrator.py ~line 593):
```python
# Before: WarningEvent + fall back to direct
# After: TypedErrorEvent — app must handle recovery
else:
    logger.warning(f"Docker unavailable for session {session.id[:8]}")
    yield TypedErrorEvent(
        code=ErrorCode.DOCKER_UNAVAILABLE,
        title="Docker Required",
        message="This session requires Docker for sandboxed execution.",
        actions=[RecoveryAction(
            label="Start Docker",
            action="start_docker",
        )],
        can_retry=True,
        session_id=session.id if session.id != "pending" else None,
    ).model_dump(by_alias=True)
```

Bot sessions keep the existing hard-fail `ErrorEvent` — no change needed there.

**Files to modify:**
- `computer/parachute/lib/typed_errors.py` — Add `DOCKER_UNAVAILABLE` to `ErrorCode`
- `computer/parachute/core/orchestrator.py` — Replace `WarningEvent` fallback with `TypedErrorEvent`
- `computer/parachute/models/events.py` — Add `RecoveryAction.action` field if not present (for semantic action identifiers)

**Tests:**
- Update `computer/tests/unit/test_orchestrator_phases.py` — Docker-unavailable test now expects `TypedErrorEvent` instead of `WarningEvent`

### Phase 3: App Supervisor Client + Docker Provider

Extend the existing Dart supervisor service and create a Docker status provider.

**Supervisor service additions** (`app/lib/core/services/supervisor_service.dart`):
```dart
Future<DockerStatus> getDockerStatus();
Future<void> startDocker();
Future<void> stopDocker();
```

**New model** (`app/lib/core/models/supervisor_models.dart`):
```dart
class DockerStatus {
  final bool daemonRunning;
  final String? runtime;
  final String? runtimeDisplay;
  final List<String> detectedRuntimes;
  final bool imageExists;
  final bool autoStartEnabled;
}
```

**New Riverpod provider** (`app/lib/core/providers/supervisor_providers.dart`):
```dart
@riverpod
class DockerStatusNotifier extends _$DockerStatusNotifier {
  // Polls supervisor every 5s while Docker is starting
  // Polls every 30s in steady state
  // Exposes: status, startDocker(), refresh()
}
```

**Files to modify:**
- `app/lib/core/services/supervisor_service.dart` — Add 3 Docker methods
- `app/lib/core/models/supervisor_models.dart` — Add `DockerStatus` model
- `app/lib/core/providers/supervisor_providers.dart` — Add `DockerStatusNotifier`

### Phase 4: Chat UI — Block Send + Start Docker Action

When Docker is down andthe session is sandboxed, the chat input blocks and shows an actionable banner.

**Chat input gating** (`app/lib/features/chat/widgets/chat_input.dart`):
- New prop: `dockerRequired` (bool) + `onStartDocker` callback
- When `dockerRequired && !dockerRunning`: disable send button, show inline "Docker needed" state

**Docker banner** (`app/lib/features/chat/widgets/docker_status_banner.dart` — new file):
- Follows `ConnectionStatusBanner` pattern (same visual hierarchy)
- States:
  1. **Docker not running**: Yellow banner — "Docker is needed for this chat. [Start Docker]"
  2. **Docker starting**: Yellow banner — "Starting Docker… (elapsed time)" with spinner
  3. **No runtime detected**: Gray banner — "No Docker runtime installed. [Get OrbStack →]"

**Message queuing**: When user hits send but Docker is starting, queue the message locally. On Docker ready (detected via `DockerStatusNotifier`), auto-send. Show a subtle "Message queued — will send when Docker is ready" indicator.

**TypedError handling**: When the orchestrator returns `DOCKER_UNAVAILABLE`, the chat provider recognizes it and triggers the Docker banner + start flow rather than showing a generic error.

**Files to create:**
- `app/lib/features/chat/widgets/docker_status_banner.dart`

**Files to modify:**
- `app/lib/features/chat/widgets/chat_input.dart` — Docker gating props
- `app/lib/features/chat/widgets/chat_screen.dart` — Wire Docker status to input + banner
- `app/lib/features/chat/providers/chat_message_providers.dart` — Handle `DOCKER_UNAVAILABLE` typed error
- `app/lib/features/chat/models/typed_error.dart` — Add `dockerUnavailable` to Dart `ErrorCode` enum

### Phase 5: Settings UI + Auto-Start

**Settings trust levels section** (`app/lib/features/settings/widgets/trust_levels_section.dart`):
- Replace dead-end "Docker not available" gray dot with:
  - Detected runtime name (e.g., "OrbStack — not running")
  - "Start Docker" button (follows existing "Build Image" button pattern)
  - Starting state with spinner
- Add auto-start toggle: "Start Docker automatically" checkbox (writes `docker_auto_start` to config via supervisor)

**Server-side auto-start** (`computer/parachute/supervisor.py`):
- On supervisor startup, if `docker_auto_start: true` and Docker not running, start the preferred runtime
- Log the auto-start attempt and result
- Don't block supervisor startup on Docker readiness — fire and forget, poll in background

**Files to modify:**
- `app/lib/features/settings/widgets/trust_levels_section.dart` — Start button, runtime display, auto-start toggle
- `computer/parachute/supervisor.py` — Auto-start on startup event

## Acceptance Criteria

- [x] `GET /supervisor/docker/status` returns runtime info, daemon state, and image status
- [x] `POST /supervisor/docker/start` starts the detected runtime and polls until ready (or timeout)
- [x] Orchestrator emits `TypedErrorEvent` with `DOCKER_UNAVAILABLE` (not `WarningEvent`) for local sandboxed sessions
- [x] Bot sessions still hard-fail with `ErrorEvent` (no change)
- [x] Chat input is disabled with actionable banner when Docker is required but down
- [x] "Start Docker" button in chat banner starts Docker via supervisor and shows progress
- [ ] Message queued during Docker startup auto-sends on readiness
- [x] Settings shows detected runtime name and "Start Docker" button
- [ ] Auto-start toggle in settings writes `docker_auto_start` config
- [x] When `docker_auto_start: true`, supervisor starts Docker on boot
- [x] Readiness polling shows elapsed time (not an indeterminate spinner)
- [x] If no Docker runtime is detected, shows "No Docker runtime installed" with link to OrbStack
- [x] All existing tests pass; new unit tests for runtime detection and orchestrator change

## Technical Considerations

**Timeout strategy**: Docker Desktop can take 30+ seconds to start. Use 45s timeout with elapsed time display. OrbStack is ~2s but we use the same timeout — the elapsed timer makes fast startups feel fine and slow ones feel transparent.

**Cache invalidation**: When the supervisor starts Docker, it should immediately invalidate `DockerSandbox._docker_available` cache (currently 60s TTL). Either expose a `reset_cache()` method or reduce TTL to 5s to match the health cache.

**Readiness check**: `poll_ready()` in `DockerRuntimeRegistry` runs `docker info` on an interval until it succeeds. This is the same check `DockerSandbox.is_available()` uses. May want to share the logic.

**macOS-only for now**: Runtime detection (app bundles, `orb`, `colima`) is macOS-specific. Linux users typically have Docker daemon via systemd — that's a different management pattern. Scope to macOS in Phase 1; Linux can follow.

**Process lifecycle**: `open -a Docker` and `orb start` are non-blocking — they return immediately while the daemon boots. That's why we need `poll_ready()`. Colima's `colima start` blocks until ready, but we still poll for consistency.

## Dependencies & Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Docker command hangs (no timeout) | Medium | Enforce subprocess timeouts on all Docker commands (5s for checks, 45s for start) |
| Runtime detection misidentifies provider | Low | Test with real installs; detection is simple PATH/bundle checks |
| Message queuing loses messages on app restart | Low | Queue is in-memory only for the startup window; user can re-send |
| Auto-start interferes with user's Docker setup | Low | Off by default; explicit opt-in via settings toggle |

## Out of Scope

- Installing Docker runtimes (users install their own)
- Linux Docker service management (different pattern — systemd)
- Windows support
- Runtime preference picker UI (use detection order for now; add picker later)
- Pausing/resuming containers during Docker restart

## References

- Brainstorm: `docs/brainstorms/2026-03-09-docker-runtime-management-brainstorm.md`
- Existing sandbox code: `computer/parachute/core/sandbox.py`
- Supervisor: `computer/parachute/supervisor.py`
- App supervisor client: `app/lib/core/services/supervisor_service.dart`
- App Docker status UI: `app/lib/features/settings/widgets/trust_levels_section.dart`
- Chat input: `app/lib/features/chat/widgets/chat_input.dart`
- Connection banner pattern: `app/lib/features/chat/widgets/connection_status_banner.dart`
