# Base Server Refactor Plan: Modular Simplicity

**Goal:** Make Base a clean, module-agnostic AI service that any Parachute module can use.

**Philosophy:** Start simple. Complexity will come naturally as needs arise.

---

## The Core Insight

Right now, Base is a "Chat backend with extra features." We want it to be an "AI service that Chat (and Daily, and Build) can use."

The key shift: **Decouple AI functionality from Chat's session model.**

---

## Phase 1: Clean AI Endpoints (Do First)

### Add Three Simple Endpoints

```javascript
// 1. Simple completion - fire and forget
POST /api/ai/complete
{
  "prompt": "Summarize this text: ...",
  "system": "You are a helpful assistant",  // optional
  "model": "claude-sonnet-4-20250514"       // optional
}
→ { "content": "Here's the summary..." }

// 2. Streaming completion - real-time response
POST /api/ai/stream
{
  "prompt": "...",
  "system": "...",
  "model": "..."
}
→ SSE: text events, then done

// 3. Embeddings - for any module's RAG
POST /api/ai/embed
{
  "text": "Some content to embed"
}
→ { "embedding": [0.1, 0.2, ...], "dimensions": 256 }
```

**Why these three?**
- `complete`: Daily needs to summarize journal entries, generate insights
- `stream`: Build needs streaming for long operations
- `embed`: Any module can build its own search index

**What we're NOT doing:**
- No session management in these endpoints
- No tool use (that's what `/api/chat/stream` is for)
- No complex options - just the basics

### Implementation

Create `lib/ai-service.js`:

```javascript
/**
 * AI Service - Simple, stateless AI operations
 *
 * No sessions, no tools, no complexity.
 * For agentic work with tools, use the Orchestrator.
 */

import Anthropic from '@anthropic-ai/sdk';

const client = new Anthropic();

export async function complete(prompt, options = {}) {
  const { system, model = 'claude-sonnet-4-20250514' } = options;

  const response = await client.messages.create({
    model,
    max_tokens: 4096,
    system: system || undefined,
    messages: [{ role: 'user', content: prompt }]
  });

  return response.content[0].text;
}

export async function* stream(prompt, options = {}) {
  const { system, model = 'claude-sonnet-4-20250514' } = options;

  const stream = await client.messages.stream({
    model,
    max_tokens: 4096,
    system: system || undefined,
    messages: [{ role: 'user', content: prompt }]
  });

  for await (const event of stream) {
    if (event.type === 'content_block_delta') {
      yield event.delta.text;
    }
  }
}

export async function embed(text) {
  // Use Ollama for local embeddings
  const response = await fetch('http://localhost:11434/api/embeddings', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'embeddinggemma', prompt: text })
  });

  const data = await response.json();
  return data.embedding.slice(0, 256); // Matryoshka truncation
}
```

Add to `server.js`:

```javascript
import * as ai from './lib/ai-service.js';

// Simple completion
app.post('/api/ai/complete', async (req, res) => {
  const { prompt, system, model } = req.body;
  if (!prompt) return res.status(400).json({ error: 'prompt required' });

  try {
    const content = await ai.complete(prompt, { system, model });
    res.json({ content });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Streaming completion
app.post('/api/ai/stream', async (req, res) => {
  const { prompt, system, model } = req.body;
  if (!prompt) return res.status(400).json({ error: 'prompt required' });

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');

  try {
    for await (const text of ai.stream(prompt, { system, model })) {
      res.write(`data: ${JSON.stringify({ text })}\n\n`);
    }
    res.write(`data: ${JSON.stringify({ done: true })}\n\n`);
    res.end();
  } catch (err) {
    res.write(`data: ${JSON.stringify({ error: err.message })}\n\n`);
    res.end();
  }
});

// Embeddings
app.post('/api/ai/embed', async (req, res) => {
  const { text } = req.body;
  if (!text) return res.status(400).json({ error: 'text required' });

  try {
    const embedding = await ai.embed(text);
    res.json({ embedding, dimensions: embedding.length });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
```

**Lines of code:** ~80
**Complexity:** Low
**Value:** High - any module can now use AI without Chat's baggage

---

## Phase 2: Module-Aware Sessions (Do Second)

### The Problem

Sessions are stored in `Chat/sessions/`. If Daily wants sessions, where do they go?

### The Simple Solution

Keep the existing session system, but make the path configurable:

```javascript
// Before (hardcoded)
POST /api/chat/stream
→ saves to Chat/sessions/

// After (module parameter)
POST /api/chat/stream
{ "module": "daily", ... }
→ saves to Daily/sessions/

POST /api/chat/stream
{ "module": "chat", ... }  // or omit for default
→ saves to Chat/sessions/
```

### Implementation

Modify `session-manager-v2.js`:

```javascript
class SessionManager {
  constructor(vaultPath, moduleName = 'Chat') {
    this.vaultPath = vaultPath;
    this.moduleName = moduleName;
    this.sessionsPath = join(vaultPath, moduleName, 'sessions');
  }
  // ... rest unchanged
}
```

Modify orchestrator to accept module:

```javascript
async runImmediateStreaming(message, options = {}) {
  const { module = 'Chat', ...rest } = options;
  const sessionManager = this.getSessionManager(module);
  // ... rest unchanged
}
```

**Lines of code:** ~20 changes
**Complexity:** Low
**Breaking changes:** None (default is 'Chat')

---

## Phase 3: Simplify the API Surface (Do Third)

### Current Problem: 75+ Endpoints

Too many endpoints, many are:
- Legacy/deprecated
- Overly specific
- Redundant

### The Cleanup

**Keep (essential):**
```
GET  /api/health
GET  /api/setup

POST /api/ai/complete          # NEW
POST /api/ai/stream            # NEW
POST /api/ai/embed             # NEW

POST /api/chat/stream          # Agentic chat (tools, MCP, etc.)
GET  /api/chat/sessions
GET  /api/chat/session/:id
DELETE /api/chat/session/:id

GET  /api/modules
GET  /api/modules/:mod/search
POST /api/modules/:mod/index

GET  /api/agents
GET  /api/mcp
POST /api/generate/image       # Simplified from /api/generate/*
```

**Deprecate (add warning, remove later):**
```
GET  /api/search               # → use /api/modules/:mod/search
GET  /api/chat/history         # → use /api/chat/sessions
DELETE /api/chat/session       # → use /api/chat/session/:id
GET  /api/vault-search/*       # → use /api/modules/*
```

**Remove (unused or over-engineered):**
```
/api/documents/*               # 8 endpoints - do we need this?
/api/queue/*                   # Queue can be internal
/api/triggers/*                # Can be internal
/api/perf/*                    # Flutter app specific
```

### Result

**Before:** 75+ endpoints
**After:** ~20 essential endpoints

---

## Phase 4: Documentation (Do Last)

Update `base/CLAUDE.md` with the new API:

```markdown
## API Reference

### AI Endpoints (Stateless)
| Endpoint | Method | Description |
|----------|--------|-------------|
| /api/ai/complete | POST | Simple completion |
| /api/ai/stream | POST | Streaming completion |
| /api/ai/embed | POST | Generate embeddings |

### Chat Endpoints (Stateful, Agentic)
| Endpoint | Method | Description |
|----------|--------|-------------|
| /api/chat/stream | POST | Agentic chat with tools |
| /api/chat/sessions | GET | List sessions |
| /api/chat/session/:id | GET | Get session |
| /api/chat/session/:id | DELETE | Delete session |

### Module Endpoints
| Endpoint | Method | Description |
|----------|--------|-------------|
| /api/modules | GET | List modules |
| /api/modules/:mod/search | GET | Search module |
| /api/modules/:mod/index | POST | Rebuild index |
```

---

## What We're NOT Doing (Intentionally)

1. **Per-module agents** - Keep agents global for now. Complexity can come later.

2. **Per-module contexts** - Keep contexts in Chat/contexts. Daily/Build can pass context in the prompt.

3. **Cross-module security** - Don't restrict MCP access by module yet. Trust the modules.

4. **Separate databases per module** - Already done with index.db, don't need more.

5. **Module registration/discovery** - Hardcode the known modules (chat, daily, build). Add more when needed.

---

## Implementation Order

| Phase | Effort | Impact | Do When |
|-------|--------|--------|---------|
| 1. AI Endpoints | 2 hours | High | Now |
| 2. Module Sessions | 1 hour | Medium | Next |
| 3. API Cleanup | 2 hours | Medium | When stable |
| 4. Documentation | 1 hour | High | After each phase |

**Total: ~6 hours of focused work**

---

## Success Criteria

After this refactor:

1. **Daily can call Base** for AI without touching Chat code
2. **API is intuitive** - new developer understands it in 5 minutes
3. **Endpoints < 25** - easy to maintain
4. **No breaking changes** - Chat app keeps working

---

## Example: Daily Using Base

```dart
// Daily app wants to summarize a journal entry
final response = await http.post(
  Uri.parse('$baseUrl/api/ai/complete'),
  body: jsonEncode({
    'prompt': 'Summarize this journal entry:\n\n$entryText',
    'system': 'You are a thoughtful assistant helping someone reflect on their day.',
  }),
);
final summary = jsonDecode(response.body)['content'];
```

No sessions. No Chat concepts. Just AI.

---

## Example: Build Using Base

```dart
// Build app wants to run a code review agent
final response = await http.post(
  Uri.parse('$baseUrl/api/chat/stream'),
  body: jsonEncode({
    'message': 'Review this code for bugs:\n\n$code',
    'module': 'build',  // Sessions saved to Build/sessions/
    'agentPath': '.agents/code-reviewer.md',
  }),
);
// Stream the response...
```

Uses the full agentic system, but with Build's own session storage.

---

**Last Updated:** December 30, 2025
