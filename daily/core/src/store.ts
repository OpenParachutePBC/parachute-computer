import type Database from "better-sqlite3";
import type {
  Store,
  Thing,
  Tag,
  TagInput,
  ThingTag,
  Edge,
  ToolDef,
  QueryOpts,
  TraverseOpts,
} from "./types.js";
import { initSchema } from "./schema.js";
import { seedBuiltins } from "./seed.js";
import * as things from "./things.js";
import * as tags from "./tags.js";
import * as edgeOps from "./edges.js";
import * as tools from "./tools.js";
import { executeTool as executeToolFn } from "./executor.js";

/**
 * SQLite-backed Store implementation.
 * Works with any better-sqlite3 compatible database (including bun:sqlite via adapter).
 */
export class SqliteStore implements Store {
  constructor(public readonly db: Database.Database) {
    initSchema(db);
    seedBuiltins(db);
  }

  // ---- Things ----

  createThing(
    content: string,
    opts?: { id?: string; tags?: TagInput[]; createdBy?: string },
  ): Thing {
    return things.createThing(this.db, content, opts);
  }

  getThing(
    id: string,
    opts?: { includeTags?: boolean; includeEdges?: boolean },
  ): Thing | null {
    return things.getThing(this.db, id, opts);
  }

  updateThing(
    id: string,
    updates: { content?: string; status?: string; tags?: TagInput[] },
  ): Thing {
    return things.updateThing(this.db, id, updates);
  }

  deleteThing(id: string): void {
    things.deleteThing(this.db, id);
  }

  queryThings(opts: QueryOpts): Thing[] {
    return things.queryThings(this.db, opts);
  }

  searchThings(
    query: string,
    opts?: { tags?: string[]; limit?: number },
  ): Thing[] {
    return things.searchThings(this.db, query, opts);
  }

  // ---- Tags ----

  createTag(tag: Omit<Tag, "createdAt" | "updatedAt">): Tag {
    return tags.createTag(this.db, tag);
  }

  getTag(name: string): Tag | null {
    return tags.getTag(this.db, name);
  }

  listTags(opts?: { publishedBy?: string }): (Tag & { count: number })[] {
    return tags.listTags(this.db, opts);
  }

  updateTag(name: string, updates: Partial<Omit<Tag, "name" | "createdAt">>): Tag {
    return tags.updateTag(this.db, name, updates);
  }

  // ---- Thing-Tag ----

  tagThing(
    thingId: string,
    tagName: string,
    fields?: Record<string, unknown>,
  ): void {
    things.tagThing(this.db, thingId, tagName, fields);
  }

  untagThing(thingId: string, tagName: string): void {
    things.untagThing(this.db, thingId, tagName);
  }

  getThingTags(thingId: string): ThingTag[] {
    return things.getThingTags(this.db, thingId);
  }

  // ---- Edges ----

  createEdge(
    sourceId: string,
    targetId: string,
    relationship: string,
    opts?: { properties?: Record<string, unknown>; createdBy?: string },
  ): Edge {
    return edgeOps.createEdge(this.db, sourceId, targetId, relationship, opts);
  }

  deleteEdge(
    sourceId: string,
    targetId: string,
    relationship: string,
  ): void {
    edgeOps.deleteEdge(this.db, sourceId, targetId, relationship);
  }

  getEdges(
    thingId: string,
    opts?: {
      relationship?: string;
      direction?: "outbound" | "inbound" | "both";
    },
  ): Edge[] {
    return edgeOps.getEdges(this.db, thingId, opts);
  }

  traverse(thingId: string, opts: TraverseOpts): Thing[] {
    return edgeOps.traverse(this.db, thingId, opts);
  }

  // ---- Tools ----

  registerTool(tool: Omit<ToolDef, "createdAt" | "updatedAt">): ToolDef {
    return tools.registerTool(this.db, tool);
  }

  getTool(name: string): ToolDef | null {
    return tools.getTool(this.db, name);
  }

  listTools(opts?: { publishedBy?: string; enabled?: boolean }): ToolDef[] {
    return tools.listTools(this.db, opts);
  }

  executeTool(name: string, params: Record<string, unknown>): unknown {
    return executeToolFn(this.db, name, params);
  }
}
