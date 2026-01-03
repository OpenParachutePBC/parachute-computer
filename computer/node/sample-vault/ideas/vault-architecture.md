---
title: Vault Architecture Ideas
tags: [ideas, architecture]
---

# Vault Architecture Ideas

Thinking through how the living vault system should be structured.

## Components

### 1. MCP Server Layer
Exposes vault operations as MCP tools:
- `read_document` - Get document content and frontmatter
- `write_document` - Create or update documents
- `search_vault` - Full-text search
- `list_documents` - Directory listing
- `get_graph` - Document relationships

### 2. Agent Orchestrator
Manages per-document agents:
- Loads agent config from frontmatter
- Routes requests to appropriate agent
- Handles agent-to-agent communication
- Manages context and memory

### 3. Interface Layer
Multiple ways to interact:
- Web interface (this prototype)
- Obsidian plugin (future)
- CLI tool (via Claude Code)
- API for external integrations

## Data Flow

```
User Query
    ↓
Interface Layer (Web/Plugin/CLI)
    ↓
Agent Orchestrator
    ↓
[Document Agent or Vault Agent]
    ↓
MCP Tools → Vault Operations
    ↓
Response
```

## Open Questions

1. **Memory persistence**: Where do agent memories live?
   - In the document frontmatter?
   - In a separate `.agent-memory/` folder?
   - In a database?

2. **Agent communication**: How do document-agents talk to each other?
   - Direct invocation?
   - Message passing?
   - Shared context?

3. **Triggers**: How do we enable time-based or event-based agent actions?
   - Cron-like scheduler?
   - File system watchers?
   - Webhook integration?

## Related
- [[projects/living-vault]]
- [[knowledge/agent-patterns]]
