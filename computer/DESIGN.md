# Obsidian Agent Pilot

**A system where every markdown file can be a living, autonomous agent.**

---

## Vision

Transform an Obsidian vault from a static knowledge repository into a dynamic, agentic system where:

- **Documents ARE agents** - A markdown file defines an agent's personality, capabilities, and behaviors
- **Agents can spawn agents** - An orchestration layer manages agent lifecycles and prevents runaway recursion
- **Multiple interfaces** - Interact via web UI, CLI, or directly from Obsidian
- **Powered by Claude Code credentials** - Uses your existing Claude Max subscription via the Agent SDK

---

## Core Concepts

### 1. Document-as-Agent

A markdown file is not just a note with an agent attached—**the file IS the agent definition**.

```
┌─────────────────────────────────────────┐
│  agents/project-manager.md              │
├─────────────────────────────────────────┤
│  YAML Frontmatter                       │
│  ├─ name, description                   │
│  ├─ tools (what it can do)              │
│  ├─ triggers (when it runs)             │
│  ├─ spawns (what agents it can invoke)  │
│  └─ context (what it can see)           │
├─────────────────────────────────────────┤
│  Markdown Body = System Prompt          │
│  ├─ Personality definition              │
│  ├─ Behavioral instructions             │
│  └─ Examples and constraints            │
└─────────────────────────────────────────┘
```

### 2. Orchestrator Pattern

Agents don't directly spawn other agents. They **request** spawns, and a central orchestrator decides when and how to run them.

```
Agent A: "I need to spawn the summarizer agent"
    ↓
Orchestrator receives request
    ↓
Orchestrator checks: depth limit? queue capacity? permissions?
    ↓
Orchestrator enqueues Agent B
    ↓
Agent B runs, results flow back to Agent A's context
```

This prevents infinite recursion and enables scheduling, prioritization, and resource management.

### 3. Agent Queue

A persistent queue that manages agent execution:

| Queue Type | Description |
|------------|-------------|
| **Immediate** | Run as soon as resources available |
| **Scheduled** | Run at specific time (cron-like) |
| **Triggered** | Run when event occurs (file created, webhook, etc.) |
| **Dependent** | Run after another agent completes |

### 4. Context Flow

Agents operate in isolated contexts but can:
- Declare which vault files they need access to
- Receive context passed from parent agents
- Return results that bubble up to parent agents
- Write to shared documents in the vault

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         INTERFACE LAYER                              │
│                                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   Web UI     │  │  Claude CLI  │  │   Obsidian   │              │
│  │ (index.html) │  │   (claude)   │  │   Plugin     │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         │                 │                 │                       │
│         └─────────────────┼─────────────────┘                       │
│                           ▼                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                      REST API                                │   │
│  │  POST /api/chat         - Chat with agent                   │   │
│  │  POST /api/agents/spawn - Request agent spawn               │   │
│  │  GET  /api/queue        - View agent queue                  │   │
│  │  POST /api/queue/run    - Trigger queue processing          │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       ORCHESTRATOR                                   │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Agent Queue                                                 │   │
│  │  ├─ Immediate: [agent-1, agent-2]                           │   │
│  │  ├─ Scheduled: [{agent-3, at: "18:00"}]                     │   │
│  │  └─ Triggered: [{agent-4, on: "file:daily/*.md"}]           │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Execution Engine                                            │   │
│  │  ├─ Load agent definition from markdown                     │   │
│  │  ├─ Build context (vault files, parent context)             │   │
│  │  ├─ Execute via Claude Agent SDK                            │   │
│  │  ├─ Capture spawn requests                                  │   │
│  │  ├─ Enqueue child agents                                    │   │
│  │  └─ Return results to parent/caller                         │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Safety & Limits                                             │   │
│  │  ├─ Max spawn depth (default: 3)                            │   │
│  │  ├─ Max concurrent agents                                   │   │
│  │  ├─ Per-agent timeout                                       │   │
│  │  └─ Cost tracking / budget limits                           │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    CLAUDE AGENT SDK                                  │
│                                                                      │
│  import { query } from '@anthropic-ai/claude-agent-sdk'             │
│                                                                      │
│  - Uses ~/.claude/.credentials.json (Claude Max subscription)       │
│  - Provides tools: Read, Write, Edit, Glob, Grep, Bash              │
│  - Streaming responses via async iterator                           │
│  - Automatic context management                                      │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      OBSIDIAN VAULT                                  │
│                                                                      │
│  vault/                                                              │
│  ├─ .agents/                    # Agent definitions                 │
│  │  ├─ daily-reflection.md                                         │
│  │  ├─ project-manager.md                                          │
│  │  ├─ idea-triage.md                                              │
│  │  └─ knowledge-keeper.md                                         │
│  │                                                                   │
│  ├─ .queue/                     # Queue state (optional persistence)│
│  │  └─ queue.json                                                   │
│  │                                                                   │
│  ├─ daily/                      # Regular vault content             │
│  │  └─ 2024-12-05.md                                               │
│  ├─ projects/                                                        │
│  │  └─ living-vault.md                                             │
│  └─ ideas/                                                           │
│     └─ inbox.md                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Agent Definition Schema

An agent is defined in a markdown file with YAML frontmatter:

```yaml
---
agent:
  # Identity
  name: daily-reflection          # Unique identifier
  description: |                  # When/why to invoke this agent
    Process daily journal entries, notice patterns,
    and help with reflection.

  # Capabilities
  model: sonnet                   # sonnet | opus | haiku
  tools:                          # Available tools
    - Read
    - Write
    - Grep
    - Glob

  # Lifecycle Triggers
  triggers:
    on_create:                    # Run when matching file is created
      pattern: "daily/*.md"
    on_modify:                    # Run when matching file is modified
      pattern: "daily/*.md"
    on_schedule:                  # Run on schedule (cron syntax)
      cron: "0 18 * * *"          # 6pm daily
    on_invoke:                    # Run when explicitly called
      enabled: true

  # Agent Spawning
  spawns:
    - agent: .agents/morning-intentions.md
      when: on_create
      context:
        include: ["projects/*", "ideas/inbox.md"]

    - agent: .agents/evening-summary.md
      when: on_schedule
      depends_on: morning-intentions  # Wait for this agent first

  # Context Configuration (what the agent can READ)
  context:
    include:                      # Files/patterns to include in context
      - "daily/*"
      - "projects/*"
    exclude:                      # Files/patterns to exclude
      - "archive/*"
      - ".agents/*"
    max_files: 20                 # Limit files loaded
    max_tokens: 50000             # Limit context size

  # Permissions (what the agent can WRITE/DO)
  permissions:
    write:                        # Where agent can create/modify files
      - "daily/*"                 # Can write to daily folder
      - "summaries/*"             # Can write to summaries folder
    read:                         # Explicit read permissions (if stricter than context)
      - "*"                       # Can read anything
    spawn:                        # Which agents it can spawn
      - ".agents/morning-intentions.md"
      - ".agents/evening-summary.md"
    tools:                        # Allowed tool operations
      - "Read"
      - "Write"
      - "Grep"
      # Note: no "Bash" means no shell commands

  # Constraints
  constraints:
    max_spawns: 3                 # Max agents this can spawn per run
    timeout: 300                  # Seconds before timeout
---

# Daily Reflection Partner

You are a thoughtful reflection partner helping process daily journal entries.

## Your Role

- Help the user reflect on their day
- Notice patterns across multiple days
- Connect daily experiences to ongoing projects
- Encourage gratitude and intention-setting

## How to Respond

1. Be encouraging but honest
2. Ask probing questions when appropriate
3. Reference specific entries from the vault when relevant
4. Keep responses concise unless deep reflection is requested

## When Spawning Other Agents

- Spawn `morning-intentions` when a new daily note is created
- Schedule `evening-summary` for end of day
- Pass relevant project context to spawned agents

## Example Interaction

User: "Today was frustrating. The prototype kept breaking."

You: "I can see from [[projects/living-vault]] that you've been deep in
prototype work. What specifically was breaking? Sometimes articulating
the blocker helps clarify the next step."
```

---

## Orchestrator Implementation

### Core Classes

```typescript
// Types
interface AgentDefinition {
  name: string;
  description: string;
  model: 'sonnet' | 'opus' | 'haiku';
  tools: string[];
  triggers: AgentTriggers;
  spawns: SpawnConfig[];
  context: ContextConfig;
  constraints: AgentConstraints;
  systemPrompt: string;  // Markdown body
}

interface QueueItem {
  id: string;
  agentPath: string;
  agent: AgentDefinition;
  status: 'pending' | 'running' | 'completed' | 'failed';
  priority: 'high' | 'normal' | 'low';
  depth: number;
  spawnedBy: string | null;
  context: ExecutionContext;
  scheduledFor: Date;
  createdAt: Date;
  startedAt?: Date;
  completedAt?: Date;
  result?: AgentResult;
  error?: string;
}

interface ExecutionContext {
  userMessage?: string;
  parentContext?: any;
  vaultFiles: string[];
  inheritedData?: any;
}

interface AgentResult {
  response: string;
  spawnRequests: SpawnRequest[];
  filesModified: string[];
  tokensUsed: number;
  costUsd: number;
  durationMs: number;
}
```

### Orchestrator Class

```typescript
class AgentOrchestrator {
  private queue: QueueItem[] = [];
  private running: Map<string, QueueItem> = new Map();
  private config: OrchestratorConfig;
  private vaultPath: string;

  constructor(vaultPath: string, config?: Partial<OrchestratorConfig>) {
    this.vaultPath = vaultPath;
    this.config = {
      maxDepth: 3,
      maxConcurrent: 2,
      defaultTimeout: 300,
      maxQueueSize: 100,
      ...config
    };
  }

  // Load agent definition from markdown file
  async loadAgent(agentPath: string): Promise<AgentDefinition> {
    const fullPath = path.join(this.vaultPath, agentPath);
    const content = await fs.readFile(fullPath, 'utf-8');
    const { data: frontmatter, content: body } = matter(content);

    return {
      ...frontmatter.agent,
      systemPrompt: body
    };
  }

  // Enqueue an agent for execution
  async enqueue(
    agentPath: string,
    context: ExecutionContext,
    options: EnqueueOptions = {}
  ): Promise<string> {
    // Check queue limits
    if (this.queue.length >= this.config.maxQueueSize) {
      throw new Error('Queue is full');
    }

    // Check depth limit
    if ((options.depth || 0) >= this.config.maxDepth) {
      throw new Error(`Max spawn depth (${this.config.maxDepth}) reached`);
    }

    const agent = await this.loadAgent(agentPath);

    const item: QueueItem = {
      id: crypto.randomUUID(),
      agentPath,
      agent,
      status: 'pending',
      priority: options.priority || 'normal',
      depth: options.depth || 0,
      spawnedBy: options.spawnedBy || null,
      context,
      scheduledFor: options.scheduledFor || new Date(),
      createdAt: new Date()
    };

    this.queue.push(item);
    this.sortQueue();

    // Auto-process if not scheduled for future
    if (item.scheduledFor <= new Date()) {
      this.processQueue();
    }

    return item.id;
  }

  // Process pending queue items
  async processQueue(): Promise<void> {
    while (
      this.running.size < this.config.maxConcurrent &&
      this.hasPendingItems()
    ) {
      const item = this.getNextItem();
      if (item) {
        this.executeAgent(item);
      }
    }
  }

  // Execute a single agent
  async executeAgent(item: QueueItem): Promise<AgentResult> {
    item.status = 'running';
    item.startedAt = new Date();
    this.running.set(item.id, item);

    try {
      // Build system prompt with context
      const systemPrompt = this.buildSystemPrompt(item);

      // Load context files
      const contextContent = await this.loadContextFiles(item);

      // Execute via Claude Agent SDK
      let result = '';
      const response = query({
        prompt: item.context.userMessage || 'Execute your primary function.',
        options: {
          systemPrompt: systemPrompt + '\n\n' + contextContent,
          cwd: this.vaultPath,
          allowedTools: item.agent.tools,
          permissionMode: 'acceptEdits'
        }
      });

      // Collect response
      for await (const message of response) {
        if (message.type === 'result' && message.result) {
          result = message.result;
        }
      }

      // Parse spawn requests from response
      const spawnRequests = this.parseSpawnRequests(result, item);

      // Enqueue spawn requests
      for (const spawn of spawnRequests) {
        await this.enqueue(spawn.agentPath, spawn.context, {
          depth: item.depth + 1,
          spawnedBy: item.id,
          priority: spawn.priority
        });
      }

      item.status = 'completed';
      item.completedAt = new Date();
      item.result = {
        response: result,
        spawnRequests,
        filesModified: [],
        tokensUsed: 0,
        costUsd: 0,
        durationMs: Date.now() - item.startedAt.getTime()
      };

      return item.result;

    } catch (error) {
      item.status = 'failed';
      item.error = error.message;
      throw error;
    } finally {
      this.running.delete(item.id);
      this.processQueue(); // Process next item
    }
  }

  // Build system prompt with agent context
  private buildSystemPrompt(item: QueueItem): string {
    let prompt = item.agent.systemPrompt;

    // Add spawn capability instructions if allowed
    if (item.agent.constraints?.can_spawn !== false) {
      prompt += `\n\n## Spawning Other Agents\n`;
      prompt += `You can request to spawn other agents by including:\n`;
      prompt += `\`\`\`spawn\n{"agent": ".agents/name.md", "context": {...}}\n\`\`\`\n`;
      prompt += `Available agents to spawn:\n`;
      for (const spawn of item.agent.spawns || []) {
        prompt += `- ${spawn.agent}\n`;
      }
    }

    // Add parent context if exists
    if (item.context.parentContext) {
      prompt += `\n\n## Context from Parent Agent\n`;
      prompt += JSON.stringify(item.context.parentContext, null, 2);
    }

    return prompt;
  }
}
```

---

## File Watchers & Triggers

The system watches for file changes and triggers agents accordingly:

```typescript
class TriggerWatcher {
  private orchestrator: AgentOrchestrator;
  private watchers: Map<string, FSWatcher> = new Map();

  constructor(orchestrator: AgentOrchestrator) {
    this.orchestrator = orchestrator;
  }

  async initialize() {
    // Load all agent definitions
    const agents = await this.loadAllAgents();

    // Set up file watchers for on_create / on_modify triggers
    for (const agent of agents) {
      if (agent.triggers?.on_create?.pattern) {
        this.watchPattern(
          agent.triggers.on_create.pattern,
          'create',
          agent
        );
      }
      if (agent.triggers?.on_modify?.pattern) {
        this.watchPattern(
          agent.triggers.on_modify.pattern,
          'modify',
          agent
        );
      }
    }

    // Set up scheduled triggers
    for (const agent of agents) {
      if (agent.triggers?.on_schedule?.cron) {
        this.scheduleAgent(agent);
      }
    }
  }

  private watchPattern(pattern: string, event: string, agent: AgentDefinition) {
    // Use chokidar or similar to watch for file changes
    // When matching file is created/modified, enqueue the agent
  }

  private scheduleAgent(agent: AgentDefinition) {
    // Use node-cron or similar for scheduled execution
  }
}
```

---

## API Endpoints

### Chat with Agent
```
POST /api/chat
{
  "message": "What's the status of my projects?",
  "agentPath": ".agents/project-manager.md",  // Optional, uses vault agent if omitted
  "context": {}  // Optional additional context
}

Response:
{
  "response": "Based on your vault...",
  "agentPath": ".agents/project-manager.md",
  "spawned": ["agent-id-1", "agent-id-2"],  // If any agents were spawned
  "tokensUsed": 1234,
  "durationMs": 5678
}
```

### Spawn Agent
```
POST /api/agents/spawn
{
  "agentPath": ".agents/daily-reflection.md",
  "context": {
    "userMessage": "Reflect on today",
    "files": ["daily/2024-12-05.md"]
  },
  "priority": "normal",
  "scheduledFor": null  // null = immediate, or ISO date string
}

Response:
{
  "queued": true,
  "queueId": "abc-123",
  "position": 3
}
```

### View Queue
```
GET /api/queue

Response:
{
  "pending": [...],
  "running": [...],
  "completed": [...],  // Recent
  "stats": {
    "totalProcessed": 42,
    "avgDurationMs": 3500,
    "totalCostUsd": 0.15
  }
}
```

### Process Queue
```
POST /api/queue/run

Response:
{
  "processed": 2,
  "remaining": 5,
  "results": [...]
}
```

---

## Web Interface

The web UI provides:

1. **Vault Browser** - Navigate documents, see which are agents
2. **Chat Panel** - Chat with vault agent or specific document agents
3. **Queue Monitor** - View pending, running, completed agents
4. **Agent Editor** - Create/edit agent definitions (future)

---

## Example Workflow: Daily Journal

### 1. User creates `daily/2024-12-06.md`

### 2. TriggerWatcher detects file creation
- Matches pattern `daily/*.md`
- Finds `.agents/daily-reflection.md` has `on_create` trigger

### 3. Orchestrator enqueues daily-reflection agent
```javascript
orchestrator.enqueue('.agents/daily-reflection.md', {
  userMessage: 'A new daily note was created',
  vaultFiles: ['daily/2024-12-06.md']
}, { depth: 0 });
```

### 4. Agent executes
- Reads the new daily note
- Reviews yesterday's note for continuity
- Spawns `morning-intentions` agent
- Schedules `evening-summary` for 6pm

### 5. Morning-intentions agent runs (depth: 1)
- Reads project files
- Generates suggested intentions
- Writes suggestions to daily note

### 6. At 6pm, scheduled trigger fires
- `evening-summary` agent runs
- Summarizes the day
- Appends reflection to daily note

---

## Project Structure

```
obsidian-agent-pilot/
├── server.js                 # Express server + API
├── lib/
│   ├── orchestrator.js       # Agent orchestration
│   ├── queue.js              # Queue management
│   ├── triggers.js           # File watchers & schedulers
│   ├── agent-loader.js       # Load agents from markdown
│   └── sdk-wrapper.js        # Claude Agent SDK wrapper
├── public/
│   └── index.html            # Web interface
├── sample-vault/
│   ├── .agents/              # Agent definitions
│   │   ├── daily-reflection.md
│   │   ├── project-manager.md
│   │   └── idea-triage.md
│   ├── .queue/               # Queue state
│   │   └── queue.json
│   ├── daily/
│   ├── projects/
│   └── ideas/
├── package.json
└── DESIGN.md                 # This file
```

---

## Implementation Phases

### Phase 1: Foundation (Current)
- [x] Express server with Claude Agent SDK
- [x] Basic vault reading/searching
- [x] Frontmatter-based agent config
- [x] Web interface for chat
- [x] Auto-credentials from Claude Code

### Phase 2: Orchestrator
- [ ] Queue data structure
- [ ] Agent loader from markdown
- [ ] Basic execution engine
- [ ] Spawn request parsing
- [ ] Depth limiting

### Phase 3: Triggers
- [ ] File watcher for on_create/on_modify
- [ ] Cron scheduler for on_schedule
- [ ] Webhook endpoint for external triggers

### Phase 4: Context & Communication
- [ ] Context file loading with limits
- [ ] Parent-to-child context passing
- [ ] Result bubbling to parent
- [ ] Shared document communication

### Phase 5: Polish
- [ ] Queue persistence
- [ ] Cost tracking
- [ ] Web UI for queue monitoring
- [ ] Agent definition editor
- [ ] Obsidian plugin wrapper

---

## Design Decisions

### Where do agent definitions live?
**Both.** Template agents in `.agents/` folder AND inline in any document.
- `.agents/` for reusable, standalone agents
- Inline frontmatter for document-specific behaviors
- A daily note can BE an agent, not just trigger one

### How do agents communicate results?
**Agent defines it.** The agent's job might be to:
- Read daily notes and create a summary in another folder
- Append to a shared document
- Return results to parent agent only
- Write to a specific output location

**Agent defines permissions.** Each agent declares:
- Where it can read from
- Where it can write to
- What actions it's allowed to perform

### What triggers agent execution?
**Start simple, expand later.**
- Phase 1: Manual invocation only
- Phase 2: File creation/modification
- Phase 3: Scheduled (cron)
- Phase 4: Webhooks, external events

### How granular is the queue?
**Start simple.** Single queue for now.
- One global queue
- Simple priority levels
- Expand to per-agent or per-type queues later if needed

---

## Remaining Open Questions

1. **Queue Persistence**: JSON file for now, revisit if needed

2. **Error Handling**: Log and continue, notify user in queue status

3. **Concurrency**: Start with 1 concurrent, make configurable

---

## Key Insight

The power of this system is that **the vault becomes self-organizing**:

- Daily journals automatically get reflected upon
- Projects automatically get status updates
- Ideas automatically get triaged
- Knowledge automatically gets connected

Instead of the user having to remember to invoke AI assistance, the vault itself knows when and how to engage AI agents based on the patterns defined in the agent markdown files.

The user's job shifts from "operating AI tools" to "defining agent behaviors" - a more declarative, set-it-and-forget-it approach to knowledge management.
