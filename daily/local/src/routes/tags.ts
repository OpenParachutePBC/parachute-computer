import { Hono } from "hono";
import type { SqliteStore } from "@parachute/core";

export function tagRoutes(store: SqliteStore): Hono {
  const app = new Hono();

  // GET / — List tags with counts
  app.get("/", (c) => {
    const publishedBy = c.req.query("published_by");
    const tags = store.listTags({ publishedBy: publishedBy ?? undefined });
    return c.json(tags);
  });

  // POST / — Create or update tag
  app.post("/", async (c) => {
    const body = await c.req.json<{
      name: string;
      display_name?: string;
      description?: string;
      schema?: unknown[];
      icon?: string;
      color?: string;
      published_by?: string;
    }>();

    const existing = store.getTag(body.name);
    if (existing) {
      const updated = store.updateTag(body.name, {
        displayName: body.display_name,
        description: body.description,
        schema: body.schema as any,
        icon: body.icon,
        color: body.color,
        publishedBy: body.published_by,
      });
      return c.json(updated);
    }

    const tag = store.createTag({
      name: body.name,
      displayName: body.display_name ?? "",
      description: body.description ?? "",
      schema: (body.schema ?? []) as any,
      icon: body.icon,
      color: body.color,
      publishedBy: body.published_by,
    });
    return c.json(tag, 201);
  });

  // GET /:name — Get tag with schema
  app.get("/:name", (c) => {
    const name = c.req.param("name");
    const tag = store.getTag(name);
    if (!tag) return c.json({ error: "Not found" }, 404);
    return c.json(tag);
  });

  return app;
}
