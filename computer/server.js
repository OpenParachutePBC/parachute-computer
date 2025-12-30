/**
 * Obsidian Agent Pilot Server
 *
 * Express server that provides:
 * - REST API for agent orchestration
 * - Web interface for vault interaction
 * - Queue management and monitoring
 */

import express from 'express';
import { marked } from 'marked';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs/promises';

import { Orchestrator } from './lib/orchestrator.js';
import { PARACHUTE_DEFAULT_PROMPT } from './lib/default-prompt.js';
import { listVaultFiles, readDocument, searchVault } from './lib/vault-utils.js';
import { validateRelativePath, sanitizeFilename, validateSessionId } from './lib/path-validator.js';
import { queryLogs, getLogStats, serverLogger as log } from './lib/logger.js';
import { initializeUsageTracker, getUsageTracker } from './lib/usage-tracker.js';
import { getVaultSearchService, ContentType } from './lib/vault-search.js';
import { getModuleSearchService } from './lib/module-search.js';
import { getOllamaStatus } from './lib/ollama-service.js';
import * as generateConfig from './lib/generate-config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Configuration
const CONFIG = {
  port: process.env.PORT || 3333,
  host: process.env.HOST || '0.0.0.0',  // Bind to all interfaces for Tailscale access
  vaultPath: process.env.VAULT_PATH || path.join(__dirname, 'sample-vault'),
  // CORS: comma-separated origins or '*' for all (default for dev)
  corsOrigins: process.env.CORS_ORIGINS || '*',
  // Optional API key for authentication
  apiKey: process.env.API_KEY || null,
  // Max message length (default 100KB)
  maxMessageLength: parseInt(process.env.MAX_MESSAGE_LENGTH || '102400', 10),
};

const app = express();
app.use(express.json());

// Parse allowed CORS origins
const allowedOrigins = CONFIG.corsOrigins === '*'
  ? null  // null means allow all
  : CONFIG.corsOrigins.split(',').map(o => o.trim()).filter(Boolean);

// CORS middleware with configurable origins
app.use((req, res, next) => {
  const origin = req.headers.origin;

  if (allowedOrigins === null) {
    // Allow all origins
    res.header('Access-Control-Allow-Origin', '*');
  } else if (origin && allowedOrigins.includes(origin)) {
    // Allow specific origin
    res.header('Access-Control-Allow-Origin', origin);
    res.header('Vary', 'Origin');
  } else if (origin) {
    // Origin not allowed - still respond but without CORS headers
    // Browser will block the response
  }

  res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-API-Key');

  if (req.method === 'OPTIONS') {
    return res.sendStatus(200);
  }
  next();
});

// Optional API key authentication middleware
const apiKeyAuth = (req, res, next) => {
  if (!CONFIG.apiKey) {
    // No API key configured, skip auth
    return next();
  }

  const providedKey = req.headers['x-api-key'] || req.headers['authorization']?.replace('Bearer ', '');

  if (providedKey !== CONFIG.apiKey) {
    return res.status(401).json({ error: 'Unauthorized: Invalid or missing API key' });
  }

  next();
};

// Apply API key auth to all /api routes
app.use('/api', apiKeyAuth);

app.use(express.static(path.join(__dirname, 'public')));

// Initialize orchestrator
const orchestrator = new Orchestrator(CONFIG.vaultPath, {
  maxDepth: 3,
  maxConcurrent: 1,
  persistQueue: true
});

// ============================================================================
// VAULT OPERATIONS (using shared vault-utils)
// ============================================================================

// Helper wrappers that use CONFIG.vaultPath
async function getVaultFiles() {
  return listVaultFiles(CONFIG.vaultPath);
}

async function getDocument(relativePath) {
  return readDocument(CONFIG.vaultPath, relativePath);
}

async function findInVault(queryStr) {
  return searchVault(CONFIG.vaultPath, queryStr);
}

// ============================================================================
// API ROUTES
// ============================================================================

/**
 * GET /api/health
 * Health check endpoint for monitoring
 * Returns detailed status if ?detailed=true is passed
 */
app.get('/api/health', async (req, res) => {
  const basic = {
    status: 'ok',
    timestamp: Date.now()
  };

  // Return basic response for simple health checks
  if (req.query.detailed !== 'true') {
    return res.json(basic);
  }

  // Detailed health check
  try {
    const sessionStats = orchestrator.getSessionStats();
    const queueState = orchestrator.getQueueState();
    const agents = await orchestrator.getAgents();

    // Check vault accessibility
    let vaultStatus = 'ok';
    try {
      await fs.access(CONFIG.vaultPath);
    } catch {
      vaultStatus = 'error';
    }

    res.json({
      ...basic,
      version: process.env.npm_package_version || 'unknown',
      vault: {
        path: CONFIG.vaultPath,
        status: vaultStatus
      },
      sessions: {
        indexed: sessionStats.indexedCount || 0,
        loaded: sessionStats.loadedCount || 0,
        active: sessionStats.activeCount || 0
      },
      queue: {
        pending: queueState.pending?.length || 0,
        running: queueState.running?.length || 0,
        completed: queueState.completed?.length || 0
      },
      agents: {
        count: agents.length
      },
      system: {
        uptime: process.uptime(),
        memory: process.memoryUsage(),
        nodeVersion: process.version
      },
      config: {
        corsOrigins: CONFIG.corsOrigins === '*' ? 'all' : 'restricted',
        authEnabled: !!CONFIG.apiKey,
        maxMessageLength: CONFIG.maxMessageLength
      }
    });
  } catch (error) {
    res.json({
      ...basic,
      status: 'degraded',
      error: error.message
    });
  }
});

/**
 * POST /api/chat
 * Chat with vault agent or specific document agent
 * Sessions are maintained automatically for conversation continuity
 */
app.post('/api/chat', async (req, res) => {
  try {
    const { message, agentPath, documentPath, sessionId, initialContext, workingDirectory } = req.body;

    log.info('Chat request', { agentPath, sessionId, workingDirectory });

    if (!message) {
      return res.status(400).json({ error: 'message is required' });
    }

    // Validate message length
    if (message.length > CONFIG.maxMessageLength) {
      return res.status(400).json({
        error: `Message too long: ${message.length} chars exceeds limit of ${CONFIG.maxMessageLength}`
      });
    }

    // Build context - use sessionId as context key for unique sessions
    const context = {};
    if (sessionId) {
      context.sessionId = sessionId;
    }
    if (documentPath) {
      context.documentPath = documentPath;
    }
    if (initialContext) {
      context.initialContext = initialContext;
    }
    if (workingDirectory) {
      context.workingDirectory = workingDirectory;
    }

    // Run agent
    const result = await orchestrator.runImmediate(
      agentPath || null,
      message,
      context
    );

    res.json({
      response: result.response,
      spawned: result.spawned,
      durationMs: result.durationMs,
      agentPath: agentPath || null,
      documentPath: documentPath || null,
      sessionId: result.sessionId || null,
      workingDirectory: result.workingDirectory || null,
      messageCount: result.messageCount || 0,
      toolCalls: result.toolCalls || undefined,
      permissionDenials: result.permissionDenials || undefined,
      sessionResume: result.sessionResume || undefined,
      debug: result.debug || undefined
    });

  } catch (error) {
    log.error('Chat error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/chat/stream
 * Streaming chat with agent via SSE
 * Events: session, init, text, tool_use, tool_result, done, error
 */
app.post('/api/chat/stream', async (req, res) => {
  // Set SSE headers
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.flushHeaders();

  // Track client disconnect to stop wasting resources
  // NOTE: Must use res.on('close'), not req.on('close')
  // req closes when body is received, res closes when client disconnects
  let clientDisconnected = false;
  res.on('close', () => {
    if (!clientDisconnected) {
      clientDisconnected = true;
      log.info('Client disconnected from stream');
    }
  });

  // SSE heartbeat to prevent proxy/network timeouts on idle connections
  const heartbeatInterval = setInterval(() => {
    if (!clientDisconnected) {
      res.write(': heartbeat\n\n');
    }
  }, 15000); // Every 15 seconds

  const { message, agentPath, sessionId, initialContext, workingDirectory, contexts, priorConversation, continuedFrom } = req.body;

  if (!message) {
    clearInterval(heartbeatInterval);
    res.write(`data: ${JSON.stringify({ type: 'error', error: 'message is required' })}\n\n`);
    res.end();
    return;
  }

  // Validate message length
  if (message.length > CONFIG.maxMessageLength) {
    clearInterval(heartbeatInterval);
    res.write(`data: ${JSON.stringify({ type: 'error', error: `Message too long: ${message.length} chars exceeds limit of ${CONFIG.maxMessageLength}` })}\n\n`);
    res.end();
    return;
  }

  log.info('Streaming chat request', {
    agentPath,
    sessionId,
    workingDirectory,
    contexts,
    hasPriorConversation: !!priorConversation,
    priorConversationLength: priorConversation?.length || 0
  });

  if (priorConversation) {
    console.log(`[Server] Prior conversation received: ${priorConversation.length} chars`);
    console.log(`[Server] Prior conversation preview: ${priorConversation.substring(0, 200)}...`);
  }

  const context = {};
  if (sessionId) {
    context.sessionId = sessionId;
  }
  if (initialContext) {
    context.initialContext = initialContext;
  }
  if (workingDirectory) {
    context.workingDirectory = workingDirectory;
  }
  // Context files to load into the system prompt
  // e.g., ["contexts/general-context.md", "contexts/parachute.md"]
  if (contexts && Array.isArray(contexts)) {
    context.contexts = contexts;
  }
  // Prior conversation for continued sessions (goes into system prompt)
  if (priorConversation) {
    context.priorConversation = priorConversation;
    console.log('[Server] Added priorConversation to context');
  }
  // Track which session this continues from (for persistence)
  if (continuedFrom) {
    context.continuedFrom = continuedFrom;
    console.log(`[Server] Session continues from: ${continuedFrom}`);
  }

  try {
    const stream = orchestrator.runImmediateStreaming(
      agentPath || null,
      message,
      context
    );

    for await (const event of stream) {
      // Stop processing if client disconnected
      if (clientDisconnected) {
        log.info('Stopping stream - client disconnected');
        break;
      }
      res.write(`data: ${JSON.stringify(event)}\n\n`);
    }
  } catch (error) {
    log.error('Stream error', error);
    // Only write error if client still connected
    if (!clientDisconnected) {
      res.write(`data: ${JSON.stringify({ type: 'error', error: error.message })}\n\n`);
    }
  } finally {
    // Always clean up heartbeat interval
    clearInterval(heartbeatInterval);
  }

  if (!clientDisconnected) {
    res.end();
  }
});

/**
 * GET /api/chat/sessions
 * List all chat sessions with pagination
 * Query params: limit, offset, sort (newest|oldest), archived
 */
app.get('/api/chat/sessions', async (req, res) => {
  try {
    const limit = Math.min(parseInt(req.query.limit, 10) || 50, 200);
    const offset = parseInt(req.query.offset, 10) || 0;
    const sort = req.query.sort || 'newest';
    const showArchived = req.query.archived === 'true';

    let sessions = orchestrator.listChatSessions();

    // Filter archived
    if (!showArchived) {
      sessions = sessions.filter(s => !s.archived);
    }

    // Sort
    sessions.sort((a, b) => {
      const dateA = new Date(a.lastAccessed || a.createdAt || 0);
      const dateB = new Date(b.lastAccessed || b.createdAt || 0);
      return sort === 'newest' ? dateB - dateA : dateA - dateB;
    });

    // Paginate
    const total = sessions.length;
    const paginated = sessions.slice(offset, offset + limit);

    res.json({
      sessions: paginated,
      pagination: {
        total,
        limit,
        offset,
        hasMore: offset + limit < total
      }
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/chat/history
 * Legacy endpoint - use GET /api/chat/session/:id instead
 */
app.get('/api/chat/history', async (req, res) => {
  res.status(400).json({
    error: 'This endpoint is deprecated. Use GET /api/chat/session/:id with the SDK session ID instead.'
  });
});

/**
 * GET /api/chat/session/:id
 * Get a specific session by ID (including messages)
 */
app.get('/api/chat/session/:id', async (req, res) => {
  try {
    // Validate session ID
    const sessionId = validateSessionId(req.params.id);
    if (!sessionId) {
      return res.status(400).json({ error: 'Invalid session ID' });
    }

    // ID is now the SDK session ID
    const session = await orchestrator.getSessionById(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    res.json({
      id: session.sdkSessionId, // SDK session ID is THE session ID
      agentPath: session.agentPath,
      agentName: (session.agentPath || 'vault-agent').replace('agents/', '').replace('.md', ''),
      messages: session.messages,
      createdAt: session.createdAt,
      lastAccessed: session.lastAccessed,
      workingDirectory: session.workingDirectory || null
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * DELETE /api/chat/session
 * Legacy endpoint - use DELETE /api/chat/session/:id instead
 */
app.delete('/api/chat/session', async (req, res) => {
  res.status(400).json({
    error: 'This endpoint is deprecated. Use DELETE /api/chat/session/:id with the SDK session ID instead.'
  });
});

/**
 * POST /api/chat/session/:id/archive
 * Archive a chat session
 */
app.post('/api/chat/session/:id/archive', async (req, res) => {
  try {
    const sessionId = validateSessionId(req.params.id);
    if (!sessionId) {
      return res.status(400).json({ error: 'Invalid session ID' });
    }

    const archived = await orchestrator.archiveSession(sessionId);
    if (archived) {
      res.json({ archived: true, id: sessionId });
    } else {
      res.status(404).json({ error: 'Session not found' });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/chat/session/:id/unarchive
 * Unarchive a chat session
 */
app.post('/api/chat/session/:id/unarchive', async (req, res) => {
  try {
    const sessionId = validateSessionId(req.params.id);
    if (!sessionId) {
      return res.status(400).json({ error: 'Invalid session ID' });
    }

    const unarchived = await orchestrator.unarchiveSession(sessionId);
    if (unarchived) {
      res.json({ unarchived: true, id: sessionId });
    } else {
      res.status(404).json({ error: 'Session not found' });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * DELETE /api/chat/session/:id
 * Delete a chat session permanently
 */
app.delete('/api/chat/session/:id', async (req, res) => {
  try {
    const sessionId = validateSessionId(req.params.id);
    if (!sessionId) {
      return res.status(400).json({ error: 'Invalid session ID' });
    }

    const deleted = await orchestrator.deleteSessionById(sessionId);
    if (deleted) {
      res.json({ deleted: true, id: sessionId });
    } else {
      res.status(404).json({ error: 'Session not found' });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/chat/sessions/reload
 * Reload the session index from disk
 * Useful when session files have been modified externally
 */
app.post('/api/chat/sessions/reload', async (req, res) => {
  try {
    await orchestrator.reloadSessionIndex();
    const sessions = orchestrator.listChatSessions();
    log.info('Session index reloaded', { count: sessions.length });
    res.json({ reloaded: true, sessionCount: sessions.length });
  } catch (error) {
    log.error('Failed to reload session index', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/agents/spawn
 * Spawn an agent (add to queue)
 */
app.post('/api/agents/spawn', async (req, res) => {
  try {
    const { agentPath, message, context, priority, scheduledFor } = req.body;

    if (!agentPath) {
      return res.status(400).json({ error: 'agentPath is required' });
    }

    const queueId = await orchestrator.enqueue(
      agentPath,
      { userMessage: message, ...context },
      { priority, scheduledFor }
    );

    res.json({
      queued: true,
      queueId,
      agentPath
    });

  } catch (error) {
    log.error('Spawn error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/agents
 * List all defined agents
 */
app.get('/api/agents', async (req, res) => {
  try {
    const agents = await orchestrator.getAgents();
    res.json(agents.map(a => ({
      name: a.name,
      path: a.path,
      description: a.description,
      type: a.type || 'chatbot',
      model: a.model,
      triggers: a.triggers
    })));
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/contexts
 * List available context files from Chat/contexts/ folder
 * Returns files that can be loaded into chat sessions
 */
app.get('/api/contexts', async (req, res) => {
  try {
    const contextsPath = path.join(CONFIG.vaultPath, 'Chat', 'contexts');

    // Check if contexts folder exists
    try {
      await fs.access(contextsPath);
    } catch {
      // No contexts folder yet
      return res.json({ contexts: [] });
    }

    // List all .md files in Chat/contexts/
    const files = await fs.readdir(contextsPath);
    const contexts = [];

    for (const file of files) {
      if (file.endsWith('.md')) {
        const filePath = path.join(contextsPath, file);
        const stats = await fs.stat(filePath);
        const content = await fs.readFile(filePath, 'utf-8');

        // Extract title from first heading or filename
        const titleMatch = content.match(/^#\s+(.+)$/m);
        const title = titleMatch ? titleMatch[1] : file.replace('.md', '');

        // Get first paragraph as description
        const lines = content.split('\n').filter(l => l.trim() && !l.startsWith('#'));
        const description = lines[0]?.substring(0, 200) || '';

        contexts.push({
          path: `Chat/contexts/${file}`,
          filename: file,
          title,
          description,
          isDefault: file === 'general-context.md',
          size: stats.size,
          modified: stats.mtime
        });
      }
    }

    // Sort: general-context first, then alphabetically
    contexts.sort((a, b) => {
      if (a.isDefault) return -1;
      if (b.isDefault) return 1;
      return a.title.localeCompare(b.title);
    });

    res.json({ contexts });
  } catch (error) {
    log.error('Error listing contexts', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/queue
 * Get queue state
 */
app.get('/api/queue', async (req, res) => {
  try {
    const state = orchestrator.getQueueState();
    res.json(state);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/stats
 * Get system stats for debugging
 */
app.get('/api/stats', async (req, res) => {
  try {
    const sessionStats = orchestrator.getSessionStats();
    const queueState = orchestrator.getQueueState();
    const documents = await orchestrator.listVaultFiles();

    res.json({
      vaultPath: CONFIG.vaultPath,
      documents: documents.length,
      sessions: sessionStats,
      queue: {
        pending: queueState.pending?.length || 0,
        running: queueState.running?.length || 0,
        completed: queueState.completed?.length || 0
      },
      uptime: process.uptime() * 1000, // Convert to milliseconds for dashboard
      nodeVersion: process.version,
      memory: process.memoryUsage()
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/stats/usage
 * Get token usage statistics from the usage tracker
 */
app.get('/api/stats/usage', async (req, res) => {
  try {
    const tracker = getUsageTracker();
    if (!tracker) {
      return res.json({
        today: { totalTokens: 0, estimatedCost: 0, requestCount: 0, cacheReadInputTokens: 0 },
        total: { totalTokens: 0, estimatedCost: 0, requestCount: 0 },
        activeSessions: 0,
        topAgents: []
      });
    }
    res.json(tracker.getSummary());
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/analytics
 * Get agent and session analytics
 */
app.get('/api/analytics', async (req, res) => {
  try {
    const sessionStats = orchestrator.getSessionStats();
    const queueState = orchestrator.getQueueState();
    const agents = await orchestrator.getAgents();

    // Group sessions by agent
    const sessions = orchestrator.listChatSessions();
    const sessionsByAgent = {};
    const sessionsByDay = {};

    for (const session of sessions) {
      // By agent
      const agentKey = session.agentPath || 'vault-agent';
      sessionsByAgent[agentKey] = (sessionsByAgent[agentKey] || 0) + 1;

      // By day (from createdAt)
      if (session.createdAt) {
        const day = new Date(session.createdAt).toISOString().split('T')[0];
        sessionsByDay[day] = (sessionsByDay[day] || 0) + 1;
      }
    }

    // Calculate averages
    const totalMessages = sessions.reduce((sum, s) => sum + (s.messageCount || 0), 0);
    const avgMessagesPerSession = sessions.length > 0 ? Math.round(totalMessages / sessions.length) : 0;

    res.json({
      overview: {
        totalSessions: sessions.length,
        activeSessions: sessionStats.activeCount || 0,
        totalAgents: agents.length,
        totalMessages,
        avgMessagesPerSession
      },
      queue: {
        pending: queueState.pending?.length || 0,
        running: queueState.running?.length || 0,
        completed: queueState.completed?.length || 0
      },
      sessionsByAgent,
      sessionsByDay: Object.entries(sessionsByDay)
        .sort(([a], [b]) => b.localeCompare(a))
        .slice(0, 30)
        .reduce((obj, [k, v]) => ({ ...obj, [k]: v }), {}),
      agents: agents.map(a => ({
        name: a.name,
        path: a.path,
        type: a.type || 'chatbot',
        sessionCount: sessionsByAgent[a.path] || 0
      })),
      system: {
        uptime: process.uptime(),
        memoryMB: Math.round(process.memoryUsage().heapUsed / 1024 / 1024)
      }
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// TOKEN USAGE TRACKING
// ============================================================================

/**
 * GET /api/usage
 * Get token usage summary
 */
app.get('/api/usage', async (req, res) => {
  try {
    const tracker = getUsageTracker();
    if (!tracker) {
      return res.json({ error: 'Usage tracking not initialized', usage: null });
    }
    res.json(tracker.getSummary());
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/usage/daily
 * Get daily usage for the last N days
 */
app.get('/api/usage/daily', async (req, res) => {
  try {
    const tracker = getUsageTracker();
    if (!tracker) {
      return res.json([]);
    }
    const days = Math.min(parseInt(req.query.days, 10) || 30, 90);
    res.json(tracker.getDailyUsage(days));
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/usage/hourly
 * Get hourly usage for the last N hours
 */
app.get('/api/usage/hourly', async (req, res) => {
  try {
    const tracker = getUsageTracker();
    if (!tracker) {
      return res.json([]);
    }
    const hours = Math.min(parseInt(req.query.hours, 10) || 24, 168);
    res.json(tracker.getHourlyUsage(hours));
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/usage/session/:id
 * Get usage for a specific session
 */
app.get('/api/usage/session/:id', async (req, res) => {
  try {
    const tracker = getUsageTracker();
    if (!tracker) {
      return res.json({ error: 'Usage tracking not initialized' });
    }
    res.json(tracker.getSessionUsage(req.params.id));
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/usage/agent/:path
 * Get usage for a specific agent
 */
app.get('/api/usage/agent/*', async (req, res) => {
  try {
    const tracker = getUsageTracker();
    if (!tracker) {
      return res.json({ error: 'Usage tracking not initialized' });
    }
    res.json(tracker.getAgentUsage(req.params[0]));
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/logs
 * Query recent logs with pagination
 * Query params: level, component, since, limit, offset
 */
app.get('/api/logs', async (req, res) => {
  try {
    const { level, component, since } = req.query;
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 100, 1), 500);
    const offset = Math.min(Math.max(parseInt(req.query.offset, 10) || 0, 0), 100000);

    // Get all matching logs first
    const allLogs = queryLogs({
      level,
      component,
      since,
      limit: 10000  // Get all then paginate
    });

    // Paginate
    const total = allLogs.length;
    const paginated = allLogs.slice(offset, offset + limit);

    res.json({
      logs: paginated,
      pagination: {
        total,
        limit,
        offset,
        hasMore: offset + limit < total
      }
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/logs/stats
 * Get log statistics
 */
app.get('/api/logs/stats', async (req, res) => {
  try {
    const stats = getLogStats();
    res.json(stats);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// APP PERFORMANCE DATA
// ============================================================================

/**
 * GET /api/perf
 * Get app performance summary (written by Flutter app)
 *
 * The Flutter app writes performance data to {vault}/.parachute/perf/
 * This endpoint reads that data for easy access from Claude Code.
 */
app.get('/api/perf', async (req, res) => {
  try {
    const perfDir = path.join(CONFIG.vaultPath, '.parachute', 'perf');
    const summaryPath = path.join(perfDir, 'summary.json');

    try {
      const content = await fs.readFile(summaryPath, 'utf-8');
      const summary = JSON.parse(content);
      res.json(summary);
    } catch (error) {
      if (error.code === 'ENOENT') {
        return res.json({
          error: 'No performance data available',
          hint: 'Run the Flutter app to generate performance data',
          path: summaryPath,
        });
      }
      throw error;
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/perf/events
 * Get recent performance events (JSONL format)
 *
 * Query params:
 * - limit: Max events to return (default 100)
 * - slow: If 'true', only return slow events (>16ms)
 * - name: Filter by operation name
 */
app.get('/api/perf/events', async (req, res) => {
  try {
    const perfDir = path.join(CONFIG.vaultPath, '.parachute', 'perf');
    const eventsPath = path.join(perfDir, 'current.jsonl');
    const limit = parseInt(req.query.limit || '100', 10);
    const onlySlow = req.query.slow === 'true';
    const nameFilter = req.query.name;

    try {
      const content = await fs.readFile(eventsPath, 'utf-8');
      let events = content
        .split('\n')
        .filter(line => line.trim())
        .map(line => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        })
        .filter(e => e !== null);

      // Apply filters
      if (onlySlow) {
        events = events.filter(e => e.isSlow);
      }
      if (nameFilter) {
        events = events.filter(e => e.name === nameFilter);
      }

      // Return most recent first, limited
      events = events.slice(-limit).reverse();

      res.json({
        count: events.length,
        events,
      });
    } catch (error) {
      if (error.code === 'ENOENT') {
        return res.json({
          count: 0,
          events: [],
          hint: 'No events recorded yet',
        });
      }
      throw error;
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/perf/report
 * Get a text-formatted performance report for easy reading
 */
app.get('/api/perf/report', async (req, res) => {
  try {
    const perfDir = path.join(CONFIG.vaultPath, '.parachute', 'perf');
    const summaryPath = path.join(perfDir, 'summary.json');

    try {
      const content = await fs.readFile(summaryPath, 'utf-8');
      const summary = JSON.parse(content);

      // Generate text report
      let report = '=== App Performance Report ===\n';
      report += `Generated: ${summary.generatedAt}\n`;
      report += `Tracking Duration: ${summary.trackingDurationSec}s\n\n`;

      report += '--- Frame Performance ---\n';
      report += `Total Frames: ${summary.frames?.total || 0}\n`;
      report += `Slow Frames (>16ms): ${summary.frames?.slow || 0}\n`;
      report += `Slow Frame Rate: ${summary.frames?.slowPercent || 0}%\n\n`;

      report += '--- Operations (by total time) ---\n';
      if (summary.operations) {
        const ops = Object.values(summary.operations)
          .sort((a, b) => (b.totalMs || 0) - (a.totalMs || 0))
          .slice(0, 15);

        for (const op of ops) {
          report += `\n${op.name}:\n`;
          report += `  Count: ${op.count}, Total: ${op.totalMs}ms, Avg: ${op.avgMs}ms, Max: ${op.maxMs}ms\n`;
          if (op.slowCount > 0) {
            report += `  Slow (>16ms): ${op.slowCount} (${((op.slowCount / op.count) * 100).toFixed(1)}%)\n`;
          }
        }
      }

      if (summary.recentSlowEvents?.length > 0) {
        report += '\n--- Recent Slow Events ---\n';
        for (const event of summary.recentSlowEvents.slice(0, 10)) {
          report += `${event.timestamp}: ${event.name} took ${event.durationMs}ms\n`;
          if (event.metadata) {
            report += `  ${JSON.stringify(event.metadata)}\n`;
          }
        }
      }

      res.type('text/plain').send(report);
    } catch (error) {
      if (error.code === 'ENOENT') {
        return res.type('text/plain').send(
          'No performance data available.\n\n' +
          'Run the Flutter app to generate performance data.\n' +
          'Data will be written to: ' + summaryPath
        );
      }
      throw error;
    }
  } catch (error) {
    res.status(500).send(`Error: ${error.message}`);
  }
});

// ============================================================================
// AGENTS.MD MANAGEMENT
// ============================================================================

/**
 * GET /api/agents-md
 * Get the AGENTS.md content from vault root
 */
app.get('/api/agents-md', async (req, res) => {
  try {
    const agentsMdPath = path.join(CONFIG.vaultPath, 'AGENTS.md');
    const content = await fs.readFile(agentsMdPath, 'utf-8');
    res.json({ content, path: agentsMdPath });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return res.json({ content: null, path: null, exists: false });
    }
    res.status(500).json({ error: error.message });
  }
});

/**
 * PUT /api/agents-md
 * Update the AGENTS.md content
 * Body: { content: string } OR { fromDefault: true }
 *
 * If fromDefault is true, copies the built-in default prompt to AGENTS.md.
 * This works even if AGENTS.md already exists, allowing users to reset to default.
 */
app.put('/api/agents-md', async (req, res) => {
  try {
    const { content, fromDefault } = req.body;
    const agentsMdPath = path.join(CONFIG.vaultPath, 'AGENTS.md');

    let contentToWrite;
    if (fromDefault === true) {
      // Copy the default prompt to AGENTS.md
      contentToWrite = PARACHUTE_DEFAULT_PROMPT;
      log.info('Copying default prompt to AGENTS.md');
    } else if (typeof content === 'string') {
      contentToWrite = content;
    } else {
      return res.status(400).json({ error: 'Content must be a string, or set fromDefault: true' });
    }

    await fs.writeFile(agentsMdPath, contentToWrite, 'utf-8');
    res.json({
      saved: true,
      path: agentsMdPath,
      fromDefault: fromDefault === true
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/default-prompt
 * Get the built-in Parachute default system prompt
 *
 * This is the prompt used when no AGENTS.md exists in the vault.
 * Users can view this to understand what behaviors are built-in,
 * then optionally create AGENTS.md to override it.
 */
app.get('/api/default-prompt', async (req, res) => {
  try {
    // Check if AGENTS.md exists (to show if override is active)
    const agentsMdPath = path.join(CONFIG.vaultPath, 'AGENTS.md');
    let hasOverride = false;
    try {
      await fs.access(agentsMdPath);
      hasOverride = true;
    } catch {
      // No AGENTS.md, using default
    }

    res.json({
      content: PARACHUTE_DEFAULT_PROMPT,
      isActive: !hasOverride,
      overrideFile: hasOverride ? 'AGENTS.md' : null,
      description: 'Built-in Parachute system prompt. Create AGENTS.md in your vault to override.'
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/permissions
 * Get pending permission requests
 */
app.get('/api/permissions', async (req, res) => {
  try {
    const pending = orchestrator.getPendingPermissions();
    res.json(pending);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/permissions/:id/grant
 * Grant a permission request
 */
app.post('/api/permissions/:id/grant', async (req, res) => {
  try {
    const granted = orchestrator.grantPermission(req.params.id);
    if (granted) {
      res.json({ granted: true, id: req.params.id });
    } else {
      res.status(404).json({ error: 'Permission request not found' });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/permissions/:id/deny
 * Deny a permission request
 */
app.post('/api/permissions/:id/deny', async (req, res) => {
  try {
    const denied = orchestrator.denyPermission(req.params.id);
    if (denied) {
      res.json({ denied: true, id: req.params.id });
    } else {
      res.status(404).json({ error: 'Permission request not found' });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/permissions/stream
 * SSE endpoint for real-time permission request notifications
 */
app.get('/api/permissions/stream', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('Access-Control-Allow-Origin', '*');

  // Send initial connection message
  res.write('data: {"type":"connected"}\n\n');

  // Listen for permission requests
  const onPermissionRequest = (request) => {
    res.write(`data: ${JSON.stringify({ type: 'permissionRequest', request })}\n\n`);
  };

  const onPermissionGranted = (request) => {
    res.write(`data: ${JSON.stringify({ type: 'permissionGranted', request })}\n\n`);
  };

  const onPermissionDenied = (request) => {
    res.write(`data: ${JSON.stringify({ type: 'permissionDenied', request })}\n\n`);
  };

  orchestrator.on('permissionRequest', onPermissionRequest);
  orchestrator.on('permissionGranted', onPermissionGranted);
  orchestrator.on('permissionDenied', onPermissionDenied);

  // Send any existing pending permissions
  const pending = orchestrator.getPendingPermissions();
  for (const request of pending) {
    res.write(`data: ${JSON.stringify({ type: 'permissionRequest', request })}\n\n`);
  }

  // Cleanup on close
  req.on('close', () => {
    orchestrator.off('permissionRequest', onPermissionRequest);
    orchestrator.off('permissionGranted', onPermissionGranted);
    orchestrator.off('permissionDenied', onPermissionDenied);
  });
});

// ============================================================================
// CAPTURES (Document Upload)
// ============================================================================

// Helper to validate vault paths using the shared utility
function validateVaultPath(relativePath) {
  return validateRelativePath(relativePath, CONFIG.vaultPath);
}

// ============================================================================
// MCP SERVER MANAGEMENT
// ============================================================================

/**
 * GET /api/mcp
 * List all MCP server configurations from .mcp.json
 */
app.get('/api/mcp', async (req, res) => {
  try {
    const servers = await orchestrator.listMcpServers();
    res.json(servers);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/mcp/:name
 * Add or update an MCP server configuration
 * Body: { command: "npx", args: [...] } or { type: "sse", url: "..." }
 */
app.post('/api/mcp/:name', async (req, res) => {
  try {
    const { name } = req.params;
    const config = req.body;

    if (!config || typeof config !== 'object') {
      return res.status(400).json({ error: 'Server configuration is required' });
    }

    // Validate config has required fields
    const hasStdio = config.command;
    const hasNetwork = config.type && config.url;
    if (!hasStdio && !hasNetwork) {
      return res.status(400).json({
        error: 'Invalid config: need either {command, args} for stdio or {type, url} for network'
      });
    }

    await orchestrator.addMcpServer(name, config);
    res.json({ added: true, name, config });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * DELETE /api/mcp/:name
 * Remove an MCP server configuration
 */
app.delete('/api/mcp/:name', async (req, res) => {
  try {
    const { name } = req.params;
    await orchestrator.removeMcpServer(name);
    res.json({ removed: true, name });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// SKILLS MANAGEMENT
// ============================================================================

/**
 * GET /api/skills
 * List all available skills in the vault
 */
app.get('/api/skills', async (req, res) => {
  try {
    const skills = await orchestrator.listSkills();
    res.json(skills);
  } catch (error) {
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
    const skill = await orchestrator.getSkill(name);
    if (!skill) {
      return res.status(404).json({ error: `Skill '${name}' not found` });
    }
    res.json(skill);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/skills/:name
 * Create or update a skill
 * Body: { name?, description, content, allowedTools? }
 */
app.post('/api/skills/:name', async (req, res) => {
  try {
    const { name } = req.params;
    const skillData = req.body;

    if (!skillData || typeof skillData !== 'object') {
      return res.status(400).json({ error: 'Skill data is required' });
    }

    if (!skillData.description) {
      return res.status(400).json({ error: 'Skill description is required' });
    }

    const skill = await orchestrator.createSkill(name, skillData);
    res.json({ created: true, skill });
  } catch (error) {
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
    const deleted = await orchestrator.deleteSkill(name);
    if (!deleted) {
      return res.status(404).json({ error: `Skill '${name}' not found` });
    }
    res.json({ deleted: true, name });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// GENERATION SETTINGS (para-generate)
// ============================================================================

/**
 * GET /api/generate/config
 * Get full generation configuration
 */
app.get('/api/generate/config', async (req, res) => {
  try {
    const config = await generateConfig.loadConfig(CONFIG.vaultPath, true);
    res.json(config);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/generate/backends/:type
 * List backends for a content type (image, audio, music, speech)
 */
app.get('/api/generate/backends/:type', async (req, res) => {
  try {
    const { type } = req.params;
    const backends = await generateConfig.listBackends(CONFIG.vaultPath, type);
    const defaultBackend = await generateConfig.getDefaultBackend(CONFIG.vaultPath, type);

    // Check availability for each backend
    const backendStatuses = await Promise.all(
      backends.map(async (b) => {
        try {
          const backendModule = await generateConfig.loadBackend(type, b.name);
          const availability = await backendModule.checkAvailability(b);
          return {
            ...b,
            available: availability.available,
            availabilityError: availability.error || null,
            info: backendModule.info,
          };
        } catch (e) {
          return {
            ...b,
            available: false,
            availabilityError: e.message,
            info: null,
          };
        }
      })
    );

    res.json({
      type,
      defaultBackend,
      backends: backendStatuses,
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * PUT /api/generate/backends/:type/:name
 * Update a specific backend's configuration
 * Body: { enabled?, model?, api_key?, steps?, quantize?, ... }
 */
app.put('/api/generate/backends/:type/:name', async (req, res) => {
  try {
    const { type, name } = req.params;
    const updates = req.body;

    if (!updates || typeof updates !== 'object') {
      return res.status(400).json({ error: 'Backend configuration is required' });
    }

    await generateConfig.updateBackendConfig(CONFIG.vaultPath, type, name, updates);
    const updated = await generateConfig.getBackendConfig(CONFIG.vaultPath, type, name);

    res.json({
      updated: true,
      type,
      name,
      config: updated,
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * PUT /api/generate/default/:type
 * Set the default backend for a content type
 * Body: { backend: "mflux" | "nano-banana" }
 */
app.put('/api/generate/default/:type', async (req, res) => {
  try {
    const { type } = req.params;
    const { backend } = req.body;

    if (!backend) {
      return res.status(400).json({ error: 'Backend name is required' });
    }

    await generateConfig.setDefaultBackend(CONFIG.vaultPath, type, backend);

    res.json({
      updated: true,
      type,
      defaultBackend: backend,
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/generate/backends/:type/:name/status
 * Check availability of a specific backend
 */
app.get('/api/generate/backends/:type/:name/status', async (req, res) => {
  try {
    const { type, name } = req.params;

    const backendModule = await generateConfig.loadBackend(type, name);
    const backendConfig = await generateConfig.getBackendConfig(CONFIG.vaultPath, type, name) || {};
    const availability = await backendModule.checkAvailability(backendConfig);

    res.json({
      name,
      type,
      available: availability.available,
      error: availability.error || null,
      info: backendModule.info,
      setupInstructions: !availability.available ? backendModule.getSetupInstructions() : null,
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/queue/process
 * Trigger queue processing
 */
app.post('/api/queue/process', async (req, res) => {
  try {
    await orchestrator.processQueue();
    const state = orchestrator.getQueueState();
    res.json({
      message: 'Processing triggered',
      ...state
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/queue/:id/stream
 * Stream live updates for a running queue item via SSE
 * Events: init, text, tool_use, done, error, close
 */
app.get('/api/queue/:id/stream', async (req, res) => {
  const { id } = req.params;

  // Set SSE headers
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.flushHeaders();

  // Check if queue item exists and is running
  const state = orchestrator.getQueueState();
  const runningItem = state.running.find(item => item.id === id);

  if (!runningItem) {
    // Check if it's in completed
    const completedItem = state.completed.find(item => item.id === id);
    if (completedItem) {
      res.write(`data: ${JSON.stringify({ type: 'already_completed', result: completedItem.result })}\n\n`);
      res.end();
      return;
    }
    res.write(`data: ${JSON.stringify({ type: 'error', error: 'Queue item not found or not running' })}\n\n`);
    res.end();
    return;
  }

  // Get or create the event stream for this queue item
  const stream = orchestrator.getQueueStream(id);

  // Send initial info
  res.write(`data: ${JSON.stringify({
    type: 'connected',
    queueItem: {
      id: runningItem.id,
      agentPath: runningItem.agentPath,
      documentPath: runningItem.context?.documentPath,
      startedAt: runningItem.startedAt
    }
  })}\n\n`);

  // Listen for events
  const eventHandler = (event) => {
    res.write(`data: ${JSON.stringify(event)}\n\n`);

    // Close connection on done, error, or close events
    if (event.type === 'done' || event.type === 'error' || event.type === 'close') {
      res.end();
    }
  };

  stream.on('event', eventHandler);

  // Cleanup on client disconnect
  req.on('close', () => {
    stream.off('event', eventHandler);
  });
});

/**
 * GET /api/documents
 * List all documents
 */
app.get('/api/documents', async (req, res) => {
  try {
    const files = await getVaultFiles();
    const documents = [];

    for (const file of files) {
      const doc = await getDocument(file);
      if (!doc) continue;
      documents.push({
        path: file,
        title: doc.frontmatter.title || path.basename(file, '.md'),
        agents: doc.frontmatter.agents || [],
        tags: doc.frontmatter.tags || [],
        preview: doc.body.substring(0, 200)
      });
    }

    res.json(documents);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/documents/agent-config
 * List all documents with agent configurations
 */
app.get('/api/documents/agent-config', async (req, res) => {
  try {
    const docs = await orchestrator.getAgentDocuments();
    res.json(docs.map(d => ({
      path: d.path,
      agent: d.agent,
      status: d.status,
      trigger: d.triggerRaw,
      lastRun: d.lastRun,
      context: d.context
    })));
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/documents/stats
 * Get document processing statistics
 */
app.get('/api/documents/stats', async (req, res) => {
  try {
    const stats = await orchestrator.getDocumentStats();
    res.json(stats);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/documents/:path/agents
 * Get all agents configured for a document
 */
app.get('/api/documents/*/agents', async (req, res) => {
  try {
    const docPath = validateVaultPath(req.params[0]);
    if (!docPath) {
      return res.status(400).json({ error: 'Invalid document path' });
    }
    const agents = await orchestrator.getDocumentAgents(docPath);
    res.json(agents);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * PUT /api/documents/:path/agents
 * Update agents configured for a document
 * Body: { agents: [{ path, trigger?, enabled? }] }
 */
app.put('/api/documents/*/agents', async (req, res) => {
  try {
    const docPath = validateVaultPath(req.params[0]);
    if (!docPath) {
      return res.status(400).json({ error: 'Invalid document path' });
    }
    const { agents } = req.body;

    if (!Array.isArray(agents)) {
      return res.status(400).json({ error: 'agents must be an array' });
    }

    await orchestrator.updateDocumentAgents(docPath, agents);
    const updated = await orchestrator.getDocumentAgents(docPath);
    res.json(updated);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/documents/:path/agents/pending
 * Get pending agents for a document
 */
app.get('/api/documents/*/agents/pending', async (req, res) => {
  try {
    const docPath = validateVaultPath(req.params[0]);
    if (!docPath) {
      return res.status(400).json({ error: 'Invalid document path' });
    }
    const agents = await orchestrator.getPendingAgents(docPath);
    res.json(agents);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/documents/:path/run-agents
 * Run agents on a document
 * Body: { agents?: string[] } - if omitted, runs all pending
 */
app.post('/api/documents/*/run-agents', async (req, res) => {
  try {
    const docPath = validateVaultPath(req.params[0]);
    if (!docPath) {
      return res.status(400).json({ error: 'Invalid document path' });
    }
    const { agents } = req.body;

    let results;
    if (agents && agents.length > 0) {
      results = await orchestrator.runAgentsOnDocument(docPath, agents);
    } else {
      results = await orchestrator.runAllAgentsOnDocument(docPath);
    }

    res.json({
      documentPath: docPath,
      results,
      ran: results.length
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/documents/:path/reset-agents
 * Reset agents to pending status
 * Body: { agents?: string[] } - if omitted, resets all
 */
app.post('/api/documents/*/reset-agents', async (req, res) => {
  try {
    const docPath = validateVaultPath(req.params[0]);
    if (!docPath) {
      return res.status(400).json({ error: 'Invalid document path' });
    }
    const { agents } = req.body;

    const reset = await orchestrator.resetDocumentAgents(docPath, agents);
    res.json({
      documentPath: docPath,
      reset,
      count: reset.length
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/documents/trigger/:path
 * Manually trigger all agents on a document for processing
 */
app.post('/api/documents/trigger/*', async (req, res) => {
  try {
    const docPath = validateVaultPath(req.params[0]);
    if (!docPath) {
      return res.status(400).json({ error: 'Invalid document path' });
    }
    const { agents } = req.body;

    let triggered;
    if (agents && agents.length > 0) {
      triggered = await orchestrator.triggerDocumentAgents(docPath, agents);
    } else {
      triggered = await orchestrator.triggerDocument(docPath);
    }

    res.json({ triggered: triggered, path: docPath, count: triggered.length });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/documents/process/:path
 * Process a document immediately (runs first/primary agent - legacy)
 */
app.post('/api/documents/process/*', async (req, res) => {
  try {
    const docPath = validateVaultPath(req.params[0]);
    if (!docPath) {
      return res.status(400).json({ error: 'Invalid document path' });
    }
    const result = await orchestrator.processDocument(docPath);
    res.json(result);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/documents/:path
 * Get a specific document (MUST be after specific routes)
 */
app.get('/api/documents/*', async (req, res) => {
  try {
    const docPath = validateVaultPath(req.params[0]);
    if (!docPath) {
      return res.status(400).json({ error: 'Invalid document path' });
    }
    const doc = await getDocument(docPath);
    if (!doc) {
      return res.status(404).json({ error: 'Document not found' });
    }
    res.json({
      ...doc,
      html: marked(doc.body)
    });
  } catch (error) {
    res.status(404).json({ error: 'Document not found' });
  }
});

/**
 * GET /api/search
 * Search the vault (legacy markdown search)
 */
app.get('/api/search', async (req, res) => {
  try {
    const { q } = req.query;
    const results = await findInVault(q || '');
    res.json(results);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// VAULT INDEX SEARCH (SQLite-based search over indexed content)
// ============================================================================

/**
 * GET /api/vault-search
 * Search indexed vault content (recordings, journals, chats)
 * Query params: q (query), limit, contentType
 */
app.get('/api/vault-search', async (req, res) => {
  try {
    const searchService = getVaultSearchService(CONFIG.vaultPath);

    if (!searchService.isAvailable()) {
      return res.json({
        available: false,
        message: 'Search index not found. The Flutter app needs to build the index first.',
        results: []
      });
    }

    const { q, limit, contentType } = req.query;

    if (!q) {
      return res.status(400).json({ error: 'Query parameter "q" is required' });
    }

    const options = {
      limit: limit ? parseInt(limit, 10) : 20,
      contentType: contentType || null
    };

    const results = searchService.search(q, options);

    res.json({
      available: true,
      query: q,
      count: results.length,
      results
    });
  } catch (error) {
    log.error('Vault search error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/vault-search/stats
 * Get statistics about indexed content
 */
app.get('/api/vault-search/stats', async (req, res) => {
  try {
    const searchService = getVaultSearchService(CONFIG.vaultPath);

    if (!searchService.isAvailable()) {
      return res.json({
        available: false,
        message: 'Search index not found'
      });
    }

    const stats = searchService.getStats();

    res.json({
      available: true,
      ...stats
    });
  } catch (error) {
    log.error('Vault search stats error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/vault-search/content
 * List all indexed content
 * Query params: contentType, limit
 */
app.get('/api/vault-search/content', async (req, res) => {
  try {
    const searchService = getVaultSearchService(CONFIG.vaultPath);

    if (!searchService.isAvailable()) {
      return res.json({
        available: false,
        message: 'Search index not found',
        content: []
      });
    }

    const { contentType, limit } = req.query;

    const options = {
      contentType: contentType || null,
      limit: limit ? parseInt(limit, 10) : 100
    };

    const content = searchService.listIndexedContent(options);

    res.json({
      available: true,
      count: content.length,
      content
    });
  } catch (error) {
    log.error('Vault search list error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/vault-search/content/:id
 * Get a specific content item by ID
 */
app.get('/api/vault-search/content/:id', async (req, res) => {
  try {
    const searchService = getVaultSearchService(CONFIG.vaultPath);

    if (!searchService.isAvailable()) {
      return res.json({
        available: false,
        message: 'Search index not found'
      });
    }

    const content = searchService.getContent(req.params.id);

    if (!content) {
      return res.status(404).json({ error: 'Content not found' });
    }

    res.json({
      available: true,
      ...content
    });
  } catch (error) {
    log.error('Vault search content error', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// MODULE SEARCH (Per-module RAG indexes)
// ============================================================================

/**
 * GET /api/modules
 * List all modules and their index status
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
 * GET /api/modules/stats
 * Get stats for all modules
 */
app.get('/api/modules/stats', async (req, res) => {
  try {
    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);
    const stats = moduleSearch.getStats();
    res.json(stats);
  } catch (error) {
    log.error('Module stats error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/modules/search
 * Search across all modules
 * Query params: q (query), limit, modules (comma-separated)
 */
app.get('/api/modules/search', async (req, res) => {
  try {
    const { q, limit, modules } = req.query;

    if (!q) {
      return res.status(400).json({ error: 'Query parameter "q" is required' });
    }

    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);
    const options = {
      limit: limit ? parseInt(limit, 10) : 20,
      modules: modules ? modules.split(',').map(m => m.trim()) : undefined,
    };

    const results = await moduleSearch.searchAll(q, options);
    res.json(results);
  } catch (error) {
    log.error('Cross-module search error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/modules/:module/search
 * Search within a specific module
 * Query params: q (query), limit
 */
app.get('/api/modules/:module/search', async (req, res) => {
  try {
    const { module } = req.params;
    const { q, limit } = req.query;

    if (!q) {
      return res.status(400).json({ error: 'Query parameter "q" is required' });
    }

    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);
    const options = {
      limit: limit ? parseInt(limit, 10) : 20,
    };

    const results = await moduleSearch.searchModule(module, q, options);
    res.json(results);
  } catch (error) {
    log.error('Module search error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/modules/:module/stats
 * Get stats for a specific module
 */
app.get('/api/modules/:module/stats', async (req, res) => {
  try {
    const { module } = req.params;
    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);
    const indexer = moduleSearch.getIndexer(module);

    if (!indexer) {
      return res.status(404).json({
        error: `Module '${module}' not found or not indexed`
      });
    }

    const stats = indexer.getStats();
    res.json({
      module,
      ...stats
    });
  } catch (error) {
    log.error('Module stats error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/modules/:module/recent
 * List recent content from a module
 * Query params: limit
 */
app.get('/api/modules/:module/recent', async (req, res) => {
  try {
    const { module } = req.params;
    const { limit } = req.query;

    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);
    const recent = moduleSearch.listRecent(module, {
      limit: limit ? parseInt(limit, 10) : 20,
    });

    res.json({
      module,
      count: recent.length,
      items: recent
    });
  } catch (error) {
    log.error('Module recent error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/modules/:module/content/:id
 * Get specific content from a module
 */
app.get('/api/modules/:module/content/:id', async (req, res) => {
  try {
    const { module, id } = req.params;
    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);
    const content = moduleSearch.getContent(module, id);

    if (!content) {
      return res.status(404).json({
        error: `Content '${id}' not found in module '${module}'`
      });
    }

    res.json({
      module,
      ...content
    });
  } catch (error) {
    log.error('Module content error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/modules/:module/index
 * Rebuild index for a module
 * Body: { withEmbeddings?: boolean }
 */
app.post('/api/modules/:module/index', async (req, res) => {
  try {
    const { module } = req.params;
    const { withEmbeddings = true } = req.body || {};

    const moduleSearch = getModuleSearchService(CONFIG.vaultPath);

    log.info('Rebuilding module index', { module, withEmbeddings });

    const result = await moduleSearch.rebuildModuleIndex(module, { withEmbeddings });

    log.info('Module index rebuilt', {
      module,
      contentCount: result.contentCount,
      chunkCount: result.chunkCount
    });

    res.json({
      success: true,
      module,
      ...result
    });
  } catch (error) {
    log.error('Module index rebuild error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/setup
 * Get system setup status including Ollama and search index availability
 *
 * Returns:
 * - ollamaStatus: Ollama running status and model availability
 * - searchIndex: Whether the search database exists
 * - semanticSearch: Whether semantic (meaning-based) search is available
 */
app.get('/api/setup', async (req, res) => {
  try {
    // Check Ollama status
    const ollamaStatus = await getOllamaStatus();

    // Check search index
    const searchService = getVaultSearchService(CONFIG.vaultPath);
    const searchIndexAvailable = searchService.isAvailable();

    // Semantic search requires both Ollama + model + search index with embeddings
    const semanticSearchReady = ollamaStatus.ready && searchIndexAvailable;

    const status = {
      ready: semanticSearchReady,
      ollama: {
        running: ollamaStatus.ollamaRunning,
        modelAvailable: ollamaStatus.modelAvailable,
        modelName: ollamaStatus.modelName,
        url: ollamaStatus.ollamaUrl,
      },
      searchIndex: {
        available: searchIndexAvailable,
        path: path.join(CONFIG.vaultPath, '.parachute', 'search.db'),
      },
      semanticSearch: {
        available: semanticSearchReady,
        reason: !ollamaStatus.ollamaRunning ? 'Ollama not running'
              : !ollamaStatus.modelAvailable ? `Model ${ollamaStatus.modelName} not installed`
              : !searchIndexAvailable ? 'Search index not built'
              : 'Ready',
      },
      setupInstructions: ollamaStatus.setupInstructions,
    };

    res.json(status);
  } catch (error) {
    log.error('Setup check error', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/vault
 * Get vault info
 */
app.get('/api/vault', async (req, res) => {
  try {
    const files = await getVaultFiles();
    const agents = await orchestrator.getAgents();

    res.json({
      path: CONFIG.vaultPath,
      totalDocuments: files.length,
      totalAgents: agents.length,
      documents: files
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/directories
 * Get directories that can be used as working directories for chat sessions
 * Returns the vault path and any recently used directories from sessions
 */
app.get('/api/directories', async (req, res) => {
  try {
    // Get the home vault directory
    const homeDir = CONFIG.vaultPath;

    // Collect unique working directories from existing sessions
    const sessions = orchestrator.listChatSessions();
    const usedDirs = new Set();

    for (const session of sessions) {
      if (session.workingDirectory && session.workingDirectory !== homeDir) {
        usedDirs.add(session.workingDirectory);
      }
    }

    // Build the list with home vault first, then recently used
    const directories = [
      {
        path: homeDir,
        name: path.basename(homeDir),
        type: 'vault',
        description: 'Home vault'
      }
    ];

    for (const dir of usedDirs) {
      directories.push({
        path: dir,
        name: path.basename(dir),
        type: 'recent',
        description: 'Recently used'
      });
    }

    res.json({
      homeVault: homeDir,
      directories
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/triggers/check
 * Manually check all triggers
 */
app.post('/api/triggers/check', async (req, res) => {
  try {
    await orchestrator.checkTriggers();
    const stats = await orchestrator.getDocumentStats();
    res.json({ checked: true, stats });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// START SERVER
// ============================================================================

// Track server instance for graceful shutdown
let server = null;
let usageTracker = null;
let isShuttingDown = false;

/**
 * Graceful shutdown handler
 */
async function gracefulShutdown(signal) {
  if (isShuttingDown) {
    log.warn('Already shutting down...');
    return;
  }

  isShuttingDown = true;
  log.info(`Received ${signal}, shutting down gracefully...`);

  // Give active requests time to complete
  const shutdownTimeout = setTimeout(() => {
    log.error('Forced shutdown after timeout');
    process.exit(1);
  }, 30000);

  try {
    // Stop accepting new connections
    if (server) {
      await new Promise((resolve) => {
        server.close(resolve);
      });
      log.info('HTTP server closed');
    }

    // Save usage data
    if (usageTracker) {
      await usageTracker.shutdown();
      log.info('Usage data saved');
    }

    // Clean up orchestrator intervals
    if (orchestrator.permissionCleanupInterval) {
      clearInterval(orchestrator.permissionCleanupInterval);
    }

    // Save session data
    // (SessionManager saves on each message, but we ensure final save)
    log.info('Cleanup complete');

    clearTimeout(shutdownTimeout);
    process.exit(0);
  } catch (error) {
    log.error('Error during shutdown', error);
    clearTimeout(shutdownTimeout);
    process.exit(1);
  }
}

// Register shutdown handlers
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// Handle uncaught errors gracefully
process.on('uncaughtException', (error) => {
  log.error('Uncaught exception', error);
  gracefulShutdown('uncaughtException');
});

process.on('unhandledRejection', (reason, promise) => {
  log.error('Unhandled rejection', { reason: String(reason), promise: String(promise) });
});

async function start() {
  // Initialize usage tracker
  usageTracker = await initializeUsageTracker(CONFIG.vaultPath);
  log.info('Usage tracker initialized');

  // Initialize orchestrator
  await orchestrator.initialize();

  server = app.listen(CONFIG.port, CONFIG.host, async () => {
    log.info('Server started', {
      host: CONFIG.host,
      port: CONFIG.port,
      vault: CONFIG.vaultPath
    });

    console.log(`
╔═══════════════════════════════════════════════════════════════╗
║           🧠 Parachute Agent Server                           ║
║         (Claude Agent SDK + Orchestrator)                     ║
╠═══════════════════════════════════════════════════════════════╣
║  Server:  http://${CONFIG.host}:${CONFIG.port}                              ║
║  Vault:   ${CONFIG.vaultPath.substring(0, 45).padEnd(45)}   ║
║  Dashboard: http://${CONFIG.host}:${CONFIG.port}/                           ║
╠═══════════════════════════════════════════════════════════════╣
║  Endpoints:                                                   ║
║    POST /api/chat            - Chat with agent                ║
║    POST /api/chat/stream     - Streaming chat (SSE)           ║
║    GET  /api/chat/sessions   - List sessions (paginated)      ║
║    GET  /api/logs            - Query server logs              ║
║    GET  /api/agents          - List defined agents            ║
║    GET  /api/setup           - Check Ollama/search status     ║
║                                                               ║
║  Graceful shutdown on SIGTERM/SIGINT                          ║
╚═══════════════════════════════════════════════════════════════╝
    `);

    // Check Ollama status and provide guidance
    try {
      const ollamaStatus = await getOllamaStatus();
      const searchService = getVaultSearchService(CONFIG.vaultPath);
      const searchIndexAvailable = searchService.isAvailable();

      console.log('\n📊 Semantic Search Status:');

      if (!ollamaStatus.ollamaRunning) {
        console.log('  ⚠️  Ollama not running - semantic search disabled');
        console.log('      Install: brew install ollama (macOS) or https://ollama.com');
      } else if (!ollamaStatus.modelAvailable) {
        console.log('  ⚠️  Embedding model not installed');
        console.log(`      Run: ollama pull ${ollamaStatus.modelName}`);
      } else if (!searchIndexAvailable) {
        console.log('  ⚠️  Search index not built');
        console.log('      Build it in the Flutter app: Search tab → Build Index');
      } else {
        console.log('  ✅ Semantic search ready (Ollama + embeddinggemma)');
      }

      if (!searchIndexAvailable) {
        console.log('\n📁 Search Index:');
        console.log('  ⚠️  Not found - build it in the Flutter app (Search tab)');
      }

      console.log('');
    } catch (e) {
      log.warn('Failed to check Ollama status', { error: e.message });
    }
  });
}

start().catch((error) => {
  log.error('Failed to start server', error);
  process.exit(1);
});
