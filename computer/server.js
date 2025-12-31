/**
 * Parachute Base Server
 *
 * Clean 8-endpoint API for AI agent execution.
 *
 * Core API:
 *   GET  /api/health           - Health check
 *   POST /api/chat             - Run agent (streaming)
 *   GET  /api/chat             - List sessions
 *   GET  /api/chat/:id         - Get session
 *   DELETE /api/chat/:id       - Delete session
 *
 * Module Resources:
 *   GET  /api/modules/:mod/prompt   - Get module prompt
 *   PUT  /api/modules/:mod/prompt   - Update module prompt
 *   GET  /api/modules/:mod/search   - Search module content
 *   POST /api/modules/:mod/index    - Rebuild module index
 */

import express from 'express';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs/promises';

import { Orchestrator } from './lib/orchestrator.js';
import { PARACHUTE_DEFAULT_PROMPT } from './lib/default-prompt.js';
import { serverLogger as log } from './lib/logger.js';
import { getModuleSearchService } from './lib/module-search.js';
import { getOllamaStatus } from './lib/ollama-service.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Configuration
const CONFIG = {
  port: process.env.PORT || 3333,
  host: process.env.HOST || '0.0.0.0',
  vaultPath: process.env.VAULT_PATH || path.join(__dirname, 'sample-vault'),
  corsOrigins: process.env.CORS_ORIGINS || '*',
  apiKey: process.env.API_KEY || null,
  maxMessageLength: parseInt(process.env.MAX_MESSAGE_LENGTH || '102400', 10),
};

const app = express();
app.use(express.json());

// CORS middleware
const allowedOrigins = CONFIG.corsOrigins === '*'
  ? null
  : CONFIG.corsOrigins.split(',').map(o => o.trim()).filter(Boolean);

app.use((req, res, next) => {
  const origin = req.headers.origin;

  if (allowedOrigins === null) {
    res.header('Access-Control-Allow-Origin', '*');
  } else if (origin && allowedOrigins.includes(origin)) {
    res.header('Access-Control-Allow-Origin', origin);
    res.header('Vary', 'Origin');
  }

  res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-API-Key');

  if (req.method === 'OPTIONS') {
    return res.sendStatus(200);
  }
  next();
});

// Optional API key authentication
const apiKeyAuth = (req, res, next) => {
  if (!CONFIG.apiKey) return next();

  const providedKey = req.headers['x-api-key'] || req.headers['authorization']?.replace('Bearer ', '');
  if (providedKey !== CONFIG.apiKey) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
};

app.use('/api', apiKeyAuth);
app.use(express.static(path.join(__dirname, 'public')));

// Initialize orchestrator
const orchestrator = new Orchestrator(CONFIG.vaultPath, {
  maxDepth: 3,
  maxConcurrent: 1,
  persistQueue: true
});

// ============================================================================
// CORE API (8 endpoints)
// ============================================================================

/**
 * GET /api/health
 * Health check endpoint
 */
app.get('/api/health', async (req, res) => {
  const basic = { status: 'ok', timestamp: Date.now() };

  if (req.query.detailed !== 'true') {
    return res.json(basic);
  }

  // Detailed health check
  try {
    const sessionStats = orchestrator.getSessionStats();
    let vaultStatus = 'ok';
    try {
      await fs.access(CONFIG.vaultPath);
    } catch {
      vaultStatus = 'inaccessible';
    }

    res.json({
      ...basic,
      vault: {
        path: CONFIG.vaultPath,
        status: vaultStatus
      },
      sessions: sessionStats,
      uptime: process.uptime()
    });
  } catch (error) {
    res.json({ ...basic, error: error.message });
  }
});

/**
 * POST /api/chat
 * Run agent with streaming response (SSE)
 *
 * Body: {
 *   message: string,
 *   sessionId?: string,
 *   module?: string,          // 'chat' | 'build' | etc
 *   systemPrompt?: string,    // Module provides this (or null for SDK default)
 *   workingDirectory?: string // Where agent operates
 * }
 */
app.post('/api/chat', async (req, res) => {
  // Set SSE headers
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.flushHeaders();

  let clientDisconnected = false;
  res.on('close', () => {
    if (!clientDisconnected) {
      clientDisconnected = true;
      log.info('Client disconnected from stream');
    }
  });

  // Heartbeat to prevent proxy timeouts
  const heartbeatInterval = setInterval(() => {
    if (!clientDisconnected) {
      res.write(': heartbeat\n\n');
    }
  }, 15000);

  const {
    message,
    sessionId,
    module = 'chat',
    systemPrompt,
    workingDirectory,
    agentPath,           // Legacy: specific agent file
    initialContext,      // Legacy: initial context
    contexts,            // Legacy: context files to load
    priorConversation,   // Legacy: prior conversation for continuations
    continuedFrom        // Legacy: session this continues from
  } = req.body;

  if (!message) {
    clearInterval(heartbeatInterval);
    res.write(`data: ${JSON.stringify({ type: 'error', error: 'message is required' })}\n\n`);
    res.end();
    return;
  }

  if (message.length > CONFIG.maxMessageLength) {
    clearInterval(heartbeatInterval);
    res.write(`data: ${JSON.stringify({ type: 'error', error: `Message too long: ${message.length} chars exceeds limit of ${CONFIG.maxMessageLength}` })}\n\n`);
    res.end();
    return;
  }

  log.info('Chat request', {
    sessionId,
    module,
    workingDirectory,
    hasSystemPrompt: !!systemPrompt
  });

  const context = {};
  if (sessionId) context.sessionId = sessionId;
  if (workingDirectory) context.workingDirectory = workingDirectory;
  if (systemPrompt) context.systemPrompt = systemPrompt;
  if (module) context.module = module;

  // Legacy support
  if (initialContext) context.initialContext = initialContext;
  if (contexts && Array.isArray(contexts)) context.contexts = contexts;
  if (priorConversation) context.priorConversation = priorConversation;
  if (continuedFrom) context.continuedFrom = continuedFrom;

  try {
    const stream = orchestrator.runImmediateStreaming(
      agentPath || null,
      message,
      context
    );

    // IMPORTANT: Don't break on disconnect - let the orchestrator complete
    // so Claude finishes its work and the session gets saved properly.
    // This enables multi-device: start on tablet, pick up on phone.
    for await (const event of stream) {
      if (!clientDisconnected) {
        res.write(`data: ${JSON.stringify(event)}\n\n`);
      }
      // If client disconnected, we still consume events to let orchestrator finish
    }

    if (clientDisconnected) {
      log.info('Stream completed after client disconnect - session saved');
    }
  } catch (error) {
    log.error('Stream error', error);
    if (!clientDisconnected) {
      res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
    }
  } finally {
    clearInterval(heartbeatInterval);
  }

  if (!clientDisconnected) {
    res.end();
  }
});

/**
 * GET /api/chat
 * List all sessions
 * Query params: module, limit, offset, archived
 */
app.get('/api/chat', async (req, res) => {
  try {
    const { module, limit = 100, offset = 0, archived } = req.query;

    const options = {
      limit: parseInt(limit, 10),
      offset: parseInt(offset, 10)
    };

    if (archived !== undefined) {
      options.archived = archived === 'true';
    }

    const sessions = orchestrator.listChatSessions();

    // Filter by module if specified
    const filtered = module
      ? sessions.filter(s => s.module === module || (!s.module && module === 'chat'))
      : sessions;

    res.json({ sessions: filtered });
  } catch (error) {
    log.error('List sessions error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/chat/:id
 * Get session by ID with messages
 */
app.get('/api/chat/:id', async (req, res) => {
  try {
    const session = await orchestrator.getSessionById(req.params.id);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    res.json(session);
  } catch (error) {
    log.error('Get session error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * DELETE /api/chat/:id
 * Delete a session
 */
app.delete('/api/chat/:id', async (req, res) => {
  try {
    const result = await orchestrator.deleteSessionById(req.params.id);
    if (!result) {
      return res.status(404).json({ error: 'Session not found' });
    }
    res.json({ success: true, deleted: req.params.id });
  } catch (error) {
    log.error('Delete session error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/chat/:id/transcript
 * Get the full SDK transcript (JSONL events) for a session
 * Query params:
 *   - types: comma-separated event types to filter (e.g., "user,assistant,tool_use")
 *   - limit: max events to return
 *   - offset: skip first N events
 */
app.get('/api/chat/:id/transcript', async (req, res) => {
  try {
    const { types, limit, offset } = req.query;

    const session = await orchestrator.getSessionById(req.params.id);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    // Get the transcript path for this session
    const transcriptPath = orchestrator.getSdkTranscriptPath(session);
    if (!transcriptPath) {
      return res.status(404).json({
        error: 'Transcript not available',
        reason: 'Session does not have SDK transcript path'
      });
    }

    // Check if file exists
    try {
      await fs.access(transcriptPath);
    } catch {
      return res.status(404).json({
        error: 'Transcript file not found',
        path: transcriptPath
      });
    }

    // Read and filter events
    const options = {};
    if (types) {
      options.types = types.split(',').map(t => t.trim());
    }
    if (limit) {
      options.limit = parseInt(limit, 10);
    }
    if (offset) {
      options.offset = parseInt(offset, 10);
    }

    const events = await orchestrator.readSdkTranscript(transcriptPath, options);

    res.json({
      sessionId: req.params.id,
      transcriptPath,
      eventCount: events.length,
      events
    });
  } catch (error) {
    log.error('Get transcript error', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// MODULE RESOURCES
// ============================================================================

/**
 * GET /api/modules/:mod/prompt
 * Get system prompt for a module (e.g., Chat/CLAUDE.md)
 */
app.get('/api/modules/:mod/prompt', async (req, res) => {
  try {
    const { mod } = req.params;
    const moduleName = mod.charAt(0).toUpperCase() + mod.slice(1).toLowerCase();
    const promptPath = path.join(CONFIG.vaultPath, moduleName, 'CLAUDE.md');

    let content = null;
    let exists = false;

    try {
      content = await fs.readFile(promptPath, 'utf-8');
      exists = true;
    } catch {
      // File doesn't exist
    }

    res.json({
      module: mod,
      path: `${moduleName}/CLAUDE.md`,
      exists,
      content,
      defaultPrompt: PARACHUTE_DEFAULT_PROMPT
    });
  } catch (error) {
    log.error('Get module prompt error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * PUT /api/modules/:mod/prompt
 * Update system prompt for a module
 * Body: { content: string } or { reset: true } to use default
 */
app.put('/api/modules/:mod/prompt', async (req, res) => {
  try {
    const { mod } = req.params;
    const { content, reset } = req.body;

    const moduleName = mod.charAt(0).toUpperCase() + mod.slice(1).toLowerCase();
    const promptPath = path.join(CONFIG.vaultPath, moduleName, 'CLAUDE.md');

    if (reset) {
      // Delete the file to use default
      try {
        await fs.unlink(promptPath);
      } catch {
        // File didn't exist
      }
      res.json({ success: true, reset: true });
    } else if (content !== undefined) {
      // Ensure module directory exists
      await fs.mkdir(path.dirname(promptPath), { recursive: true });
      await fs.writeFile(promptPath, content, 'utf-8');
      res.json({ success: true, path: `${moduleName}/CLAUDE.md` });
    } else {
      res.status(400).json({ error: 'content or reset required' });
    }
  } catch (error) {
    log.error('Update module prompt error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/modules/:mod/search
 * Search module content
 * Query params: q (query), limit
 */
app.get('/api/modules/:mod/search', async (req, res) => {
  try {
    const { mod } = req.params;
    const { q, limit = 20 } = req.query;

    if (!q) {
      return res.status(400).json({ error: 'Query parameter "q" is required' });
    }

    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);
    const results = await moduleSearch.searchModule(mod, q, {
      limit: parseInt(limit, 10)
    });

    res.json(results);
  } catch (error) {
    log.error('Module search error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/modules/:mod/index
 * Rebuild search index for a module
 * Body: { withEmbeddings?: boolean }
 */
app.post('/api/modules/:mod/index', async (req, res) => {
  try {
    const { mod } = req.params;
    const { withEmbeddings = true } = req.body || {};

    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);

    log.info('Rebuilding module index', { mod, withEmbeddings });

    const result = await moduleSearch.rebuildModuleIndex(mod, { withEmbeddings });

    log.info('Module index rebuilt', {
      mod,
      contentCount: result.contentCount,
      chunkCount: result.chunkCount
    });

    res.json({ success: true, module: mod, ...result });
  } catch (error) {
    log.error('Module index error', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// ADDITIONAL MODULE ENDPOINTS (for convenience)
// ============================================================================

/**
 * GET /api/modules
 * List all modules and their status
 */
app.get('/api/modules', async (req, res) => {
  try {
    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);
    const modules = moduleSearch.listModules();
    res.json({ modules });
  } catch (error) {
    log.error('Module list error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/modules/:mod/stats
 * Get stats for a specific module
 */
app.get('/api/modules/:mod/stats', async (req, res) => {
  try {
    const { mod } = req.params;
    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);
    const stats = moduleSearch.getStats();

    if (stats.modules[mod]) {
      res.json({ module: mod, ...stats.modules[mod] });
    } else {
      res.status(404).json({ error: `Module '${mod}' not found` });
    }
  } catch (error) {
    log.error('Module stats error', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// FILESYSTEM NAVIGATION (Generic for all modules)
// ============================================================================

/**
 * GET /api/ls
 * List directory contents with metadata
 * Query: path (relative to vault, e.g., "Build/repos" or "Chat/contexts")
 * Returns: { entries: [{ name, type, path, isSymlink, hasClaudeMd, isGitRepo, lastModified }] }
 */
app.get('/api/ls', async (req, res) => {
  try {
    const relativePath = req.query.path || '';

    // Prevent path traversal attacks
    if (relativePath.includes('..')) {
      return res.status(400).json({ error: 'Invalid path' });
    }

    const targetPath = path.join(CONFIG.vaultPath, relativePath);

    // Ensure directory exists
    try {
      await fs.mkdir(targetPath, { recursive: true });
    } catch {
      // May already exist
    }

    const dirEntries = await fs.readdir(targetPath, { withFileTypes: true });
    const entries = [];

    for (const entry of dirEntries) {
      if (entry.name.startsWith('.')) continue; // Skip hidden

      const entryPath = path.join(targetPath, entry.name);
      const isDir = entry.isDirectory();

      // Check if symlink
      let isSymlink = false;
      let symlinkTarget = null;
      try {
        const lstat = await fs.lstat(entryPath);
        isSymlink = lstat.isSymbolicLink();
        if (isSymlink) {
          symlinkTarget = await fs.readlink(entryPath);
        }
      } catch {
        // Can't lstat
      }

      // Get metadata for directories
      let hasClaudeMd = false;
      let isGitRepo = false;

      if (isDir) {
        try {
          await fs.access(path.join(entryPath, 'CLAUDE.md'));
          hasClaudeMd = true;
        } catch {}

        try {
          await fs.access(path.join(entryPath, '.git'));
          isGitRepo = true;
        } catch {}
      }

      // Get timestamps
      let lastModified = null;
      let size = null;
      try {
        const stat = await fs.stat(entryPath);
        lastModified = stat.mtime.toISOString();
        if (!isDir) size = stat.size;
      } catch {}

      entries.push({
        name: entry.name,
        type: isDir ? 'directory' : 'file',
        path: entryPath,
        relativePath: path.join(relativePath, entry.name),
        isSymlink,
        symlinkTarget,
        hasClaudeMd,
        isGitRepo,
        lastModified,
        size
      });
    }

    // Sort: directories first, then by last modified
    entries.sort((a, b) => {
      if (a.type !== b.type) return a.type === 'directory' ? -1 : 1;
      if (!a.lastModified) return 1;
      if (!b.lastModified) return -1;
      return new Date(b.lastModified) - new Date(a.lastModified);
    });

    res.json({
      path: relativePath || '/',
      fullPath: targetPath,
      entries
    });
  } catch (error) {
    log.error('List directory error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/symlink
 * Create a symlink within the vault
 * Body: { target: "/absolute/external/path", link: "Build/repos/myproject" }
 */
app.post('/api/symlink', async (req, res) => {
  try {
    const { target, link } = req.body;

    if (!target || !link) {
      return res.status(400).json({ error: 'target and link are required' });
    }

    // Prevent path traversal
    if (link.includes('..')) {
      return res.status(400).json({ error: 'Invalid link path' });
    }

    // Verify target exists
    try {
      await fs.access(target);
    } catch {
      return res.status(400).json({ error: 'Target path does not exist' });
    }

    const linkPath = path.join(CONFIG.vaultPath, link);
    const linkDir = path.dirname(linkPath);

    // Ensure parent directory exists
    await fs.mkdir(linkDir, { recursive: true });

    // Check if already exists
    try {
      await fs.access(linkPath);
      return res.status(409).json({ error: 'Path already exists' });
    } catch {
      // Good - doesn't exist
    }

    // Create symlink
    await fs.symlink(target, linkPath, 'dir');

    log.info('Symlink created', { target, link: linkPath });

    res.json({
      success: true,
      symlink: {
        target,
        link,
        fullPath: linkPath
      }
    });
  } catch (error) {
    log.error('Create symlink error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * DELETE /api/symlink
 * Remove a symlink (only symlinks, not regular files/dirs)
 * Query: path (relative to vault)
 */
app.delete('/api/symlink', async (req, res) => {
  try {
    const relativePath = req.query.path;

    if (!relativePath) {
      return res.status(400).json({ error: 'path is required' });
    }

    // Prevent path traversal
    if (relativePath.includes('..')) {
      return res.status(400).json({ error: 'Invalid path' });
    }

    const linkPath = path.join(CONFIG.vaultPath, relativePath);

    // Check if it's a symlink
    const stat = await fs.lstat(linkPath);
    if (!stat.isSymbolicLink()) {
      return res.status(400).json({ error: 'Not a symlink - manual deletion required for safety' });
    }

    await fs.unlink(linkPath);

    log.info('Symlink removed', { path: relativePath });

    res.json({ success: true, removed: relativePath });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return res.status(404).json({ error: 'Path not found' });
    }
    log.error('Remove symlink error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/read
 * Read file contents
 * Query: path (relative to vault)
 * Returns: { path, content, size, lastModified }
 */
app.get('/api/read', async (req, res) => {
  try {
    const relativePath = req.query.path;

    if (!relativePath) {
      return res.status(400).json({ error: 'path is required' });
    }

    // Prevent path traversal
    if (relativePath.includes('..')) {
      return res.status(400).json({ error: 'Invalid path' });
    }

    const filePath = path.join(CONFIG.vaultPath, relativePath);

    // Check if file exists and is a file (not directory)
    const stat = await fs.stat(filePath);
    if (stat.isDirectory()) {
      return res.status(400).json({ error: 'Path is a directory, not a file' });
    }

    // Read file content
    const content = await fs.readFile(filePath, 'utf-8');

    res.json({
      path: relativePath,
      fullPath: filePath,
      content,
      size: stat.size,
      lastModified: stat.mtime.toISOString()
    });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return res.status(404).json({ error: 'File not found' });
    }
    log.error('Read file error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * PUT /api/write
 * Write content to a file in the vault
 *
 * Body: { path: string, content: string }
 * Security: Only allows writing to certain directories (Chat/contexts/, etc.)
 *
 * Returns: { path, size, lastModified }
 */
app.put('/api/write', async (req, res) => {
  try {
    const { path: relativePath, content } = req.body;

    if (!relativePath) {
      return res.status(400).json({ error: 'path is required' });
    }

    if (content === undefined || content === null) {
      return res.status(400).json({ error: 'content is required' });
    }

    // Prevent path traversal
    if (relativePath.includes('..')) {
      return res.status(400).json({ error: 'Invalid path' });
    }

    // Security: Only allow writing to certain directories
    const allowedPrefixes = ['Chat/contexts/'];
    const isAllowed = allowedPrefixes.some(prefix => relativePath.startsWith(prefix));
    if (!isAllowed) {
      return res.status(403).json({
        error: 'Write access denied - can only write to: ' + allowedPrefixes.join(', ')
      });
    }

    const filePath = path.join(CONFIG.vaultPath, relativePath);

    // Ensure parent directory exists
    const parentDir = path.dirname(filePath);
    await fs.mkdir(parentDir, { recursive: true });

    // Write file
    await fs.writeFile(filePath, content, 'utf-8');

    // Get updated stat
    const stat = await fs.stat(filePath);

    res.json({
      path: relativePath,
      size: stat.size,
      lastModified: stat.mtime.toISOString()
    });
  } catch (error) {
    log.error('Write file error', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// ASSET SERVING
// ============================================================================

/**
 * GET /api/assets/*
 * Serve asset files from the vault
 * Path examples:
 *   /api/assets/Chat/assets/2025-12/photo.png
 *   /api/assets/Daily/assets/2025-12/recording.opus
 *
 * Security: Only serves files from known asset directories (assets/, artifacts/)
 */
app.get('/api/assets/*', async (req, res) => {
  try {
    // Get the path after /api/assets/
    const assetPath = req.params[0];

    if (!assetPath) {
      return res.status(400).json({ error: 'Asset path is required' });
    }

    // Prevent path traversal
    if (assetPath.includes('..')) {
      return res.status(400).json({ error: 'Invalid path' });
    }

    // Only allow serving from asset directories for security
    const allowedDirs = ['assets', 'artifacts'];
    const pathParts = assetPath.split('/');

    // Check if path contains an allowed directory
    const hasAllowedDir = pathParts.some(part => allowedDirs.includes(part));
    if (!hasAllowedDir) {
      return res.status(403).json({
        error: 'Access denied - can only serve from assets/ or artifacts/ directories'
      });
    }

    const fullPath = path.join(CONFIG.vaultPath, assetPath);

    // Verify the file exists and is a file
    const stat = await fs.stat(fullPath);
    if (stat.isDirectory()) {
      return res.status(400).json({ error: 'Path is a directory' });
    }

    // Determine content type based on extension
    const ext = path.extname(fullPath).toLowerCase();
    const contentTypes = {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.svg': 'image/svg+xml',
      '.mp3': 'audio/mpeg',
      '.wav': 'audio/wav',
      '.opus': 'audio/opus',
      '.ogg': 'audio/ogg',
      '.m4a': 'audio/mp4',
      '.mp4': 'video/mp4',
      '.webm': 'video/webm',
      '.pdf': 'application/pdf',
      '.json': 'application/json',
      '.txt': 'text/plain',
      '.md': 'text/markdown',
    };

    const contentType = contentTypes[ext] || 'application/octet-stream';

    // Set headers
    res.setHeader('Content-Type', contentType);
    res.setHeader('Content-Length', stat.size);
    res.setHeader('Cache-Control', 'public, max-age=86400'); // Cache for 1 day

    // Stream the file
    const { createReadStream } = await import('fs');
    const stream = createReadStream(fullPath);
    stream.pipe(res);

  } catch (error) {
    if (error.code === 'ENOENT') {
      return res.status(404).json({ error: 'Asset not found' });
    }
    log.error('Asset serving error', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// SERVER STARTUP
// ============================================================================

const server = app.listen(CONFIG.port, CONFIG.host, async () => {
  // Initialize orchestrator (session manager, para ID service, etc.)
  await orchestrator.initialize();

  log.info('Server started', { host: CONFIG.host, port: CONFIG.port, vault: CONFIG.vaultPath });

  console.log(`
╔═══════════════════════════════════════════════════════════════╗
║           🪂 Parachute Base Server                            ║
╠═══════════════════════════════════════════════════════════════╣
║  Server:  http://${CONFIG.host}:${CONFIG.port}                              ║
║  Vault:   ${CONFIG.vaultPath.substring(0, 45).padEnd(45)}║
╠═══════════════════════════════════════════════════════════════╣
║  API (8 endpoints):                                           ║
║    POST /api/chat             - Run agent (streaming)         ║
║    GET  /api/chat             - List sessions                 ║
║    GET  /api/chat/:id         - Get session                   ║
║    DELETE /api/chat/:id       - Delete session                ║
║    GET  /api/modules/:mod/prompt   - Get module prompt        ║
║    PUT  /api/modules/:mod/prompt   - Update module prompt     ║
║    GET  /api/modules/:mod/search   - Search module            ║
║    POST /api/modules/:mod/index    - Rebuild index            ║
╚═══════════════════════════════════════════════════════════════╝
    `);

  // Check Ollama status
  try {
    const ollamaStatus = await getOllamaStatus();
    if (ollamaStatus.ready) {
      console.log('📊 Semantic Search: ✅ Ready (Ollama + embeddinggemma)\n');
    } else {
      console.log(`📊 Semantic Search: ⚠️ ${ollamaStatus.reason || 'Ollama not available'}\n`);
    }
  } catch {
    console.log('📊 Semantic Search: ⚠️ Could not check Ollama status\n');
  }
});

// Graceful shutdown
const shutdown = async (signal) => {
  log.info(`${signal} received, shutting down gracefully`);

  server.close(() => {
    log.info('HTTP server closed');
  });

  // Give connections 30 seconds to close
  setTimeout(() => {
    log.warn('Forcing shutdown after timeout');
    process.exit(1);
  }, 30000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

export default app;
