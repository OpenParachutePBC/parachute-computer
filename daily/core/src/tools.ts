import type Database from "better-sqlite3";
import type { ToolDef } from "./types.js";

interface ToolRow {
  name: string;
  display_name: string;
  description: string;
  tool_type: string;
  input_schema_json: string;
  definition_json: string;
  published_by: string;
  enabled: string;
  created_at: string;
  updated_at: string | null;
}

function rowToTool(row: ToolRow): ToolDef {
  return {
    name: row.name,
    displayName: row.display_name,
    description: row.description,
    toolType: row.tool_type as ToolDef["toolType"],
    inputSchema: JSON.parse(row.input_schema_json),
    definition: JSON.parse(row.definition_json),
    publishedBy: row.published_by || undefined,
    enabled: row.enabled === "true",
    createdAt: row.created_at,
    updatedAt: row.updated_at ?? undefined,
  };
}

export function registerTool(
  db: Database.Database,
  tool: Omit<ToolDef, "createdAt" | "updatedAt">,
): ToolDef {
  const now = new Date().toISOString();
  db.prepare(
    `INSERT OR REPLACE INTO tools
     (name, display_name, description, tool_type, input_schema_json, definition_json, published_by, enabled, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    tool.name,
    tool.displayName,
    tool.description,
    tool.toolType,
    JSON.stringify(tool.inputSchema),
    JSON.stringify(tool.definition),
    tool.publishedBy ?? "",
    tool.enabled ? "true" : "false",
    now,
    now,
  );
  return getTool(db, tool.name)!;
}

export function getTool(db: Database.Database, name: string): ToolDef | null {
  const row = db.prepare("SELECT * FROM tools WHERE name = ?").get(name) as ToolRow | undefined;
  return row ? rowToTool(row) : null;
}

export function listTools(
  db: Database.Database,
  opts?: { publishedBy?: string; enabled?: boolean },
): ToolDef[] {
  const conditions: string[] = [];
  const params: unknown[] = [];

  if (opts?.publishedBy) {
    conditions.push("published_by = ?");
    params.push(opts.publishedBy);
  }
  if (opts?.enabled !== undefined) {
    conditions.push("enabled = ?");
    params.push(opts.enabled ? "true" : "false");
  }

  let sql = "SELECT * FROM tools";
  if (conditions.length > 0) {
    sql += ` WHERE ${conditions.join(" AND ")}`;
  }
  sql += " ORDER BY name";

  const rows = db.prepare(sql).all(...params) as ToolRow[];
  return rows.map(rowToTool);
}
