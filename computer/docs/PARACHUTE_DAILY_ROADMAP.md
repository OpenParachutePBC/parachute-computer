# Parachute Daily Roadmap

> $1/month offering: Daily journal sync + AI reflection

---

## Overview

Parachute Daily is the entry-level paid tier. Users get:
1. **Sync**: Daily/ markdown files sync between device and cloud
2. **AI Reflection**: Daily curator-style reflection on journal entries

This document outlines the implementation path.

---

## Architecture

```
┌─────────────────────────────────────────┐
│            User's Device                │
│  ┌───────────────────────────────────┐  │
│  │  Parachute App                    │  │
│  │  - Local Daily/ (source of truth) │  │
│  │  - Sync client                    │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│         Per-User VM (Fly.io)            │
│  ┌───────────────────────────────────┐  │
│  │  Parachute Base (daily mode)      │  │
│  │  - Sync endpoints                 │  │
│  │  - Goose agent runtime            │  │
│  │  - Daily/ storage on volume       │  │
│  └───────────────────────────────────┘  │
│                                         │
│  Volume: ~50-100MB                      │
│  Compute: ~5 min/day (scale-to-zero)    │
└─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────┐
│         LLM Provider (DeepInfra)        │
│  - Nemotron Nano                        │
│  - ~$0.30/user/month in tokens          │
└─────────────────────────────────────────┘
```

---

## Implementation Phases

### Phase 1: Sync (Current)

**Goal**: Reliable markdown sync between app and server

**Components**:
- [x] Sync API endpoints in Base (`/api/sync/`)
  - `GET /manifest` - File hashes for change detection
  - `POST /push` - Upload changed files
  - `POST /pull` - Download files
  - `DELETE /files` - Remove deleted files
- [ ] Sync client in Flutter app
- [ ] Conflict resolution (last-write-wins + simple merge)
- [ ] Background sync on app lifecycle events

**Sync Protocol**:
```
1. App: GET /sync/manifest?root=Daily
2. App: Compare local hashes with server hashes
3. App: POST /sync/push (local changes)
4. App: POST /sync/pull (server changes)
5. App: DELETE /sync/files (removed files)
```

**Testing**:
- Sync works with local Base server
- Sync handles offline gracefully
- Conflicts merge reasonably

---

### Phase 2: Goose Integration

**Goal**: Replace Claude SDK with Goose for AI runtime

**Why Goose**:
- Model-agnostic (works with Nemotron, not just Claude)
- Lighter weight than Claude SDK
- Still has session/memory concepts
- Better long-term fit for Parachute's multi-provider future

**Components**:
- [ ] Goose installation and configuration
- [ ] Daily reflection agent using Goose
- [ ] Session persistence (memory across runs)
- [ ] Integration with sync (read journals, write reflections)

**Reflection Flow**:
```
1. Scheduler triggers daily job
2. Goose agent wakes up
3. Reads recent Daily/ entries
4. Generates reflection/insights
5. Writes reflection to Daily/ or designated location
6. Agent stops, VM scales to zero
```

**Open Questions**:
- Where do reflections get written? (Daily/reflections/? Daily/YYYY-MM/?)
- How much journal history does the agent read?
- What's the reflection prompt/format?

---

### Phase 3: Cloud Deployment

**Goal**: Per-user VMs on Fly.io

**Components**:
- [ ] Dockerfile for Base (daily mode)
- [ ] fly.toml configuration
- [ ] Volume setup for user data
- [ ] Machine provisioning flow
- [ ] Auto-stop after job completion

**Cost Model** (per user/month):
| Item | Cost |
|------|------|
| Compute (~1 hr) | $0.003 |
| Volume (100MB) | $0.015 |
| Tokens (Nemotron) | $0.30 |
| **Total** | **~$0.32** |

At $1/month: ~68% margin

**Deployment Config**:
```toml
# fly.toml
app = "parachute-user-{id}"
primary_region = "den"  # Denver, close to Boulder

[build]
  dockerfile = "Dockerfile.daily"

[env]
  PARACHUTE_MODE = "daily"

[mounts]
  source = "user_data"
  destination = "/data"

[http_service]
  internal_port = 3333
  auto_stop_machines = true
  auto_start_machines = true
  min_machines_running = 0
```

---

### Phase 4: Control Plane (Future)

**Goal**: Central service for auth, billing, orchestration

Not needed for MVP. Initially:
- Auth: API key generated on user's VM
- Billing: Manual Stripe setup
- Orchestration: Cron job on each VM

Later (at scale):
- Central auth service
- Stripe webhook handling
- VM provisioning API
- Usage tracking and limits

---

## Open Decisions

1. **Sync trigger**: Manual button? Background interval? On app pause?

2. **Multi-device**: For $1 tier, probably single-device only. Sync is device→cloud, not device↔device.

3. **Reflection delivery**: Push notification? Just appears in Daily/? Email digest?

4. **Upgrade path**: How does a $1 user become a $5 user? VM gets reconfigured? New VM?

---

## File Locations

- Sync API: `base/parachute/api/sync.py`
- Config: `base/parachute/config.py` (add PARACHUTE_MODE)
- Goose agent: `base/parachute/core/goose_agent.py` (to be created)
- Dockerfile: `base/Dockerfile.daily` (to be created)
