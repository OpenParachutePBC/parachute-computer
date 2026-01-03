/**
 * Para ID Service
 *
 * Generates and manages unique para IDs for content:
 * - Chat messages: `### para:chat:abc123def456 User | timestamp`
 * - Assets: `assets/2025-12/para_chat_abc123def456_audio.wav`
 * - Sessions: `session_id: "chat:abc123def456"`
 *
 * Format: `para:{module}:{uuid}` where module is 'daily', 'chat', etc.
 * This aligns with the Dart implementations in Daily and Chat apps.
 *
 * New IDs are 12 characters (36^12 = 4.7 quintillion combinations).
 * Legacy 6-character IDs and non-prefixed IDs are still supported for parsing.
 *
 * Registry stored in `.parachute/ids.jsonl` (JSONL format, append-only).
 * Legacy `uuids.txt` is read for backwards compatibility.
 */

import fs from 'fs/promises';
import fsSync from 'fs';
import path from 'path';
import crypto from 'crypto';

// Para ID types
export const ParaIdType = {
  ENTRY: 'entry',      // Journal entries
  MESSAGE: 'message',  // Chat messages
  ASSET: 'asset',      // Media files
  SESSION: 'session',  // Chat sessions
};

// Constants
const LEGACY_FILENAME = 'uuids.txt';
const REGISTRY_FILENAME = 'ids.jsonl';
const DIR_NAME = '.parachute';
const NEW_ID_LENGTH = 12;
const LEGACY_ID_LENGTH = 6;
const VALID_LENGTHS = [LEGACY_ID_LENGTH, NEW_ID_LENGTH];
const CHARSET = 'abcdefghijklmnopqrstuvwxyz0123456789';

// Module prefix for this service (aligns with Dart Chat app)
const MODULE = 'chat';
const VALID_MODULES = ['daily', 'chat'];

/**
 * Para ID Service class
 */
export class ParaIdService {
  constructor(vaultPath) {
    this.vaultPath = vaultPath;
    this.existingIds = new Set();
    this.registry = new Map(); // id -> entry
    this.initialized = false;
    this.registryPath = path.join(vaultPath, DIR_NAME, REGISTRY_FILENAME);
    this.legacyPath = path.join(vaultPath, DIR_NAME, LEGACY_FILENAME);
  }

  /**
   * Initialize the service by loading existing IDs
   */
  async initialize() {
    if (this.initialized) return;

    try {
      // Ensure directory exists
      const dir = path.join(this.vaultPath, DIR_NAME);
      await fs.mkdir(dir, { recursive: true });

      // Load legacy uuids.txt
      await this.loadLegacyIds();

      // Load ids.jsonl registry
      await this.loadRegistry();

      console.log(`[ParaIdService] Loaded ${this.existingIds.size} para IDs (${this.registry.size} with metadata)`);
      this.initialized = true;
    } catch (e) {
      console.error('[ParaIdService] Failed to initialize:', e.message);
      throw e;
    }
  }

  /**
   * Load legacy uuids.txt file
   */
  async loadLegacyIds() {
    try {
      const content = await fs.readFile(this.legacyPath, 'utf-8');
      const ids = content
        .split('\n')
        .map(line => line.trim())
        .filter(line => line && !line.startsWith('#'));

      for (const id of ids) {
        this.existingIds.add(id.toLowerCase());
      }
      console.log(`[ParaIdService] Loaded ${ids.length} IDs from legacy uuids.txt`);
    } catch (e) {
      // File may not exist
    }
  }

  /**
   * Load ids.jsonl registry
   */
  async loadRegistry() {
    try {
      const content = await fs.readFile(this.registryPath, 'utf-8');
      const lines = content
        .split('\n')
        .filter(line => line.trim());

      for (const line of lines) {
        try {
          const entry = JSON.parse(line);
          this.existingIds.add(entry.id.toLowerCase());
          this.registry.set(entry.id.toLowerCase(), entry);
        } catch (e) {
          console.warn('[ParaIdService] Invalid registry line:', line);
        }
      }
    } catch (e) {
      // File may not exist, create it
      await fs.writeFile(this.registryPath, '', 'utf-8');
    }
  }

  /**
   * Generate a new unique para ID
   *
   * @param {string} type - ParaIdType value (entry, message, asset, session)
   * @param {string} [filePath] - Optional path to associated file
   * @returns {Promise<string>} - Generated ID
   */
  async generate(type = ParaIdType.ENTRY, filePath = null) {
    this.ensureInitialized();

    let id;
    let attempts = 0;
    const maxAttempts = 100;

    do {
      id = this.generateRandomId();
      attempts++;
      if (attempts > maxAttempts) {
        throw new Error('Failed to generate unique ID after 100 attempts');
      }
    } while (this.existingIds.has(id));

    // Create registry entry
    const entry = {
      id,
      type,
      created: new Date().toISOString(),
      ...(filePath && { path: filePath }),
    };

    // Add to memory
    this.existingIds.add(id);
    this.registry.set(id, entry);

    // Persist to JSONL registry (append-only)
    try {
      await fs.appendFile(this.registryPath, JSON.stringify(entry) + '\n', 'utf-8');
      console.log(`[ParaIdService] Generated new para ID: ${id} (${type})`);
    } catch (e) {
      // Rollback on failure
      this.existingIds.delete(id);
      this.registry.delete(id);
      throw e;
    }

    return id;
  }

  /**
   * Generate a random ID (synchronous version for quick generation)
   * Note: This does NOT persist to registry - use generate() for that
   */
  generateSync() {
    let id;
    let attempts = 0;

    do {
      id = this.generateRandomId();
      attempts++;
    } while (this.existingIds.has(id) && attempts < 100);

    // Add to memory only (will be persisted when message is saved)
    this.existingIds.add(id);
    return id;
  }

  /**
   * Check if an ID exists
   */
  exists(id) {
    this.ensureInitialized();
    return this.existingIds.has(id.toLowerCase());
  }

  /**
   * Get registry entry for an ID
   */
  getEntry(id) {
    this.ensureInitialized();
    return this.registry.get(id.toLowerCase());
  }

  /**
   * Register an existing ID
   *
   * @param {string} id - The ID to register
   * @param {string} type - ParaIdType value
   * @param {string} [filePath] - Optional path
   * @returns {Promise<boolean>} - True if newly registered
   */
  async register(id, type = ParaIdType.ENTRY, filePath = null) {
    this.ensureInitialized();

    const normalizedId = id.toLowerCase();
    if (this.existingIds.has(normalizedId)) {
      return false;
    }

    const entry = {
      id: normalizedId,
      type,
      created: new Date().toISOString(),
      ...(filePath && { path: filePath }),
    };

    this.existingIds.add(normalizedId);
    this.registry.set(normalizedId, entry);

    try {
      await fs.appendFile(this.registryPath, JSON.stringify(entry) + '\n', 'utf-8');
      return true;
    } catch (e) {
      this.existingIds.delete(normalizedId);
      this.registry.delete(normalizedId);
      throw e;
    }
  }

  /**
   * Validate a para ID format (accepts both 6 and 12 char IDs)
   */
  static isValidFormat(id) {
    if (!VALID_LENGTHS.includes(id.length)) return false;
    return id.toLowerCase().split('').every(char => CHARSET.includes(char));
  }

  /**
   * Check if an ID is the new 12-char format
   */
  static isNewFormat(id) {
    return id.length === NEW_ID_LENGTH && ParaIdService.isValidFormat(id);
  }

  /**
   * Check if an ID is the legacy 6-char format
   */
  static isLegacyFormat(id) {
    return id.length === LEGACY_ID_LENGTH && ParaIdService.isValidFormat(id);
  }

  /**
   * Parse a para ID from an H1 line (journal entries)
   * Expected format: `# para:abc123def456 Title here`
   */
  static parseFromH1(line) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('# para:')) return null;

    const afterPrefix = trimmed.substring(7); // Skip "# para:"

    for (const length of [NEW_ID_LENGTH, LEGACY_ID_LENGTH]) {
      if (afterPrefix.length >= length) {
        const potentialId = afterPrefix.substring(0, length);
        if (ParaIdService.isValidFormat(potentialId)) {
          if (afterPrefix.length === length ||
              afterPrefix[length] === ' ' ||
              afterPrefix[length] === '\t') {
            return potentialId.toLowerCase();
          }
        }
      }
    }

    return null;
  }

  /**
   * Parse a para ID from an H3 line (chat messages)
   * Supports both formats:
   * - New: `### para:chat:abc123def456 User | timestamp`
   * - Legacy: `### para:abc123def456 User | timestamp`
   */
  static parseFromH3(line) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('### para:')) return null;

    let afterPrefix = trimmed.substring(9); // Skip "### para:"

    // Check for module prefix (e.g., "chat:" or "daily:")
    for (const mod of VALID_MODULES) {
      if (afterPrefix.startsWith(mod + ':')) {
        afterPrefix = afterPrefix.substring(mod.length + 1);
        break;
      }
    }

    for (const length of [NEW_ID_LENGTH, LEGACY_ID_LENGTH]) {
      if (afterPrefix.length >= length) {
        const potentialId = afterPrefix.substring(0, length);
        if (ParaIdService.isValidFormat(potentialId)) {
          if (afterPrefix.length === length ||
              afterPrefix[length] === ' ' ||
              afterPrefix[length] === '\t') {
            return potentialId.toLowerCase();
          }
        }
      }
    }

    return null;
  }

  /**
   * Format an H1 line with para ID (for journal entries)
   */
  static formatH1(id, title) {
    const trimmedTitle = (title || '').trim();
    if (!trimmedTitle) {
      return `# para:${id}`;
    }
    return `# para:${id} ${trimmedTitle}`;
  }

  /**
   * Format an H3 line with para ID (for chat messages)
   * Uses module prefix: `### para:chat:abc123def456 User | timestamp`
   */
  static formatH3(id, role, timestamp) {
    return `### para:${MODULE}:${id} ${role} | ${timestamp}`;
  }

  /**
   * Format an H3 line without para ID (legacy format)
   */
  static formatH3Legacy(role, timestamp) {
    return `### ${role} | ${timestamp}`;
  }

  /**
   * Parse role and timestamp from a message header
   * Supports both new and legacy formats:
   * - New: `### para:chat:abc123def456 User | timestamp`
   * - Legacy: `### para:abc123def456 User | timestamp`
   * - Very legacy: `### User | timestamp`
   */
  static parseMessageHeader(line) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('### ')) return null;

    let afterHeader = trimmed.substring(4); // Skip "### "

    // Check if it has a para ID
    if (afterHeader.startsWith('para:')) {
      afterHeader = afterHeader.substring(5); // Skip "para:"

      // Check for module prefix (e.g., "chat:" or "daily:")
      for (const mod of VALID_MODULES) {
        if (afterHeader.startsWith(mod + ':')) {
          afterHeader = afterHeader.substring(mod.length + 1);
          break;
        }
      }

      // Skip the ID
      for (const length of [NEW_ID_LENGTH, LEGACY_ID_LENGTH]) {
        if (afterHeader.length >= length) {
          const potentialId = afterHeader.substring(0, length);
          if (ParaIdService.isValidFormat(potentialId)) {
            afterHeader = afterHeader.substring(length).trimStart();
            break;
          }
        }
      }
    }

    // Now parse "Role | timestamp"
    const pipeIndex = afterHeader.indexOf(' | ');
    if (pipeIndex === -1) return null;

    const role = afterHeader.substring(0, pipeIndex).trim();
    const timestamp = afterHeader.substring(pipeIndex + 3).trim();

    return { role, timestamp };
  }

  /**
   * Generate a random 12-character ID
   */
  generateRandomId() {
    const bytes = crypto.randomBytes(NEW_ID_LENGTH);
    let id = '';
    for (let i = 0; i < NEW_ID_LENGTH; i++) {
      id += CHARSET[bytes[i] % CHARSET.length];
    }
    return id;
  }

  ensureInitialized() {
    if (!this.initialized) {
      throw new Error('ParaIdService not initialized. Call initialize() first.');
    }
  }
}

// Export singleton factory
let instance = null;

export function getParaIdService(vaultPath) {
  if (!instance || instance.vaultPath !== vaultPath) {
    instance = new ParaIdService(vaultPath);
  }
  return instance;
}

export default ParaIdService;
