import type Database from "better-sqlite3";
import type { Tag, ToolDef } from "./types.js";
import { createTag, getTag } from "./tags.js";
import { registerTool, getTool } from "./tools.js";

// ---- Builtin Tags ----

const BUILTIN_TAGS: Omit<Tag, "createdAt" | "updatedAt">[] = [
  {
    name: "daily-note",
    displayName: "Daily Note",
    description: "A journal entry — text, voice, or handwriting",
    schema: [
      { name: "entry_type", type: "select", options: ["text", "voice", "handwriting"], default: "text" },
      { name: "audio_url", type: "text", description: "URL or path to audio file" },
      { name: "duration_seconds", type: "number" },
      { name: "transcription_status", type: "select", options: ["pending", "processing", "complete", "failed"] },
      { name: "cleanup_status", type: "select", options: ["pending", "processing", "complete", "failed"] },
      { name: "date", type: "date", description: "Journal date (YYYY-MM-DD)" },
    ],
    publishedBy: "parachute-daily",
  },
  {
    name: "card",
    displayName: "Card",
    description: "An AI-generated output — reflection, summary, briefing",
    schema: [
      { name: "card_type", type: "select", options: ["reflection", "summary", "briefing", "default"] },
      { name: "read_at", type: "datetime", description: "When the user read this card" },
      { name: "date", type: "date", description: "Date this card covers" },
    ],
    publishedBy: "parachute-daily",
  },
  {
    name: "person",
    displayName: "Person",
    description: "A person — contact, collaborator, friend",
    schema: [
      { name: "email", type: "text" },
      { name: "role", type: "text" },
      { name: "notes", type: "text" },
    ],
    publishedBy: "parachute-daily",
  },
  {
    name: "project",
    displayName: "Project",
    description: "A project or initiative",
    schema: [
      { name: "status", type: "select", options: ["active", "paused", "complete", "archived"] },
      { name: "deadline", type: "date" },
      { name: "notes", type: "text" },
    ],
    publishedBy: "parachute-daily",
  },
];

// ---- Builtin Tools ----

const BUILTIN_TOOLS: Omit<ToolDef, "createdAt" | "updatedAt">[] = [
  {
    name: "read-daily-notes",
    displayName: "Read Daily Notes",
    description: "Read journal entries for a given date. Returns things tagged daily-note.",
    toolType: "query",
    inputSchema: {
      type: "object",
      properties: {
        date: { type: "string", description: "Date in YYYY-MM-DD format. Defaults to today." },
        limit: { type: "number", description: "Max entries to return", default: 50 },
      },
    },
    definition: {
      action: "query_things",
      tags: ["daily-note"],
      filters: { date: "$date" },
      sort: "created_at:asc",
      limit: "$limit",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "read-recent-notes",
    displayName: "Read Recent Notes",
    description: "Read journal entries from the past N days.",
    toolType: "query",
    inputSchema: {
      type: "object",
      properties: {
        since_date: { type: "string", description: "Read entries from this date onward (YYYY-MM-DD)" },
        limit: { type: "number", default: 100 },
      },
    },
    definition: {
      action: "query_things",
      tags: ["daily-note"],
      filters: { created_at: { gte: "$since_date" } },
      sort: "created_at:desc",
      limit: "$limit",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "search-notes",
    displayName: "Search Notes",
    description: "Full-text search across journal entries.",
    toolType: "query",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search query" },
        tags: { type: "array", items: { type: "string" }, description: "Optional tag filter" },
        limit: { type: "number", default: 20 },
      },
      required: ["query"],
    },
    definition: {
      action: "search_things",
      query: "$query",
      tags: "$tags",
      limit: "$limit",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "write-card",
    displayName: "Write Card",
    description: "Write an output card (reflection, summary, briefing).",
    toolType: "mutation",
    inputSchema: {
      type: "object",
      properties: {
        content: { type: "string", description: "Card content (markdown)" },
        card_type: { type: "string", description: "Card type", default: "reflection" },
        date: { type: "string", description: "Date this card covers (YYYY-MM-DD)" },
      },
      required: ["content"],
    },
    definition: {
      action: "upsert_thing",
      id_template: "$card_type:$date",
      content: "$content",
      created_by: "tool:write-card",
      tags: { card: { card_type: "$card_type", date: "$date" } },
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "read-cards",
    displayName: "Read Cards",
    description: "Read AI-generated cards, optionally filtered by date or type.",
    toolType: "query",
    inputSchema: {
      type: "object",
      properties: {
        date: { type: "string", description: "Filter by date (YYYY-MM-DD)" },
        limit: { type: "number", default: 20 },
      },
    },
    definition: {
      action: "query_things",
      tags: ["card"],
      filters: { date: "$date" },
      sort: "created_at:desc",
      limit: "$limit",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "read-recent-cards",
    displayName: "Read Recent Cards",
    description: "Read cards from the past N days for continuity.",
    toolType: "query",
    inputSchema: {
      type: "object",
      properties: {
        since_date: { type: "string", description: "Read cards from this date onward" },
        card_type: { type: "string", description: "Filter by card type" },
        limit: { type: "number", default: 10 },
      },
    },
    definition: {
      action: "query_things",
      tags: ["card"],
      filters: { created_at: { gte: "$since_date" } },
      sort: "created_at:desc",
      limit: "$limit",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "create-thing",
    displayName: "Create Thing",
    description: "Create a new thing in the graph with optional tags.",
    toolType: "mutation",
    inputSchema: {
      type: "object",
      properties: {
        content: { type: "string", description: "Thing content" },
        tags: {
          type: "object",
          description: "Tags to apply: { tagName: { field: value, ... } }",
          additionalProperties: { type: "object" },
        },
      },
      required: ["content"],
    },
    definition: {
      action: "upsert_thing",
      content: "$content",
      tags: "$tags",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "update-thing",
    displayName: "Update Thing",
    description: "Update an existing thing's content.",
    toolType: "mutation",
    inputSchema: {
      type: "object",
      properties: {
        thing_id: { type: "string", description: "ID of the thing to update" },
        content: { type: "string", description: "New content" },
      },
      required: ["thing_id"],
    },
    definition: {
      action: "update_thing",
      id: "$thing_id",
      content: "$content",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "link-things",
    displayName: "Link Things",
    description: "Create a relationship between two things (e.g. note mentions person).",
    toolType: "mutation",
    inputSchema: {
      type: "object",
      properties: {
        source_id: { type: "string", description: "Source thing ID" },
        target_id: { type: "string", description: "Target thing ID" },
        relationship: { type: "string", description: "Relationship type (e.g. mentions, has-collaborator)" },
      },
      required: ["source_id", "target_id", "relationship"],
    },
    definition: {
      action: "create_edge",
      source: "$source_id",
      target: "$target_id",
      relationship: "$relationship",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "get-related",
    displayName: "Get Related",
    description: "Find things related to a given thing via edges.",
    toolType: "query",
    inputSchema: {
      type: "object",
      properties: {
        thing_id: { type: "string", description: "Thing to find relations for" },
        relationship: { type: "string", description: "Filter by relationship type" },
        direction: { type: "string", enum: ["outbound", "inbound", "both"], default: "both" },
      },
      required: ["thing_id"],
    },
    definition: {
      action: "query_edges",
      from: "$thing_id",
      edge: "$relationship",
      direction: "$direction",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
  {
    name: "search-graph",
    displayName: "Search Graph",
    description: "Traverse the graph from a starting thing, following edges to find connected things.",
    toolType: "query",
    inputSchema: {
      type: "object",
      properties: {
        thing_id: { type: "string", description: "Starting thing ID" },
        edge: { type: "string", description: "Edge type to follow" },
        direction: { type: "string", enum: ["outbound", "inbound", "both"], default: "outbound" },
        depth: { type: "number", description: "Max traversal depth", default: 1 },
        target_tags: { type: "array", items: { type: "string" }, description: "Filter results by tag" },
        limit: { type: "number", default: 50 },
      },
      required: ["thing_id"],
    },
    definition: {
      action: "traverse",
      from: "$thing_id",
      edge: "$edge",
      direction: "$direction",
      depth: "$depth",
      target_tags: "$target_tags",
      limit: "$limit",
    },
    publishedBy: "parachute-daily",
    enabled: true,
  },
];

/**
 * Seed builtin tags and tools. Idempotent — skips if already present.
 */
export function seedBuiltins(db: Database.Database): void {
  for (const tag of BUILTIN_TAGS) {
    if (!getTag(db, tag.name)) {
      createTag(db, tag);
    }
  }

  for (const tool of BUILTIN_TOOLS) {
    if (!getTool(db, tool.name)) {
      registerTool(db, tool);
    }
  }
}

export { BUILTIN_TAGS, BUILTIN_TOOLS };
