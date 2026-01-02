/**
 * Parachute Base Server
 *
 * AI agent execution with session management.
 *
 * Core API:
 *   GET  /api/health           - Health check
 *   POST /api/chat             - Run agent (streaming)
 *   GET  /api/chat             - List sessions
 *   GET  /api/chat/:id         - Get session
 *   DELETE /api/chat/:id       - Delete session
 *   POST /api/chat/:id/abort   - Abort active stream
 *
 * Module Resources:
 *   GET  /api/modules/:mod/prompt   - Get module prompt
 *   PUT  /api/modules/:mod/prompt   - Update module prompt
 *   GET  /api/modules/:mod/search   - Search module content
 *   POST /api/modules/:mod/index    - Rebuild module index
 *
 * Claude Code Session Import:
 *   GET  /api/claude-code/recent        - List recent sessions (all projects)
 *   GET  /api/claude-code/projects      - List Claude Code projects
 *   GET  /api/claude-code/sessions      - List sessions in a project
 *   GET  /api/claude-code/sessions/:id  - Get session details
 *   POST /api/claude-code/adopt/:id     - Adopt session into Parachute
 *   POST /api/claude-code/migrate/:id   - Migrate session to new path
 */

import express from 'express';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs/promises';
import multer from 'multer';
import { createReadStream } from 'fs';
import { createUnzip } from 'zlib';
import { pipeline } from 'stream/promises';
import { Extract } from 'unzipper';

import { Orchestrator } from './lib/orchestrator.js';
import { PARACHUTE_DEFAULT_PROMPT } from './lib/default-prompt.js';
import { serverLogger as log } from './lib/logger.js';
import { getModuleSearchService } from './lib/module-search.js';
import { getOllamaStatus } from './lib/ollama-service.js';
import { loadMcpServers, listMcpServers, addMcpServer, removeMcpServer } from './lib/mcp-loader.js';
import { discoverSkills, loadSkill, createSkill, deleteSkill } from './lib/skills-loader.js';
import { listProjects, listSessions, getSession, findSession, getSessionFilePath, listRecentSessions, migrateSessionPath } from './lib/claude-code-sessions.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Track active streams for abort functionality
// Map of sessionId -> AbortController
const activeStreams = new Map();

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

  // Create abort controller for this stream
  const abortController = new AbortController();
  let streamSessionId = sessionId; // Will be updated when we get session event

  try {
    const stream = orchestrator.runImmediateStreaming(
      agentPath || null,
      message,
      context,
      abortController
    );

    // IMPORTANT: Don't break on disconnect - let the orchestrator complete
    // so Claude finishes its work and the session gets saved properly.
    // This enables multi-device: start on tablet, pick up on phone.
    for await (const event of stream) {
      // Track session ID from session event for abort mapping
      if (event.type === 'session' && event.sessionId) {
        streamSessionId = event.sessionId;
        // Register abort controller for this session
        activeStreams.set(streamSessionId, abortController);
        log.info('Registered abort controller for session', { sessionId: streamSessionId });
      }

      if (!clientDisconnected) {
        res.write(`data: ${JSON.stringify(event)}\n\n`);
      }
      // If client disconnected, we still consume events to let orchestrator finish
    }

    if (clientDisconnected) {
      log.info('Stream completed after client disconnect - session saved');
    }
  } catch (error) {
    // Check if this was an abort
    if (error.name === 'AbortError' || abortController.signal.aborted) {
      log.info('Stream aborted by user', { sessionId: streamSessionId });
      if (!clientDisconnected) {
        res.write(`data: ${JSON.stringify({ type: 'aborted', message: 'Stream stopped by user' })}\n\n`);
      }
    } else {
      log.error('Stream error', error);
      if (!clientDisconnected) {
        res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
      }
    }
  } finally {
    clearInterval(heartbeatInterval);
    // Clean up abort controller tracking
    if (streamSessionId) {
      activeStreams.delete(streamSessionId);
    }
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
 * POST /api/chat/:id/abort
 * Abort an active streaming session
 * Returns success if stream was aborted, or 404 if no active stream found
 */
app.post('/api/chat/:id/abort', (req, res) => {
  const sessionId = req.params.id;
  const abortController = activeStreams.get(sessionId);

  if (!abortController) {
    // No active stream - could be already completed or invalid session
    return res.status(404).json({
      error: 'No active stream found for this session',
      sessionId
    });
  }

  try {
    log.info('Aborting stream', { sessionId });
    abortController.abort();
    // The abort controller will be cleaned up by the stream's finally block
    res.json({ success: true, message: 'Stream abort signal sent', sessionId });
  } catch (error) {
    log.error('Abort error', error);
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
// MCP MANAGEMENT
// ============================================================================

/**
 * GET /api/mcps
 * List all configured MCP servers
 */
app.get('/api/mcps', async (req, res) => {
  try {
    const servers = await listMcpServers(CONFIG.vaultPath);
    res.json({ servers });
  } catch (error) {
    log.error('MCP list error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/mcps
 * Add or update an MCP server configuration
 * Body: { name: string, config: { command, args, env, ... } }
 */
app.post('/api/mcps', async (req, res) => {
  try {
    const { name, config } = req.body;

    if (!name || typeof name !== 'string') {
      return res.status(400).json({ error: 'Server name is required' });
    }

    if (!config || typeof config !== 'object') {
      return res.status(400).json({ error: 'Server config is required' });
    }

    // Validate basic structure
    if (!config.command && !config.url) {
      return res.status(400).json({ error: 'Config must have command (stdio) or url (http)' });
    }

    const servers = await addMcpServer(CONFIG.vaultPath, name, config);
    res.json({ success: true, server: { name, ...config }, total: Object.keys(servers).length });
  } catch (error) {
    log.error('MCP add error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * DELETE /api/mcps/:name
 * Remove an MCP server configuration
 */
app.delete('/api/mcps/:name', async (req, res) => {
  try {
    const { name } = req.params;
    const servers = await removeMcpServer(CONFIG.vaultPath, name);
    res.json({ success: true, remaining: Object.keys(servers).length });
  } catch (error) {
    log.error('MCP remove error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/mcps/:name
 * Get a specific MCP server configuration
 */
app.get('/api/mcps/:name', async (req, res) => {
  try {
    const { name } = req.params;
    const servers = await loadMcpServers(CONFIG.vaultPath);

    if (servers[name]) {
      res.json({ name, ...servers[name] });
    } else {
      res.status(404).json({ error: `MCP server '${name}' not found` });
    }
  } catch (error) {
    log.error('MCP get error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/mcps/:name/test
 * Test if an MCP server can start successfully
 * Spawns the process briefly and checks for errors
 */
app.post('/api/mcps/:name/test', async (req, res) => {
  const { spawn } = await import('child_process');

  try {
    const { name } = req.params;
    const servers = await loadMcpServers(CONFIG.vaultPath);

    if (!servers[name]) {
      return res.status(404).json({ error: `MCP server '${name}' not found` });
    }

    const config = servers[name];

    if (!config.command) {
      return res.status(400).json({
        error: 'Only stdio MCP servers can be tested',
        status: 'unknown'
      });
    }

    // Check for unresolved environment variables (from raw config)
    const rawServers = await loadMcpServers(CONFIG.vaultPath, true);
    const rawConfig = rawServers[name];
    const configStr = JSON.stringify(rawConfig || config);
    const unresolvedMatch = configStr.match(/\$\{([^}]+)\}/);
    if (unresolvedMatch) {
      return res.json({
        name,
        status: 'error',
        error: `Missing environment variable: ${unresolvedMatch[1]}`,
        hint: 'Set this variable in the MCP server settings'
      });
    }

    // Try to spawn the process
    const testProcess = spawn(config.command, config.args || [], {
      env: { ...process.env, ...(config.env || {}) },
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';
    let resolved = false;

    const cleanup = () => {
      if (!resolved) {
        resolved = true;
        testProcess.kill('SIGTERM');
      }
    };

    testProcess.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    testProcess.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    // Wait a short time to see if the process starts and stays running
    const timeout = setTimeout(() => {
      if (!resolved) {
        resolved = true;
        testProcess.kill('SIGTERM');
        res.json({
          name,
          status: 'ok',
          message: 'MCP server started successfully'
        });
      }
    }, 2000);

    testProcess.on('error', (err) => {
      if (!resolved) {
        resolved = true;
        clearTimeout(timeout);
        res.json({
          name,
          status: 'error',
          error: `Failed to start: ${err.message}`,
          hint: config.command === 'npx' ? 'Make sure npm/npx is installed' : undefined
        });
      }
    });

    testProcess.on('exit', (code, signal) => {
      if (!resolved) {
        resolved = true;
        clearTimeout(timeout);
        if (code !== null && code !== 0) {
          res.json({
            name,
            status: 'error',
            error: `Process exited with code ${code}`,
            stderr: stderr.slice(0, 500) || undefined,
            hint: stderr.includes('API') ? 'Check if your API key is valid' : undefined
          });
        } else if (signal) {
          // Process was killed by us or something else
          res.json({
            name,
            status: 'ok',
            message: 'MCP server starts correctly'
          });
        }
      }
    });

  } catch (error) {
    log.error('MCP test error', error);
    res.status(500).json({ error: error.message, status: 'error' });
  }
});

/**
 * GET /api/mcps/:name/tools
 * Get the list of tools provided by an MCP server
 * Spawns the MCP server and performs proper MCP handshake to get tools list
 */
app.get('/api/mcps/:name/tools', async (req, res) => {
  const { spawn } = await import('child_process');

  try {
    const { name } = req.params;
    const servers = await loadMcpServers(CONFIG.vaultPath);

    if (!servers[name]) {
      return res.status(404).json({ error: `MCP server '${name}' not found` });
    }

    const config = servers[name];

    if (!config.command) {
      return res.status(400).json({
        error: 'Only stdio MCP servers can be queried for tools',
      });
    }

    // Check for unresolved environment variables
    const configStr = JSON.stringify(config);
    const unresolvedMatch = configStr.match(/\$\{([^}]+)\}/);
    if (unresolvedMatch) {
      return res.json({
        name,
        error: `Missing environment variable: ${unresolvedMatch[1]}`,
        tools: []
      });
    }

    // Spawn the MCP process
    const mcpProcess = spawn(config.command, config.args || [], {
      env: { ...process.env, ...(config.env || {}) },
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';
    let resolved = false;
    let handshakeState = 'init'; // init -> initialized -> ready
    let requestId = 1;

    const cleanup = () => {
      if (!resolved) {
        resolved = true;
        mcpProcess.kill('SIGTERM');
      }
    };

    const sendRequest = (method, params = {}) => {
      const id = requestId++;
      const request = JSON.stringify({
        jsonrpc: '2.0',
        id,
        method,
        params
      }) + '\n';
      mcpProcess.stdin.write(request);
      return id;
    };

    const sendNotification = (method, params = {}) => {
      const notification = JSON.stringify({
        jsonrpc: '2.0',
        method,
        params
      }) + '\n';
      mcpProcess.stdin.write(notification);
    };

    mcpProcess.stdout.on('data', (data) => {
      stdout += data.toString();

      // Process each complete JSON line
      const lines = stdout.split('\n');
      // Keep incomplete last line in buffer
      stdout = lines.pop() || '';

      for (const line of lines) {
        if (!line.trim()) continue;

        try {
          const response = JSON.parse(line);

          // Handle initialize response
          if (handshakeState === 'init' && response.result && response.result.capabilities) {
            handshakeState = 'initialized';
            // Send initialized notification
            sendNotification('notifications/initialized');
            // Now request tools
            handshakeState = 'ready';
            sendRequest('tools/list');
          }
          // Handle tools/list response
          else if (handshakeState === 'ready' && response.result && response.result.tools) {
            cleanup();
            res.json({
              name,
              tools: response.result.tools.map(t => ({
                name: t.name,
                description: t.description,
                inputSchema: t.inputSchema
              }))
            });
            return;
          }
          // Handle error response
          else if (response.error) {
            cleanup();
            res.json({
              name,
              error: response.error.message || 'Unknown MCP error',
              tools: []
            });
            return;
          }
        } catch (e) {
          // Not valid JSON, skip
        }
      }
    });

    mcpProcess.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    // Start MCP handshake after a brief delay for process startup
    setTimeout(() => {
      if (!resolved && handshakeState === 'init') {
        // Send initialize request (required by MCP protocol)
        sendRequest('initialize', {
          protocolVersion: '2024-11-05',
          capabilities: {},
          clientInfo: {
            name: 'parachute-base',
            version: '1.0.0'
          }
        });
      }
    }, 100);

    // Timeout after 10 seconds
    const timeout = setTimeout(() => {
      if (!resolved) {
        cleanup();
        res.json({
          name,
          error: `Timeout waiting for tools list (state: ${handshakeState})`,
          tools: []
        });
      }
    }, 10000);

    mcpProcess.on('error', (err) => {
      if (!resolved) {
        resolved = true;
        clearTimeout(timeout);
        res.json({
          name,
          error: `Failed to start: ${err.message}`,
          tools: []
        });
      }
    });

    mcpProcess.on('exit', (code) => {
      if (!resolved) {
        resolved = true;
        clearTimeout(timeout);
        res.json({
          name,
          error: code !== 0 ? `Process exited with code ${code}` : 'Process ended unexpectedly',
          tools: []
        });
      }
    });

  } catch (error) {
    log.error('MCP tools error', error);
    res.status(500).json({ error: error.message, tools: [] });
  }
});

// ============================================================================
// SKILLS MANAGEMENT
// ============================================================================

/**
 * GET /api/skills
 * List all available agent skills
 */
app.get('/api/skills', async (req, res) => {
  try {
    const skills = await discoverSkills(CONFIG.vaultPath);
    res.json({ skills });
  } catch (error) {
    log.error('Skills list error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/skills/:name
 * Get full content of a specific skill
 */
app.get('/api/skills/:name', async (req, res) => {
  try {
    const { name } = req.params;
    const skill = await loadSkill(CONFIG.vaultPath, name);

    if (skill) {
      res.json(skill);
    } else {
      res.status(404).json({ error: `Skill '${name}' not found` });
    }
  } catch (error) {
    log.error('Skill get error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/skills
 * Create a new skill
 * Body: { name: string, description?: string, content?: string, allowedTools?: string[] }
 */
app.post('/api/skills', async (req, res) => {
  try {
    const { name, description, content, allowedTools } = req.body;

    if (!name || typeof name !== 'string') {
      return res.status(400).json({ error: 'Skill name is required' });
    }

    // Sanitize name for directory
    const dirName = name.toLowerCase().replace(/[^a-z0-9-]/g, '-');

    const skill = await createSkill(CONFIG.vaultPath, dirName, {
      name,
      description,
      content,
      allowedTools
    });

    res.json({ success: true, skill });
  } catch (error) {
    log.error('Skill create error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * DELETE /api/skills/:name
 * Delete a skill
 */
app.delete('/api/skills/:name', async (req, res) => {
  try {
    const { name } = req.params;
    const deleted = await deleteSkill(CONFIG.vaultPath, name);

    if (deleted) {
      res.json({ success: true, deleted: name });
    } else {
      res.status(404).json({ error: `Skill '${name}' not found or could not be deleted` });
    }
  } catch (error) {
    log.error('Skill delete error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/skills/upload
 * Upload a .skill file (ZIP format) and extract it to the skills directory
 * Accepts multipart/form-data with a 'file' field
 */
const skillUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 50 * 1024 * 1024 }, // 50MB limit
  fileFilter: (req, file, cb) => {
    // Accept .skill or .zip files
    const ext = path.extname(file.originalname).toLowerCase();
    if (ext === '.skill' || ext === '.zip') {
      cb(null, true);
    } else {
      cb(new Error('Only .skill or .zip files are allowed'));
    }
  }
});

app.post('/api/skills/upload', skillUpload.single('file'), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'No file uploaded' });
    }

    const skillsDir = path.join(CONFIG.vaultPath, '.claude', 'skills');
    await fs.mkdir(skillsDir, { recursive: true });

    // Get skill name from filename (without extension)
    const originalName = path.basename(req.file.originalname, path.extname(req.file.originalname));
    const sanitizedName = originalName.toLowerCase().replace(/[^a-z0-9-]/g, '-');
    const skillDir = path.join(skillsDir, sanitizedName);

    // Check if skill already exists
    try {
      await fs.access(skillDir);
      return res.status(409).json({ error: `Skill '${sanitizedName}' already exists. Delete it first to replace.` });
    } catch {
      // Skill doesn't exist, good to proceed
    }

    // Create the skill directory
    await fs.mkdir(skillDir, { recursive: true });

    // Extract the ZIP file
    const { Readable } = await import('stream');
    const bufferStream = Readable.from(req.file.buffer);

    await pipeline(
      bufferStream,
      Extract({ path: skillDir })
    );

    log.info(`Uploaded skill: ${sanitizedName}`);

    // Reload and return the skill
    const skill = await loadSkill(CONFIG.vaultPath, sanitizedName);
    res.json({ success: true, skill });
  } catch (error) {
    log.error('Skill upload error', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// CLAUDE CODE SESSION IMPORT
// ============================================================================

/**
 * GET /api/claude-code/projects
 * List all Claude Code projects (working directories)
 * Returns: { projects: [{ encodedName, path, sessionCount }] }
 */
app.get('/api/claude-code/projects', async (req, res) => {
  try {
    const projects = await listProjects();
    res.json({ projects });
  } catch (error) {
    log.error('Error listing Claude Code projects', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/claude-code/recent
 * List recent sessions across ALL projects, sorted by last activity
 * Query: limit (default 100)
 * Returns: { sessions: [{ sessionId, title, firstMessage, messageCount, createdAt, lastTimestamp, model, projectPath, projectDisplayName }] }
 */
app.get('/api/claude-code/recent', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit || '100');
    const sessions = await listRecentSessions(limit);
    res.json({ sessions });
  } catch (error) {
    log.error('Error listing recent Claude Code sessions', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/claude-code/sessions
 * List sessions for a specific project path
 * Query: path (the decoded project path, e.g., "/Users/unforced/Parachute/Build/repos/parachute")
 * Returns: { sessions: [{ sessionId, title, firstMessage, messageCount, createdAt, lastTimestamp, model }] }
 */
app.get('/api/claude-code/sessions', async (req, res) => {
  try {
    const projectPath = req.query.path;
    if (!projectPath) {
      return res.status(400).json({ error: 'Project path required' });
    }

    const sessions = await listSessions(projectPath);
    res.json({ sessions });
  } catch (error) {
    log.error('Error listing Claude Code sessions', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/claude-code/sessions/:id
 * Get full session details including messages
 * Query: path (project path)
 * Returns: { sessionId, title, messages: [...], cwd, model, createdAt }
 */
app.get('/api/claude-code/sessions/:id', async (req, res) => {
  try {
    const sessionId = req.params.id;
    let projectPath = req.query.path;

    // If no path provided, try to find the session
    if (!projectPath) {
      const found = await findSession(sessionId);
      if (!found.found) {
        return res.status(404).json({ error: 'Session not found' });
      }
      projectPath = found.projectPath;
    }

    const session = await getSession(sessionId, projectPath);
    res.json(session);
  } catch (error) {
    log.error('Error getting Claude Code session', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/claude-code/adopt/:id
 * Adopt a Claude Code session into Parachute
 * This creates a Parachute markdown mirror and allows resuming via the SDK
 * Query: path (project path)
 * Body: { workingDirectory?: string } - optional override for cwd
 * Returns: { success, parachuteSessionId, message }
 */
app.post('/api/claude-code/adopt/:id', async (req, res) => {
  try {
    const sessionId = req.params.id;
    let projectPath = req.query.path;
    const { workingDirectory } = req.body || {};

    // Find the session if path not provided
    if (!projectPath) {
      const found = await findSession(sessionId);
      if (!found.found) {
        return res.status(404).json({ error: 'Session not found' });
      }
      projectPath = found.projectPath;
    }

    // Get full session details
    const ccSession = await getSession(sessionId, projectPath);

    // Determine effective cwd - either from request, session, or vault
    const effectiveCwd = workingDirectory || ccSession.cwd || CONFIG.vaultPath;

    // Create a lightweight pointer file in flat sessions folder
    const sessionsDir = path.join(CONFIG.vaultPath, 'Chat', 'sessions');
    await fs.mkdir(sessionsDir, { recursive: true });

    // Generate filename
    const createdDate = ccSession.createdAt
      ? new Date(ccSession.createdAt).toISOString().split('T')[0]
      : new Date().toISOString().split('T')[0];
    const shortId = sessionId.slice(0, 8);
    const filename = `${createdDate}-${shortId}.md`;
    const filePath = path.join(sessionsDir, filename);

    // Check if already adopted
    try {
      await fs.access(filePath);
      return res.json({
        success: true,
        alreadyAdopted: true,
        parachuteSessionId: sessionId,
        message: 'Session already adopted into Parachute'
      });
    } catch {
      // File doesn't exist, continue with adoption
    }

    // Build lightweight pointer - NO message content, just metadata
    const title = ccSession.title ||
      (ccSession.messages[0]?.content?.slice(0, 50) + '...' || 'Imported Session');

    const markdown = `---
sdk_session_id: "${sessionId}"
title: "${title.replace(/"/g, '\\"')}"
created_at: "${ccSession.createdAt || new Date().toISOString()}"
last_accessed: "${new Date().toISOString()}"
archived: false
working_directory: "${effectiveCwd}"
model: "${ccSession.model || 'unknown'}"
source: "claude-code"
message_count: ${ccSession.messages.length}
---
`;

    // Write the lightweight pointer file
    await fs.writeFile(filePath, markdown, 'utf8');

    // Add to session index so it shows up immediately
    await orchestrator.sessionManager.indexSessionFromFile(filePath);

    log.info('Adopted Claude Code session (lightweight pointer)', {
      sessionId,
      filePath,
      messageCount: ccSession.messages.length
    });

    res.json({
      success: true,
      parachuteSessionId: sessionId,
      filePath,
      messageCount: ccSession.messages.length,
      message: `Session adopted with ${ccSession.messages.length} messages.`
    });
  } catch (error) {
    log.error('Error adopting Claude Code session', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/claude-code/migrate/:id
 * Migrate a session to be accessible from a new project path
 * Creates a symlink so the SDK can find the session from the new location
 * Body: { originalPath, newPath }
 * Returns: { success, message }
 */
app.post('/api/claude-code/migrate/:id', async (req, res) => {
  try {
    const sessionId = req.params.id;
    const { originalPath, newPath } = req.body || {};

    if (!originalPath || !newPath) {
      return res.status(400).json({ error: 'Both originalPath and newPath required' });
    }

    const result = await migrateSessionPath(sessionId, originalPath, newPath);
    res.json(result);
  } catch (error) {
    log.error('Error migrating Claude Code session', error);
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
