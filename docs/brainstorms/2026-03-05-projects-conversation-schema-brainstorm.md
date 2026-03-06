# Brainstorm: Projects + Conversation Schema Unification

**Date:** 2026-03-05
**Status:** Brainstorm
**Priority:** P1
**Tags:** graph, schema, chat, computer, app
**Issue:** #196

---

## What We're Building

A unified, cleaner graph schema built around three core concepts:

1. **Project** — a named execution environment (Docker container) with shared artifacts and a `core_memory` system prompt. Groups related conversations together.
2. **Conversation** — a single chat session (consolidates the current `Parachute_Session` + `Chat_Session` duplication into one table).
3. **Exchange** — a single user↔AI turn within a conversation.

Plus two simplifications:
- Drop the `Day` node table — query `Note` and `Card` directly by `date` field.
- Rename `Journal_Entry` → `Note` — more flexible, not Daily-specific. Most notes will have `note_type: "journal"` but notes can be other things (meeting notes, reference notes, etc.).

---

## Why This Approach

After today's major refactors (graph as core infra, Brain module dissolved, storage restructured), the schema has some friction:

- `Parachute_Session` and `Chat_Session` are duplicates — same `session_id` PK, thin vs. fat versions of the same concept. Every chat conversation writes two rows.
- `Parachute_ContainerEnv` (slug, display_name, created_at) is underweight — it's almost a Project but missing the identity and memory fields that would make it one.
- `Day` nodes exist purely as grouping keys — `Journal_Entry` and `Card` both have a `date` field; filtering by date is simpler than maintaining a node table.
- `Journal_Entry` is too Daily-specific — calling it `Note` makes the type flexible and composable with the rest of the graph.
- The terminology (`Parachute_Session`, `Chat_Session`, `Chat_Exchange`) doesn't match the mental model (conversations, exchanges, projects).

---

## Key Decisions

### 1. Project = Container (upgraded)

`Parachute_ContainerEnv` is renamed to `Project` and gains:
- `core_memory` (TEXT) — markdown field that injects into the system prompt for any conversation in this project
- All existing fields retained: `slug` (PK), `display_name`, `created_at`

A Project is: a named Docker container + shared filesystem + system prompt context + organizational unit for conversations. The container file browser (PRs #184/#186) becomes the "Project Files" browser.

### 2. Conversation = merged Parachute_Session + Chat_Session

`Chat_Session` is dropped entirely. `Parachute_Session` is renamed to `Conversation`.

- `project_id` (nullable STRING) added — references `Project.slug`. NULL = personal/ephemeral conversation with no shared project.
- `HAS_EXCHANGE` rel updated: `Conversation →[HAS_EXCHANGE]→ Exchange`
- All existing fields on `Parachute_Session` carry over (trust_level, source, model, tags_json, etc.)

### 3. Exchange = renamed Chat_Exchange

`Chat_Exchange` is renamed to `Exchange`. No field changes — just a naming cleanup.

### 4. Null project is fine

Conversations without a project are first-class — personal sessions, daily agent runs, bot sessions. No default project needed.

### 5. Journal_Entry → Note

`Journal_Entry` is renamed to `Note` with a `note_type` field (e.g., `"journal"`, `"meeting"`, `"reference"`). The Daily module writes notes with `note_type: "journal"` by default. The rename makes the type broadly useful across the system — not just for daily journaling.

### 6. Drop Day node table

`Day → HAS_ENTRY → Journal_Entry` and `Day → HAS_CARD → Card` relationships are removed. Queries filter `Note` and `Card` directly by `date` field. Simpler schema, same query power.

### 7. Conversation list UI filters by default, but can show all

The `Conversation` table now stores every session type — user chats, daily agent runs, bot sessions, background agents. The Chat UI filters to human-initiated chat sessions by default (e.g., `source = "parachute"` or `agent_type = "orchestrator"`). But it's possible to zoom out and view all conversations, including agent runs — which gives real transparency into what the system is doing. The Brain/graph tab becomes the natural place to see everything unfiltered.

---

## Resulting Schema

```
Project (slug PK, display_name, core_memory, created_at)
  └─[HAS_CONVERSATION]→ Conversation  (was Parachute_Session + Chat_Session)
                            └─[HAS_EXCHANGE]→ Exchange  (was Chat_Exchange)

Note (name, date, note_type, content, audio_path, aliases, status, created_by, created_at, ...)   (was Journal_Entry)
Card (date, agent_name, display_name, content, status, ...)
Caller (agent definitions — name, system_prompt, tools, schedule, model)
Parachute_PairingRequest (bot authorization — platform, status, trust_level)
```

No more `Day`, `Journal_Entry`, `Brain_Entity`, `Brain_Relationship`, or `Chat_Session` tables.

---

## Deeper Reasoning

### Why Project works as a primitive

People come to their AI/journal to *progress* something. "Eating healthier," "improving my relationships," "building Parachute" — these are all projects in the same sense. A Project isn't a software concept, it's a cognitive unit: something with intention, memory, and accumulated work. The `core_memory` field is the distillation of that — what this project is, what matters, what's been decided. Any conversation started in a project inherits that context automatically.

### Why Note works as a primitive

Everything in Obsidian is a markdown note with a name. A note *can* represent a person, a concept, a decision, an idea — without needing a special Entity type. The daily journal is just a stream of notes tagged by date. Meeting notes, reference notes, voice memos — all just notes with a `note_type`. This means:
- **Obsidian vaults import natively** — a vault is just a folder of named markdown notes. Parachute's Note table is structurally identical.
- **Entity emerges from notes** — a note named "John" with rich content *is* a person entity. We don't need an explicit Entity primitive yet. It can be added later as a typed view over notes when the use case demands it.

### The full picture

Parachute is becoming a system with three natural layers:
- **Doing layer**: Projects → Conversations → Exchanges (getting things done, with AI)
- **Capturing layer**: Notes (markdown, typed, dated — journal, meeting, idea, reference)
- **Automation layer**: Callers → Cards (scheduled agents, their outputs)

These three layers are coherent, minimal, and composable. They cover the main reasons someone opens their AI: to *work*, to *capture*, or to *understand what's happening*.

### Validation from the PKM landscape

Research across Obsidian, Roam, Logseq, Tana, Notion, Mem.ai, Letta, and Claude Projects validates this direction:

- **Note-as-primitive is the most proven PKM pattern** — Obsidian (the most widely used PKM tool) uses it. Parachute's `Note` with `note_type` and date fields is structurally identical to an Obsidian vault. Whole Obsidian vaults import as a directory walk + frontmatter parse + Note MERGE.

- **Project with `core_memory` is genuinely novel** — No PKM system does this. It combines PARA's organizational insight (projects as progress-oriented buckets), Claude Projects' persistent instruction injection, and Letta's bounded memory-block architecture into one primitive. The Docker container binding makes it an *active* cognitive environment, not just a folder. **Letta recommends a soft size limit (2,000–4,000 chars) on memory blocks** to force distillation and prevent the field becoming a grab-bag.

- **Conversation-as-graph-node is ahead of the market** — Consumer AI (ChatGPT, Claude) treats conversations as blobs. `Conversation → Exchange` as Kuzu nodes enables structural queries no other consumer system supports. The value fully unlocks when a bridge agent extracts knowledge from exchanges into Notes and relationships.

### Note → Entity emergence: when it works and when it breaks

The Obsidian community uses "entity notes" extensively — a note named `John Smith` with rich content and backlinks *is* a person entity without needing a `Person` table. This pattern works until:
1. You need structured queries (filter people by company)
2. Deduplication becomes critical ("John" vs "John Smith" vs "John from Acme")
3. Type enforcement matters (all person notes must have a `role` field)

These pain points typically appear at scale (thousands of notes) and can be addressed then by adding typed entity tables as views over notes, with notes remaining the source of truth.

### What note-first systems are eventually forced to add

In order of urgency:
1. **`LINKS_TO` relationship** — wikilinks in note content (`[[Note Name]]`) must be parsed into graph edges or you have documents, not a graph. Two-pass import: create Note nodes, then parse links into `LINKS_TO` rels.
2. **`aliases` field on Note** — critical for deduplication and wikilink resolution. A note named "John Smith" with `aliases: ["John", "J. Smith"]` ensures all internal links resolve correctly.
3. **`status` field on Note** — draft, active, archived, evergreen. Without it, old notes accumulate without a way to distinguish live working notes from historical ones.
4. **`Note → Note` parent/child relationship** — hierarchy emerges naturally (folders in Obsidian, nesting in Tana). Not urgent but needed at scale.

### Active risks

1. **Wikilinks without graph edges** — note content will contain `[[...]]` links. Without a parse step creating `LINKS_TO` rels, the graph has no edges and you lose the core value of a graph database.
2. **Unbounded `core_memory`** — needs a soft character limit to remain useful as a distilled context, not a dump.
3. **Conversation knowledge stays latent** — conversations accumulate as searchable text but don't become graph knowledge without an extraction step. The bridge agent is the primitive that connects the Doing layer to the Capturing layer.
4. **`Note` vs `Card` distinction blurs over time** — add `created_by: "user" | "agent" | "import"` to both. This makes the distinction behavioral (how it was created), not just semantic.

---

## Open Questions

1. **core_memory injection** — ✅ Unblocked by #197 (merged). `_build_system_prompt(mode, ...)` now builds the prompt in layers. `core_memory` adds a `project_memory: Optional[str] = None` parameter that appends a `## Project Context` section after the mode framing (CONVERSE_PROMPT or COCREATE_PROMPT_APPEND) and before context files. The orchestrator loads the Project node via `project_id` on the session and passes `core_memory` through at the `run_streaming()` call site.

2. **Migration strategy** — Kuzu doesn't have native `ALTER TABLE RENAME`. Do we: (a) write new tables + copy data + drop old, or (b) accept that existing graph data in dev keeps old table names until a migration script runs? Production migration plan needed.

3. **HAS_CONVERSATION rel vs. project_id field** — A `project_id` field on `Conversation` is sufficient for filtering. The `HAS_CONVERSATION` graph rel enables Kuzu traversal queries (`MATCH (p:Project)-[:HAS_CONVERSATION]->(c:Conversation)`). Include the rel for completeness or defer until needed?

4. **Container file browser rename** — PR #186 built the container file browser as "Container Files." Should this be renamed/reframed as "Project Files" in the UI as part of this work?

5. **Conversations without containers** — Daily agent runs, bot sessions, and direct sessions currently have `container_env_id = NULL`. After this change they'd have `project_id = NULL`. The container lifecycle (Docker create/destroy) is unchanged — just the naming.
