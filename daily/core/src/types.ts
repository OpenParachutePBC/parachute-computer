// ---- Field / Schema Types ----

export type FieldType =
  | "text"
  | "number"
  | "boolean"
  | "select"
  | "date"
  | "datetime"
  | "url"
  | "json";

export interface FieldDef {
  name: string;
  type: FieldType;
  description?: string;
  options?: string[]; // for select type
  default?: unknown;
}

// ---- Thing ----

export interface Thing {
  id: string;
  content: string;
  createdAt: string; // ISO-8601
  updatedAt?: string;
  createdBy: string;
  status: "active" | "archived" | "deleted";
  tags?: ThingTag[];
  edges?: Edge[];
}

// ---- Tag ----

export interface Tag {
  name: string;
  displayName: string;
  description: string;
  schema: FieldDef[];
  icon?: string;
  color?: string;
  publishedBy?: string;
  createdAt: string;
  updatedAt?: string;
}

export interface TagInput {
  name: string;
  fields?: Record<string, unknown>;
}

export interface ThingTag {
  tagName: string;
  fieldValues: Record<string, unknown>;
  taggedAt: string;
}

// ---- Edge ----

export interface Edge {
  sourceId: string;
  targetId: string;
  relationship: string;
  properties: Record<string, unknown>;
  createdBy: string;
  createdAt: string;
  source?: Thing;
  target?: Thing;
}

// ---- Tool ----

export type ToolType = "query" | "mutation";

export interface ToolDef {
  name: string;
  displayName: string;
  description: string;
  toolType: ToolType;
  inputSchema: Record<string, unknown>;
  definition: Record<string, unknown>;
  publishedBy?: string;
  enabled: boolean;
  createdAt: string;
  updatedAt?: string;
}

// ---- Query Options ----

export type Filter =
  | string
  | { gte: string }
  | { lte: string }
  | { contains: string }
  | { in: string[] };

export interface QueryOpts {
  tags?: string[];
  filters?: Record<string, Filter>;
  sort?: string; // "field:asc" or "field:desc"
  limit?: number;
  offset?: number;
  includeEdges?: boolean;
}

export interface TraverseOpts {
  edge?: string;
  direction?: "outbound" | "inbound" | "both";
  depth?: number;
  targetTags?: string[];
  limit?: number;
}

// ---- Store Interface ----

export interface Store {
  // Things
  createThing(
    content: string,
    opts?: { id?: string; tags?: TagInput[]; createdBy?: string },
  ): Thing;
  getThing(id: string, opts?: { includeTags?: boolean; includeEdges?: boolean }): Thing | null;
  updateThing(
    id: string,
    updates: { content?: string; status?: string; tags?: TagInput[] },
  ): Thing;
  deleteThing(id: string): void;
  queryThings(opts: QueryOpts): Thing[];
  searchThings(
    query: string,
    opts?: { tags?: string[]; limit?: number },
  ): Thing[];

  // Tags
  createTag(tag: Omit<Tag, "createdAt" | "updatedAt">): Tag;
  getTag(name: string): Tag | null;
  listTags(opts?: { publishedBy?: string }): (Tag & { count: number })[];
  updateTag(name: string, updates: Partial<Omit<Tag, "name" | "createdAt">>): Tag;

  // Thing-Tag relationships
  tagThing(
    thingId: string,
    tagName: string,
    fields?: Record<string, unknown>,
  ): void;
  untagThing(thingId: string, tagName: string): void;
  getThingTags(thingId: string): ThingTag[];

  // Edges
  createEdge(
    sourceId: string,
    targetId: string,
    relationship: string,
    opts?: { properties?: Record<string, unknown>; createdBy?: string },
  ): Edge;
  deleteEdge(
    sourceId: string,
    targetId: string,
    relationship: string,
  ): void;
  getEdges(
    thingId: string,
    opts?: {
      relationship?: string;
      direction?: "outbound" | "inbound" | "both";
    },
  ): Edge[];
  traverse(thingId: string, opts: TraverseOpts): Thing[];

  // Tools
  registerTool(tool: Omit<ToolDef, "createdAt" | "updatedAt">): ToolDef;
  getTool(name: string): ToolDef | null;
  listTools(opts?: { publishedBy?: string; enabled?: boolean }): ToolDef[];
  executeTool(name: string, params: Record<string, unknown>): unknown;
}
