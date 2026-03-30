import { describe, it, expect, beforeEach } from "vitest";
import Database from "better-sqlite3";
import { SqliteStore } from "./store.js";
import type { Thing, Edge } from "./types.js";
import { validateFieldValues } from "./tags.js";
import { BUILTIN_TAGS, BUILTIN_TOOLS } from "./seed.js";

let store: SqliteStore;

beforeEach(() => {
  const db = new Database(":memory:");
  store = new SqliteStore(db);
});

// ---- Schema & Seed ----

describe("schema and seed", () => {
  it("creates all tables", () => {
    const tables = store.db
      .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
      .all() as { name: string }[];
    const names = tables.map((t) => t.name);
    expect(names).toContain("things");
    expect(names).toContain("tags");
    expect(names).toContain("thing_tags");
    expect(names).toContain("edges");
    expect(names).toContain("tools");
    expect(names).toContain("schema_version");
  });

  it("seeds builtin tags", () => {
    for (const tag of BUILTIN_TAGS) {
      const found = store.getTag(tag.name);
      expect(found).not.toBeNull();
      expect(found!.displayName).toBe(tag.displayName);
    }
  });

  it("seeds builtin tools", () => {
    for (const tool of BUILTIN_TOOLS) {
      const found = store.getTool(tool.name);
      expect(found).not.toBeNull();
      expect(found!.description).toBe(tool.description);
    }
  });

  it("is idempotent — double init does not error", () => {
    // Create a second store on the same DB
    const store2 = new SqliteStore(store.db);
    expect(store2.listTags().length).toBeGreaterThan(0);
  });
});

// ---- Things CRUD ----

describe("things", () => {
  it("creates a thing with content", () => {
    const thing = store.createThing("Hello world");
    expect(thing.id).toBeTruthy();
    expect(thing.content).toBe("Hello world");
    expect(thing.status).toBe("active");
    expect(thing.createdBy).toBe("user");
  });

  it("creates a thing with custom ID and tags", () => {
    const thing = store.createThing("Voice entry", {
      id: "2026-03-30-09-15-00-000000",
      tags: [{ name: "daily-note", fields: { entry_type: "voice", date: "2026-03-30" } }],
      createdBy: "app",
    });
    expect(thing.id).toBe("2026-03-30-09-15-00-000000");
    expect(thing.createdBy).toBe("app");
    expect(thing.tags).toHaveLength(1);
    expect(thing.tags![0].tagName).toBe("daily-note");
    expect(thing.tags![0].fieldValues.entry_type).toBe("voice");
  });

  it("gets a thing by ID with tags", () => {
    const created = store.createThing("Test", {
      tags: [{ name: "daily-note", fields: { entry_type: "text" } }],
    });
    const found = store.getThing(created.id);
    expect(found).not.toBeNull();
    expect(found!.tags).toHaveLength(1);
  });

  it("returns null for missing thing", () => {
    expect(store.getThing("nonexistent")).toBeNull();
  });

  it("updates thing content", () => {
    const thing = store.createThing("Original");
    const updated = store.updateThing(thing.id, { content: "Updated" });
    expect(updated.content).toBe("Updated");
    expect(updated.updatedAt).toBeTruthy();
  });

  it("updates thing status", () => {
    const thing = store.createThing("To archive");
    const updated = store.updateThing(thing.id, { status: "archived" });
    expect(updated.status).toBe("archived");
  });

  it("replaces tags on update", () => {
    const thing = store.createThing("Tagged", {
      tags: [{ name: "daily-note", fields: { entry_type: "text" } }],
    });
    const updated = store.updateThing(thing.id, {
      tags: [{ name: "card", fields: { card_type: "reflection" } }],
    });
    expect(updated.tags).toHaveLength(1);
    expect(updated.tags![0].tagName).toBe("card");
  });

  it("deletes a thing and cascades", () => {
    const thing = store.createThing("Delete me", {
      tags: [{ name: "daily-note" }],
    });
    store.deleteThing(thing.id);
    expect(store.getThing(thing.id)).toBeNull();
    // Tags should be gone too
    expect(store.getThingTags(thing.id)).toHaveLength(0);
  });
});

// ---- Query Things ----

describe("queryThings", () => {
  beforeEach(() => {
    store.createThing("Morning walk", {
      id: "2026-03-30-08-00-00-000000",
      tags: [{ name: "daily-note", fields: { entry_type: "text", date: "2026-03-30" } }],
    });
    store.createThing("Afternoon meeting", {
      id: "2026-03-30-14-00-00-000000",
      tags: [
        { name: "daily-note", fields: { entry_type: "voice", date: "2026-03-30" } },
      ],
    });
    store.createThing("Yesterday reflection", {
      id: "2026-03-29-20-00-00-000000",
      tags: [{ name: "card", fields: { card_type: "reflection", date: "2026-03-29" } }],
    });
  });

  it("queries by tag", () => {
    const notes = store.queryThings({ tags: ["daily-note"] });
    expect(notes).toHaveLength(2);
  });

  it("queries by multiple tags (AND)", () => {
    // Tag one note with an extra tag
    store.tagThing("2026-03-30-08-00-00-000000", "person", {});
    const results = store.queryThings({ tags: ["daily-note", "person"] });
    expect(results).toHaveLength(1);
  });

  it("queries with field filter", () => {
    const results = store.queryThings({
      tags: ["daily-note"],
      filters: { entry_type: "voice" },
    });
    expect(results).toHaveLength(1);
    expect(results[0].content).toBe("Afternoon meeting");
  });

  it("queries with date range filter on tag field", () => {
    const results = store.queryThings({
      tags: ["daily-note"],
      filters: { date: "2026-03-30" },
    });
    expect(results).toHaveLength(2);
  });

  it("respects sort and limit", () => {
    const results = store.queryThings({
      tags: ["daily-note"],
      sort: "id:desc",
      limit: 1,
    });
    expect(results).toHaveLength(1);
    // ID "2026-03-30-14-..." sorts after "2026-03-30-08-..."
    expect(results[0].content).toBe("Afternoon meeting");
  });
});

// ---- Full-Text Search ----

describe("searchThings", () => {
  beforeEach(() => {
    store.createThing("Walked up Flagstaff trail with Alice", {
      tags: [{ name: "daily-note", fields: { entry_type: "text" } }],
    });
    store.createThing("Met with Bob about the Horizon project", {
      tags: [{ name: "daily-note", fields: { entry_type: "text" } }],
    });
    store.createThing("Today was a good day for reflection", {
      tags: [{ name: "card", fields: { card_type: "reflection" } }],
    });
  });

  it("searches by content", () => {
    const results = store.searchThings("Flagstaff");
    expect(results).toHaveLength(1);
    expect(results[0].content).toContain("Flagstaff");
  });

  it("searches with tag filter", () => {
    const results = store.searchThings("reflection", { tags: ["card"] });
    expect(results).toHaveLength(1);
  });

  it("returns empty for no match", () => {
    const results = store.searchThings("nonexistent-term-xyz");
    expect(results).toHaveLength(0);
  });
});

// ---- Tags ----

describe("tags", () => {
  it("creates and retrieves a custom tag", () => {
    const tag = store.createTag({
      name: "meeting",
      displayName: "Meeting",
      description: "A meeting note",
      schema: [{ name: "attendees", type: "text" }],
    });
    expect(tag.name).toBe("meeting");
    expect(tag.schema).toHaveLength(1);

    const found = store.getTag("meeting");
    expect(found!.schema[0].name).toBe("attendees");
  });

  it("lists tags with counts", () => {
    store.createThing("Note 1", { tags: [{ name: "daily-note" }] });
    store.createThing("Note 2", { tags: [{ name: "daily-note" }] });
    const allTags = store.listTags();
    const dailyNote = allTags.find((t) => t.name === "daily-note");
    expect(dailyNote!.count).toBe(2);
  });

  it("updates a tag", () => {
    store.updateTag("daily-note", { description: "Updated description" });
    const tag = store.getTag("daily-note");
    expect(tag!.description).toBe("Updated description");
  });

  it("tags and untags a thing", () => {
    const thing = store.createThing("Test");
    store.tagThing(thing.id, "daily-note", { entry_type: "text" });
    expect(store.getThingTags(thing.id)).toHaveLength(1);

    store.untagThing(thing.id, "daily-note");
    expect(store.getThingTags(thing.id)).toHaveLength(0);
  });
});

// ---- Tag Validation ----

describe("validateFieldValues", () => {
  const schema = BUILTIN_TAGS.find((t) => t.name === "daily-note")!.schema;

  it("accepts valid values", () => {
    const errors = validateFieldValues(schema, { entry_type: "voice", duration_seconds: 120 });
    expect(errors).toHaveLength(0);
  });

  it("rejects invalid select value", () => {
    const errors = validateFieldValues(schema, { entry_type: "invalid" });
    expect(errors.length).toBeGreaterThan(0);
    expect(errors[0]).toContain("not in options");
  });

  it("rejects wrong type", () => {
    const errors = validateFieldValues(schema, { duration_seconds: "not a number" });
    expect(errors.length).toBeGreaterThan(0);
  });

  it("rejects unknown field", () => {
    const errors = validateFieldValues(schema, { unknown_field: "value" });
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("Unknown field");
  });
});

// ---- Edges ----

describe("edges", () => {
  let noteId: string;
  let personId: string;
  let projectId: string;

  beforeEach(() => {
    const note = store.createThing("Met with Alice about Horizon", {
      tags: [{ name: "daily-note" }],
    });
    noteId = note.id;

    const person = store.createThing("Alice", {
      id: "alice",
      tags: [{ name: "person", fields: { role: "engineer" } }],
    });
    personId = person.id;

    const project = store.createThing("Horizon", {
      id: "horizon",
      tags: [{ name: "project", fields: { status: "active" } }],
    });
    projectId = project.id;
  });

  it("creates an edge", () => {
    const edge = store.createEdge(noteId, personId, "mentions");
    expect(edge.sourceId).toBe(noteId);
    expect(edge.targetId).toBe(personId);
    expect(edge.relationship).toBe("mentions");
  });

  it("is idempotent — duplicate edge is ignored", () => {
    store.createEdge(noteId, personId, "mentions");
    store.createEdge(noteId, personId, "mentions"); // no error
    const edges = store.getEdges(noteId, { direction: "outbound" });
    const mentions = edges.filter(
      (e) => e.targetId === personId && e.relationship === "mentions",
    );
    expect(mentions).toHaveLength(1);
  });

  it("allows multiple relationship types between same things", () => {
    store.createEdge(noteId, personId, "mentions");
    store.createEdge(noteId, personId, "assigned-to");
    const edges = store.getEdges(noteId, { direction: "outbound" });
    expect(edges).toHaveLength(2);
  });

  it("gets edges by direction", () => {
    store.createEdge(noteId, personId, "mentions");
    store.createEdge(projectId, personId, "has-collaborator");

    const outbound = store.getEdges(noteId, { direction: "outbound" });
    expect(outbound).toHaveLength(1);

    const inbound = store.getEdges(personId, { direction: "inbound" });
    expect(inbound).toHaveLength(2);

    const both = store.getEdges(personId, { direction: "both" });
    expect(both).toHaveLength(2);
  });

  it("filters edges by relationship", () => {
    store.createEdge(noteId, personId, "mentions");
    store.createEdge(noteId, projectId, "mentions");
    store.createEdge(projectId, personId, "has-collaborator");

    const mentions = store.getEdges(noteId, {
      direction: "outbound",
      relationship: "mentions",
    });
    expect(mentions).toHaveLength(2);
  });

  it("deletes an edge", () => {
    store.createEdge(noteId, personId, "mentions");
    store.deleteEdge(noteId, personId, "mentions");
    const edges = store.getEdges(noteId);
    expect(edges).toHaveLength(0);
  });

  it("cascades edge deletion when thing is deleted", () => {
    store.createEdge(noteId, personId, "mentions");
    store.deleteThing(noteId);
    const edges = store.getEdges(personId, { direction: "inbound" });
    expect(edges).toHaveLength(0);
  });
});

// ---- Traversal ----

describe("traverse", () => {
  beforeEach(() => {
    // Build a small graph:
    // note1 --mentions--> Alice --collaborates-on--> Horizon
    // note1 --mentions--> Horizon
    store.createThing("Meeting notes", {
      id: "note1",
      tags: [{ name: "daily-note" }],
    });
    store.createThing("Alice", {
      id: "alice",
      tags: [{ name: "person" }],
    });
    store.createThing("Horizon", {
      id: "horizon",
      tags: [{ name: "project" }],
    });

    store.createEdge("note1", "alice", "mentions");
    store.createEdge("note1", "horizon", "mentions");
    store.createEdge("alice", "horizon", "collaborates-on");
  });

  it("traverses 1 hop outbound", () => {
    const results = store.traverse("note1", { direction: "outbound", depth: 1 });
    expect(results).toHaveLength(2);
    const ids = results.map((r) => r.id).sort();
    expect(ids).toEqual(["alice", "horizon"]);
  });

  it("traverses 2 hops outbound", () => {
    const results = store.traverse("note1", { direction: "outbound", depth: 2 });
    // note1 -> alice, horizon (depth 1), alice -> horizon (depth 2, already visited)
    expect(results).toHaveLength(2);
  });

  it("traverses with edge filter", () => {
    const results = store.traverse("note1", {
      edge: "mentions",
      direction: "outbound",
      depth: 1,
    });
    expect(results).toHaveLength(2);
  });

  it("traverses with target tag filter", () => {
    const results = store.traverse("note1", {
      direction: "outbound",
      depth: 1,
      targetTags: ["person"],
    });
    expect(results).toHaveLength(1);
    expect(results[0].id).toBe("alice");
  });

  it("traverses inbound", () => {
    const results = store.traverse("horizon", {
      direction: "inbound",
      depth: 1,
    });
    const ids = results.map((r) => r.id).sort();
    expect(ids).toEqual(["alice", "note1"]);
  });

  it("returns things with tags attached", () => {
    const results = store.traverse("note1", {
      direction: "outbound",
      depth: 1,
      targetTags: ["person"],
    });
    expect(results[0].tags).toBeDefined();
    expect(results[0].tags!.some((t) => t.tagName === "person")).toBe(true);
  });
});

// ---- Tool Execution ----

describe("tool execution", () => {
  beforeEach(() => {
    store.createThing("Morning walk in the park", {
      id: "entry-1",
      tags: [{ name: "daily-note", fields: { entry_type: "text", date: "2026-03-30" } }],
    });
    store.createThing("Afternoon coding session", {
      id: "entry-2",
      tags: [{ name: "daily-note", fields: { entry_type: "text", date: "2026-03-30" } }],
    });
  });

  it("executes read-daily-notes tool", () => {
    const results = store.executeTool("read-daily-notes", {
      date: "2026-03-30",
    }) as Thing[];
    expect(results).toHaveLength(2);
  });

  it("executes search-notes tool", () => {
    const results = store.executeTool("search-notes", {
      query: "park",
    }) as Thing[];
    expect(results).toHaveLength(1);
    expect(results[0].content).toContain("park");
  });

  it("executes write-card tool", () => {
    const result = store.executeTool("write-card", {
      content: "Today was productive",
      card_type: "reflection",
      date: "2026-03-30",
    }) as Thing;
    expect(result.content).toBe("Today was productive");
    expect(result.tags!.some((t) => t.tagName === "card")).toBe(true);
  });

  it("executes create-thing tool", () => {
    const result = store.executeTool("create-thing", {
      content: "Alice",
      tags: { person: { role: "engineer" } },
    }) as Thing;
    expect(result.content).toBe("Alice");
    expect(result.tags!.some((t) => t.tagName === "person")).toBe(true);
  });

  it("executes link-things tool", () => {
    const alice = store.createThing("Alice", { id: "alice", tags: [{ name: "person" }] });
    const edge = store.executeTool("link-things", {
      source_id: "entry-1",
      target_id: "alice",
      relationship: "mentions",
    }) as Edge;
    expect(edge.sourceId).toBe("entry-1");
    expect(edge.targetId).toBe("alice");
  });

  it("executes get-related tool", () => {
    store.createThing("Alice", { id: "alice", tags: [{ name: "person" }] });
    store.createEdge("entry-1", "alice", "mentions");
    const edges = store.executeTool("get-related", {
      thing_id: "entry-1",
      direction: "outbound",
    }) as Edge[];
    expect(edges).toHaveLength(1);
    expect(edges[0].relationship).toBe("mentions");
  });

  it("throws for disabled tool", () => {
    // Disable a tool
    store.db
      .prepare("UPDATE tools SET enabled = 'false' WHERE name = ?")
      .run("read-daily-notes");
    expect(() => store.executeTool("read-daily-notes", {})).toThrow("disabled");
  });

  it("throws for unknown tool", () => {
    expect(() => store.executeTool("nonexistent", {})).toThrow("not found");
  });
});

// ---- MCP Generation ----

describe("MCP generation", () => {
  it("generates MCP tools from database", async () => {
    const { generateMcpTools } = await import("./mcp.js");
    const mcpTools = generateMcpTools(store.db);
    expect(mcpTools.length).toBeGreaterThan(0);

    const readNotes = mcpTools.find((t) => t.name === "read-daily-notes");
    expect(readNotes).toBeDefined();
    expect(readNotes!.description).toContain("journal entries");
    expect(readNotes!.inputSchema).toBeDefined();
    expect(typeof readNotes!.execute).toBe("function");
  });

  it("MCP tool execute works end-to-end", async () => {
    store.createThing("Test note", {
      tags: [{ name: "daily-note", fields: { date: "2026-03-30" } }],
    });

    const { generateMcpTools } = await import("./mcp.js");
    const mcpTools = generateMcpTools(store.db);
    const readNotes = mcpTools.find((t) => t.name === "read-daily-notes")!;
    const results = readNotes.execute({ date: "2026-03-30" }) as Thing[];
    expect(results).toHaveLength(1);
  });
});
