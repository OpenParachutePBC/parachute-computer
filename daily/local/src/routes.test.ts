import { describe, it, expect, beforeEach } from "vitest";
import { Hono } from "hono";
import Database from "better-sqlite3";
import { SqliteStore } from "@parachute/core";
import { createRoutes } from "./routes.js";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";

let app: Hono;
let store: SqliteStore;
let assetsDir: string;

beforeEach(() => {
  const db = new Database(":memory:");
  store = new SqliteStore(db);
  assetsDir = fs.mkdtempSync(path.join(os.tmpdir(), "parachute-test-"));

  app = new Hono();
  app.get("/api/health", (c) => c.json({ status: "ok" }));
  app.route("/api", createRoutes(store, assetsDir));
});

async function req(method: string, path: string, body?: unknown) {
  const init: RequestInit = {
    method,
    headers: { "Content-Type": "application/json" },
  };
  if (body) init.body = JSON.stringify(body);
  return app.request(`http://localhost/api${path}`, init);
}

// ---- Health ----

describe("health", () => {
  it("returns ok", async () => {
    const res = await app.request("http://localhost/api/health");
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.status).toBe("ok");
  });
});

// ---- Things CRUD ----

describe("things", () => {
  it("creates a thing", async () => {
    const res = await req("POST", "/things", {
      content: "Morning walk",
      tags: { "daily-note": { entry_type: "text", date: "2026-03-30" } },
    });
    expect(res.status).toBe(201);
    const thing = await res.json();
    expect(thing.content).toBe("Morning walk");
    expect(thing.tags).toHaveLength(1);
    expect(thing.tags[0].tagName).toBe("daily-note");
  });

  it("gets a thing by ID", async () => {
    const createRes = await req("POST", "/things", { content: "Test" });
    const created = await createRes.json();

    const res = await req("GET", `/things/${created.id}`);
    expect(res.status).toBe(200);
    const thing = await res.json();
    expect(thing.id).toBe(created.id);
  });

  it("returns 404 for missing thing", async () => {
    const res = await req("GET", "/things/nonexistent");
    expect(res.status).toBe(404);
  });

  it("updates a thing", async () => {
    const createRes = await req("POST", "/things", { content: "Original" });
    const created = await createRes.json();

    const res = await req("PATCH", `/things/${created.id}`, { content: "Updated" });
    expect(res.status).toBe(200);
    const updated = await res.json();
    expect(updated.content).toBe("Updated");
  });

  it("deletes a thing", async () => {
    const createRes = await req("POST", "/things", { content: "Delete me" });
    const created = await createRes.json();

    const res = await req("DELETE", `/things/${created.id}`);
    expect(res.status).toBe(200);

    const getRes = await req("GET", `/things/${created.id}`);
    expect(getRes.status).toBe(404);
  });

  it("queries things by tag", async () => {
    await req("POST", "/things", {
      content: "Note 1",
      tags: { "daily-note": { date: "2026-03-30" } },
    });
    await req("POST", "/things", {
      content: "Card 1",
      tags: { card: { card_type: "reflection" } },
    });

    const res = await req("GET", "/things?tag=daily-note");
    expect(res.status).toBe(200);
    const things = await res.json();
    expect(things).toHaveLength(1);
    expect(things[0].content).toBe("Note 1");
  });

  it("gets edges for a thing", async () => {
    const noteRes = await req("POST", "/things", { content: "Note" });
    const note = await noteRes.json();
    const personRes = await req("POST", "/things", {
      content: "Alice",
      id: "alice",
      tags: { person: {} },
    });

    await req("POST", "/edges", {
      source_id: note.id,
      target_id: "alice",
      relationship: "mentions",
    });

    const res = await req("GET", `/things/${note.id}/edges?direction=outbound`);
    expect(res.status).toBe(200);
    const edges = await res.json();
    expect(edges).toHaveLength(1);
    expect(edges[0].relationship).toBe("mentions");
  });
});

// ---- Tags ----

describe("tags", () => {
  it("lists builtin tags", async () => {
    const res = await req("GET", "/tags");
    expect(res.status).toBe(200);
    const tags = await res.json();
    expect(tags.length).toBeGreaterThan(0);
    expect(tags.some((t: any) => t.name === "daily-note")).toBe(true);
  });

  it("creates a custom tag", async () => {
    const res = await req("POST", "/tags", {
      name: "meeting",
      display_name: "Meeting",
      description: "A meeting note",
      schema: [{ name: "attendees", type: "text" }],
    });
    expect(res.status).toBe(201);
    const tag = await res.json();
    expect(tag.name).toBe("meeting");
  });

  it("gets a tag by name", async () => {
    const res = await req("GET", "/tags/daily-note");
    expect(res.status).toBe(200);
    const tag = await res.json();
    expect(tag.schema.length).toBeGreaterThan(0);
  });
});

// ---- Edges ----

describe("edges", () => {
  it("creates and deletes an edge", async () => {
    await req("POST", "/things", { content: "A", id: "a" });
    await req("POST", "/things", { content: "B", id: "b" });

    const createRes = await req("POST", "/edges", {
      source_id: "a",
      target_id: "b",
      relationship: "links-to",
    });
    expect(createRes.status).toBe(201);

    const delRes = await req("DELETE", "/edges", {
      source_id: "a",
      target_id: "b",
      relationship: "links-to",
    });
    expect(delRes.status).toBe(200);
  });
});

// ---- Tools ----

describe("tools", () => {
  it("lists builtin tools", async () => {
    const res = await req("GET", "/tools");
    const tools = await res.json();
    expect(tools.length).toBeGreaterThan(0);
    expect(tools.some((t: any) => t.name === "read-daily-notes")).toBe(true);
  });

  it("executes a tool", async () => {
    await req("POST", "/things", {
      content: "Test note",
      tags: { "daily-note": { entry_type: "text", date: "2026-03-30" } },
    });

    const res = await req("POST", "/tools/read-daily-notes/execute", {
      date: "2026-03-30",
    });
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.result).toHaveLength(1);
  });

  it("returns error for unknown tool", async () => {
    const res = await req("POST", "/tools/nonexistent/execute", {});
    expect(res.status).toBe(400);
  });
});

// ---- Search ----

describe("search", () => {
  it("searches things by content", async () => {
    await req("POST", "/things", {
      content: "Walked up Flagstaff trail",
      tags: { "daily-note": {} },
    });
    await req("POST", "/things", {
      content: "Meeting about Horizon",
      tags: { "daily-note": {} },
    });

    const res = await req("GET", "/search?q=Flagstaff");
    expect(res.status).toBe(200);
    const results = await res.json();
    expect(results).toHaveLength(1);
    expect(results[0].content).toContain("Flagstaff");
  });

  it("traverses the graph", async () => {
    await req("POST", "/things", { content: "Note", id: "note1" });
    await req("POST", "/things", { content: "Alice", id: "alice", tags: { person: {} } });
    await req("POST", "/edges", {
      source_id: "note1",
      target_id: "alice",
      relationship: "mentions",
    });

    const res = await req("POST", "/search/traverse", {
      thing_id: "note1",
      direction: "outbound",
      depth: 1,
    });
    expect(res.status).toBe(200);
    const results = await res.json();
    expect(results).toHaveLength(1);
    expect(results[0].id).toBe("alice");
  });
});

// ---- Register ----

describe("register", () => {
  it("registers custom tags and tools", async () => {
    const res = await req("POST", "/register", {
      app: "test-app",
      tags: [
        { name: "bookmark", display_name: "Bookmark", schema: [{ name: "url", type: "url" }] },
      ],
      tools: [
        {
          name: "read-bookmarks",
          description: "Read bookmarks",
          tool_type: "query",
          definition: { action: "query_things", tags: ["bookmark"] },
        },
      ],
    });
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.tags_created).toBe(1);
    expect(data.tools_created).toBe(1);

    // Verify they exist
    const tagRes = await req("GET", "/tags/bookmark");
    expect(tagRes.status).toBe(200);

    const toolRes = await req("GET", "/tools/read-bookmarks");
    expect(toolRes.status).toBe(200);
  });

  it("skips existing tags/tools", async () => {
    const res = await req("POST", "/register", {
      app: "parachute-daily",
      tags: [{ name: "daily-note", display_name: "Daily Note" }],
      tools: [{ name: "read-daily-notes", description: "Read notes" }],
    });
    const data = await res.json();
    expect(data.tags_created).toBe(0);
    expect(data.tools_created).toBe(0);
  });
});
