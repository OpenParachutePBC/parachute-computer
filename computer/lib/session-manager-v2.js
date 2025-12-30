/**
 * Session Manager v2 - Simplified
 *
 * Uses Claude Agent SDK's session ID as the ONLY session identifier.
 * The SDK handles all session persistence and context rebuilding.
 * Markdown files are just human-readable mirrors for Obsidian compatibility.
 *
 * Key simplifications:
 * - ONE session ID: The SDK's session_id
 * - NO context injection: SDK rebuilds context from its own storage
 * - NO session_key: Direct lookup by SDK ID
 * - Markdown = human-readable archive only
 */

import fs from 'fs/promises';
import fsSync from 'fs';
import path from 'path';
import { generateSessionTitle } from './title-generator.js';
import { ParaIdService, ParaIdType, getParaIdService } from './para-id-service.js';

/**
 * Session resumption info for debugging/visibility
 */
export class SessionResumeInfo {
  constructor() {
    this.isNewSession = true;
    this.sdkSessionId = null;
    this.previousMessageCount = 0;
    this.loadedFromDisk = false;
    this.cacheHit = false;
  }

  toJSON() {
    // method: 'new' | 'sdk_resume' (no more context_injection in v2)
    const method = this.isNewSession ? 'new' : 'sdk_resume';

    return {
      method,
      isNewSession: this.isNewSession,
      sdkSessionId: this.sdkSessionId ? `${this.sdkSessionId.slice(0, 8)}...` : null,
      sdkSessionValid: !this.isNewSession && this.sdkSessionId != null,
      sdkResumeAttempted: !this.isNewSession,
      previousMessageCount: this.previousMessageCount,
      loadedFromDisk: this.loadedFromDisk,
      cacheHit: this.cacheHit,
      // These are always false in v2 (no context injection)
      contextInjected: false,
      messagesInjected: 0,
      tokensEstimate: 0
    };
  }

  toString() {
    if (this.isNewSession) {
      return `[New Session]`;
    }
    return `[Resume] ${this.previousMessageCount} msgs in history`;
  }
}

export class SessionManager {
  constructor(vaultPath) {
    this.vaultPath = vaultPath;
    // Sessions stored in Chat module folder
    this.sessionsPath = path.join(vaultPath, 'Chat', 'sessions');

    // Index by SDK session ID
    // sdkSessionId -> { filePath, agentPath, title, ... }
    this.sessionIndex = new Map();

    // Full sessions loaded on-demand
    // sdkSessionId -> full session object
    this.loadedSessions = new Map();

    // Para ID service for generating unique message IDs
    this.paraIdService = getParaIdService(vaultPath);

    // Cache settings
    this.cacheMaxAge = 30 * 60 * 1000; // 30 minutes

    // Write locks to prevent concurrent writes to same session
    // sdkSessionId -> Promise (resolves when write completes)
    this.writeLocks = new Map();
  }

  /**
   * Acquire a write lock for a session
   * Returns a release function to call when done
   * Throws if lock cannot be acquired within timeout
   */
  async acquireWriteLock(sdkSessionId, timeoutMs = 30000) {
    const startTime = Date.now();

    // Wait for any pending write to complete (with timeout)
    while (this.writeLocks.has(sdkSessionId)) {
      const elapsed = Date.now() - startTime;
      if (elapsed >= timeoutMs) {
        throw new Error(`Write lock timeout for session ${sdkSessionId.slice(0, 8)}... after ${timeoutMs}ms`);
      }

      // Wait with remaining timeout
      const remaining = timeoutMs - elapsed;
      try {
        await Promise.race([
          this.writeLocks.get(sdkSessionId),
          new Promise((_, reject) =>
            setTimeout(() => reject(new Error('Lock wait timeout')), remaining)
          )
        ]);
      } catch (e) {
        if (e.message === 'Lock wait timeout') {
          throw new Error(`Write lock timeout for session ${sdkSessionId.slice(0, 8)}... after ${timeoutMs}ms`);
        }
        throw e;
      }
    }

    // Create our lock
    let releaseLock;
    const lockPromise = new Promise(resolve => {
      releaseLock = resolve;
    });
    this.writeLocks.set(sdkSessionId, lockPromise);

    return () => {
      this.writeLocks.delete(sdkSessionId);
      releaseLock();
    };
  }

  /**
   * Initialize session manager
   */
  async initialize() {
    await fs.mkdir(this.sessionsPath, { recursive: true });
    await this.paraIdService.initialize();
    await this.buildSessionIndex();

    // Cleanup if index is too large after initial load
    this.cleanupSessionIndex();

    console.log(`[SessionManager] Indexed ${this.sessionIndex.size} sessions`);

    // Periodic cleanup every hour
    this.cleanupInterval = setInterval(() => {
      this.cleanupSessionIndex();
    }, 60 * 60 * 1000); // 1 hour
  }

  /**
   * Shutdown session manager (cleanup resources)
   */
  shutdown() {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
      this.cleanupInterval = null;
    }
  }

  /**
   * Reload the session index from disk
   */
  async reloadSessionIndex() {
    console.log('[SessionManager] Reloading session index...');
    this.sessionIndex.clear();
    this.loadedSessions.clear();
    await this.buildSessionIndex();
    console.log(`[SessionManager] Reloaded ${this.sessionIndex.size} sessions`);
  }

  /**
   * Build session index from markdown files
   */
  async buildSessionIndex() {
    await this.indexSessionsFromDir(this.sessionsPath);

    // Also index legacy paths
    const legacyPaths = [
      path.join(this.vaultPath, 'agent-chats'),
      path.join(this.vaultPath, 'agent-logs')
    ];
    for (const legacyPath of legacyPaths) {
      try {
        await this.indexSessionsFromDir(legacyPath);
      } catch (e) {
        // Legacy directory may not exist
      }
    }
  }

  /**
   * Recursively index sessions from a directory
   */
  async indexSessionsFromDir(dir) {
    try {
      const entries = await fs.readdir(dir, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          await this.indexSessionsFromDir(fullPath);
        } else if (entry.name.endsWith('.md')) {
          await this.indexSessionFromFile(fullPath);
        }
      }
    } catch (e) {
      // Directory doesn't exist
    }
  }

  /**
   * Add a session to the index
   */
  async indexSessionFromFile(filePath) {
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const matter = this.parseFrontmatter(content);

      // SDK session ID is the primary key
      const sdkSessionId = matter.data.sdk_session_id;
      if (!sdkSessionId || sdkSessionId === '' || sdkSessionId === '[object Object]') {
        // Skip sessions without valid SDK ID (legacy or corrupted)
        return;
      }

      this.sessionIndex.set(sdkSessionId, {
        sdkSessionId,
        filePath,
        agentPath: matter.data.agent || 'vault-agent',
        agentName: matter.data.agent_name,
        title: matter.data.title || null,
        createdAt: matter.data.created_at,
        lastAccessed: matter.data.last_accessed,
        archived: matter.data.archived === 'true' || matter.data.archived === true,
        workingDirectory: matter.data.working_directory || null,
        continuedFrom: matter.data.continued_from || null,
        messageCount: (content.match(/### (Human|User|Assistant|System) \|/g) || []).length
      });
    } catch (e) {
      console.error(`[SessionManager] Error indexing ${filePath}:`, e.message);
    }
  }

  /**
   * Get or create a session
   *
   * @param {string|null} sdkSessionId - SDK session ID if resuming, null for new
   * @param {string} agentPath - Agent path
   * @param {object} options - { workingDirectory, continuedFrom }
   * @returns {{ session, resumeInfo, isNew }}
   */
  async getSession(sdkSessionId, agentPath, options = {}) {
    const resumeInfo = new SessionResumeInfo();

    // Resuming existing session
    if (sdkSessionId) {
      // Check memory cache
      if (this.loadedSessions.has(sdkSessionId)) {
        const session = this.loadedSessions.get(sdkSessionId);
        session.lastAccessed = new Date().toISOString();
        resumeInfo.isNewSession = false;
        resumeInfo.sdkSessionId = sdkSessionId;
        resumeInfo.cacheHit = true;
        resumeInfo.previousMessageCount = session.messages.length;
        console.log(`[SessionManager] Cache hit: ${sdkSessionId.slice(0, 8)}...`);
        return { session, resumeInfo, isNew: false };
      }

      // Check index and load from disk
      if (this.sessionIndex.has(sdkSessionId)) {
        const index = this.sessionIndex.get(sdkSessionId);
        const session = await this.loadSessionFromFile(index.filePath);
        if (session) {
          session.lastAccessed = new Date().toISOString();
          resumeInfo.isNewSession = false;
          resumeInfo.sdkSessionId = sdkSessionId;
          resumeInfo.loadedFromDisk = true;
          resumeInfo.previousMessageCount = session.messages.length;
          console.log(`[SessionManager] Loaded from disk: ${sdkSessionId.slice(0, 8)}...`);
          return { session, resumeInfo, isNew: false };
        }
      }

      // SDK ID provided but not found - might be a new SDK session from resumed conversation
      console.log(`[SessionManager] SDK ID ${sdkSessionId.slice(0, 8)}... not in index, treating as new`);
    }

    // New session - we'll get the SDK ID after first message
    // Create a placeholder session that will be finalized after SDK response
    const session = {
      sdkSessionId: null, // Will be set after SDK response
      agentPath: agentPath || 'vault-agent',
      title: null,
      messages: [],
      filePath: null, // Will be set when we get SDK ID
      createdAt: new Date().toISOString(),
      lastAccessed: new Date().toISOString(),
      archived: false,
      workingDirectory: options.workingDirectory || null,
      continuedFrom: options.continuedFrom || null
    };

    resumeInfo.isNewSession = true;
    console.log(`[SessionManager] New session (pending SDK ID)`);
    return { session, resumeInfo, isNew: true };
  }

  /**
   * Finalize a new session after receiving SDK session ID
   * Called after first SDK response with the session_id
   * Uses write lock to prevent race conditions from concurrent requests
   */
  async finalizeSession(session, sdkSessionId) {
    console.log(`[SessionManager] finalizeSession called with SDK ID: ${sdkSessionId?.slice(0, 12) || 'null'}`);
    if (!sdkSessionId || typeof sdkSessionId !== 'string') {
      console.error(`[SessionManager] Cannot finalize session: invalid SDK ID (got ${typeof sdkSessionId})`);
      return;
    }

    // Check if already finalized (race condition guard)
    if (session.sdkSessionId === sdkSessionId) {
      console.log(`[SessionManager] Session already finalized with this SDK ID`);
      return;
    }

    // Acquire write lock to prevent concurrent finalization
    const releaseLock = await this.acquireWriteLock(sdkSessionId);

    try {
      // Double-check after acquiring lock
      if (session.sdkSessionId === sdkSessionId) {
        console.log(`[SessionManager] Session finalized by another request`);
        return;
      }

      session.sdkSessionId = sdkSessionId;

      // Generate file path using SDK ID
      const agentName = (session.agentPath || 'vault-agent').replace('agents/', '').replace('.md', '');
      const today = new Date().toISOString().split('T')[0];
      const shortId = sdkSessionId.slice(0, 8);
      session.filePath = path.join(this.sessionsPath, agentName, `${today}-${shortId}.md`);

      // Ensure directory exists
      await fs.mkdir(path.dirname(session.filePath), { recursive: true });

      // Add to cache and index
      this.loadedSessions.set(sdkSessionId, session);
      this.sessionIndex.set(sdkSessionId, {
        sdkSessionId,
        filePath: session.filePath,
        agentPath: session.agentPath,
        agentName,
        title: session.title,
        createdAt: session.createdAt,
        lastAccessed: session.lastAccessed,
        archived: false,
        workingDirectory: session.workingDirectory,
        continuedFrom: session.continuedFrom,
        messageCount: session.messages.length
      });

      // Save to disk
      await this.saveSession(session);
      console.log(`[SessionManager] Finalized session: ${sdkSessionId.slice(0, 8)}... at ${session.filePath}`);
    } finally {
      releaseLock();
    }
  }

  /**
   * Load full session from markdown file
   */
  async loadSessionFromFile(filePath) {
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const session = this.parseSessionMarkdown(content, filePath);
      if (session) {
        this.loadedSessions.set(session.sdkSessionId, session);
      }
      return session;
    } catch (e) {
      console.error(`[SessionManager] Error loading session from ${filePath}:`, e.message);
      return null;
    }
  }

  /**
   * Parse a session from markdown format
   */
  parseSessionMarkdown(content, filePath) {
    const matter = this.parseFrontmatter(content);
    const sdkSessionId = matter.data.sdk_session_id;

    if (!sdkSessionId || sdkSessionId === '' || sdkSessionId === '[object Object]') {
      return null;
    }

    return {
      sdkSessionId,
      agentPath: matter.data.agent || 'vault-agent',
      title: matter.data.title || null,
      messages: this.parseMessages(matter.body),
      filePath,
      createdAt: matter.data.created_at,
      lastAccessed: matter.data.last_accessed,
      archived: matter.data.archived === 'true' || matter.data.archived === true,
      workingDirectory: matter.data.working_directory || null,
      continuedFrom: matter.data.continued_from || null
    };
  }

  /**
   * Parse frontmatter from markdown
   */
  parseFrontmatter(content) {
    const match = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
    if (!match) {
      return { data: {}, body: content };
    }

    const yamlStr = match[1];
    const body = match[2];
    const data = {};

    for (const line of yamlStr.split('\n')) {
      const colonIdx = line.indexOf(':');
      if (colonIdx > 0) {
        const key = line.slice(0, colonIdx).trim();
        let value = line.slice(colonIdx + 1).trim();

        if ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'"))) {
          value = value.slice(1, -1);
        }

        data[key] = value;
      }
    }

    return { data, body };
  }

  /**
   * Parse messages from markdown body
   */
  parseMessages(body) {
    const messages = [];
    const regex = /### (para:[a-z0-9]+\s+)?(Human|User|Assistant|System) \| (\d{4}-\d{2}-\d{2}T[\d:.]+Z?)\n\n([\s\S]*?)(?=\n### |\n---|\n## |$)/g;

    let match;
    while ((match = regex.exec(body)) !== null) {
      const headerLine = `### ${match[1] || ''}${match[2]} | ${match[3]}`;
      const paraId = ParaIdService.parseFromH3(headerLine);
      const roleStr = match[2];
      const role = (roleStr === 'Human' || roleStr === 'User') ? 'user' : roleStr.toLowerCase();

      messages.push({
        role,
        timestamp: match[3],
        content: match[4].trim(),
        paraId: paraId || null
      });
    }

    return messages;
  }

  /**
   * Add a message to session (updates markdown mirror)
   * Uses write lock to prevent concurrent writes losing data
   */
  async addMessage(session, role, content) {
    if (!session.sdkSessionId) {
      console.warn(`[SessionManager] Cannot add message - session not finalized`);
      return;
    }

    // Acquire write lock to prevent race conditions
    const releaseLock = await this.acquireWriteLock(session.sdkSessionId);

    try {
      const paraId = await this.paraIdService.generate(ParaIdType.MESSAGE, session.filePath);

      session.messages.push({
        role,
        content,
        timestamp: new Date().toISOString(),
        paraId
      });
      session.lastAccessed = new Date().toISOString();

      await this.saveSession(session);
      console.log(`[SessionManager] Added ${role} message (para:${paraId})`);
    } finally {
      releaseLock();
    }
  }

  /**
   * Generate a title for a session if it doesn't have one
   */
  async maybeGenerateTitle(session, agentName) {
    if (session.title) return session.title;

    const hasUser = session.messages.some(m => m.role === 'user');
    const hasAssistant = session.messages.some(m => m.role === 'assistant');
    if (!hasUser || !hasAssistant) return null;

    try {
      const title = await generateSessionTitle(session.messages, agentName);
      if (title) {
        session.title = title;
        await this.saveSession(session);
        console.log(`[SessionManager] Set title: "${title}"`);
        return title;
      }
    } catch (error) {
      console.error(`[SessionManager] Error generating title:`, error.message);
    }

    return null;
  }

  /**
   * Save session to markdown file
   * Uses atomic write (write to temp, then rename) to prevent corruption
   */
  async saveSession(session) {
    console.log(`[SessionManager] saveSession called:`, {
      hasFilePath: !!session.filePath,
      hasSdkSessionId: !!session.sdkSessionId,
      filePath: session.filePath,
      sdkSessionId: session.sdkSessionId?.slice(0, 12)
    });

    if (!session.filePath || !session.sdkSessionId) {
      console.warn(`[SessionManager] Cannot save - session not finalized (filePath=${session.filePath}, sdkId=${session.sdkSessionId})`);
      return;
    }

    try {
      console.log(`[SessionManager] Writing to: ${session.filePath}`);
      await fs.mkdir(path.dirname(session.filePath), { recursive: true });
      const markdown = this.sessionToMarkdown(session);

      // Atomic write: write to temp file, then rename
      const tempPath = `${session.filePath}.tmp.${Date.now()}`;
      await fs.writeFile(tempPath, markdown, 'utf-8');
      await fs.rename(tempPath, session.filePath);
      console.log(`[SessionManager] Successfully wrote session file`);

      // Update index
      const agentName = (session.agentPath || 'vault-agent').replace('agents/', '').replace('.md', '');
      this.sessionIndex.set(session.sdkSessionId, {
        sdkSessionId: session.sdkSessionId,
        filePath: session.filePath,
        agentPath: session.agentPath,
        agentName,
        title: session.title,
        createdAt: session.createdAt,
        lastAccessed: session.lastAccessed,
        archived: session.archived,
        workingDirectory: session.workingDirectory,
        continuedFrom: session.continuedFrom,
        messageCount: session.messages.length
      });
    } catch (e) {
      console.error(`[SessionManager] Failed to save session:`, e.message);
    }
  }

  /**
   * Convert session to markdown format
   */
  sessionToMarkdown(session) {
    const agentName = (session.agentPath || 'vault-agent').replace('agents/', '').replace('.md', '');
    const heading = session.title || `Chat with ${agentName}`;

    // Build frontmatter
    const frontmatterLines = [
      `sdk_session_id: "${session.sdkSessionId}"`,
      `agent: "${session.agentPath}"`,
      `agent_name: "${agentName}"`,
    ];

    if (session.title) {
      frontmatterLines.push(`title: "${session.title}"`);
    }

    frontmatterLines.push(
      `type: chat`,
      `created_at: "${session.createdAt}"`,
      `last_accessed: "${session.lastAccessed}"`,
      `archived: ${session.archived || false}`
    );

    if (session.workingDirectory) {
      frontmatterLines.push(`working_directory: "${session.workingDirectory}"`);
    }

    if (session.continuedFrom) {
      frontmatterLines.push(`continued_from: "${session.continuedFrom}"`);
    }

    let md = `---\n${frontmatterLines.join('\n')}\n---\n\n# ${heading}\n\n## Conversation\n\n`;

    for (const msg of session.messages) {
      const role = msg.role === 'user' ? 'Human' : 'Assistant';
      const timestamp = msg.timestamp || new Date().toISOString();

      if (msg.paraId) {
        md += `### para:${msg.paraId} ${role} | ${timestamp}\n\n${msg.content}\n\n`;
      } else {
        md += `### ${role} | ${timestamp}\n\n${msg.content}\n\n`;
      }
    }

    return md;
  }

  /**
   * List all sessions
   */
  listSessions() {
    return Array.from(this.sessionIndex.values())
      .filter(s => s && s.sdkSessionId)
      .map(s => ({
        id: s.sdkSessionId, // SDK session ID is the only ID
        sdkSessionId: s.sdkSessionId,
        agentPath: s.agentPath || 'vault-agent',
        agentName: s.agentName || 'vault-agent',
        title: s.title || null,
        messageCount: s.messageCount || 0,
        createdAt: s.createdAt,
        lastAccessed: s.lastAccessed,
        filePath: s.filePath ? s.filePath.replace(this.vaultPath + '/', '') : null,
        archived: s.archived || false,
        workingDirectory: s.workingDirectory || null,
        continuedFrom: s.continuedFrom || null
      }));
  }

  /**
   * Cleanup session index to prevent unbounded memory growth
   * Keeps most recently accessed sessions up to maxIndexSize
   */
  cleanupSessionIndex(maxIndexSize = 1000) {
    if (this.sessionIndex.size <= maxIndexSize) {
      return; // No cleanup needed
    }

    // Sort by lastAccessed descending (most recent first)
    const sorted = Array.from(this.sessionIndex.entries())
      .sort((a, b) => {
        const dateA = a[1]?.lastAccessed ? new Date(a[1].lastAccessed) : new Date(0);
        const dateB = b[1]?.lastAccessed ? new Date(b[1].lastAccessed) : new Date(0);
        return dateB - dateA;
      });

    // Keep only the most recent entries
    const toKeep = sorted.slice(0, maxIndexSize);
    const removedCount = this.sessionIndex.size - toKeep.length;

    this.sessionIndex = new Map(toKeep);

    // Also clean up loaded sessions that are no longer indexed
    for (const sdkSessionId of this.loadedSessions.keys()) {
      if (!this.sessionIndex.has(sdkSessionId)) {
        this.loadedSessions.delete(sdkSessionId);
      }
    }

    console.log(`[SessionManager] Trimmed session index: removed ${removedCount} old entries, kept ${toKeep.length}`);
  }

  /**
   * Get session by SDK session ID
   */
  async getSessionById(sdkSessionId) {
    if (this.loadedSessions.has(sdkSessionId)) {
      return this.loadedSessions.get(sdkSessionId);
    }

    if (this.sessionIndex.has(sdkSessionId)) {
      const index = this.sessionIndex.get(sdkSessionId);
      return await this.loadSessionFromFile(index.filePath);
    }

    return null;
  }

  /**
   * Archive a session
   */
  async archiveSession(sdkSessionId) {
    const session = await this.getSessionById(sdkSessionId);
    if (session) {
      session.archived = true;
      session.lastAccessed = new Date().toISOString();
      await this.saveSession(session);
      return true;
    }
    return false;
  }

  /**
   * Unarchive a session
   */
  async unarchiveSession(sdkSessionId) {
    const session = await this.getSessionById(sdkSessionId);
    if (session) {
      session.archived = false;
      session.lastAccessed = new Date().toISOString();
      await this.saveSession(session);
      return true;
    }
    return false;
  }

  /**
   * Delete a session
   */
  async deleteSession(sdkSessionId) {
    const session = await this.getSessionById(sdkSessionId);
    if (!session) return false;

    if (session.filePath) {
      try {
        await fs.unlink(session.filePath);
      } catch (e) {
        // Ignore if file doesn't exist
      }
    }

    this.loadedSessions.delete(sdkSessionId);
    this.sessionIndex.delete(sdkSessionId);
    console.log(`[SessionManager] Deleted session: ${sdkSessionId.slice(0, 8)}...`);
    return true;
  }

  /**
   * Evict stale sessions from memory cache
   */
  evictStaleSessions() {
    const now = Date.now();
    let evicted = 0;

    for (const [key, session] of this.loadedSessions) {
      const lastAccess = new Date(session.lastAccessed).getTime();
      if (now - lastAccess > this.cacheMaxAge) {
        this.loadedSessions.delete(key);
        evicted++;
      }
    }

    if (evicted > 0) {
      console.log(`[SessionManager] Evicted ${evicted} stale sessions`);
    }

    return evicted;
  }

  /**
   * Clean up old sessions
   */
  async cleanupOldSessions(maxAgeDays = 30) {
    this.evictStaleSessions();
    return 0; // Keep all sessions for history
  }

  /**
   * Get session stats
   */
  getStats() {
    return {
      indexedSessions: this.sessionIndex.size,
      loadedSessions: this.loadedSessions.size,
      cacheMaxAge: this.cacheMaxAge
    };
  }
}

export default SessionManager;
