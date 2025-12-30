---
title: Agent Patterns
tags: [knowledge, patterns, ai]
---

# Agent Patterns for Living Documents

A collection of patterns for making documents agentic using the Agent Pilot system.

## Agent Types

There are three agent types:

| Type | Description | Use Case |
|------|-------------|----------|
| `doc` | Runs ON a specific document | Daily reflection, task breakdown, idea triage |
| `standalone` | Runs independently, gathers its own context | Weekly reviews, vault-wide analysis |
| `chatbot` | Persistent conversation with memory | Interactive assistants, Q&A |

### Doc Agents
- Receive the document content directly
- Process a single document at a time
- Typically configured in the document's frontmatter
- One-shot execution

```yaml
agent:
  name: daily-reflection
  type: doc
  description: Process a daily journal entry
  permissions:
    read: ["*"]
    write: ["daily/*"]
    tools: [Read, Write]
```

### Standalone Agents
- Run independently, no document required
- Gather their own context using Glob/Grep
- Good for cross-vault operations
- One-shot execution

```yaml
agent:
  name: weekly-review
  type: standalone
  description: Review the past week's notes
  permissions:
    read: ["*"]
    write: ["reviews/*"]
    tools: [Read, Write, Glob, Grep]
```

### Chatbot Agents
- Maintain conversation history
- Interactive Q&A style
- Session persists across messages

```yaml
agent:
  name: project-manager
  type: chatbot
  description: Track project status interactively
  permissions:
    read: ["*"]
    write: ["projects/*"]
    tools: [Read, Write, Glob, Grep]
```

## Document-Agent Configuration

Any document can have agents assigned via frontmatter:

```yaml
---
title: My Daily Note
agents:
  - path: agents/daily-reflection.md
    status: pending
    trigger: manual
---
```

The agent runs ON this document when triggered.

## Trigger Patterns

| Trigger | Description |
|---------|-------------|
| `manual` | User-initiated only |
| `daily@22:00` | Run daily at specified time |
| `weekly@monday` | Run weekly on specified day |
| `on_save` | Run when document is saved |

## Common Patterns

### The Reflector (doc)
Process individual entries and add commentary.

```yaml
agent:
  name: daily-reflection
  type: doc
```
- Runs on a single daily note
- Adds a `## Reflection` section

### The Aggregator (standalone)
Gather and summarize across multiple documents.

```yaml
agent:
  name: weekly-review
  type: standalone
```
- Finds its own files via Glob
- Creates summary documents

### The Assistant (chatbot)
Interactive helper for ongoing work.

```yaml
agent:
  name: project-manager
  type: chatbot
```
- Remembers conversation history
- Can spawn other agents

## Best Practices

1. **Choose the right type**: Use `doc` when processing a specific document, `standalone` for cross-vault operations, `chatbot` for interaction
2. **Keep it simple**: Agents should have a single, clear purpose
3. **Minimal permissions**: Only grant write access where needed
4. **Test with manual**: Start with `manual` trigger before automating
