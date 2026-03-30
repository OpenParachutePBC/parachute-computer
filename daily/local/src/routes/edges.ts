import { Hono } from "hono";
import type { SqliteStore } from "@parachute/core";

export function edgeRoutes(store: SqliteStore): Hono {
  const app = new Hono();

  // POST / — Create edge
  app.post("/", async (c) => {
    const body = await c.req.json<{
      source_id: string;
      target_id: string;
      relationship: string;
      properties?: Record<string, unknown>;
      created_by?: string;
    }>();

    if (!body.source_id || !body.target_id || !body.relationship) {
      return c.json({ error: "source_id, target_id, and relationship are required" }, 400);
    }

    const edge = store.createEdge(body.source_id, body.target_id, body.relationship, {
      properties: body.properties,
      createdBy: body.created_by,
    });
    return c.json(edge, 201);
  });

  // DELETE / — Delete edge
  app.delete("/", async (c) => {
    const body = await c.req.json<{
      source_id: string;
      target_id: string;
      relationship: string;
    }>();

    store.deleteEdge(body.source_id, body.target_id, body.relationship);
    return c.json({ deleted: true });
  });

  return app;
}
