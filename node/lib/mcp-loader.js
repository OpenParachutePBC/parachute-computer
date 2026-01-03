/**
 * MCP Server Loader
 *
 * Loads MCP server definitions from .mcp.json in the vault root.
 * Provides resolution of server references in agent configs.
 *
 * MCPs are user-defined - modules and users add their own:
 * - Module MCPs: Each module (Daily, Chat) can provide search/indexing MCPs
 * - User MCPs: Additional tools like image generation, browser automation
 *
 * Configuration is stored in {vault}/.mcp.json
 *
 * Environment variable substitution:
 * - ${VAULT_PATH} - Replaced with actual vault path
 * - ${PARACHUTE_BASE} - Replaced with parachute-base installation path
 * - ${VAR_NAME} - Replaced from process.env
 */

import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PARACHUTE_BASE = path.resolve(__dirname, '..');

/**
 * MCP Server configuration cache
 */
let mcpServersCache = null;
let mcpServersPath = null;
let mcpVaultPath = null;

/**
 * Track missing environment variables during substitution
 */
let missingEnvVars = new Set();

/**
 * Substitute environment variables in a string
 *
 * Replaces ${VAR_NAME} with corresponding environment variable.
 * Special variables:
 * - ${VAULT_PATH} - Current vault path
 * - ${PARACHUTE_BASE} - parachute-base installation directory
 *
 * @param {string} str - String with ${VAR} placeholders
 * @param {string} vaultPath - Current vault path
 * @returns {string} String with substitutions applied
 */
function substituteEnvVars(str, vaultPath) {
  if (typeof str !== 'string') return str;

  return str.replace(/\$\{([^}]+)\}/g, (match, varName) => {
    // Special built-in variables
    if (varName === 'VAULT_PATH') return vaultPath;
    if (varName === 'PARACHUTE_BASE') return PARACHUTE_BASE;

    // Environment variable
    const value = process.env[varName];
    if (value === undefined) {
      missingEnvVars.add(varName);
      return match; // Keep placeholder so we can detect and filter later
    }
    return value;
  });
}

/**
 * Check if a value contains unresolved environment variable placeholders
 */
function hasUnresolvedEnvVars(obj) {
  if (typeof obj === 'string') {
    return /\$\{[^}]+\}/.test(obj);
  }
  if (Array.isArray(obj)) {
    return obj.some(item => hasUnresolvedEnvVars(item));
  }
  if (obj && typeof obj === 'object') {
    return Object.values(obj).some(value => hasUnresolvedEnvVars(value));
  }
  return false;
}

/**
 * Deep substitute environment variables in an object
 *
 * @param {any} obj - Object/array/string to process
 * @param {string} vaultPath - Current vault path
 * @returns {any} Object with substitutions applied
 */
function deepSubstituteEnvVars(obj, vaultPath) {
  if (typeof obj === 'string') {
    return substituteEnvVars(obj, vaultPath);
  }
  if (Array.isArray(obj)) {
    return obj.map(item => deepSubstituteEnvVars(item, vaultPath));
  }
  if (obj && typeof obj === 'object') {
    const result = {};
    for (const [key, value] of Object.entries(obj)) {
      // Skip description fields (metadata only)
      if (key.startsWith('_')) {
        result[key] = value;
      } else {
        result[key] = deepSubstituteEnvVars(value, vaultPath);
      }
    }
    return result;
  }
  return obj;
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
  if (!forceReload && mcpServersCache && mcpServersPath === configPath && mcpVaultPath === vaultPath) {
    return mcpServersCache;
  }

  let servers = {};

  try {
    const content = await fs.readFile(configPath, 'utf-8');
    const config = JSON.parse(content);

    // Validate structure
    if (typeof config !== 'object' || config === null) {
      console.warn('[MCP] Invalid .mcp.json structure - expected object');
    } else {
      // Reset missing env vars tracker
      missingEnvVars = new Set();

      // Apply environment variable substitution
      const substituted = deepSubstituteEnvVars(config, vaultPath);

      // Filter out servers with unresolved environment variables
      for (const [name, serverConfig] of Object.entries(substituted)) {
        if (hasUnresolvedEnvVars(serverConfig)) {
          // Find which env vars are missing for this server
          const unresolvedMatches = JSON.stringify(serverConfig).match(/\$\{([^}]+)\}/g) || [];
          const unresolvedVars = unresolvedMatches.map(m => m.slice(2, -1));
          console.warn(`[MCP] Skipping "${name}" - missing environment variable(s): ${unresolvedVars.join(', ')}`);
        } else {
          servers[name] = serverConfig;
        }
      }

      // Log if any env vars were missing overall
      if (missingEnvVars.size > 0) {
        console.log(`[MCP] Some servers skipped due to missing env vars: ${[...missingEnvVars].join(', ')}`);
      }
    }
  } catch (e) {
    if (e.code !== 'ENOENT') {
      console.error('[MCP] Error loading .mcp.json:', e.message);
    }
    // File doesn't exist - no MCPs configured
  }

  // Cache and return
  mcpServersCache = servers;
  mcpServersPath = configPath;
  mcpVaultPath = vaultPath;

  const serverNames = Object.keys(servers);
  if (serverNames.length > 0) {
    console.log(`[MCP] Loaded ${serverNames.length} server(s): ${serverNames.join(', ')}`);
  }

  return servers;
}

/**
 * Resolve MCP server references in an agent config
 *
 * Agent can specify mcpServers as:
 * - null/undefined: No MCPs
 * - 'all': Load all servers from .mcp.json
 * - Array of strings (references): ["browser", "filesystem"]
 * - Object with inline configs: { browser: { command: "npx", args: [...] } }
 * - Mixed: ["browser", { custom: { command: "..." } }]
 *
 * @param {object|array|string|null} agentMcpServers - Agent's mcpServers config
 * @param {object} globalServers - Global server definitions from .mcp.json
 * @returns {object|null} Resolved server configs ready for SDK
 */
export function resolveMcpServers(agentMcpServers, globalServers) {
  // If no mcpServers specified, return null (no MCPs)
  if (!agentMcpServers) {
    return null;
  }

  // Handle 'all' - load everything from .mcp.json
  if (agentMcpServers === 'all') {
    if (globalServers && Object.keys(globalServers).length > 0) {
      console.log(`[MCP] Loading all servers: ${Object.keys(globalServers).join(', ')}`);
      return { ...globalServers };
    }
    return null;
  }

  const resolved = {};

  // Handle array format: ["browser", "filesystem"] or mixed
  if (Array.isArray(agentMcpServers)) {
    for (const item of agentMcpServers) {
      if (typeof item === 'string') {
        // Reference to global server
        if (globalServers && globalServers[item]) {
          resolved[item] = globalServers[item];
        } else {
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
        // Reference by value: { browser: "browser" }
        if (globalServers && globalServers[config]) {
          resolved[name] = globalServers[config];
        } else {
          console.warn(`[MCP] Unknown server reference: "${config}"`);
        }
      } else if (config && typeof config === 'object') {
        // Inline config
        resolved[name] = config;
      }
    }
  }

  if (Object.keys(resolved).length > 0) {
    console.log(`[MCP] Resolved servers: ${Object.keys(resolved).join(', ')}`);
    return resolved;
  }

  return null;
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
