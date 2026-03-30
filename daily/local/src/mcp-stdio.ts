import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createStore } from "./db.js";
import { generateMcpTools } from "@parachute/core";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";

const DB_PATH = process.env.PARACHUTE_DB ?? path.join(os.homedir(), ".parachute", "daily.db");
fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });

const store = createStore(DB_PATH);
const mcpTools = generateMcpTools(store.db);

const server = new McpServer(
  { name: "parachute-daily", version: "0.1.0" },
);

// Register each tool from the database as an MCP tool
for (const tool of mcpTools) {
  server.tool(
    tool.name,
    tool.description,
    async (extra) => {
      try {
        // Params come from the tool call arguments
        const params = (extra as Record<string, unknown>).params ?? {};
        const result = tool.execute(params as Record<string, unknown>);
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(result, null, 2),
            },
          ],
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : "Unknown error";
        return {
          content: [{ type: "text" as const, text: `Error: ${message}` }],
          isError: true,
        };
      }
    },
  );
}

// Start stdio transport
const transport = new StdioServerTransport();
await server.connect(transport);
