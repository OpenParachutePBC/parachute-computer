/**
 * MCP Server Loader
 *
 * Loads MCP server definitions from .mcp.json in the vault root.
 * Provides resolution of server references in agent configs.
 *
 * Built-in servers (always available, auto-injected):
 * - vault-search: Search past conversations, journals, and captures
 *   Gives agents "memory" by allowing searches over the vault's SQLite index
 *
 * User servers (optional, defined in vault's .mcp.json):
 * - Can define additional MCP servers like browser automation
 * - User servers can override built-in servers if needed
 */

import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';

// Get the agent directory for built-in MCP servers
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const AGENT_DIR = path.dirname(__dirname); // Parent of lib/

/**
 * MCP Server configuration cache
 */
let mcpServersCache = null;
let mcpServersPath = null;

/**
 * Get built-in MCP servers that are always available
 * @param {string} vaultPath - Path to the vault (for env vars)
 * @returns {object} Map of built-in server name -> config
 */
function getBuiltInServers(vaultPath) {
  // Pass VAULT_PATH to built-in MCPs so they know where to find config
  // Note: SDK doesn't support 'cwd' - use absolute paths in args instead
  const env = {
    ...process.env,
    VAULT_PATH: vaultPath || process.env.VAULT_PATH || './sample-vault'
  };

  return {
    'vault-search': {
      type: 'stdio',
      command: 'node',
      args: [path.join(AGENT_DIR, 'mcp-vault-search.js')],
      env
    },
    'para-generate': {
      type: 'stdio',
      command: 'node',
      args: [path.join(AGENT_DIR, 'mcp-para-generate.js')],
      env
    }
  };
}

/**
 * Load MCP servers from .mcp.json
 *
 * @param {string} vaultPath - Path to the vault
 * @param {boolean} forceReload - Force reload from disk
 * @returns {Promise<object>} Map of server name -> config
 */
export async function loadMcpServers(vaultPath, forceReload = false) {
  const configPath = path.join(vaultPath, '.mcp.json');

  // Return cached if available and path matches
  if (!forceReload && mcpServersCache && mcpServersPath === configPath) {
    return mcpServersCache;
  }

  // Start with built-in servers (pass vault path for env vars)
  const builtIn = getBuiltInServers(vaultPath);
  let userServers = {};

  try {
    const content = await fs.readFile(configPath, 'utf-8');
    const config = JSON.parse(content);

    // Validate structure
    if (typeof config !== 'object' || config === null) {
      console.warn('[MCP] Invalid .mcp.json structure - expected object');
    } else {
      userServers = config;
    }
  } catch (e) {
    if (e.code !== 'ENOENT') {
      console.error('[MCP] Error loading .mcp.json:', e.message);
    }
    // File doesn't exist or error - just use built-ins
  }

  // Merge: user servers can override built-ins if needed
  const allServers = { ...builtIn, ...userServers };

  // Cache and return
  mcpServersCache = allServers;
  mcpServersPath = configPath;

  const builtInNames = Object.keys(builtIn);
  const userNames = Object.keys(userServers);

  if (userNames.length > 0) {
    console.log(`[MCP] Loaded ${userNames.length} user server(s): ${userNames.join(', ')}`);
  }
  console.log(`[MCP] Built-in servers: ${builtInNames.join(', ')}`);

  return allServers;
}

/**
 * Resolve MCP server references in an agent config
 *
 * Agent can specify mcpServers as:
 * - null/undefined: Get built-in servers only (vault-search, etc.)
 * - 'all': Load all servers from .mcp.json (built-in + user-defined)
 * - Array of strings (references): ["browser", "filesystem"]
 * - Object with inline configs: { browser: { command: "npx", args: [...] } }
 * - Mixed: ["browser", { custom: { command: "..." } }]
 *
 * Built-in servers (like vault-search) are ALWAYS included regardless of config.
 *
 * @param {object|array|string|null} agentMcpServers - Agent's mcpServers config
 * @param {object} globalServers - Global server definitions from .mcp.json (includes built-ins with env vars)
 * @returns {object|null} Resolved server configs ready for SDK
 */
export function resolveMcpServers(agentMcpServers, globalServers) {
  // Built-in server names (globalServers already includes these with correct env vars)
  const builtInNames = ['vault-search', 'para-generate'];

  // Extract built-in servers from globalServers (they have the correct env vars set)
  const builtIn = {};
  for (const name of builtInNames) {
    if (globalServers && globalServers[name]) {
      builtIn[name] = globalServers[name];
    }
  }

  // If no mcpServers specified, still return built-in servers
  if (!agentMcpServers) {
    console.log(`[MCP] Using built-in servers: ${Object.keys(builtIn).join(', ')}`);
    return { ...builtIn };
  }

  // Handle 'all' - load everything from .mcp.json (already includes built-ins)
  if (agentMcpServers === 'all') {
    if (globalServers && Object.keys(globalServers).length > 0) {
      console.log(`[MCP] Loading all servers: ${Object.keys(globalServers).join(', ')}`);
      return { ...globalServers };
    }
    // Even with no user servers, return built-ins
    console.log(`[MCP] Using built-in servers: ${Object.keys(builtIn).join(', ')}`);
    return { ...builtIn };
  }

  // Start with built-in servers (always included)
  const resolved = { ...builtIn };

  // Handle array format: ["browser", "filesystem"] or mixed
  if (Array.isArray(agentMcpServers)) {
    for (const item of agentMcpServers) {
      if (typeof item === 'string') {
        // Reference to global server
        if (globalServers[item]) {
          resolved[item] = globalServers[item];
        } else if (!builtInNames.includes(item)) {
          // Only warn if not a built-in server
          console.warn(`[MCP] Unknown server reference: "${item}" - not found in .mcp.json`);
        }
      } else if (typeof item === 'object' && item !== null) {
        // Inline config: { serverName: { config } }
        for (const [name, config] of Object.entries(item)) {
          resolved[name] = config;
        }
      }
    }
  }
  // Handle object format: { browser: { command: "npx", ... } }
  else if (typeof agentMcpServers === 'object') {
    for (const [name, config] of Object.entries(agentMcpServers)) {
      if (typeof config === 'string') {
        // Reference by value: { browser: "browser" } (unusual but support it)
        if (globalServers[config]) {
          resolved[name] = globalServers[config];
        } else if (!builtInNames.includes(config)) {
          console.warn(`[MCP] Unknown server reference: "${config}"`);
        }
      } else if (config && typeof config === 'object') {
        // Inline config
        resolved[name] = config;
      }
    }
  }

  console.log(`[MCP] Resolved servers: ${Object.keys(resolved).join(', ')}`);
  return resolved;
}

/**
 * Save MCP servers to .mcp.json
 *
 * @param {string} vaultPath - Path to the vault
 * @param {object} servers - Server configurations
 * @returns {Promise<void>}
 */
export async function saveMcpServers(vaultPath, servers) {
  const configPath = path.join(vaultPath, '.mcp.json');

  try {
    const content = JSON.stringify(servers, null, 2);
    await fs.writeFile(configPath, content, 'utf-8');

    // Update cache
    mcpServersCache = servers;
    mcpServersPath = configPath;

    console.log(`[MCP] Saved ${Object.keys(servers).length} server(s) to .mcp.json`);
  } catch (e) {
    console.error('[MCP] Error saving .mcp.json:', e.message);
    throw e;
  }
}

/**
 * Add or update a single MCP server
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} name - Server name
 * @param {object} config - Server configuration
 * @returns {Promise<object>} Updated servers
 */
export async function addMcpServer(vaultPath, name, config) {
  const servers = await loadMcpServers(vaultPath);
  servers[name] = config;
  await saveMcpServers(vaultPath, servers);
  return servers;
}

/**
 * Remove an MCP server
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} name - Server name
 * @returns {Promise<object>} Updated servers
 */
export async function removeMcpServer(vaultPath, name) {
  const servers = await loadMcpServers(vaultPath);
  delete servers[name];
  await saveMcpServers(vaultPath, servers);
  return servers;
}

/**
 * Get list of available MCP servers
 *
 * @param {string} vaultPath - Path to the vault
 * @returns {Promise<array>} Array of { name, config } objects
 */
export async function listMcpServers(vaultPath) {
  const servers = await loadMcpServers(vaultPath);
  return Object.entries(servers).map(([name, config]) => ({
    name,
    ...config,
    // Add display info
    displayType: config.command ? 'stdio' : config.type || 'unknown',
    displayCommand: config.command
      ? `${config.command} ${(config.args || []).join(' ')}`
      : config.url || 'N/A'
  }));
}

/**
 * Clear the cache (useful for testing or after external changes)
 */
export function clearMcpCache() {
  mcpServersCache = null;
  mcpServersPath = null;
}

export default {
  loadMcpServers,
  resolveMcpServers,
  saveMcpServers,
  addMcpServer,
  removeMcpServer,
  listMcpServers,
  clearMcpCache
};
