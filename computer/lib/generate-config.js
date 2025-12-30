/**
 * Generation Configuration Manager
 *
 * Manages configuration for the para-generate MCP server.
 * Settings are stored in {vault}/.parachute/generate.json
 */

import fs from 'fs/promises';
import path from 'path';

// Default configuration
const DEFAULT_CONFIG = {
  image: {
    default: 'mflux',
    backends: {
      mflux: {
        enabled: true,
        model: 'schnell',  // 'schnell' (fast) or 'dev' (quality)
        steps: 4,          // schnell: 4, dev: 20-50
      },
      'nano-banana': {
        enabled: false,
        api_key: '',
        model: 'flux-schnell',
      },
    },
  },
  audio: {
    default: null,
    backends: {},
  },
  music: {
    default: null,
    backends: {},
  },
  speech: {
    default: null,
    backends: {},
  },
};

// Backend registry - maps backend names to their module paths
const BACKEND_REGISTRY = {
  image: {
    mflux: './generate-backends/mflux.js',
    'nano-banana': './generate-backends/nano-banana.js',
  },
  audio: {},
  music: {},
  speech: {},
};

let configCache = null;
let configPath = null;

/**
 * Get the config file path for a vault
 */
function getConfigPath(vaultPath) {
  return path.join(vaultPath, '.parachute', 'generate.json');
}

/**
 * Load generation config from vault
 *
 * @param {string} vaultPath - Path to the vault
 * @param {boolean} forceReload - Force reload from disk
 * @returns {Promise<object>} Configuration object
 */
export async function loadConfig(vaultPath, forceReload = false) {
  const cfgPath = getConfigPath(vaultPath);

  // Return cached if available
  if (!forceReload && configCache && configPath === cfgPath) {
    return configCache;
  }

  let userConfig = {};

  try {
    const content = await fs.readFile(cfgPath, 'utf-8');
    userConfig = JSON.parse(content);
  } catch (e) {
    if (e.code !== 'ENOENT') {
      console.error('[GenerateConfig] Error loading config:', e.message);
    }
    // File doesn't exist - use defaults
  }

  // Deep merge with defaults
  const config = deepMerge(DEFAULT_CONFIG, userConfig);

  configCache = config;
  configPath = cfgPath;

  return config;
}

/**
 * Save generation config to vault
 *
 * @param {string} vaultPath - Path to the vault
 * @param {object} config - Configuration to save
 */
export async function saveConfig(vaultPath, config) {
  const cfgPath = getConfigPath(vaultPath);

  // Ensure .parachute directory exists
  const dir = path.dirname(cfgPath);
  await fs.mkdir(dir, { recursive: true });

  await fs.writeFile(cfgPath, JSON.stringify(config, null, 2));

  configCache = config;
  configPath = cfgPath;

  console.log('[GenerateConfig] Saved config');
}

/**
 * Get the default backend for a content type
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} contentType - 'image', 'audio', 'music', 'speech'
 * @returns {Promise<string|null>} Backend name or null
 */
export async function getDefaultBackend(vaultPath, contentType) {
  const config = await loadConfig(vaultPath);
  return config[contentType]?.default || null;
}

/**
 * Get backend configuration
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} contentType - 'image', 'audio', etc.
 * @param {string} backendName - Name of the backend
 * @returns {Promise<object|null>} Backend config or null
 */
export async function getBackendConfig(vaultPath, contentType, backendName) {
  const config = await loadConfig(vaultPath);
  return config[contentType]?.backends?.[backendName] || null;
}

/**
 * Get list of available backends for a content type
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} contentType - 'image', 'audio', etc.
 * @returns {Promise<array>} Array of { name, enabled, isDefault, ...config }
 */
export async function listBackends(vaultPath, contentType) {
  const config = await loadConfig(vaultPath);
  const typeConfig = config[contentType] || {};
  const backends = typeConfig.backends || {};
  const defaultBackend = typeConfig.default;

  return Object.entries(backends).map(([name, cfg]) => ({
    name,
    isDefault: name === defaultBackend,
    ...cfg,
  }));
}

/**
 * Load a backend adapter module
 *
 * @param {string} contentType - 'image', 'audio', etc.
 * @param {string} backendName - Name of the backend
 * @returns {Promise<object>} Backend module with generate() function
 */
export async function loadBackend(contentType, backendName) {
  const modulePath = BACKEND_REGISTRY[contentType]?.[backendName];

  if (!modulePath) {
    throw new Error(`Unknown backend: ${contentType}/${backendName}`);
  }

  try {
    const module = await import(modulePath);
    return module;
  } catch (e) {
    throw new Error(`Failed to load backend ${backendName}: ${e.message}`);
  }
}

/**
 * Update a specific backend's configuration
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} contentType - 'image', 'audio', etc.
 * @param {string} backendName - Name of the backend
 * @param {object} updates - Configuration updates to apply
 */
export async function updateBackendConfig(vaultPath, contentType, backendName, updates) {
  const config = await loadConfig(vaultPath);

  if (!config[contentType]) {
    config[contentType] = { default: null, backends: {} };
  }

  if (!config[contentType].backends) {
    config[contentType].backends = {};
  }

  config[contentType].backends[backendName] = {
    ...config[contentType].backends[backendName],
    ...updates,
  };

  await saveConfig(vaultPath, config);
}

/**
 * Set the default backend for a content type
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} contentType - 'image', 'audio', etc.
 * @param {string} backendName - Name of the backend to set as default
 */
export async function setDefaultBackend(vaultPath, contentType, backendName) {
  const config = await loadConfig(vaultPath);

  if (!config[contentType]) {
    config[contentType] = { default: null, backends: {} };
  }

  config[contentType].default = backendName;

  await saveConfig(vaultPath, config);
}

/**
 * Generate the assets output path for a new file
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} extension - File extension (jpg, png, opus, etc.)
 * @returns {Promise<{absolutePath: string, relativePath: string}>}
 */
export async function getOutputPath(vaultPath, extension) {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const monthFolder = `${year}-${month}`;

  // Generate unique filename
  const timestamp = now.toISOString().replace(/[-:T]/g, '').split('.')[0];
  const random = Math.random().toString(36).substring(2, 8);
  const filename = `gen_${timestamp}_${random}.${extension}`;

  const relativePath = `assets/${monthFolder}/${filename}`;
  const absolutePath = path.join(vaultPath, relativePath);

  // Ensure directory exists
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });

  return { absolutePath, relativePath };
}

/**
 * Deep merge two objects
 */
function deepMerge(target, source) {
  const result = { ...target };

  for (const key of Object.keys(source)) {
    if (
      source[key] &&
      typeof source[key] === 'object' &&
      !Array.isArray(source[key])
    ) {
      result[key] = deepMerge(result[key] || {}, source[key]);
    } else {
      result[key] = source[key];
    }
  }

  return result;
}

/**
 * Clear config cache
 */
export function clearCache() {
  configCache = null;
  configPath = null;
}

export default {
  loadConfig,
  saveConfig,
  getDefaultBackend,
  getBackendConfig,
  listBackends,
  loadBackend,
  updateBackendConfig,
  setDefaultBackend,
  getOutputPath,
  clearCache,
};
