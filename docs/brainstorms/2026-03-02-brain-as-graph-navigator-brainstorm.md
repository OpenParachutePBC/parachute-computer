---
title: "Brain as graph navigator — unified memory layer across modules"
date: 2026-03-02
status: Brainstorm
priority: P1
modules: brain, chat, daily, app
tags: [brain, graph, navigation, architecture, cross-module]
---

# Brain as graph navigator — unified memory layer across modules

## What We're Building

A reorientation of how Brain fits into Parachute:

- **Brain module** keeps its current job: owning and managing `Brain_Entity` nodes
  (people, projects, ideas — explicit, named knowledge). Nothing changes here.

- **Brain UI** evolves from an entity list into a **graph navigator** — the primary
  interface for exploring the entire Kuzu knowledge graph across all three modules.
  Brain entities are the anchor points. From any entity, you can traverse to the
  journal entries that mentioned it, the chat sessions that discussed it, and the
  relationships connecting it to other entities.

- **Cross-module graph edges** are the new thing that makes this possible. Right now
  `brain_links_json` on `Journal_Entry` hints at connections but they're JSON blobs, not
  real Kuzu relationships. Making them actual edges unlocks graph traversal.

## The Three Layers

| Layer | Owns | Role |
|-------|------|------|
| Brain module | `Brain_Entity` nodes | Named, curated knowledge anchors |
| Daily module | `Journal_Entry`, `Day` nodes | Timestamped capture and reflection |
| Chat module | `Chat_Session`, `Chat_Exchange` nodes | Conversation and agent history |
| Containers | Docker environments | Execution — separate from memory |

The Kuzu graph DB unifies all three memory layers in one queryable store. Brain entities
are the connective tissue that links daily and chat data to named concepts.

## Why This Framing

The power of a knowledge graph is in the **relationships**, not just the nodes. Knowing
that "Woven Web" is a project entity is useful. Knowing which journal entries mentioned
it, which chat sessions explored it, and who's been working on it is the extended mind.

Brain entities are the entry points that make traversal meaningful for everyday users —
you start with something named, then explore outward. A raw table of all `Journal_Entry`
nodes would be overwhelming; a `Woven Web` entity that surfaces its 12 related journal
entries and 3 chat sessions is comprehensible.

This also resolves the UI ambiguity: Brain isn't just an "entity browser," it's how you
navigate your memory. The name makes sense at both levels — Brain module manages entities,
Brain screen navigates everything.

## What Needs to Be Built

### 1. Cross-module edges in Kuzu

New relationship types connecting Brain_Entity to other modules:

```
MENTIONED_IN: Brain_Entity → Journal_Entry
DISCUSSED_IN: Brain_Entity → Chat_Exchange
```

**Creation paths:**
- **Import backfill**: `_migrate_from_markdown()` already populates `brain_links_json` on
  entries — convert those to real Kuzu edges on import
- **Live writes**: When a journal entry or chat exchange is created, parse for entity
  mentions and write edges
- **Manual tagging**: Let the user explicitly link an entity to an entry from the Brain UI
- **Agent writes**: Brain/bridge agent can create edges when it detects relevant connections

Open question: how much of this is automatic vs. manual vs. agent-driven? Start manual
(user-initiated), layer in automation later (YAGNI).

### 2. Brain UI: graph navigator

**Default view** — Brain entities only. The existing entity type sidebar + entity list +
detail pane stays as-is. This serves everyday users who just want to manage their
knowledge.

**"Show all modules" toggle** — a simple switch on the Brain screen that expands the
sidebar to also show `Journal_Entry` and `Chat_Session` node tables. When enabled, you
can browse Daily and Chat nodes directly alongside Brain entities. This is the power-user
window into the full Kuzu graph without cluttering the default experience.

**Entity detail pane** — gains a "Related" section showing nodes connected via cross-module
edges:
- **Journal entries that mention this** — `MENTIONS` edges, sorted by date, snippet preview
- **Related entities** — existing `Brain_Relationship` edges (already in graph)
- (Chat edges deferred — see open question 4)

Navigation is bidirectional: tap a journal entry preview → deep link into Daily.

### 4. Container workspace UI (connected but separate track)

The container-per-chat execution architecture is fully shipped (#145). What's missing is
the Flutter UI: named env picker on chat startup, named env management screen, visual
indicator on sessions. This is tracked in #146 and should be prioritized alongside the
Brain graph work — they're both about making the architecture visible to the user.

## Issue Cleanup

With this reorientation, existing issues need reassessment:

- **#134 (Brain Phase 4 — dedup, vector search)**: Premature. Entity deduplication only
  matters at volume, and there are very few Brain_Entity writes happening yet. Deprioritize
  or close. Reopen when entity writes become frequent.

- **#141 (Brain agent for intelligent graph operations)**: Still relevant but reframe.
  The brain agent's job isn't just Brain_Entity management — it's intelligently creating
  cross-module edges (deciding when a journal entry relates to an entity, resolving
  ambiguous mentions). Repurpose this issue around cross-module edge intelligence.

- **#146 (Container env future work)**: Still fully relevant. The persistent scratch
  volumes, Flutter named env UI, and tools installer are all valid next-up work.

## Open Questions

1. **Edge creation trigger**: Automatic (on write, parse for mentions), manual (user tags),
   or agent-driven (bridge/brain agent decides)? Probably start manual.

2. **Traversal depth**: Does the Brain UI show 1-hop relationships only, or deeper?
   (Entry → Entity → related entries?) Keep shallow for now.

3. **`brain_links_json` migration**: Convert existing JSON blobs to real Kuzu edges as
   part of the next import pass? Yes — this is the quick win that immediately populates
   the graph with cross-module edges from existing journal data.

4. **Chat edges**: Chat exchanges reference entities more loosely than journal entries.
   Do we create `DISCUSSED_IN` edges from Chat_Exchange to Brain_Entity? Or only from
   Journal_Entry for now? Start with Journal_Entry (simpler, more intentional data).

5. **Container workspace UI priority**: Should the named env Flutter UI (#146) come before
   or alongside the Brain graph navigator work? They're independent — can be parallelized.

**Issue:** #163

