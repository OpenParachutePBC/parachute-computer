import type Database from "better-sqlite3";
import type { ToolDef } from "./types.js";
import { listTools } from "./tools.js";
import { executeTool } from "./executor.js";

export interface McpToolDef {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  execute: (params: Record<string, unknown>) => unknown;
}

/**
 * Generate MCP tool definitions from the tools table.
 * Each registered, enabled tool becomes an MCP-callable tool.
 */
export function generateMcpTools(db: Database.Database): McpToolDef[] {
  const tools = listTools(db, { enabled: true });

  return tools.map((tool) => ({
    name: tool.name,
    description: tool.description,
    inputSchema: tool.inputSchema,
    execute: (params: Record<string, unknown>) => executeTool(db, tool.name, params),
  }));
}

/**
 * Format tool definitions for MCP protocol listing (without execute function).
 */
export function listMcpTools(db: Database.Database): Omit<McpToolDef, "execute">[] {
  const tools = listTools(db, { enabled: true });
  return tools.map((tool) => ({
    name: tool.name,
    description: tool.description,
    inputSchema: tool.inputSchema,
  }));
}
