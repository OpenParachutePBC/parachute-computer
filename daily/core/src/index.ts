// Schema
export { initSchema, SCHEMA_SQL, SCHEMA_VERSION } from "./schema.js";

// Types
export type {
  Thing,
  Tag,
  TagInput,
  ThingTag,
  Edge,
  ToolDef,
  ToolType,
  FieldDef,
  FieldType,
  Filter,
  QueryOpts,
  TraverseOpts,
  Store,
} from "./types.js";

// Store
export { SqliteStore } from "./store.js";

// Operations
export * as things from "./things.js";
export * as tags from "./tags.js";
export * as edges from "./edges.js";
export * as tools from "./tools.js";

// Executor
export { executeTool } from "./executor.js";

// MCP
export { generateMcpTools, listMcpTools } from "./mcp.js";
export type { McpToolDef } from "./mcp.js";

// Seed
export { seedBuiltins, BUILTIN_TAGS, BUILTIN_TOOLS } from "./seed.js";
