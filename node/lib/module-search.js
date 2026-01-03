/**
 * Module Search Service
 *
 * Unified search across all Parachute modules.
 * Each module has its own index.db, this service provides:
 * - Per-module search
 * - Cross-module search
 * - Index management
 */

import { existsSync } from 'fs';
import { join } from 'path';
import { ModuleIndexer } from './module-indexer.js';
import { createChatScanner } from './scanners/chat-scanner.js';
import { createDailyScanner } from './scanners/daily-scanner.js';
import { createLogger } from './logger.js';

const log = createLogger('ModuleSearch');

// Module configurations
const MODULE_CONFIGS = {
  chat: {
    name: 'Chat',
    folder: 'Chat',
    createScanner: (modulePath) => createChatScanner(modulePath),
  },
  daily: {
    name: 'Daily',
    folder: 'Daily',
    createScanner: (modulePath) => createDailyScanner(modulePath),
  },
  // Future modules
  // build: { name: 'Build', folder: 'Build', ... }
};

/**
 * Module Search Service
 */
export class ModuleSearchService {
  /**
   * @param {string} vaultPath - Path to vault root
   */
  constructor(vaultPath) {
    this.vaultPath = vaultPath;
    this.indexers = new Map();
  }

  /**
   * Get or create indexer for a module
   * @param {string} moduleName - Module name (chat, daily, etc.)
   * @returns {ModuleIndexer|null}
   */
  getIndexer(moduleName) {
    const key = moduleName.toLowerCase();

    if (this.indexers.has(key)) {
      return this.indexers.get(key);
    }

    const config = MODULE_CONFIGS[key];
    if (!config) {
      log.warn(`Unknown module: ${moduleName}`);
      return null;
    }

    const modulePath = join(this.vaultPath, config.folder);
    if (!existsSync(modulePath)) {
      log.debug(`Module path not found: ${modulePath}`);
      return null;
    }

    // Check if index exists or if we can create one
    const indexPath = join(modulePath, 'index.db');
    if (!config.createScanner && !existsSync(indexPath)) {
      log.debug(`No index found for ${moduleName} and no scanner available`);
      return null;
    }

    // Create scanner if available
    const scanner = config.createScanner ? config.createScanner(modulePath) : null;

    const indexer = new ModuleIndexer(modulePath, scanner, {
      moduleName: config.name,
    });

    this.indexers.set(key, indexer);
    return indexer;
  }

  /**
   * List available modules
   * @returns {Object[]}
   */
  listModules() {
    const modules = [];

    for (const [key, config] of Object.entries(MODULE_CONFIGS)) {
      const modulePath = join(this.vaultPath, config.folder);
      const indexPath = join(modulePath, 'index.db');

      modules.push({
        id: key,
        name: config.name,
        folder: config.folder,
        exists: existsSync(modulePath),
        hasIndex: existsSync(indexPath),
        canIndex: !!config.createScanner,
      });
    }

    return modules;
  }

  /**
   * Search within a specific module
   * @param {string} moduleName
   * @param {string} query
   * @param {Object} options
   * @returns {Promise<Object>}
   */
  async searchModule(moduleName, query, options = {}) {
    const indexer = this.getIndexer(moduleName);
    if (!indexer) {
      return {
        module: moduleName,
        error: 'Module not found or not indexed',
        results: [],
      };
    }

    try {
      const results = await indexer.search(query, options);
      return {
        module: moduleName,
        query,
        results,
        count: results.length,
      };
    } catch (err) {
      log.error(`Search failed for ${moduleName}: ${err.message}`);
      return {
        module: moduleName,
        error: err.message,
        results: [],
      };
    }
  }

  /**
   * Search across all modules
   * @param {string} query
   * @param {Object} options
   * @param {string[]} options.modules - Specific modules to search (default: all)
   * @param {number} options.limit - Results per module
   * @returns {Promise<Object>}
   */
  async searchAll(query, options = {}) {
    const { modules: targetModules, limit = 10 } = options;

    const moduleList = targetModules || Object.keys(MODULE_CONFIGS);
    const results = {};

    await Promise.all(
      moduleList.map(async (moduleName) => {
        const result = await this.searchModule(moduleName, query, { ...options, limit });
        results[moduleName] = result;
      })
    );

    // Flatten and sort all results
    const allResults = [];
    for (const [moduleName, moduleResult] of Object.entries(results)) {
      for (const r of moduleResult.results || []) {
        allResults.push({ ...r, module: moduleName });
      }
    }

    // Sort by match quality then date
    allResults.sort((a, b) => {
      if (a.matchType === 'both' && b.matchType !== 'both') return -1;
      if (b.matchType === 'both' && a.matchType !== 'both') return 1;
      if (a.similarity && b.similarity) return b.similarity - a.similarity;
      return new Date(b.date) - new Date(a.date);
    });

    return {
      query,
      byModule: results,
      combined: allResults.slice(0, options.limit || 20),
      totalCount: allResults.length,
    };
  }

  /**
   * Rebuild index for a module
   * @param {string} moduleName
   * @param {Object} options
   * @returns {Promise<Object>}
   */
  async rebuildModuleIndex(moduleName, options = {}) {
    const config = MODULE_CONFIGS[moduleName.toLowerCase()];
    if (!config) {
      throw new Error(`Unknown module: ${moduleName}`);
    }

    if (!config.createScanner) {
      throw new Error(`Module ${moduleName} uses client-side indexing`);
    }

    const indexer = this.getIndexer(moduleName);
    if (!indexer) {
      throw new Error(`Could not create indexer for ${moduleName}`);
    }

    return await indexer.rebuildIndex(options);
  }

  /**
   * Get stats for all modules
   * @returns {Object}
   */
  getStats() {
    const stats = {
      modules: {},
      total: {
        contentCount: 0,
        chunkCount: 0,
        embeddedCount: 0,
      },
    };

    for (const moduleName of Object.keys(MODULE_CONFIGS)) {
      try {
        const indexer = this.getIndexer(moduleName);
        if (indexer) {
          const moduleStats = indexer.getStats();
          stats.modules[moduleName] = moduleStats;
          stats.total.contentCount += moduleStats.contentCount;
          stats.total.chunkCount += moduleStats.chunkCount;
          stats.total.embeddedCount += moduleStats.embeddedCount;
        } else {
          stats.modules[moduleName] = { error: 'Not indexed' };
        }
      } catch (err) {
        stats.modules[moduleName] = { error: err.message };
      }
    }

    return stats;
  }

  /**
   * Get content by ID from any module
   * @param {string} moduleName
   * @param {string} contentId
   * @returns {Object|null}
   */
  getContent(moduleName, contentId) {
    const indexer = this.getIndexer(moduleName);
    if (!indexer) return null;
    return indexer.getContent(contentId);
  }

  /**
   * List recent content from a module
   * @param {string} moduleName
   * @param {Object} options
   * @returns {Array}
   */
  listRecent(moduleName, options = {}) {
    const indexer = this.getIndexer(moduleName);
    if (!indexer) return [];
    return indexer.listRecent(options);
  }

  /**
   * Close all database connections
   */
  close() {
    for (const indexer of this.indexers.values()) {
      indexer.close();
    }
    this.indexers.clear();
  }
}

// Singleton instance
let instance = null;

/**
 * Get the module search service instance
 * @param {string} vaultPath
 * @returns {ModuleSearchService}
 */
export function getModuleSearchService(vaultPath) {
  if (!instance || instance.vaultPath !== vaultPath) {
    if (instance) instance.close();
    instance = new ModuleSearchService(vaultPath);
  }
  return instance;
}

export default ModuleSearchService;
