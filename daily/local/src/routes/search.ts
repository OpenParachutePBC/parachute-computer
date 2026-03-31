import { Hono } from "hono";
import type { SqliteStore } from "@parachute/core";

export function searchRoutes(store: SqliteStore): Hono {
  const app = new Hono();

  // GET / — Full-text search
  app.get("/", (c) => {
    const query = c.req.query("q");
    if (!query) return c.json({ error: "q parameter is required" }, 400);

    const tag = c.req.query("tag");
    const tags = tag ? tag.split(",") : undefined;
    const limit = c.req.query("limit");

    const results = store.searchThings(query, {
      tags,
      limit: limit ? parseInt(limit, 10) : undefined,
    });
    return c.json(results);
  });

  // POST /traverse — Graph traversal
  app.post("/traverse", async (c) => {
    const body = await c.req.json<{
      thing_id: string;
      edge?: string;
      direction?: "outbound" | "inbound" | "both";
      depth?: number;
      target_tags?: string[];
      limit?: number;
    }>();

    if (!body.thing_id) {
      return c.json({ error: "thing_id is required" }, 400);
    }

    const results = store.traverse(body.thing_id, {
      edge: body.edge,
      direction: body.direction ?? "outbound",
      depth: body.depth ?? 1,
      targetTags: body.target_tags,
      limit: body.limit,
    });
    return c.json(results);
  });

  return app;
}
