/**
 * Vault Utilities
 *
 * Shared utilities for vault file operations.
 * Consolidates duplicate code from server.js, orchestrator.js, and document-scanner.js
 */

import fs from 'fs/promises';
import path from 'path';
import matter from 'gray-matter';

/**
 * List all markdown files in a vault
 *
 * @param {string} vaultPath - Base vault path
 * @param {string} dir - Directory to scan (defaults to vaultPath)
 * @param {string[]} files - Accumulator for recursive calls
 * @returns {Promise<string[]>} Array of relative paths
 */
export async function listVaultFiles(vaultPath, dir = null, files = []) {
  const scanDir = dir || vaultPath;
  const entries = await fs.readdir(scanDir, { withFileTypes: true });

  for (const entry of entries) {
    const fullPath = path.join(scanDir, entry.name);

    if (entry.isDirectory() && !entry.name.startsWith('.')) {
      await listVaultFiles(vaultPath, fullPath, files);
    } else if (entry.name.endsWith('.md')) {
      files.push(path.relative(vaultPath, fullPath));
    }
  }

  return files;
}

/**
 * Read and parse a markdown document
 *
 * @param {string} vaultPath - Base vault path
 * @param {string} relativePath - Relative path to document
 * @returns {Promise<object|null>} Parsed document or null if not found
 */
export async function readDocument(vaultPath, relativePath) {
  const fullPath = path.join(vaultPath, relativePath);

  try {
    const content = await fs.readFile(fullPath, 'utf-8');
    const { data: frontmatter, content: body } = matter(content);

    return {
      path: relativePath,
      fullPath,
      frontmatter,
      body,
      raw: content
    };
  } catch (e) {
    return null;
  }
}

/**
 * Write a markdown document
 *
 * @param {string} vaultPath - Base vault path
 * @param {string} relativePath - Relative path to document
 * @param {object} frontmatter - YAML frontmatter object
 * @param {string} body - Markdown body content
 * @returns {Promise<void>}
 */
export async function writeDocument(vaultPath, relativePath, frontmatter, body) {
  const fullPath = path.join(vaultPath, relativePath);

  // Ensure directory exists
  await fs.mkdir(path.dirname(fullPath), { recursive: true });

  const content = matter.stringify(body, frontmatter);
  await fs.writeFile(fullPath, content);
}

/**
 * Update a document's frontmatter
 *
 * @param {string} vaultPath - Base vault path
 * @param {string} relativePath - Relative path to document
 * @param {object} updates - Frontmatter fields to update
 * @returns {Promise<object>} Updated document
 */
export async function updateDocumentFrontmatter(vaultPath, relativePath, updates) {
  const doc = await readDocument(vaultPath, relativePath);
  if (!doc) {
    throw new Error(`Document not found: ${relativePath}`);
  }

  const newFrontmatter = { ...doc.frontmatter, ...updates };
  await writeDocument(vaultPath, relativePath, newFrontmatter, doc.body);

  return readDocument(vaultPath, relativePath);
}

/**
 * Search vault for documents matching a query
 *
 * @param {string} vaultPath - Base vault path
 * @param {string} query - Search query (case-insensitive)
 * @param {object} options - Search options
 * @returns {Promise<object[]>} Matching documents with context
 */
export async function searchVault(vaultPath, query, options = {}) {
  const { maxResults = 50, maxMatchesPerDoc = 3 } = options;
  const files = await listVaultFiles(vaultPath);
  const results = [];
  const queryLower = query.toLowerCase();

  for (const file of files) {
    if (results.length >= maxResults) break;

    const doc = await readDocument(vaultPath, file);
    if (!doc) continue;

    const contentLower = doc.raw.toLowerCase();
    if (contentLower.includes(queryLower)) {
      const lines = doc.raw.split('\n');
      const matchingLines = lines
        .filter(line => line.toLowerCase().includes(queryLower))
        .slice(0, maxMatchesPerDoc);

      results.push({
        path: file,
        title: doc.frontmatter.title || path.basename(file, '.md'),
        matches: matchingLines,
        hasAgentConfig: Array.isArray(doc.frontmatter.agents) && doc.frontmatter.agents.length > 0
      });
    }
  }

  return results;
}

/**
 * Check if a file path matches any of the given glob-like patterns
 *
 * @param {string} filePath - Path to check
 * @param {string[]} patterns - Glob-like patterns
 * @returns {boolean}
 */
export function matchesPatterns(filePath, patterns) {
  for (const pattern of patterns) {
    if (pattern === '*') return true;

    // Simple glob matching
    const regexPattern = pattern
      .replace(/\./g, '\\.')
      .replace(/\*\*/g, '.*')
      .replace(/\*/g, '[^/]*')
      .replace(/\?/g, '.');

    const regex = new RegExp(`^${regexPattern}$`);
    if (regex.test(filePath)) return true;
  }
  return false;
}

/**
 * Get vault statistics
 *
 * @param {string} vaultPath - Base vault path
 * @returns {Promise<object>} Vault statistics
 */
export async function getVaultStats(vaultPath) {
  const files = await listVaultFiles(vaultPath);

  let withAgents = 0;
  const byFolder = {};

  for (const file of files) {
    const doc = await readDocument(vaultPath, file);
    if (doc?.frontmatter?.agents?.length > 0) {
      withAgents++;
    }

    const folder = path.dirname(file) || '.';
    byFolder[folder] = (byFolder[folder] || 0) + 1;
  }

  return {
    totalFiles: files.length,
    withAgents,
    byFolder
  };
}

export default {
  listVaultFiles,
  readDocument,
  writeDocument,
  updateDocumentFrontmatter,
  searchVault,
  matchesPatterns,
  getVaultStats
};
