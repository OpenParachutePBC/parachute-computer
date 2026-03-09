# Docker Runtime Management from the App

**Status:** Brainstorm
**Priority:** P2
**Labels:** computer, app
**Issue:** #209

---

## What We're Building

Integrated Docker runtime management so the app can detect, start, and monitor Docker — rather than silently falling back to unsandboxed mode when Docker is down.

Today, if Docker isn't running when you send a sandboxed chat message, the orchestrator emits a `WarningEvent` and falls back to direct (trusted) execution. The user sees a warning banner but can't do anything about it from within the app. The sandbox — which should be the default secure experience — just quietly disappears. Worse, mixing sandboxed and unsandboxed messages in the same session creates real problems: different file access, different working directories, different security boundaries. The fallback isn't just a UX issue — it's a correctness issue.

**The goal:** Parachute Computer manages Docker as a dependency, not something the user has to think about separately.

## Why This Approach

Sandbox mode is the intended default for chat. When it silently degrades, users lose the security boundary without taking an explicit action. Making Docker a managed dependency (like the main server already is) keeps the sandbox promise intact and makes the whole system feel like one cohesive thing rather than a bag of parts.

The supervisor already manages the main server lifecycle (start/stop/restart via daemon manager). Docker runtime management follows the exact same pattern — the supervisor knows how to start it, the app knows how to ask.

## Key Decisions

### 1. Multi-runtime support via detection registry

Multiple Docker runtimes exist on macOS. Rather than hardcoding OrbStack, we detect what's installed and support starting any of them:

| Runtime | Detection | Start Command | Notes |
|---------|-----------|---------------|-------|
| OrbStack | `which orb` | `orb start` | Fastest (~2s), lightest (~200MB idle) |
| Docker Desktop | app bundle exists | `open -a Docker` | Heaviest (~2GB idle), slow startup |
| Colima | `which colima` | `colima start` | CLI-only, boots VM (~10-20s) |
| Rancher Desktop | app bundle exists | `open -a "Rancher Desktop"` | Kubernetes-focused |

**Preference order** (when multiple installed): OrbStack > Colima > Docker Desktop > Rancher Desktop. User can override in settings.

### 2. Supervisor endpoints for Docker lifecycle

New supervisor endpoints following the existing `/supervisor/server/*` pattern:

- `GET /supervisor/docker/status` — which runtime is detected, is it running, is the sandbox image built
- `POST /supervisor/docker/start` — start the detected/configured runtime
- `POST /supervisor/docker/stop` — stop the runtime (less common, but symmetric)

The supervisor already runs on port 3334 independently of the main server. Docker management fits naturally here.

### 3. Auto-start on server boot (opt-in)

When the Parachute server starts, if sandbox mode is configured and Docker isn't running, the supervisor can auto-start it. This is opt-in via a config setting (e.g., `docker_auto_start: true`).

This means: open the app → server starts → Docker starts → sandbox ready. One action, everything boots.

### 4. Actionable UI in two places

**Chat screen:** When Docker is down and user tries to send a sandboxed message, **block the send** rather than falling back to direct mode. Show an actionable state: "Docker is needed for this chat. [Start Docker]". Starting Docker shows progress, and once ready, the queued message sends automatically. No "continue without sandbox" escape hatch — mixing sandboxed and unsandboxed messages in the same session creates real problems (different file access, different working directories, different security boundaries). Sandbox is the commitment, not a suggestion.

**Settings screen:** The current gray dot "Docker not available" dead-end becomes a "Start Docker" button (same pattern as the existing "Build Image" button). Shows detected runtime name.

### 5. Remove the silent fallback from the orchestrator

The current orchestrator path (lines ~567-604) checks `is_available()`, and if Docker is down for a non-bot session, emits a `WarningEvent` and runs in trusted mode. This path gets removed. Sandboxed sessions should return a blocking error (new event type or error code) that the app interprets as "Docker required, not available." The app handles it from there — start Docker, queue the message, retry on readiness. Bot sessions already hard-fail, which is correct.

### 6. Readiness polling after start

Docker runtimes take variable time to become ready (OrbStack ~2s, Docker Desktop ~30s). After issuing the start command, the supervisor polls `docker info` on a short interval until it succeeds or times out. The app shows a spinner/progress indicator during this window.

## Scope

**In scope:**
- Runtime detection (which Docker provider is installed)
- Supervisor endpoints for Docker start/stop/status
- Auto-start on server boot (opt-in config)
- Remove orchestrator silent fallback — sandboxed sessions block when Docker is down
- App chat UI: block send + "Start Docker" action + auto-retry on readiness
- Settings UI: start button, detected runtime display
- Readiness polling with progress feedback

**Out of scope (for now):**
- Installing Docker runtimes (users install their own)
- Linux support (systemd Docker service is already auto-managed differently)
- Runtime preference UI in settings (can default to detection order, add picker later)
- Windows support

## Open Questions

1. **Timeout for readiness polling** — 30s covers Docker Desktop, but is that too long to show a spinner? Should we show elapsed time or a "this might take a moment" message?
2. **What if no runtime is detected?** — Show a "Install Docker" link pointing to OrbStack? Or stay neutral?
3. **Should auto-start be on by default?** — It's the "computer just handles it" experience, but some users may not want Docker starting automatically.
