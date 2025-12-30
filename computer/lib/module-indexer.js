/**
 * Module Indexer
 *
 * Common indexing logic for all Parachute modules.
 * Each module (Daily, Chat, Build) has its own index.db following the same schema.
 *
 * Usage:
 *   const indexer = new ModuleIndexer(modulePath, contentScanner);
 *   await indexer.rebuildIndex();
 *   const results = await indexer.search('query');
 */

import Database from 'better-sqlite3';
import { readFileSync, existsSync, readdirSync, statSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { createHash } from 'crypto';
import { generateEmbedding, cosineSimilarity, getOllamaStatus } from './ollama-service.js';
import { createLogger } from './logger.js';

const log = createLogger('ModuleIndexer');

const __dirname = dirname(fileURLToPath(import.meta.url));

// Chunking configuration
const CHUNK_SIZE = 512;        // Target chunk size in characters
const CHUNK_OVERLAP = 64;      // Overlap between chunks
const MIN_CHUNK_SIZE = 50;     // Minimum chunk size to index

/**
 * Content scanner interface
 * Each module implements its own scanner to extract indexable content
 *
 * @typedef {Object} ContentItem
 * @property {string} id - Unique identifier
 * @property {string} type - Content type (session, journal, artifact, etc.)
 * @property {string} sourcePath - Relative path to source file
 * @property {string} title - Display title
 * @property {string} date - ISO 8601 date
 * @property {string} content - Full text content to index
 * @property {Object} metadata - Type-specific metadata
 */

/**
 * @typedef {Object} ContentScanner
 * @property {function(): Promise<ContentItem[]>} scan - Scan module for all content
 * @property {function(string): Promise<ContentItem|null>} getById - Get single item by ID
 */

export class ModuleIndexer {
  /**
   * @param {string} modulePath - Path to module directory (e.g., /vault/Chat)
   * @param {ContentScanner} scanner - Module-specific content scanner
   * @param {Object} options
   * @param {string} options.moduleName - Module name for logging
   */
  constructor(modulePath, scanner, options = {}) {
    this.modulePath = modulePath;
    this.scanner = scanner;
    this.moduleName = options.moduleName || 'Module';
    this.dbPath = join(modulePath, 'index.db');
    this.db = null;
  }

  /**
   * Initialize database connection and schema
   */
  init() {
    if (this.db) return;

    this.db = new Database(this.dbPath);
    this.db.pragma('journal_mode = WAL');

    // Load and execute schema
    const schemaPath = join(__dirname, 'index-schema.sql');
    const schema = readFileSync(schemaPath, 'utf-8');
    this.db.exec(schema);

    log.info(`Index initialized at ${this.dbPath}`);
  }

  /**
   * Close database connection
   */
  close() {
    if (this.db) {
      this.db.close();
      this.db = null;
    }
  }

  /**
   * Check if content needs re-indexing based on hash
   * @param {string} contentId
   * @param {string} contentHash
   * @returns {boolean}
   */
  needsReindex(contentId, contentHash) {
    this.init();
    const row = this.db.prepare(
      'SELECT content_hash FROM manifest WHERE content_id = ?'
    ).get(contentId);

    return !row || row.content_hash !== contentHash;
  }

  /**
   * Chunk text into smaller pieces for embedding
   * @param {string} text
   * @returns {string[]}
   */
  chunkText(text) {
    if (!text || text.length < MIN_CHUNK_SIZE) {
      return text ? [text] : [];
    }

    const chunks = [];
    let start = 0;

    while (start < text.length) {
      let end = start + CHUNK_SIZE;

      // Try to break at sentence boundary
      if (end < text.length) {
        const slice = text.slice(start, end + 100); // Look ahead a bit
        const sentenceEnd = slice.search(/[.!?]\s+/);
        if (sentenceEnd > CHUNK_SIZE * 0.5) {
          end = start + sentenceEnd + 1;
        }
      }

      const chunk = text.slice(start, Math.min(end, text.length)).trim();
      if (chunk.length >= MIN_CHUNK_SIZE) {
        chunks.push(chunk);
      }

      start = end - CHUNK_OVERLAP;
      if (start >= text.length) break;
    }

    return chunks;
  }

  /**
   * Generate content hash for change detection
   * @param {string} content
   * @returns {string}
   */
  hashContent(content) {
    return createHash('sha256').update(content).digest('hex').slice(0, 16);
  }

  /**
   * Index a single content item
   * @param {ContentItem} item
   * @param {boolean} withEmbeddings - Generate embeddings (requires Ollama)
   * @returns {Promise<{chunks: number, embedded: number}>}
   */
  async indexItem(item, withEmbeddings = true) {
    this.init();

    const contentHash = this.hashContent(item.content);

    // Skip if unchanged
    if (!this.needsReindex(item.id, contentHash)) {
      return { chunks: 0, embedded: 0, skipped: true };
    }

    const now = new Date().toISOString();
    const chunks = this.chunkText(item.content);

    // Start transaction
    const tx = this.db.transaction(() => {
      // Remove old chunks
      this.db.prepare('DELETE FROM chunks WHERE content_id = ?').run(item.id);
      this.db.prepare('DELETE FROM manifest WHERE content_id = ?').run(item.id);

      // Insert new chunks
      const insertChunk = this.db.prepare(`
        INSERT INTO chunks (id, content_id, content_type, field, chunk_index, chunk_text, embedding, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      `);

      for (let i = 0; i < chunks.length; i++) {
        insertChunk.run(
          `chunk:${item.id}:${i}`,
          item.id,
          item.type,
          'content',
          i,
          chunks[i],
          null, // Embedding added later
          now
        );
      }

      // Insert manifest entry
      this.db.prepare(`
        INSERT INTO manifest (content_id, content_type, source_path, content_hash, title, date, indexed_at, chunk_count, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        item.id,
        item.type,
        item.sourcePath,
        contentHash,
        item.title,
        item.date,
        now,
        chunks.length,
        JSON.stringify(item.metadata || {})
      );
    });

    tx();

    // Generate embeddings if requested
    let embedded = 0;
    if (withEmbeddings && chunks.length > 0) {
      embedded = await this.embedChunks(item.id, chunks);
    }

    return { chunks: chunks.length, embedded, skipped: false };
  }

  /**
   * Generate and store embeddings for chunks
   * @param {string} contentId
   * @param {string[]} chunks
   * @returns {Promise<number>} Number of chunks embedded
   */
  async embedChunks(contentId, chunks) {
    const updateEmbedding = this.db.prepare(
      'UPDATE chunks SET embedding = ? WHERE id = ?'
    );

    let embedded = 0;
    for (let i = 0; i < chunks.length; i++) {
      try {
        const vector = await generateEmbedding(chunks[i]);
        const buffer = Buffer.from(new Float64Array(vector).buffer);
        updateEmbedding.run(buffer, `chunk:${contentId}:${i}`);
        embedded++;
      } catch (err) {
        log.warn(`Failed to embed chunk ${i} of ${contentId}: ${err.message}`);
      }
    }

    return embedded;
  }

  /**
   * Rebuild entire index
   * @param {Object} options
   * @param {boolean} options.withEmbeddings - Generate embeddings (default: true)
   * @param {function(number, number)} options.onProgress - Progress callback (indexed, total)
   * @returns {Promise<{total: number, indexed: number, embedded: number, errors: number}>}
   */
  async rebuildIndex(options = {}) {
    const { withEmbeddings = true, onProgress } = options;

    this.init();
    log.info('Starting index rebuild...');

    // Check Ollama if embeddings requested
    if (withEmbeddings) {
      const status = await getOllamaStatus();
      if (!status.ready) {
        log.warn('Ollama not available, indexing without embeddings');
      }
    }

    const items = await this.scanner.scan();
    const stats = { total: items.length, indexed: 0, embedded: 0, errors: 0 };

    for (let i = 0; i < items.length; i++) {
      try {
        const result = await this.indexItem(items[i], withEmbeddings);
        if (!result.skipped) {
          stats.indexed++;
          stats.embedded += result.embedded;
        }

        if (onProgress) {
          onProgress(i + 1, items.length);
        }
      } catch (err) {
        log.error(`Failed to index ${items[i].id}: ${err.message}`);
        stats.errors++;
      }
    }

    // Update metadata
    this.db.prepare(`
      INSERT OR REPLACE INTO metadata (key, value, updated_at)
      VALUES ('last_rebuild', ?, datetime('now'))
    `).run(new Date().toISOString());

    log.info(`Index rebuild complete: ${stats.indexed}/${stats.total} items, ${stats.embedded} embeddings`);
    return stats;
  }

  /**
   * Keyword search
   * @param {string} query
   * @param {Object} options
   * @param {number} options.limit
   * @param {string} options.contentType
   * @returns {Array}
   */
  keywordSearch(query, options = {}) {
    this.init();
    const { limit = 20, contentType } = options;

    const terms = query.toLowerCase().split(/\s+/).filter(t => t.length > 2);
    if (terms.length === 0) return [];

    let sql = `
      SELECT
        c.content_id,
        c.content_type,
        c.chunk_text,
        m.title,
        m.date,
        m.source_path
      FROM chunks c
      JOIN manifest m ON c.content_id = m.content_id
      WHERE 1=1
    `;

    const params = [];

    if (contentType) {
      sql += ' AND c.content_type = ?';
      params.push(contentType);
    }

    // Add term matching
    const termClauses = terms.map(() => 'LOWER(c.chunk_text) LIKE ?');
    sql += ` AND (${termClauses.join(' OR ')})`;
    params.push(...terms.map(t => `%${t}%`));

    sql += ' ORDER BY m.date DESC LIMIT ?';
    params.push(limit);

    const rows = this.db.prepare(sql).all(...params);

    // Dedupe by content_id and add snippets
    const seen = new Set();
    return rows.filter(row => {
      if (seen.has(row.content_id)) return false;
      seen.add(row.content_id);
      return true;
    }).map(row => ({
      id: row.content_id,
      type: row.content_type,
      title: row.title,
      date: row.date,
      sourcePath: row.source_path,
      snippet: this.extractSnippet(row.chunk_text, terms[0]),
      matchType: 'keyword',
    }));
  }

  /**
   * Semantic search using embeddings
   * @param {string} query
   * @param {Object} options
   * @param {number} options.limit
   * @param {string} options.contentType
   * @param {number} options.minSimilarity
   * @returns {Promise<Array>}
   */
  async semanticSearch(query, options = {}) {
    this.init();
    const { limit = 20, contentType, minSimilarity = 0.3 } = options;

    // Generate query embedding
    let queryVector;
    try {
      queryVector = await generateEmbedding(query);
    } catch (err) {
      log.warn(`Semantic search unavailable: ${err.message}`);
      return [];
    }

    // Get all chunks with embeddings
    let sql = `
      SELECT
        c.content_id,
        c.content_type,
        c.chunk_text,
        c.embedding,
        m.title,
        m.date,
        m.source_path
      FROM chunks c
      JOIN manifest m ON c.content_id = m.content_id
      WHERE c.embedding IS NOT NULL
    `;

    const params = [];
    if (contentType) {
      sql += ' AND c.content_type = ?';
      params.push(contentType);
    }

    const rows = this.db.prepare(sql).all(...params);

    // Calculate similarities
    const scored = rows.map(row => {
      const embedding = new Float64Array(row.embedding.buffer);
      const similarity = cosineSimilarity(queryVector, Array.from(embedding));
      return { ...row, similarity };
    }).filter(r => r.similarity >= minSimilarity);

    // Sort by similarity and dedupe
    scored.sort((a, b) => b.similarity - a.similarity);

    const seen = new Set();
    return scored.filter(row => {
      if (seen.has(row.content_id)) return false;
      seen.add(row.content_id);
      return true;
    }).slice(0, limit).map(row => ({
      id: row.content_id,
      type: row.content_type,
      title: row.title,
      date: row.date,
      sourcePath: row.source_path,
      snippet: row.chunk_text.slice(0, 200),
      similarity: row.similarity,
      matchType: 'semantic',
    }));
  }

  /**
   * Hybrid search combining keyword and semantic
   * @param {string} query
   * @param {Object} options
   * @returns {Promise<Array>}
   */
  async search(query, options = {}) {
    const { limit = 20 } = options;

    // Run both searches
    const [keywordResults, semanticResults] = await Promise.all([
      this.keywordSearch(query, { ...options, limit }),
      this.semanticSearch(query, { ...options, limit }).catch(() => []),
    ]);

    // Merge results, preferring semantic matches
    const resultMap = new Map();

    for (const r of semanticResults) {
      resultMap.set(r.id, { ...r, matchType: 'semantic' });
    }

    for (const r of keywordResults) {
      if (!resultMap.has(r.id)) {
        resultMap.set(r.id, { ...r, matchType: 'keyword' });
      } else {
        // Boost items found by both
        const existing = resultMap.get(r.id);
        existing.matchType = 'both';
      }
    }

    // Sort: 'both' first, then by similarity/date
    const results = Array.from(resultMap.values());
    results.sort((a, b) => {
      if (a.matchType === 'both' && b.matchType !== 'both') return -1;
      if (b.matchType === 'both' && a.matchType !== 'both') return 1;
      if (a.similarity && b.similarity) return b.similarity - a.similarity;
      return new Date(b.date) - new Date(a.date);
    });

    return results.slice(0, limit);
  }

  /**
   * Get index statistics
   * @returns {Object}
   */
  getStats() {
    this.init();

    const chunkCount = this.db.prepare('SELECT COUNT(*) as count FROM chunks').get().count;
    const embeddedCount = this.db.prepare('SELECT COUNT(*) as count FROM chunks WHERE embedding IS NOT NULL').get().count;
    const contentCount = this.db.prepare('SELECT COUNT(*) as count FROM manifest').get().count;

    const typeStats = this.db.prepare(`
      SELECT content_type, COUNT(*) as count
      FROM manifest
      GROUP BY content_type
    `).all();

    const lastRebuild = this.db.prepare(
      "SELECT value FROM metadata WHERE key = 'last_rebuild'"
    ).get();

    return {
      module: this.moduleName,
      path: this.dbPath,
      contentCount,
      chunkCount,
      embeddedCount,
      embeddingCoverage: chunkCount > 0 ? (embeddedCount / chunkCount * 100).toFixed(1) + '%' : '0%',
      byType: Object.fromEntries(typeStats.map(r => [r.content_type, r.count])),
      lastRebuild: lastRebuild?.value || null,
    };
  }

  /**
   * Extract a snippet around the search term
   * @param {string} text
   * @param {string} term
   * @returns {string}
   */
  extractSnippet(text, term, maxLength = 200) {
    const lower = text.toLowerCase();
    const idx = lower.indexOf(term.toLowerCase());

    if (idx === -1) {
      return text.slice(0, maxLength);
    }

    const start = Math.max(0, idx - 50);
    const end = Math.min(text.length, idx + term.length + 150);
    let snippet = text.slice(start, end);

    if (start > 0) snippet = '...' + snippet;
    if (end < text.length) snippet = snippet + '...';

    return snippet;
  }

  /**
   * Get content by ID
   * @param {string} contentId
   * @returns {Object|null}
   */
  getContent(contentId) {
    this.init();

    const manifest = this.db.prepare(
      'SELECT * FROM manifest WHERE content_id = ?'
    ).get(contentId);

    if (!manifest) return null;

    const chunks = this.db.prepare(
      'SELECT chunk_text FROM chunks WHERE content_id = ? ORDER BY chunk_index'
    ).all(contentId);

    return {
      id: manifest.content_id,
      type: manifest.content_type,
      title: manifest.title,
      date: manifest.date,
      sourcePath: manifest.source_path,
      content: chunks.map(c => c.chunk_text).join(' '),
      metadata: JSON.parse(manifest.metadata || '{}'),
      indexedAt: manifest.indexed_at,
    };
  }

  /**
   * List recent content
   * @param {Object} options
   * @returns {Array}
   */
  listRecent(options = {}) {
    this.init();
    const { limit = 20, contentType } = options;

    let sql = 'SELECT * FROM manifest';
    const params = [];

    if (contentType) {
      sql += ' WHERE content_type = ?';
      params.push(contentType);
    }

    sql += ' ORDER BY date DESC LIMIT ?';
    params.push(limit);

    return this.db.prepare(sql).all(...params).map(row => ({
      id: row.content_id,
      type: row.content_type,
      title: row.title,
      date: row.date,
      sourcePath: row.source_path,
      chunkCount: row.chunk_count,
      indexedAt: row.indexed_at,
    }));
  }
}

export default ModuleIndexer;
