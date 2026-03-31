import { Hono } from "hono";
import type { SqliteStore } from "@parachute/core";

export function toolRoutes(store: SqliteStore): Hono {
  const app = new Hono();

  // GET / — List tools
  app.get("/", (c) => {
    const publishedBy = c.req.query("published_by");
    const enabled = c.req.query("enabled");
    const tools = store.listTools({
      publishedBy: publishedBy ?? undefined,
      enabled: enabled ? enabled === "true" : undefined,
    });
    return c.json(tools);
  });

  // POST / — Register tool
  app.post("/", async (c) => {
    const body = await c.req.json<{
      name: string;
      display_name?: string;
      description?: string;
      tool_type?: "query" | "mutation";
      input_schema?: Record<string, unknown>;
      definition?: Record<string, unknown>;
      published_by?: string;
      enabled?: boolean;
    }>();

    const tool = store.registerTool({
      name: body.name,
      displayName: body.display_name ?? "",
      description: body.description ?? "",
      toolType: body.tool_type ?? "query",
      inputSchema: body.input_schema ?? {},
      definition: body.definition ?? {},
      publishedBy: body.published_by,
      enabled: body.enabled ?? true,
    });
    return c.json(tool, 201);
  });

  // GET /:name — Get tool
  app.get("/:name", (c) => {
    const name = c.req.param("name");
    const tool = store.getTool(name);
    if (!tool) return c.json({ error: "Not found" }, 404);
    return c.json(tool);
  });

  // POST /:name/execute — Execute tool
  app.post("/:name/execute", async (c) => {
    const name = c.req.param("name");
    const params = await c.req.json<Record<string, unknown>>();

    try {
      const result = store.executeTool(name, params);
      return c.json({ result });
    } catch (err) {
      const message = err instanceof Error ? err.message : "Unknown error";
      return c.json({ error: message }, 400);
    }
  });

  return app;
}
