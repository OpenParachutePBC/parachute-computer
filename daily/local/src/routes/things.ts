import { Hono } from "hono";
import type { SqliteStore } from "@parachute/core";

export type ThingCreatedHook = (thing: any) => void;

export function thingRoutes(store: SqliteStore, onCreated?: ThingCreatedHook): Hono {
  const app = new Hono();

  // GET / — Query things
  app.get("/", (c) => {
    const tag = c.req.query("tag");
    const tags = tag ? tag.split(",") : undefined;
    const sort = c.req.query("sort");
    const limit = c.req.query("limit");
    const offset = c.req.query("offset");

    // Collect filter params (anything not a known query param)
    const filters: Record<string, string> = {};
    for (const [key, value] of Object.entries(c.req.query())) {
      if (!["tag", "sort", "limit", "offset"].includes(key)) {
        filters[key] = value;
      }
    }

    const results = store.queryThings({
      tags,
      filters: Object.keys(filters).length > 0 ? filters : undefined,
      sort: sort ?? undefined,
      limit: limit ? parseInt(limit, 10) : undefined,
      offset: offset ? parseInt(offset, 10) : undefined,
    });

    return c.json(results);
  });

  // POST / — Create thing
  app.post("/", async (c) => {
    const body = await c.req.json<{
      content: string;
      id?: string;
      tags?: Record<string, Record<string, unknown>>;
      created_by?: string;
    }>();

    const tagInputs = body.tags
      ? Object.entries(body.tags).map(([name, fields]) => ({ name, fields }))
      : undefined;

    const thing = store.createThing(body.content ?? "", {
      id: body.id,
      tags: tagInputs,
      createdBy: body.created_by,
    });

    // Fire post-creation hook (non-blocking)
    if (onCreated) {
      try { onCreated(thing); } catch (_) { /* don't fail the response */ }
    }

    return c.json(thing, 201);
  });

  // GET /:id — Get thing
  app.get("/:id", (c) => {
    const id = c.req.param("id");
    const includeEdges = c.req.query("edges") === "true";
    const thing = store.getThing(id, { includeTags: true, includeEdges });
    if (!thing) return c.json({ error: "Not found" }, 404);
    return c.json(thing);
  });

  // PATCH /:id — Update thing
  app.patch("/:id", async (c) => {
    const id = c.req.param("id");
    const existing = store.getThing(id);
    if (!existing) return c.json({ error: "Not found" }, 404);

    const body = await c.req.json<{
      content?: string;
      status?: string;
      tags?: Record<string, Record<string, unknown>>;
    }>();

    const tagInputs = body.tags
      ? Object.entries(body.tags).map(([name, fields]) => ({ name, fields }))
      : undefined;

    const updated = store.updateThing(id, {
      content: body.content,
      status: body.status,
      tags: tagInputs,
    });

    return c.json(updated);
  });

  // DELETE /:id — Delete thing
  app.delete("/:id", (c) => {
    const id = c.req.param("id");
    const existing = store.getThing(id);
    if (!existing) return c.json({ error: "Not found" }, 404);

    store.deleteThing(id);
    return c.json({ deleted: true });
  });

  // GET /:id/edges — Get edges for a thing
  app.get("/:id/edges", (c) => {
    const id = c.req.param("id");
    const relationship = c.req.query("relationship");
    const direction = c.req.query("direction") as "outbound" | "inbound" | "both" | undefined;

    const edges = store.getEdges(id, {
      relationship: relationship ?? undefined,
      direction: direction ?? "both",
    });

    return c.json(edges);
  });

  return app;
}
