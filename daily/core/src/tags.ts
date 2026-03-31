import type Database from "better-sqlite3";
import type { Tag, FieldDef } from "./types.js";

interface TagRow {
  name: string;
  display_name: string;
  description: string;
  schema_json: string;
  icon: string;
  color: string;
  published_by: string;
  created_at: string;
  updated_at: string | null;
}

function rowToTag(row: TagRow): Tag {
  return {
    name: row.name,
    displayName: row.display_name,
    description: row.description,
    schema: JSON.parse(row.schema_json) as FieldDef[],
    icon: row.icon || undefined,
    color: row.color || undefined,
    publishedBy: row.published_by || undefined,
    createdAt: row.created_at,
    updatedAt: row.updated_at ?? undefined,
  };
}

export function createTag(
  db: Database.Database,
  tag: Omit<Tag, "createdAt" | "updatedAt">,
): Tag {
  const now = new Date().toISOString();
  db.prepare(
    `INSERT INTO tags (name, display_name, description, schema_json, icon, color, published_by, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    tag.name,
    tag.displayName,
    tag.description,
    JSON.stringify(tag.schema),
    tag.icon ?? "",
    tag.color ?? "",
    tag.publishedBy ?? "",
    now,
  );
  return getTag(db, tag.name)!;
}

export function getTag(db: Database.Database, name: string): Tag | null {
  const row = db.prepare("SELECT * FROM tags WHERE name = ?").get(name) as TagRow | undefined;
  return row ? rowToTag(row) : null;
}

export function listTags(
  db: Database.Database,
  opts?: { publishedBy?: string },
): (Tag & { count: number })[] {
  let sql = `
    SELECT t.*, COALESCE(c.cnt, 0) AS count
    FROM tags t
    LEFT JOIN (SELECT tag_name, COUNT(*) as cnt FROM thing_tags GROUP BY tag_name) c
      ON c.tag_name = t.name
  `;
  const params: unknown[] = [];

  if (opts?.publishedBy) {
    sql += " WHERE t.published_by = ?";
    params.push(opts.publishedBy);
  }

  sql += " ORDER BY t.name";

  const rows = db.prepare(sql).all(...params) as (TagRow & { count: number })[];
  return rows.map((row) => ({ ...rowToTag(row), count: row.count }));
}

export function updateTag(
  db: Database.Database,
  name: string,
  updates: Partial<Omit<Tag, "name" | "createdAt">>,
): Tag {
  const now = new Date().toISOString();
  const sets: string[] = ["updated_at = ?"];
  const values: unknown[] = [now];

  if (updates.displayName !== undefined) {
    sets.push("display_name = ?");
    values.push(updates.displayName);
  }
  if (updates.description !== undefined) {
    sets.push("description = ?");
    values.push(updates.description);
  }
  if (updates.schema !== undefined) {
    sets.push("schema_json = ?");
    values.push(JSON.stringify(updates.schema));
  }
  if (updates.icon !== undefined) {
    sets.push("icon = ?");
    values.push(updates.icon);
  }
  if (updates.color !== undefined) {
    sets.push("color = ?");
    values.push(updates.color);
  }
  if (updates.publishedBy !== undefined) {
    sets.push("published_by = ?");
    values.push(updates.publishedBy);
  }

  values.push(name);
  db.prepare(`UPDATE tags SET ${sets.join(", ")} WHERE name = ?`).run(...values);
  return getTag(db, name)!;
}

/**
 * Validate field values against a tag's schema.
 * Returns an array of error messages (empty = valid).
 */
export function validateFieldValues(
  schema: FieldDef[],
  values: Record<string, unknown>,
): string[] {
  const errors: string[] = [];

  for (const [key, value] of Object.entries(values)) {
    const field = schema.find((f) => f.name === key);
    if (!field) {
      errors.push(`Unknown field: ${key}`);
      continue;
    }

    if (value === null || value === undefined) continue;

    switch (field.type) {
      case "text":
      case "url":
      case "date":
      case "datetime":
        if (typeof value !== "string") {
          errors.push(`${key}: expected string, got ${typeof value}`);
        }
        break;
      case "number":
        if (typeof value !== "number") {
          errors.push(`${key}: expected number, got ${typeof value}`);
        }
        break;
      case "boolean":
        if (typeof value !== "boolean") {
          errors.push(`${key}: expected boolean, got ${typeof value}`);
        }
        break;
      case "select":
        if (field.options && !field.options.includes(value as string)) {
          errors.push(`${key}: value "${value}" not in options [${field.options.join(", ")}]`);
        }
        break;
      case "json":
        // Accept anything JSON-serializable
        break;
    }
  }

  return errors;
}
