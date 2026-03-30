import { Hono } from "hono";
import type { SqliteStore } from "@parachute/core";

export function registerRoutes(store: SqliteStore): Hono {
  const app = new Hono();

  // POST / — App registration (bulk tags + tools)
  app.post("/", async (c) => {
    const body = await c.req.json<{
      app: string;
      version?: string;
      tags?: Array<{
        name: string;
        display_name?: string;
        description?: string;
        schema?: unknown[];
        icon?: string;
        color?: string;
      }>;
      tools?: Array<{
        name: string;
        display_name?: string;
        description?: string;
        tool_type?: "query" | "mutation";
        input_schema?: Record<string, unknown>;
        definition?: Record<string, unknown>;
        enabled?: boolean;
      }>;
    }>();

    const publishedBy = body.app;
    let tagsCreated = 0;
    let toolsCreated = 0;

    // Merge tags (create-if-not-exists)
    if (body.tags) {
      for (const tag of body.tags) {
        const existing = store.getTag(tag.name);
        if (!existing) {
          store.createTag({
            name: tag.name,
            displayName: tag.display_name ?? "",
            description: tag.description ?? "",
            schema: (tag.schema ?? []) as any,
            icon: tag.icon,
            color: tag.color,
            publishedBy,
          });
          tagsCreated++;
        }
      }
    }

    // Merge tools (create-if-not-exists)
    if (body.tools) {
      for (const tool of body.tools) {
        const existing = store.getTool(tool.name);
        if (!existing) {
          store.registerTool({
            name: tool.name,
            displayName: tool.display_name ?? "",
            description: tool.description ?? "",
            toolType: tool.tool_type ?? "query",
            inputSchema: tool.input_schema ?? {},
            definition: tool.definition ?? {},
            publishedBy,
            enabled: tool.enabled ?? true,
          });
          toolsCreated++;
        }
      }
    }

    return c.json({
      registered: true,
      app: publishedBy,
      tags_created: tagsCreated,
      tools_created: toolsCreated,
    });
  });

  return app;
}
