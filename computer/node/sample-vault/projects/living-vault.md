---
title: Living Vault Project
tags: [project, ai, obsidian]
status: active
agents:
  - path: agents/project-manager.md
    status: pending
    trigger: manual
---

# Living Vault Project

Building an agentic backend for Obsidian where each document can have its own AI personality.

## Vision

Transform a static knowledge vault into a living, breathing system where:
- Each document can act as an autonomous agent
- Documents can maintain themselves (update dates, check links, archive old content)
- Natural language interfaces let you navigate and query the vault
- The vault evolves and organizes itself over time

## Current Status

**Phase**: Prototype

### Completed
- [x] Basic server architecture
- [x] Frontmatter-based agent configuration
- [x] Web interface for vault interaction
- [x] Tool system (read, write, search)

### In Progress
- [ ] Per-document agent invocation
- [ ] Agent-to-agent communication
- [ ] Scheduled agent triggers

### Backlog
- [ ] Integration with real Obsidian vault
- [ ] MCP server implementation
- [ ] Claude Agent SDK integration
- [ ] Document relationship analysis

## Architecture Notes

The system has three layers:
1. **Interface Layer**: Web UI, CLI, Obsidian plugin
2. **Agent Layer**: Claude-powered agents with vault tools
3. **Vault Layer**: Markdown files with frontmatter configuration

## Related Documents

- [[ideas/vault-architecture]]
- [[knowledge/agent-patterns]]
