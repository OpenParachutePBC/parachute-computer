---
title: "Parachute Daily v2: Self-Hosted Server + App"
type: feat
date: 2026-03-30
issue: 359
---

# Parachute Daily v2: Self-Hosted Server + App

Build the TypeScript core library, Bun self-hosted server, and simplified Flutter app for Parachute Daily v2. A personal graph database that humans journal into and AI agents read/write through MCP.

## Design Philosophy

**Parachute Daily is not an AI app. It's a note-taking app that AI can plug into.**

The graph stores your things — notes, people, projects, reflections — and the relationships between them. Tools are the MCP interface: named graph queries and mutations. The intelligence lives in whatever model connects via MCP, not in the tools themselves.

### Core Principles

- **SQLite everywhere** — same schema on Bun (self-hosted) and CF Durable Objects (hosted), no platform divergence
- **Graph in SQL** — nodes (`things`), types (`tags`), edges (`edges`), all in plain SQLite with indexes and FTS5
- **Tools are graph operations** — pure queries and mutations, no LLM inside. The model calling via MCP decides what to read/write
- **Five tables** — things, tags, thing_tags, edges, tools. That's the whole database.

---

## The Data Model

### Five Tables

```sql
-- Nodes: the universal record
CREATE TABLE things (
  id TEXT PRIMARY KEY,                    -- timestamp: YYYY-MM-DD-HH-MM-SS-ffffff
  content TEXT DEFAULT '',                -- text/markdown payload
  created_at TEXT NOT NULL,
  updated_at TEXT,
  created_by TEXT DEFAULT 'user',         -- who/what created it
  status TEXT DEFAULT 'active'            -- active | archived | deleted
);

-- Node types: Tana-style supertags with field schemas
CREATE TABLE tags (
  name TEXT PRIMARY KEY,                  -- kebab-case: daily-note, person, project
  display_name TEXT DEFAULT '',
  description TEXT DEFAULT '',
  schema_json TEXT DEFAULT '[]',          -- field definitions for this type
  icon TEXT DEFAULT '',
  color TEXT DEFAULT '',
  published_by TEXT DEFAULT '',           -- which app registered this tag
  created_at TEXT NOT NULL,
  updated_at TEXT
);

-- Typing: "this thing IS a daily-note" (with typed field values)
CREATE TABLE thing_tags (
  thing_id TEXT NOT NULL REFERENCES things(id),
  tag_name TEXT NOT NULL REFERENCES tags(name),
  field_values_json TEXT DEFAULT '{}',    -- fields defined by the tag's schema
  tagged_at TEXT NOT NULL,
  PRIMARY KEY (thing_id, tag_name)
);

-- Relationships: "this note MENTIONS that person"
CREATE TABLE edges (
  source_id TEXT NOT NULL REFERENCES things(id),
  target_id TEXT NOT NULL REFERENCES things(id),
  relationship TEXT NOT NULL,             -- mentions, has-collaborator, summarizes, etc.
  properties_json TEXT DEFAULT '{}',      -- optional edge metadata
  created_by TEXT DEFAULT 'user',
  created_at TEXT NOT NULL,
  UNIQUE(source_id, target_id, relationship)
);

-- MCP tool definitions: named graph operations
CREATE TABLE tools (
  name TEXT PRIMARY KEY,                  -- kebab-case: read-daily-notes, link-mention
  display_name TEXT DEFAULT '',
  description TEXT DEFAULT '',            -- shown to LLMs via MCP
  tool_type TEXT DEFAULT 'query',         -- query | mutation
  input_schema_json TEXT DEFAULT '{}',    -- JSON Schema for parameters
  definition_json TEXT DEFAULT '{}',      -- declarative query/mutation spec
  published_by TEXT DEFAULT '',
  enabled TEXT DEFAULT 'true',
  created_at TEXT NOT NULL,
  updated_at TEXT
);

-- Full-text search
CREATE VIRTUAL TABLE things_fts USING fts5(content, content='things', content_rowid='rowid');

-- Indexes
CREATE INDEX idx_things_status ON things(status);
CREATE INDEX idx_things_created ON things(created_at);
CREATE INDEX idx_thing_tags_tag ON thing_tags(tag_name);
CREATE INDEX idx_edges_source ON edges(source_id);
CREATE INDEX idx_edges_target ON edges(target_id);
CREATE INDEX idx_edges_rel ON edges(relationship);
```

### How It All Connects

```
Thing: "Walked up Flagstaff with Alice, discussed the Horizon project..."
  ├── tagged: daily-note { entry_type: "voice", audio_url: "...", duration: 120 }
  ├── tagged: reflection
  ├── edge: --mentions--> Thing:"Alice" (tagged: person { email: "alice@..." })
  └── edge: --mentions--> Thing:"Horizon" (tagged: project { status: "active" })

Thing: "Alice"
  ├── tagged: person { email: "alice@...", role: "engineer" }
  └── edge: --collaborates-on--> Thing:"Horizon"

Thing: "Horizon"
  ├── tagged: project { status: "active", deadline: "2026-06-01" }
  └── edge: --has-collaborator--> Thing:"Alice"
```

### Tag Schema Definition

A tag's `schema_json` defines what fields are available when that tag is applied:

```json
[
  { "name": "entry_type", "type": "select", "options": ["text", "voice", "handwriting"], "default": "text" },
  { "name": "audio_url", "type": "text", "description": "URL or path to audio file" },
  { "name": "duration_seconds", "type": "number" },
  { "name": "transcription_status", "type": "select", "options": ["pending", "processing", "complete", "failed"] }
]
```

Field types for v1: `text`, `number`, `boolean`, `select`, `date`, `datetime`, `url`, `json`.

### Why SQLite, Not a Graph DB

The graph is real — things connect to things via typed edges. But the queries are shallow:

- **v1**: Mostly 1-hop (things by tag, edges from a thing, search by content)
- **v2**: 2-hop (things mentioned by notes from this week, people connected to a project)
- **Future**: Multi-hop with `WITH RECURSIVE` CTEs or batch BFS in application code

SQLite handles all of this and runs identically on Bun and CF Durable Objects. No Kuzu, no extensions, no platform divergence. If deep graph traversal becomes critical later, it can be added as an optional local enrichment layer.

References:
- [Graph DB on Cloudflare Durable Objects](https://boristane.com/blog/durable-objects-graph-databases/) — nodes/edges schema, BFS in JS, DO-per-user
- [Edge-Native Knowledge Graphs with D1](https://dev.to/yedanyagamiaicmd/edge-native-knowledge-graphs-with-cloudflare-d1-vectorize-no-database-server-required-5a9l) — batch BFS, confidence scoring, FTS5 + Vectorize hybrid

---

## Tools: The MCP Interface

Tools are **named graph operations** — pure reads and writes, no LLM inside. They get exposed via MCP. Whatever model connects (Claude Code, ChatGPT, a custom agent) calls these tools to interact with the graph.

### Tool Definition Language

Every tool has a `definition_json` that specifies the graph operation:

#### Query Actions

**`query_things`** — find things by tag, field values, date:
```json
{
  "name": "read-daily-notes",
  "tool_type": "query",
  "description": "Read journal entries for a date",
  "input_schema": {
    "properties": {
      "date": { "type": "string", "description": "YYYY-MM-DD, defaults to today" },
      "limit": { "type": "number", "default": 50 }
    }
  },
  "definition": {
    "action": "query_things",
    "tags": ["daily-note"],
    "filters": { "date": "$date" },
    "sort": "created_at:asc",
    "limit": "$limit"
  }
}
```

**`search_things`** — full-text search with optional tag/edge context:
```json
{
  "name": "search-notes",
  "tool_type": "query",
  "description": "Search journal entries by content",
  "input_schema": {
    "properties": {
      "query": { "type": "string" },
      "tags": { "type": "array", "items": { "type": "string" } },
      "include_edges": { "type": "boolean", "default": false }
    },
    "required": ["query"]
  },
  "definition": {
    "action": "search_things",
    "query": "$query",
    "tags": "$tags",
    "include_edges": "$include_edges"
  }
}
```

**`traverse`** — follow edges from a thing:
```json
{
  "name": "get-project-collaborators",
  "tool_type": "query",
  "description": "Find people who collaborate on a project",
  "input_schema": {
    "properties": {
      "project_id": { "type": "string" }
    },
    "required": ["project_id"]
  },
  "definition": {
    "action": "traverse",
    "from": "$project_id",
    "edge": "has-collaborator",
    "direction": "outbound",
    "target_tags": ["person"]
  }
}
```

**`query_edges`** — find relationships for a thing:
```json
{
  "name": "get-mentions",
  "tool_type": "query",
  "description": "Find all things mentioned by a note",
  "input_schema": {
    "properties": {
      "thing_id": { "type": "string" }
    },
    "required": ["thing_id"]
  },
  "definition": {
    "action": "query_edges",
    "from": "$thing_id",
    "direction": "outbound",
    "edge": "mentions"
  }
}
```

#### Mutation Actions

**`upsert_thing`** — create or update a thing with tags:
```json
{
  "name": "write-card",
  "tool_type": "mutation",
  "description": "Write an output card (reflection, summary, etc.)",
  "input_schema": {
    "properties": {
      "content": { "type": "string" },
      "card_type": { "type": "string", "default": "reflection" },
      "date": { "type": "string" }
    },
    "required": ["content"]
  },
  "definition": {
    "action": "upsert_thing",
    "id_template": "$card_type:$date",
    "content": "$content",
    "tags": { "card": { "card_type": "$card_type" } }
  }
}
```

**`create_edge`** — link two things:
```json
{
  "name": "link-mention",
  "tool_type": "mutation",
  "description": "Record that a note mentions a person, project, or other thing",
  "input_schema": {
    "properties": {
      "note_id": { "type": "string" },
      "entity_id": { "type": "string" },
      "relationship": { "type": "string", "default": "mentions" }
    },
    "required": ["note_id", "entity_id"]
  },
  "definition": {
    "action": "create_edge",
    "source": "$note_id",
    "target": "$entity_id",
    "relationship": "$relationship"
  }
}
```

**`update_thing`** — modify content or tag fields:
```json
{
  "name": "update-note",
  "tool_type": "mutation",
  "description": "Update a journal entry's content",
  "input_schema": {
    "properties": {
      "thing_id": { "type": "string" },
      "content": { "type": "string" }
    },
    "required": ["thing_id"]
  },
  "definition": {
    "action": "update_thing",
    "id": "$thing_id",
    "content": "$content"
  }
}
```

### Filter Spec

Filters in `query_things` support:

```typescript
type Filter =
  | string                     // exact match or "$param" substitution
  | { gte: string }            // >= value (dates, numbers)
  | { lte: string }            // <= value
  | { contains: string }       // substring match
  | { in: string[] }           // one of these values
```

Example — "notes from the last 7 days tagged meeting":
```json
{
  "action": "query_things",
  "tags": ["daily-note", "meeting"],
  "filters": { "created_at": { "gte": "$since_date" } },
  "sort": "created_at:desc",
  "limit": "$limit"
}
```

### How an AI Uses These Tools

An AI connected via MCP processes a daily note:

```
1. read-daily-notes(date: "2026-03-30")
   → returns today's journal entries

2. search-notes(query: "Alice")
   → finds existing person thing, or knows to create one

3. upsert-thing(content: "Alice", tags: { person: { role: "engineer" } })
   → creates Alice if she doesn't exist

4. link-mention(note_id: "2026-03-30-09-15-...", entity_id: "alice-id")
   → creates edge: note --mentions--> Alice

5. write-card(content: "Today you discussed Horizon with Alice...", card_type: "reflection")
   → creates reflection card for the day
```

The model decides all of this. The tools are just the graph API.

### MCP Generation

Tools are read from the database and dynamically exposed via MCP:

```typescript
function generateMcpTools(store: Store): McpToolDef[] {
  const tools = store.listTools({ enabled: true })
  return tools.map(tool => ({
    name: tool.name,
    description: tool.description,
    inputSchema: JSON.parse(tool.input_schema_json),
    execute: (params) => store.executeTool(tool.name, params)
  }))
}
```

No code changes to add new MCP tools. An app publishes a tool definition → it's immediately available to any MCP client.

---

## Phase 1: Core Library (`core/`)

The foundation. Both local and hosted import from this package. No platform-specific code.

### 1.1 Schema + Migrations

**File:** `core/src/schema.ts`

- Five tables + FTS5 virtual table (as defined above)
- `CREATE TABLE IF NOT EXISTS` for idempotent init
- Migration system: `schema_version` table, sequential migrations, `transactionSync()` for atomicity

### 1.2 Store Interface

**File:** `core/src/store.ts`

Abstract interface that both Bun SQLite and CF DO SQLite implement:

```typescript
interface Store {
  // Things
  createThing(content: string, opts?: { id?: string, tags?: TagInput[], createdBy?: string }): Thing
  getThing(id: string): Thing | null
  updateThing(id: string, updates: { content?: string, status?: string }): Thing
  queryThings(opts: QueryOpts): Thing[]
  searchThings(query: string, opts?: { tags?: string[], limit?: number }): Thing[]

  // Tags
  createTag(tag: TagDef): Tag
  getTag(name: string): Tag | null
  listTags(opts?: { publishedBy?: string }): Tag[]

  // Thing-Tag relationships
  tagThing(thingId: string, tagName: string, fields?: Record<string, unknown>): void
  untagThing(thingId: string, tagName: string): void
  getThingsByTag(tagName: string, opts?: QueryOpts): Thing[]

  // Edges (relationships between things)
  createEdge(sourceId: string, targetId: string, relationship: string, properties?: Record<string, unknown>): void
  deleteEdge(sourceId: string, targetId: string, relationship: string): void
  getEdgesFrom(thingId: string, opts?: { relationship?: string, direction?: 'outbound' | 'inbound' | 'both' }): Edge[]
  traverse(thingId: string, opts: { edge: string, direction: 'outbound' | 'inbound', depth?: number, targetTags?: string[] }): Thing[]

  // Tools
  registerTool(tool: ToolDef): void
  getTool(name: string): ToolDef | null
  listTools(opts?: { publishedBy?: string, enabled?: boolean }): ToolDef[]
  executeTool(name: string, params: Record<string, unknown>): unknown
}
```

### 1.3 CRUD + Graph Operations

**Files:** `core/src/things.ts`, `core/src/tags.ts`, `core/src/edges.ts`, `core/src/tools.ts`

Pure functions that take a database connection and return results. No HTTP, no platform code.

- **Thing IDs**: Timestamp-based `YYYY-MM-DD-HH-MM-SS-ffffff` — human-readable, sortable, collision-resistant
- **Tag schema validation**: When tagging a thing, validate `field_values_json` against the tag's `schema_json`
- **Edge idempotency**: `INSERT OR IGNORE` on the unique triple — reconnecting is a no-op
- **Cascade delete**: Deleting a thing removes all its edges (both directions) and thing_tags
- **Traversal**: 1-hop via simple JOIN, multi-hop via batch BFS (one query per depth level) or `WITH RECURSIVE` CTE

### 1.4 Tool Execution Engine

**File:** `core/src/executor.ts`

Interprets `definition_json` and runs the corresponding graph operation:

```typescript
function executeTool(store: Store, tool: ToolDef, params: Record<string, unknown>): unknown {
  const def = JSON.parse(tool.definition_json)
  const resolved = resolveParams(def, params) // substitute $param references

  switch (resolved.action) {
    case 'query_things':   return store.queryThings(resolved)
    case 'search_things':  return store.searchThings(resolved.query, resolved)
    case 'traverse':       return store.traverse(resolved.from, resolved)
    case 'query_edges':    return store.getEdgesFrom(resolved.from, resolved)
    case 'upsert_thing':   return upsertThing(store, resolved)
    case 'update_thing':   return store.updateThing(resolved.id, resolved)
    case 'create_edge':    return store.createEdge(resolved.source, resolved.target, resolved.relationship, resolved.properties)
    case 'delete_edge':    return store.deleteEdge(resolved.source, resolved.target, resolved.relationship)
  }
}
```

### 1.5 Seed Data

**File:** `core/src/seed.ts`

Builtin tags and tools for Parachute Daily:

**Tags:**

| Name | Description | Schema Fields |
|------|-------------|--------------|
| `daily-note` | Journal entry | `entry_type` (text/voice/handwriting), `audio_url`, `duration_seconds`, `transcription_status`, `cleanup_status` |
| `card` | AI-generated output | `card_type` (reflection/summary/briefing), `read_at` |
| `person` | A person | `email`, `role`, `notes` |
| `project` | A project or initiative | `status` (active/paused/complete), `deadline`, `notes` |

**Tools:**

| Name | Type | Action | Description |
|------|------|--------|-------------|
| `read-daily-notes` | query | `query_things` | Read journal entries for a date |
| `read-recent-notes` | query | `query_things` | Read entries from past N days |
| `search-notes` | query | `search_things` | Full-text search across entries |
| `write-card` | mutation | `upsert_thing` | Write a reflection/summary card |
| `read-cards` | query | `query_things` | Read cards for a date |
| `read-recent-cards` | query | `query_things` | Read cards from past N days |
| `create-thing` | mutation | `upsert_thing` | Create a thing with tags |
| `update-thing` | mutation | `update_thing` | Update a thing's content or fields |
| `link-things` | mutation | `create_edge` | Create a relationship between things |
| `get-related` | query | `query_edges` | Find things related to a thing |
| `search-graph` | query | `traverse` | Multi-hop traversal from a thing |

### 1.6 Types

**File:** `core/src/types.ts`

```typescript
interface Thing {
  id: string
  content: string
  createdAt: string
  updatedAt?: string
  createdBy: string
  status: 'active' | 'archived' | 'deleted'
  tags?: ThingTag[]       // included when fetching with tags
  edges?: Edge[]          // included when fetching with edges
}

interface Tag {
  name: string
  displayName: string
  description: string
  schema: FieldDef[]
  icon?: string
  color?: string
  publishedBy?: string
}

interface ThingTag {
  tagName: string
  fieldValues: Record<string, unknown>
  taggedAt: string
}

interface Edge {
  sourceId: string
  targetId: string
  relationship: string
  properties: Record<string, unknown>
  createdBy: string
  createdAt: string
  source?: Thing          // populated on fetch
  target?: Thing          // populated on fetch
}

interface ToolDef {
  name: string
  displayName: string
  description: string
  toolType: 'query' | 'mutation'
  inputSchema: Record<string, unknown>   // JSON Schema
  definition: Record<string, unknown>    // action spec
  publishedBy?: string
  enabled: boolean
}

interface FieldDef {
  name: string
  type: 'text' | 'number' | 'boolean' | 'select' | 'date' | 'datetime' | 'url' | 'json'
  description?: string
  options?: string[]      // for select type
  default?: unknown
}

interface QueryOpts {
  tags?: string[]
  filters?: Record<string, Filter>
  sort?: string           // "field:asc" or "field:desc"
  limit?: number
  offset?: number
}

type Filter =
  | string
  | { gte: string }
  | { lte: string }
  | { contains: string }
  | { in: string[] }
```

### Acceptance Criteria — Phase 1

- [x] `core/` builds as standalone TypeScript package (no platform deps)
- [x] Schema creates 5 tables + FTS5 index idempotently
- [x] CRUD operations pass unit tests (using in-memory SQLite via better-sqlite3 or similar)
- [x] Tag schema validation works (reject invalid field values)
- [x] Edge creation/deletion with cascade works
- [x] Traversal works for 1-hop and 2-hop queries
- [x] Tool execution engine handles all action types (query_things, search_things, traverse, query_edges, upsert_thing, update_thing, create_edge, delete_edge)
- [x] MCP tool generation produces valid tool definitions from DB
- [x] Seed data inserts Daily tags, entity tags, and tools correctly

---

## Phase 2: Self-Hosted Server (`local/`)

Bun + Hono server. Implements Store interface with `bun:sqlite`.

### 2.1 Bun SQLite Store

**File:** `local/src/store.ts`

```typescript
import { Database } from "bun:sqlite"
import { initSchema, seedBuiltins } from "@parachute/core"

class BunStore implements Store {
  private db: Database

  constructor(path: string) {
    this.db = new Database(path)
    this.db.exec("PRAGMA journal_mode=WAL")
    this.db.exec("PRAGMA foreign_keys=ON")
    initSchema(this.db)
    seedBuiltins(this.db)
  }
  // ... implement Store methods using bun:sqlite
}
```

- Database at `~/.parachute/daily.db`
- WAL mode for concurrent reads
- Foreign keys enforced

### 2.2 Hono Routes

**File:** `local/src/server.ts`

Shared route handlers from core, with local storage and config on top:

| Route | Method | Purpose |
|-------|--------|---------|
| `/api/health` | GET | Health check |
| `/api/things` | GET | Query things (by tag, date, search, edges) |
| `/api/things` | POST | Create thing with tags |
| `/api/things/:id` | GET | Get thing with tags and edges |
| `/api/things/:id` | PATCH | Update thing content/tags |
| `/api/things/:id` | DELETE | Archive thing (cascade edges) |
| `/api/things/:id/edges` | GET | Get edges for a thing |
| `/api/edges` | POST | Create edge between things |
| `/api/edges` | DELETE | Remove edge |
| `/api/tags` | GET | List tags with counts |
| `/api/tags` | POST | Create/update tag definition |
| `/api/tags/:name` | GET | Get tag with schema |
| `/api/tools` | GET | List registered tools |
| `/api/tools` | POST | Register a tool |
| `/api/tools/:name` | GET | Get tool definition |
| `/api/tools/:name/execute` | POST | Execute a tool with parameters |
| `/api/search` | GET | Full-text search across things |
| `/api/traverse` | POST | Multi-hop graph traversal |
| `/api/register` | POST | App registration (bulk tags + tools) |
| `/api/storage/upload` | POST | Upload audio/image file |
| `/api/storage/*path` | GET | Serve stored file |

### 2.3 MCP over stdio

**File:** `local/src/mcp-stdio.ts`

For Claude Code and MCP clients connecting locally:

```typescript
import { generateMcpTools } from "@parachute/core"

// Read tools table, expose via MCP stdio protocol
// Claude Code: claude mcp add parachute -- parachute-daily mcp
```

Dynamic — tools added to the DB appear in MCP without restart.

### 2.4 Local File Storage

**File:** `local/src/storage.ts`

- Audio/images stored at `~/.parachute/daily/assets/`
- Upload returns relative path, stored as field value on the thing's tag (e.g. `audio_url`)
- Serve files via `/api/storage/*path`

### 2.5 Transcription (Local)

**File:** `local/src/transcription.ts`

For v1: external API support (Groq Whisper, OpenAI Whisper). The Flutter app still handles on-device transcription via Sherpa-ONNX.

Future: Whisper.cpp via Bun subprocess, or Sherpa-ONNX via FFI.

### Acceptance Criteria — Phase 2

- [ ] `bun run local/src/server.ts` starts server on port 3333
- [x] All CRUD routes work for things, tags, edges, tools
- [x] MCP stdio server exposes all registered tools
- [ ] Claude Code can connect via MCP and read/write things + create edges
- [ ] File upload + serve works for audio
- [x] Traversal endpoint returns multi-hop results
- [x] FTS search works across all things

---

## Phase 3: Flutter App — Fresh Daily

Start from the existing `app/` but strip aggressively. The app becomes a single-purpose journal that talks to the graph API.

### 3.1 Delete What We Don't Need

Remove entirely:
- `features/chat/` (99 files) — all of it
- `features/brain/` — memory navigator
- `features/vault/` — file browser
- Settings widgets: bot connectors, computer section, server control, capabilities, trust levels
- Core models/providers/services for chat, supervisor, computer
- Chat-related deps from `pubspec.yaml` (`web_socket_channel`, etc.)

### 3.2 New API Service

**File:** `lib/core/services/graph_api_service.dart` (new)

Targets the v2 graph API:

```dart
class GraphApiService {
  // Things
  Future<List<Thing>> queryThings({String? tag, String? date, int? limit});
  Future<Thing> createThing(String content, {List<TagInput>? tags, String? id});
  Future<Thing> updateThing(String id, {String? content, Map<String, dynamic>? tagFields});
  Future<void> deleteThing(String id);
  Future<List<Thing>> searchThings(String query, {List<String>? tags});

  // Edges
  Future<void> createEdge(String sourceId, String targetId, String relationship);
  Future<List<Edge>> getEdges(String thingId, {String? relationship, String? direction});

  // Tags
  Future<List<Tag>> getTags();

  // Tools
  Future<List<ToolDef>> getTools();
  Future<dynamic> executeTool(String name, Map<String, dynamic> params);

  // Storage
  Future<String> uploadAudio(Uint8List data, String filename);

  // Registration
  Future<void> register({required List<TagDef> tags, required List<ToolDef> tools});
}
```

### 3.3 New Data Models

**File:** `lib/core/models/thing.dart`

```dart
class Thing {
  final String id;
  final String content;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;
  final String status;
  final List<ThingTag> tags;
  final List<Edge> edges;

  // Convenience getters (via tags)
  bool get isDailyNote => hasTag('daily-note');
  bool get isCard => hasTag('card');
  bool get isPerson => hasTag('person');
  bool get isProject => hasTag('project');
  String? get entryType => tagField('daily-note', 'entry_type');
  String? get audioUrl => tagField('daily-note', 'audio_url');
  String? get cardType => tagField('card', 'card_type');
  bool get isRead => tagField('card', 'read_at') != null;

  // Convenience getters (via edges)
  List<Thing> get mentions => edgeTargets('mentions');
  List<Thing> get collaborators => edgeTargets('has-collaborator');
}
```

Keep `JournalEntry` as a **view model** that wraps `Thing` for the journal UI.

### 3.4 Simplify Navigation

**Current:** 4-tab shell (Chat, Daily, Brain, Vault)
**New:** Single-purpose journal app

```
App
├── JournalScreen (home — date picker, entry list, cards)
├── EntryDetailScreen (view/edit entry, see mentions/edges)
├── SearchScreen (full-text search, filter by tag)
├── ThingDetailScreen (view a person, project, or any linked thing)
└── SettingsScreen (server URL, transcription, account)
```

### 3.5 Adapt Voice Recording

Keep existing recorder infrastructure (`features/daily/recorder/`), update:
- Upload audio via `/api/storage/upload`
- Create thing with `daily-note` tag and `audio_url` field value
- Listen for transcription status updates (poll thing's tag field values)

### 3.6 Adapt Offline Support

Keep the two-phase load pattern and pending queue:
- Local SQLite cache stores `Thing` objects with their tags
- Pending queue stores create/update/edge operations
- Flush on reconnect

### 3.7 Backend Target Switching

- Settings: server URL (default `http://localhost:3333`)
- Hosted: auth headers (session token from magic link)
- Local: no auth needed (localhost)

### 3.8 Keep and Clean

| Keep As-Is | Clean Up |
|------------|----------|
| Design tokens, BrandColors, theme | Remove chat/brain color overrides |
| ErrorBoundary, ErrorSnackbar | — |
| TagInput widget | Adapt for thing_tags |
| Sherpa-ONNX transcription, VAD | — |
| JournalContentView | Adapt for Thing content |
| PendingSyncBanner | Adapt for new queue |

### Acceptance Criteria — Phase 3

- [ ] App builds and runs on macOS/iOS with no chat/brain/vault code
- [ ] Journal screen displays things tagged `daily-note` for selected date
- [ ] Cards section displays things tagged `card`
- [ ] Create text entry → creates thing with daily-note tag
- [ ] Voice recording → upload audio → create thing → transcription
- [ ] Entry detail → view/edit content, see tags, see linked things (edges)
- [ ] Search → full-text search across things
- [ ] Thing detail → view a person/project with their edges
- [ ] Offline mode works (cache + pending queue)
- [ ] Works against both local Bun server and hosted CF backend

---

## Phase 4: Hosted Migration

Port the existing `hosted/daily/` to use the shared core library and new schema.

### 4.1 Shared Core in Durable Objects

- DailyVault DO implements Store interface using DO SQLite
- Import schema, seed data, executor, and types from `@parachute/core`
- Same Hono route handlers as local server (extracted into core)
- Keep auth (magic link), R2 storage, Workers AI transcription as platform adapters

### 4.2 Data Migration

One-time migration on DO start (check version flag):
- `notes` → things with `daily-note` tag
- `cards` → things with `card` tag
- `tools` → new tool definitions (declarative, no agent mode)
- Drop old tables after migration

### 4.3 Shared Route Handlers

```typescript
// core/src/routes.ts
export function createRoutes(store: Store): Hono {
  const app = new Hono()
  // all /api/* routes written against Store interface
  return app
}

// local/src/server.ts
const store = new BunStore("~/.parachute/daily.db")
const app = createRoutes(store)
// add local storage middleware

// hosted/src/server.ts
// add auth middleware, proxy to DO
// DO implements Store, uses same route handlers
```

### Acceptance Criteria — Phase 4

- [ ] Hosted backend uses core library for schema, CRUD, and tool execution
- [ ] Existing user data migrated to things/tags/edges/tools schema
- [ ] Same API surface as local server
- [ ] Auth, R2, Workers AI still work

---

## Phase 5: Polish + Launch

### 5.1 App Registration

On first connect, app sends `POST /api/register` with Daily's builtin tags and tools. Server merges (create-if-not-exists, update-if-newer).

### 5.2 TestFlight + APK Distribution (#282)

- iOS: TestFlight beta
- Android: Direct APK or Google Play internal testing

### 5.3 MCP Documentation

Skill file for Claude Code users:

```bash
claude mcp add parachute -- parachute-daily mcp
```

### 5.4 Vector Search (Future)

- Embeddings on thing content for semantic search
- Local: Ollama embeddings stored alongside SQLite
- Hosted: Cloudflare Vectorize as seed-entity finder feeding into graph traversal

---

## Open Decisions

| Question | Leaning | Notes |
|----------|---------|-------|
| New repo or restructure existing? | New repo `parachute-daily` | Clean break, no Python baggage |
| Keep Omi Bluetooth support? | Defer | Nice-to-have, not v1 |
| Local transcription in Bun? | External API for v1 | App still does local Sherpa-ONNX |
| Multi-hop traversal strategy? | Batch BFS for v1, `WITH RECURSIVE` later | One query per depth level, O(depth) queries |
| Edge confidence scoring? | Defer to v2 | Article 2 pattern — `confidence REAL` on edges for PageRank-weighted retrieval |
| Tag inheritance / composition? | Defer | "A meeting-note IS-A daily-note" — tag hierarchy |

## Execution Order

```
Phase 1 (core)  ──→  Phase 2 (local server)  ──→  Phase 3 (app)
                                                        ↓
                      Phase 4 (hosted migration) ←──────┘
                                                        ↓
                                                  Phase 5 (launch)
```

Phases 2 and 3 can overlap. Phase 4 can start once core is stable.

## References

- #359 — Daily v2 brainstorm (Things, Tags, Tools architecture)
- #344 — Hosted Daily v1 (existing CF Workers backend)
- #345 — Future roadmap (API access, migration, billing)
- [Graph DB on Cloudflare Durable Objects](https://boristane.com/blog/durable-objects-graph-databases/)
- [Edge-Native Knowledge Graphs with D1 + Vectorize](https://dev.to/yedanyagamiaicmd/edge-native-knowledge-graphs-with-cloudflare-d1-vectorize-no-database-server-required-5a9l)
- #282 — TestFlight/APK distribution
