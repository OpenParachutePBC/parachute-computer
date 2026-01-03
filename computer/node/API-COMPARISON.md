# API Schema: Current vs Proposed

## Current API (75+ endpoints)

### Health & System (4)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/health` | GET | ✅ | Essential |
| `/api/stats` | GET | ✅ | Useful for debugging |
| `/api/analytics` | GET | ❓ | Is this used? |
| `/api/setup` | GET | ✅ | Ollama/search status |

### Chat & Sessions (11)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/chat` | POST | ❌ | Non-streaming, unused |
| `/api/chat/stream` | POST | ✅ | **Core endpoint** |
| `/api/chat/sessions` | GET | ✅ | List sessions |
| `/api/chat/session/:id` | GET | ✅ | Get session |
| `/api/chat/session/:id/archive` | POST | ✅ | Archive |
| `/api/chat/session/:id/unarchive` | POST | ✅ | Unarchive |
| `/api/chat/session/:id` | DELETE | ✅ | Delete |
| `/api/chat/sessions/reload` | POST | ❓ | Internal use only? |
| `/api/chat/session` | DELETE | ❌ | Legacy, remove |
| `/api/chat/history` | GET | ❌ | Legacy, remove |
| `/api/directories` | GET | ✅ | Working directory picker |

### Agents (2)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/agents` | GET | ✅ | List agents |
| `/api/agents/spawn` | POST | ❓ | Is this used by clients? |

### Contexts (1)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/contexts` | GET | ✅ | List context files |

### Logging (4)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/logs` | GET | ✅ | Query logs |
| `/api/logs/stats` | GET | ❓ | Overkill? |
| `/api/perf` | GET | ❓ | Flutter-specific |
| `/api/perf/events` | GET | ❓ | Flutter-specific |
| `/api/perf/report` | GET | ❓ | Flutter-specific |

### Usage Tracking (5)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/usage` | GET | ✅ | Token usage summary |
| `/api/usage/daily` | GET | ❓ | Overkill? |
| `/api/usage/hourly` | GET | ❓ | Overkill? |
| `/api/usage/session/:id` | GET | ❓ | Overkill? |
| `/api/usage/agent/:path` | GET | ❓ | Overkill? |

### Vault Search - Legacy (4)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/vault-search` | GET | ❌ | Replaced by /api/modules |
| `/api/vault-search/stats` | GET | ❌ | Replaced |
| `/api/vault-search/content` | GET | ❌ | Replaced |
| `/api/vault-search/content/:id` | GET | ❌ | Replaced |

### Module Search - New (8)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/modules` | GET | ✅ | List modules |
| `/api/modules/stats` | GET | ✅ | All module stats |
| `/api/modules/search` | GET | ✅ | Cross-module search |
| `/api/modules/:mod/search` | GET | ✅ | Per-module search |
| `/api/modules/:mod/stats` | GET | ✅ | Module stats |
| `/api/modules/:mod/recent` | GET | ✅ | Recent content |
| `/api/modules/:mod/content/:id` | GET | ✅ | Get content |
| `/api/modules/:mod/index` | POST | ✅ | Rebuild index |

### AGENTS.md (3)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/agents-md` | GET | ✅ | Get system prompt |
| `/api/agents-md` | PUT | ✅ | Update system prompt |
| `/api/default-prompt` | GET | ✅ | Built-in default |

### Permissions (4)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/permissions` | GET | ✅ | Pending requests |
| `/api/permissions/:id/grant` | POST | ✅ | Grant |
| `/api/permissions/:id/deny` | POST | ✅ | Deny |
| `/api/permissions/stream` | GET | ✅ | SSE stream |

### MCP Servers (3)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/mcp` | GET | ✅ | List servers |
| `/api/mcp/:name` | POST | ✅ | Add/update |
| `/api/mcp/:name` | DELETE | ✅ | Remove |

### Skills (4)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/skills` | GET | ✅ | List skills |
| `/api/skills/:name` | GET | ✅ | Get skill |
| `/api/skills/:name` | POST | ✅ | Create/update |
| `/api/skills/:name` | DELETE | ✅ | Delete |

### Content Generation (5)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/generate/config` | GET | ✅ | Full config |
| `/api/generate/backends/:type` | GET | ✅ | List backends |
| `/api/generate/backends/:type/:name` | PUT | ✅ | Update backend |
| `/api/generate/default/:type` | PUT | ✅ | Set default |
| `/api/generate/backends/:type/:name/status` | GET | ✅ | Check status |

### Documents (11)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/documents` | GET | ❓ | Used? |
| `/api/documents/agent-config` | GET | ❓ | Used? |
| `/api/documents/stats` | GET | ❓ | Used? |
| `/api/documents/*/agents` | GET | ❓ | Used? |
| `/api/documents/*/agents` | PUT | ❓ | Used? |
| `/api/documents/*/agents/pending` | GET | ❓ | Used? |
| `/api/documents/*/run-agents` | POST | ❓ | Used? |
| `/api/documents/*/reset-agents` | POST | ❓ | Used? |
| `/api/documents/trigger/*` | POST | ❓ | Used? |
| `/api/documents/process/*` | POST | ❓ | Used? |
| `/api/documents/*` | GET | ❓ | Used? |

### Queue (3)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/queue` | GET | ❓ | Internal? |
| `/api/queue/process` | POST | ❓ | Internal? |
| `/api/queue/:id/stream` | GET | ❓ | Internal? |

### Vault (2)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/vault` | GET | ✅ | Vault info |
| `/api/search` | GET | ❌ | Legacy |

### Triggers (1)
| Endpoint | Method | Keep? | Notes |
|----------|--------|-------|-------|
| `/api/triggers/check` | POST | ❓ | Internal? |

---

## Proposed API (Simplified)

### Tier 1: Essential (Used by Chat app today)
```
GET  /api/health
GET  /api/setup

POST /api/chat/stream              ← The main event
GET  /api/chat/sessions
GET  /api/chat/session/:id
POST /api/chat/session/:id/archive
POST /api/chat/session/:id/unarchive
DELETE /api/chat/session/:id

GET  /api/agents
GET  /api/contexts
GET  /api/directories
```
**Count: 11 endpoints**

### Tier 2: Module System (New, valuable)
```
GET  /api/modules
GET  /api/modules/stats
GET  /api/modules/search
GET  /api/modules/:mod/search
GET  /api/modules/:mod/stats
GET  /api/modules/:mod/recent
GET  /api/modules/:mod/content/:id
POST /api/modules/:mod/index
```
**Count: 8 endpoints**

### Tier 3: Configuration & Management
```
GET  /api/agents-md
PUT  /api/agents-md
GET  /api/default-prompt

GET  /api/mcp
POST /api/mcp/:name
DELETE /api/mcp/:name

GET  /api/skills
GET  /api/skills/:name
POST /api/skills/:name
DELETE /api/skills/:name

GET  /api/generate/config
GET  /api/generate/backends/:type
PUT  /api/generate/backends/:type/:name
GET  /api/generate/backends/:type/:name/status
```
**Count: 14 endpoints**

### Tier 4: Permissions (Required for agentic)
```
GET  /api/permissions
POST /api/permissions/:id/grant
POST /api/permissions/:id/deny
GET  /api/permissions/stream
```
**Count: 4 endpoints**

### Tier 5: Observability (Keep but simplify)
```
GET  /api/stats
GET  /api/logs
GET  /api/usage
GET  /api/vault
```
**Count: 4 endpoints**

---

## Summary

| Category | Current | Proposed | Change |
|----------|---------|----------|--------|
| Essential | 11 | 11 | Same |
| Modules | 8 | 8 | Same (new) |
| Config | ~15 | 14 | -1 |
| Permissions | 4 | 4 | Same |
| Observability | ~15 | 4 | -11 |
| Documents | 11 | 0 | -11 (remove or internal) |
| Queue | 3 | 0 | -3 (internal) |
| Legacy | ~8 | 0 | -8 (remove) |
| **Total** | **~75** | **41** | **-34** |

---

## Questions to Answer

Before finalizing, we should check:

1. **Documents endpoints** - Does the Chat app use these? Or was this for a feature that didn't ship?

2. **Queue endpoints** - Are these exposed to clients or just internal?

3. **Perf endpoints** - Is Flutter app actually using these?

4. **Usage breakdown endpoints** - Do we need hourly/daily/per-session or just the summary?

5. **Analytics endpoint** - What's this for?

---

## What We're NOT Adding

| Proposed Earlier | Why Not |
|-----------------|---------|
| `POST /api/ai/complete` | No client needs it yet |
| `POST /api/ai/stream` | `/api/chat/stream` already works |
| `POST /api/ai/embed` | Modules use their own indexing |
| Module-aware sessions | Chat works fine, wait for Daily/Build |

**Principle: Don't build it until a client needs it.**
