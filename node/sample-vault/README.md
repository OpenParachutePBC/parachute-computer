---
title: Sample Vault Home
tags: [home, index]
---

# Sample Vault

This is a demonstration vault for the Obsidian Agent Pilot system.

## How It Works

This vault shows the two key concepts:

### 1. Agent Definitions (in `agents/`)

The `agents/` folder contains agent definitions - markdown files that define how agents behave:

| Agent | Type | Purpose |
|-------|------|---------|
| [daily-reflection](agents/daily-reflection.md) | workflow | Process daily journal entries |
| [idea-curator](agents/idea-curator.md) | workflow | Triage and organize ideas |
| [project-manager](agents/project-manager.md) | chatbot | Track project status |
| [weekly-review](agents/weekly-review.md) | workflow | Create weekly summaries |
| [task-breakdown](agents/task-breakdown.md) | workflow | Break down complex tasks |

### 2. Document-Agent Configuration

Any document can have agents assigned to it via frontmatter:

```yaml
agents:
  - path: agents/daily-reflection.md
    status: pending
    trigger: daily@22:00
```

## Sample Documents

### Daily Notes
- [2024-12-05](daily/2024-12-05.md) - Prototype development day
- [2024-12-06](daily/2024-12-06.md) - Orchestration layer development

### Ideas
- [inbox](ideas/inbox.md) - Raw ideas inbox (processed by idea-curator)
- [vault-architecture](ideas/vault-architecture.md) - Architecture brainstorming
- [vault-gardener-agent](ideas/vault-gardener-agent.md) - Future agent concept

### Projects
- [living-vault](projects/living-vault.md) - The main project document

### Knowledge
- [agent-patterns](knowledge/agent-patterns.md) - Reference guide for agent patterns

## Try These

1. Open a document with agents configured (like a daily note)
2. Use Command Palette (Cmd+P) → "Run Agents on Current Document"
3. Or use "Manage Document Agents" to add/remove agents
4. Check the Activity tab in the Agent Pilot panel to see execution status

## Folder Structure

```
sample-vault/
├── agents/           # Agent definitions (the "how")
├── daily/            # Daily notes (targets for agents)
├── ideas/            # Ideas and brainstorming
├── projects/         # Project documents
├── knowledge/        # Reference material
├── summaries/        # Generated summaries (by weekly agents)
└── reviews/          # Generated reviews (by weekly agents)
```
