import type Database from "better-sqlite3";
import type { Edge, Thing, TraverseOpts } from "./types.js";

interface EdgeRow {
  source_id: string;
  target_id: string;
  relationship: string;
  properties_json: string;
  created_by: string;
  created_at: string;
}

function rowToEdge(row: EdgeRow): Edge {
  return {
    sourceId: row.source_id,
    targetId: row.target_id,
    relationship: row.relationship,
    properties: JSON.parse(row.properties_json),
    createdBy: row.created_by,
    createdAt: row.created_at,
  };
}

export function createEdge(
  db: Database.Database,
  sourceId: string,
  targetId: string,
  relationship: string,
  opts?: { properties?: Record<string, unknown>; createdBy?: string },
): Edge {
  const now = new Date().toISOString();
  const properties = JSON.stringify(opts?.properties ?? {});
  const createdBy = opts?.createdBy ?? "user";

  db.prepare(
    `INSERT OR IGNORE INTO edges (source_id, target_id, relationship, properties_json, created_by, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  ).run(sourceId, targetId, relationship, properties, createdBy, now);

  // Return the edge (may have already existed due to IGNORE)
  const row = db.prepare(
    `SELECT * FROM edges WHERE source_id = ? AND target_id = ? AND relationship = ?`,
  ).get(sourceId, targetId, relationship) as EdgeRow;
  return rowToEdge(row);
}

export function deleteEdge(
  db: Database.Database,
  sourceId: string,
  targetId: string,
  relationship: string,
): void {
  db.prepare(
    "DELETE FROM edges WHERE source_id = ? AND target_id = ? AND relationship = ?",
  ).run(sourceId, targetId, relationship);
}

export function getEdges(
  db: Database.Database,
  thingId: string,
  opts?: { relationship?: string; direction?: "outbound" | "inbound" | "both" },
): Edge[] {
  const direction = opts?.direction ?? "both";
  const conditions: string[] = [];
  const params: unknown[] = [];

  if (direction === "outbound" || direction === "both") {
    conditions.push("source_id = ?");
    params.push(thingId);
  }
  if (direction === "inbound" || direction === "both") {
    conditions.push("target_id = ?");
    params.push(thingId);
  }

  let sql = `SELECT * FROM edges WHERE (${conditions.join(" OR ")})`;

  if (opts?.relationship) {
    sql += " AND relationship = ?";
    params.push(opts.relationship);
  }

  sql += " ORDER BY created_at DESC";

  const rows = db.prepare(sql).all(...params) as EdgeRow[];
  return rows.map(rowToEdge);
}

/**
 * Traverse the graph from a starting thing, following edges.
 * Uses batch BFS — one query per depth level.
 */
export function traverse(
  db: Database.Database,
  thingId: string,
  opts: TraverseOpts,
): Thing[] {
  const maxDepth = opts.depth ?? 1;
  const direction = opts.direction ?? "outbound";
  const limit = opts.limit ?? 100;

  let frontier = [thingId];
  const visited = new Set<string>([thingId]);
  const results: string[] = [];

  for (let depth = 0; depth < maxDepth; depth++) {
    if (frontier.length === 0) break;

    const neighborIds = getNeighborIds(db, frontier, direction, opts.edge);

    const newFrontier: string[] = [];
    for (const id of neighborIds) {
      if (!visited.has(id)) {
        visited.add(id);
        newFrontier.push(id);
        results.push(id);
      }
    }

    frontier = newFrontier;
  }

  if (results.length === 0) return [];

  // Fetch the actual things
  const placeholders = results.slice(0, limit).map(() => "?").join(", ");
  const rows = db
    .prepare(
      `SELECT * FROM things WHERE id IN (${placeholders}) AND status = 'active'`,
    )
    .all(...results.slice(0, limit)) as ThingRow[];

  let things = rows.map(rowToThing);

  // Filter by target tags if specified
  if (opts.targetTags && opts.targetTags.length > 0) {
    const tagSet = new Set(opts.targetTags);
    things = things.filter((t) => {
      const tagRows = db
        .prepare("SELECT tag_name FROM thing_tags WHERE thing_id = ?")
        .all(t.id) as { tag_name: string }[];
      return tagRows.some((r) => tagSet.has(r.tag_name));
    });
  }

  // Attach tags
  for (const thing of things) {
    const tagRows = db
      .prepare(
        "SELECT tag_name, field_values_json, tagged_at FROM thing_tags WHERE thing_id = ?",
      )
      .all(thing.id) as { tag_name: string; field_values_json: string; tagged_at: string }[];
    thing.tags = tagRows.map((r) => ({
      tagName: r.tag_name,
      fieldValues: JSON.parse(r.field_values_json),
      taggedAt: r.tagged_at,
    }));
  }

  return things;
}

// ---- Internal ----

interface ThingRow {
  id: string;
  content: string;
  created_at: string;
  updated_at: string | null;
  created_by: string;
  status: string;
}

function rowToThing(row: ThingRow): Thing {
  return {
    id: row.id,
    content: row.content,
    createdAt: row.created_at,
    updatedAt: row.updated_at ?? undefined,
    createdBy: row.created_by,
    status: row.status as Thing["status"],
  };
}

/**
 * Batch-fetch neighbor IDs for a set of source/target IDs.
 * One query per BFS level (not per node).
 */
function getNeighborIds(
  db: Database.Database,
  ids: string[],
  direction: "outbound" | "inbound" | "both",
  edge?: string,
): string[] {
  if (ids.length === 0) return [];

  const placeholders = ids.map(() => "?").join(", ");
  const parts: string[] = [];
  const params: unknown[] = [];

  if (direction === "outbound" || direction === "both") {
    let sql = `SELECT DISTINCT target_id AS neighbor FROM edges WHERE source_id IN (${placeholders})`;
    params.push(...ids);
    if (edge) {
      sql += " AND relationship = ?";
      params.push(edge);
    }
    parts.push(sql);
  }

  if (direction === "inbound" || direction === "both") {
    let sql = `SELECT DISTINCT source_id AS neighbor FROM edges WHERE target_id IN (${placeholders})`;
    params.push(...ids);
    if (edge) {
      sql += " AND relationship = ?";
      params.push(edge);
    }
    parts.push(sql);
  }

  const fullSql = parts.join(" UNION ");
  const rows = db.prepare(fullSql).all(...params) as { neighbor: string }[];
  return rows.map((r) => r.neighbor);
}
