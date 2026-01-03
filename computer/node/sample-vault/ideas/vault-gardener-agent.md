---
title: Vault Gardener Agent
tags: [ideas, feature, agent]
status: proposed
created: 2024-12-05
---

# Vault Gardener Agent

A vault-level agent that maintains overall vault health and organization.

## Concept

Unlike document-specific agents, the Vault Gardener operates at the vault level, periodically analyzing the entire knowledge base and suggesting maintenance tasks. Think of it as an automated librarian that keeps the collection organized and accessible.

## Capabilities

### 1. Document Merging
- Identify documents with significant content overlap
- Suggest which documents to merge and how
- Preserve links and references during consolidation

### 2. Link Maintenance
- Find and report dead/broken links
- Suggest fixes (similar document names, typos)
- Option to auto-fix obvious typos

### 3. Orphan Connection
- Surface notes with no incoming or outgoing links
- Suggest relevant documents to link to
- Help integrate isolated notes into the knowledge graph

### 4. Hub/MOC Generation
- Identify clusters of related documents
- Suggest when a topic needs its own Map of Content
- Auto-generate draft hub pages

### 5. Staleness Detection
- Flag documents not updated in X months
- Surface content that may be outdated
- Suggest archiving or updating

## Implementation Considerations

### Triggering
- Scheduled (weekly/monthly)
- On-demand by user
- Event-based (after significant vault changes)

### Output Format
- Report document with findings
- Interactive suggestions (approve/dismiss)
- Direct modifications (with user permission)

### Tools Required
- `get_graph` - Analyze document relationships
- `search_vault` - Full-text search for duplicates
- `list_documents` - Directory traversal
- `read_document` - Content analysis
- `write_document` - Apply fixes (with permission)

## Agent Pattern

```yaml
agent:
  role: vault-gardener
  scope: vault  # Not document-specific
  personality: You are a meticulous librarian who takes pride in a well-organized knowledge base. You notice patterns, connections, and areas that need attention.
  behaviors:
    - Analyze vault structure
    - Identify maintenance opportunities
    - Suggest improvements
    - Execute approved changes
  schedule:
    frequency: weekly
    day: sunday
```

## Open Questions

1. **Permissions**: How much should the gardener be allowed to modify without explicit approval?
2. **Scope**: Should it respect document-level agent permissions/boundaries?
3. **Priorities**: How to rank suggestions (impact vs. effort)?

## Related

- [[knowledge/agent-patterns]] - Add "The Vault Gardener" as a new pattern
- [[ideas/vault-architecture]] - Vault-level agent infrastructure
- [[projects/living-vault]] - Parent project
