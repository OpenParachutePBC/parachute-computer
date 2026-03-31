import type Database from "better-sqlite3";
import type { Thing, TagInput, QueryOpts, Filter, ThingTag } from "./types.js";

let idCounter = 0;

/** Generate a timestamp-based ID: YYYY-MM-DD-HH-MM-SS-ffffff */
export function generateThingId(): string {
  const now = new Date();
  const pad = (n: number, len = 2) => String(n).padStart(len, "0");
  // Add counter suffix to guarantee uniqueness within the same millisecond
  const micro = now.getMilliseconds() * 1000 + (idCounter++ % 1000);
  return [
    now.getFullYear(),
    pad(now.getMonth() + 1),
    pad(now.getDate()),
    pad(now.getHours()),
    pad(now.getMinutes()),
    pad(now.getSeconds()),
    pad(micro, 6),
  ].join("-");
}

export function createThing(
  db: Database.Database,
  content: string,
  opts?: { id?: string; tags?: TagInput[]; createdBy?: string },
): Thing {
  const id = opts?.id ?? generateThingId();
  const now = new Date().toISOString();
  const createdBy = opts?.createdBy ?? "user";

  db.prepare(
    `INSERT INTO things (id, content, created_at, created_by, status)
     VALUES (?, ?, ?, ?, 'active')`,
  ).run(id, content, now, createdBy);

  if (opts?.tags) {
    for (const tag of opts.tags) {
      tagThing(db, id, tag.name, tag.fields);
    }
  }

  return getThing(db, id)!;
}

export function getThing(
  db: Database.Database,
  id: string,
  opts?: { includeTags?: boolean; includeEdges?: boolean },
): Thing | null {
  const row = db.prepare("SELECT * FROM things WHERE id = ?").get(id) as ThingRow | undefined;
  if (!row) return null;

  const thing = rowToThing(row);

  if (opts?.includeTags !== false) {
    thing.tags = getThingTags(db, id);
  }

  if (opts?.includeEdges) {
    const edgeRows = db.prepare(
      `SELECT * FROM edges WHERE source_id = ? OR target_id = ?`,
    ).all(id, id) as EdgeRow[];
    thing.edges = edgeRows.map(rowToEdge);
  }

  return thing;
}

export function updateThing(
  db: Database.Database,
  id: string,
  updates: { content?: string; status?: string; tags?: TagInput[] },
): Thing {
  const now = new Date().toISOString();
  const sets: string[] = ["updated_at = ?"];
  const values: unknown[] = [now];

  if (updates.content !== undefined) {
    sets.push("content = ?");
    values.push(updates.content);
  }
  if (updates.status !== undefined) {
    sets.push("status = ?");
    values.push(updates.status);
  }

  values.push(id);
  db.prepare(`UPDATE things SET ${sets.join(", ")} WHERE id = ?`).run(...values);

  if (updates.tags) {
    // Replace all tags
    db.prepare("DELETE FROM thing_tags WHERE thing_id = ?").run(id);
    for (const tag of updates.tags) {
      tagThing(db, id, tag.name, tag.fields);
    }
  }

  return getThing(db, id)!;
}

export function deleteThing(db: Database.Database, id: string): void {
  // CASCADE handles thing_tags and edges via foreign keys
  db.prepare("DELETE FROM things WHERE id = ?").run(id);
}

export function queryThings(db: Database.Database, opts: QueryOpts): Thing[] {
  const conditions: string[] = ["t.status = 'active'"];
  const params: unknown[] = [];
  const joins: string[] = [];

  // Filter by tags
  if (opts.tags && opts.tags.length > 0) {
    for (let i = 0; i < opts.tags.length; i++) {
      const alias = `tt${i}`;
      joins.push(`JOIN thing_tags ${alias} ON ${alias}.thing_id = t.id AND ${alias}.tag_name = ?`);
      params.push(opts.tags[i]);
    }
  }

  // Filter by field values
  if (opts.filters) {
    for (const [key, filter] of Object.entries(opts.filters)) {
      // Check if this is a thing column or a tag field
      if (["created_at", "updated_at", "created_by", "status", "content"].includes(key)) {
        applyColumnFilter(conditions, params, `t.${key}`, filter);
      } else {
        // Tag field filter — requires a thing_tags join with json_extract
        const alias = `ttf_${key}`;
        joins.push(`JOIN thing_tags ${alias} ON ${alias}.thing_id = t.id`);
        applyColumnFilter(
          conditions,
          params,
          `json_extract(${alias}.field_values_json, '$.${key}')`,
          filter,
        );
      }
    }
  }

  // Sort
  let orderBy = "t.created_at ASC";
  if (opts.sort) {
    const [field, dir] = opts.sort.split(":");
    const safeField = ["created_at", "updated_at", "id", "content"].includes(field!)
      ? `t.${field}`
      : `t.created_at`;
    orderBy = `${safeField} ${dir === "desc" ? "DESC" : "ASC"}`;
  }

  const limit = typeof opts.limit === "number" ? opts.limit : 100;
  const offset = typeof opts.offset === "number" ? opts.offset : 0;

  const sql = `
    SELECT DISTINCT t.* FROM things t
    ${joins.join("\n")}
    WHERE ${conditions.join(" AND ")}
    ORDER BY ${orderBy}
    LIMIT ? OFFSET ?
  `;
  params.push(limit, offset);

  const rows = db.prepare(sql).all(...params) as ThingRow[];
  return rows.map((row) => {
    const thing = rowToThing(row);
    thing.tags = getThingTags(db, thing.id);
    return thing;
  });
}

export function searchThings(
  db: Database.Database,
  query: string,
  opts?: { tags?: string[]; limit?: number },
): Thing[] {
  const limit = typeof opts?.limit === "number" ? opts.limit : 50;

  if (opts?.tags && Array.isArray(opts.tags) && opts.tags.length > 0) {
    try {
      const tagPlaceholders = opts.tags.map(() => "?").join(", ");
      const rows = db.prepare(`
        SELECT DISTINCT t.* FROM things t
        JOIN things_fts fts ON fts.rowid = t.rowid
        JOIN thing_tags tt ON tt.thing_id = t.id AND tt.tag_name IN (${tagPlaceholders})
        WHERE things_fts MATCH ? AND t.status = 'active'
        ORDER BY rank
        LIMIT ?
      `).all(...opts.tags, query, limit) as ThingRow[];
      return rows.map((row) => {
        const thing = rowToThing(row);
        thing.tags = getThingTags(db, thing.id);
        return thing;
      });
    } catch {
      return [];
    }
  }

  try {
    const rows = db.prepare(`
      SELECT t.* FROM things t
      JOIN things_fts fts ON fts.rowid = t.rowid
      WHERE things_fts MATCH ? AND t.status = 'active'
      ORDER BY rank
      LIMIT ?
    `).all(query, limit) as ThingRow[];
    return rows.map((row) => {
      const thing = rowToThing(row);
      thing.tags = getThingTags(db, thing.id);
      return thing;
    });
  } catch {
    // FTS5 throws for terms not in the index
    return [];
  }
}

// ---- Tag Operations ----

export function tagThing(
  db: Database.Database,
  thingId: string,
  tagName: string,
  fields?: Record<string, unknown>,
): void {
  const now = new Date().toISOString();
  const fieldValues = JSON.stringify(fields ?? {});
  db.prepare(
    `INSERT OR REPLACE INTO thing_tags (thing_id, tag_name, field_values_json, tagged_at)
     VALUES (?, ?, ?, ?)`,
  ).run(thingId, tagName, fieldValues, now);
}

export function untagThing(
  db: Database.Database,
  thingId: string,
  tagName: string,
): void {
  db.prepare("DELETE FROM thing_tags WHERE thing_id = ? AND tag_name = ?").run(
    thingId,
    tagName,
  );
}

export function getThingTags(db: Database.Database, thingId: string): ThingTag[] {
  const rows = db.prepare(
    "SELECT tag_name, field_values_json, tagged_at FROM thing_tags WHERE thing_id = ?",
  ).all(thingId) as { tag_name: string; field_values_json: string; tagged_at: string }[];

  return rows.map((row) => ({
    tagName: row.tag_name,
    fieldValues: JSON.parse(row.field_values_json),
    taggedAt: row.tagged_at,
  }));
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

interface EdgeRow {
  source_id: string;
  target_id: string;
  relationship: string;
  properties_json: string;
  created_by: string;
  created_at: string;
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

function rowToEdge(row: EdgeRow) {
  return {
    sourceId: row.source_id,
    targetId: row.target_id,
    relationship: row.relationship,
    properties: JSON.parse(row.properties_json),
    createdBy: row.created_by,
    createdAt: row.created_at,
  };
}

function applyColumnFilter(
  conditions: string[],
  params: unknown[],
  column: string,
  filter: Filter,
): void {
  if (typeof filter === "string") {
    conditions.push(`${column} = ?`);
    params.push(filter);
  } else if ("gte" in filter) {
    conditions.push(`${column} >= ?`);
    params.push(filter.gte);
  } else if ("lte" in filter) {
    conditions.push(`${column} <= ?`);
    params.push(filter.lte);
  } else if ("contains" in filter) {
    conditions.push(`${column} LIKE ?`);
    params.push(`%${filter.contains}%`);
  } else if ("in" in filter) {
    const placeholders = filter.in.map(() => "?").join(", ");
    conditions.push(`${column} IN (${placeholders})`);
    params.push(...filter.in);
  }
}
