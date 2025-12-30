/**
 * Agent Orchestrator
 *
 * Central controller that manages agent execution:
 * - Loads agents from markdown definitions
 * - Manages the execution queue
 * - Runs agents via Claude Agent SDK
 * - Handles spawn requests with depth limiting
 * - Enforces permissions
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import path from 'path';
import fs from 'fs/promises';
import { loadAgent, buildSystemPrompt, hasPermission, matchesPatterns, loadAllAgents, AgentType } from './agent-loader.js';
import { AgentQueue, Status, Priority } from './queue.js';
import { DocumentScanner, AgentStatus, parseTrigger, shouldTriggerFire } from './document-scanner.js';
import { SessionManager } from './session-manager-v2.js';
import { loadAgentContext, formatContextForPrompt } from './context-loader.js';
import { loadMcpServers, resolveMcpServers, listMcpServers, addMcpServer, removeMcpServer } from './mcp-loader.js';
import { discoverSkills, loadSkill, createSkill, deleteSkill, ensureSkillsDir } from './skills-loader.js';
import { EventEmitter } from 'events';
import { orchestratorLogger as log } from './logger.js';
import { PARACHUTE_DEFAULT_PROMPT } from './default-prompt.js';

/**
 * Default orchestrator configuration
 */
const DEFAULT_CONFIG = {
  maxDepth: 3,           // Max agent spawn depth
  maxConcurrent: 1,      // Max concurrent agent executions
  defaultTimeout: 300,   // Default timeout in seconds
  persistQueue: true     // Persist queue to disk
};

/**
 * Agent Orchestrator class
 */
export class Orchestrator extends EventEmitter {
  constructor(vaultPath, config = {}) {
    super();
    this.vaultPath = vaultPath;
    this.config = { ...DEFAULT_CONFIG, ...config };

    // Initialize queue
    this.queue = new AgentQueue({
      maxSize: 100,
      persistPath: this.config.persistQueue
        ? path.join(vaultPath, '.queue', 'queue.json')
        : null,
      keepCompleted: 50
    });

    // Track running executions
    this.running = new Map();

    // Processing state
    this.isProcessing = false;

    // Document scanner
    this.documentScanner = new DocumentScanner(vaultPath);

    // Session manager for chatbot agents
    this.sessionManager = new SessionManager(vaultPath);

    // Pending permission requests (for interactive approval flow)
    this.pendingPermissions = new Map();

    // Queue item event streams (for watching running queue items)
    // Map<queueItemId, EventEmitter>
    this.queueStreams = new Map();

    // Permission cleanup interval (to prevent memory leaks)
    this.permissionCleanupInterval = null;

    // Bounds limits to prevent memory exhaustion
    this.MAX_PENDING_PERMISSIONS = 100;
    this.MAX_QUEUE_STREAMS = 50;
  }

  /**
   * Check if we can add a pending permission (memory bounds)
   */
  canAddPendingPermission() {
    if (this.pendingPermissions.size >= this.MAX_PENDING_PERMISSIONS) {
      console.warn(`[Orchestrator] Too many pending permissions (${this.pendingPermissions.size}), denying new request`);
      return false;
    }
    return true;
  }

  /**
   * Check if we can add a queue stream (memory bounds)
   */
  canAddQueueStream() {
    if (this.queueStreams.size >= this.MAX_QUEUE_STREAMS) {
      console.warn(`[Orchestrator] Too many queue streams (${this.queueStreams.size}), rejecting`);
      return false;
    }
    return true;
  }

  /**
   * Permission tiers for tool access:
   * - TIER 1 (always allow): Read-only tools
   * - TIER 2 (configurable): Write tools - ask if outside allowed paths
   * - TIER 3 (ask first): MCP tools - ask unless pre-approved for session
   */
  // TIER 1: Read-only tools - always allow
  static TIER1_ALWAYS_ALLOW = [
    'Read', 'Glob', 'Grep', 'LS',           // File reading & search
    'WebSearch', 'WebFetch',                 // Web access
    'NotebookRead',                          // Notebook reading
    'Task'                                   // Sub-agent spawning (for complex tasks)
  ];
  // TIER 2: Write tools - check against allowed paths
  static TIER2_WRITE_TOOLS = [
    'Write', 'Edit', 'MultiEdit',            // File writing
    'Bash',                                  // Command execution
    'NotebookEdit'                           // Notebook editing
  ];

  /**
   * Create a canUseTool callback for an agent that enforces permissions
   * and can request user approval for out-of-bounds operations.
   *
   * This callback will BLOCK and wait for user approval when a write
   * operation is attempted outside the allowed paths, or when an MCP
   * tool is used for the first time in a session.
   *
   * @param {object} agent - Agent definition
   * @param {string} sessionId - Session ID for tracking
   * @param {Function} onDenial - Callback when permission is denied
   * @param {object} sessionSettings - Session-level settings (approved MCPs, etc.)
   */
  createPermissionHandler(agent, sessionId, onDenial = null, sessionSettings = {}) {
    // Track MCPs approved during this session
    const approvedMcpsThisSession = new Set(sessionSettings.approvedMcps || []);

    return async (toolName, input, options) => {
      // Log ALL tool calls for debugging
      console.log(`[Orchestrator] canUseTool called: ${toolName}`, JSON.stringify({
        input: typeof input === 'object' ? Object.keys(input) : input,
        blockedPath: options?.blockedPath,
        decisionReason: options?.decisionReason
      }));

      // ─────────────────────────────────────────────────────────────────
      // TIER 1: Always allow read-only tools
      // ─────────────────────────────────────────────────────────────────
      if (Orchestrator.TIER1_ALWAYS_ALLOW.includes(toolName)) {
        console.log(`[Orchestrator] TIER 1 auto-allow: ${toolName}`);
        return { behavior: 'allow', updatedInput: input };
      }

      // ─────────────────────────────────────────────────────────────────
      // TIER 3: MCP tools - ask first unless pre-approved
      // MCP tools have names like mcp__servername__toolname
      // ─────────────────────────────────────────────────────────────────
      if (toolName.startsWith('mcp__')) {
        const mcpParts = toolName.split('__');
        const mcpServerName = mcpParts[1];
        const mcpToolName = mcpParts[2] || 'unknown';

        // Built-in MCPs are always auto-approved (safe, local operations)
        const builtInMcps = ['vault-search', 'para-generate'];
        if (builtInMcps.includes(mcpServerName)) {
          console.log(`[Orchestrator] MCP auto-allow (built-in): ${toolName}`);
          return { behavior: 'allow', updatedInput: input };
        }

        // Check if this MCP server is pre-approved for this session
        if (approvedMcpsThisSession.has(mcpServerName)) {
          console.log(`[Orchestrator] MCP auto-allow (session-approved): ${toolName}`);
          return { behavior: 'allow', updatedInput: input };
        }

        // Check if globally approved in agent config
        const approvedMcps = agent.permissions?.approvedMcps || [];
        if (approvedMcps.includes(mcpServerName) || approvedMcps.includes('*')) {
          console.log(`[Orchestrator] MCP auto-allow (agent config): ${toolName}`);
          return { behavior: 'allow', updatedInput: input };
        }

        // Request permission for this MCP tool
        console.log(`[Orchestrator] MCP requires approval: ${toolName}`);

        const requestId = `${sessionId}-${options?.toolUseID || Date.now()}`;
        const { promise, resolve } = this.createPermissionPromise(requestId);

        // Check bounds before adding permission request
        if (!this.canAddPendingPermission()) {
          if (onDenial) onDenial({ toolName, mcpServer: mcpServerName, reason: 'server_overloaded' });
          return {
            behavior: 'deny',
            message: 'Server overloaded with pending permission requests. Please try again.',
            interrupt: false
          };
        }

        const permissionRequest = {
          id: requestId,
          type: 'mcp',
          toolName,
          mcpServer: mcpServerName,
          mcpTool: mcpToolName,
          input,
          agentName: agent.name,
          agentPath: agent.path,
          timestamp: Date.now(),
          status: 'pending',
          resolve
        };

        this.pendingPermissions.set(requestId, permissionRequest);
        this.emit('permissionRequest', {
          ...permissionRequest,
          resolve: undefined
        });

        const timeoutMs = 120000;
        const decision = await Promise.race([
          promise,
          new Promise(r => setTimeout(() => r('timeout'), timeoutMs))
        ]);

        console.log(`[Orchestrator] MCP permission decision for ${requestId}: ${decision}`);
        this.pendingPermissions.delete(requestId);

        if (decision === 'granted' || decision === 'allow_session') {
          // If allow_session, remember for future calls in this session
          if (decision === 'allow_session') {
            approvedMcpsThisSession.add(mcpServerName);
            console.log(`[Orchestrator] MCP ${mcpServerName} approved for session`);
          }
          return { behavior: 'allow', updatedInput: input };
        } else if (decision === 'timeout') {
          if (onDenial) onDenial({ toolName, mcpServer: mcpServerName, reason: 'timeout' });
          return {
            behavior: 'deny',
            message: `MCP tool approval timed out.`,
            interrupt: false
          };
        } else {
          if (onDenial) onDenial({ toolName, mcpServer: mcpServerName, reason: 'denied' });
          return {
            behavior: 'deny',
            message: `MCP tool ${mcpToolName} denied by user.`,
            interrupt: false
          };
        }
      }

      // ─────────────────────────────────────────────────────────────────
      // TIER 2: Write tools - check against allowed paths
      // ─────────────────────────────────────────────────────────────────
      let filePath = input.file_path || input.path;

      // Convert absolute paths to relative paths for permission matching
      // SDK provides absolute paths but permissions use relative patterns
      if (filePath && filePath.startsWith(this.vaultPath)) {
        filePath = filePath.slice(this.vaultPath.length).replace(/^\//, '');
        console.log(`[Orchestrator] Converted to relative path: ${filePath}`);
      }

      // Check if this is a write operation (uses TIER2 tools)
      const isWriteOp = Orchestrator.TIER2_WRITE_TOOLS.includes(toolName);

      // For Bash, check if agent has unrestricted write permissions
      // If write: ['*'], auto-approve Bash. Otherwise request approval.
      if (toolName === 'Bash' && input.command) {
        const cmd = input.command;
        const writePatterns = agent.permissions?.write || ['*'];
        const hasFullWriteAccess = writePatterns.includes('*');

        if (hasFullWriteAccess) {
          // Agent has full write access, auto-approve Bash
          console.log(`[Orchestrator] Bash auto-approved (agent has write: ['*']): ${cmd}`);
          return { behavior: 'allow', updatedInput: input };
        }

        // Agent has restricted write access, request approval for Bash
        console.log(`[Orchestrator] Bash command requires approval: ${cmd}`);

        const requestId = `${sessionId}-${options.toolUseID}`;

        // Check bounds before adding permission request
        if (!this.canAddPendingPermission()) {
          if (onDenial) onDenial({ toolName: 'Bash', filePath: cmd, reason: 'server_overloaded' });
          return {
            behavior: 'deny',
            message: 'Server overloaded with pending permission requests. Please try again.',
            interrupt: false
          };
        }

        const { promise, resolve } = this.createPermissionPromise(requestId);

        const permissionRequest = {
          id: requestId,
          toolName: 'Bash',
          filePath: cmd,  // Use command as the "path" for display
          input,
          agentName: agent.name,
          agentPath: agent.path,
          allowedPatterns: writePatterns,
          timestamp: Date.now(),
          status: 'pending',
          resolve
        };

        this.pendingPermissions.set(requestId, permissionRequest);
        this.emit('permissionRequest', {
          ...permissionRequest,
          resolve: undefined
        });

        const timeoutMs = 120000;
        const decision = await Promise.race([
          promise,
          new Promise(r => setTimeout(() => r('timeout'), timeoutMs))
        ]);

        console.log(`[Orchestrator] Bash permission decision for ${requestId}: ${decision}`);

        // Clean up the permission request immediately after decision
        this.pendingPermissions.delete(requestId);

        if (decision === 'granted') {
          return { behavior: 'allow', updatedInput: input };
        } else if (decision === 'timeout') {
          if (onDenial) onDenial({ toolName: 'Bash', filePath: cmd, reason: 'timeout' });
          return {
            behavior: 'deny',
            message: `Bash command approval timed out.`,
            interrupt: false
          };
        } else {
          if (onDenial) onDenial({ toolName: 'Bash', filePath: cmd, reason: 'denied' });
          return {
            behavior: 'deny',
            message: `Bash command denied by user.`,
            interrupt: false
          };
        }
      }

      if (isWriteOp && filePath) {
        const writePatterns = agent.permissions?.write || ['*'];
        const isAllowed = matchesPatterns(filePath, writePatterns);

        if (!isAllowed) {
          console.log(`[Orchestrator] Permission check: ${toolName} to ${filePath} - needs approval`);

          // Create a permission request
          const requestId = `${sessionId}-${options.toolUseID}`;

          // Check bounds before adding permission request
          if (!this.canAddPendingPermission()) {
            if (onDenial) onDenial({ toolName, filePath, reason: 'server_overloaded' });
            return {
              behavior: 'deny',
              message: 'Server overloaded with pending permission requests. Please try again.',
              interrupt: false
            };
          }

          // Create a promise that will resolve when user responds
          const { promise, resolve } = this.createPermissionPromise(requestId);

          const permissionRequest = {
            id: requestId,
            toolName,
            filePath,
            input,
            agentName: agent.name,
            agentPath: agent.path,
            allowedPatterns: writePatterns,
            timestamp: Date.now(),
            status: 'pending',
            resolve  // Store resolver so grant/deny can call it
          };

          // Store the pending request
          this.pendingPermissions.set(requestId, permissionRequest);

          // Emit event for listeners (SSE, WebSocket, etc.)
          this.emit('permissionRequest', {
            ...permissionRequest,
            resolve: undefined  // Don't send the resolver
          });

          console.log(`[Orchestrator] Waiting for user approval on ${requestId}...`);

          // Wait for user decision (with timeout)
          const timeoutMs = 120000; // 2 minutes
          const decision = await Promise.race([
            promise,
            new Promise(r => setTimeout(() => r('timeout'), timeoutMs))
          ]);

          console.log(`[Orchestrator] Permission decision for ${requestId}: ${decision}`);

          // Clean up the permission request immediately after decision
          this.pendingPermissions.delete(requestId);

          if (decision === 'granted') {
            // User approved - allow the operation
            return {
              behavior: 'allow',
              updatedInput: input
            };
          } else if (decision === 'timeout') {
            // Track this denial
            if (onDenial) onDenial({ toolName, filePath, reason: 'timeout' });
            return {
              behavior: 'deny',
              message: `Permission request timed out after ${timeoutMs/1000} seconds. The user did not respond.`,
              interrupt: false
            };
          } else {
            // User denied or other - track this denial
            if (onDenial) onDenial({ toolName, filePath, reason: 'denied' });
            return {
              behavior: 'deny',
              message: `Write permission denied by user for "${filePath}".`,
              interrupt: false
            };
          }
        }

        console.log(`[Orchestrator] Permission check: ${toolName} to ${filePath} - ALLOWED by policy`);
      }

      // Allow the operation
      return {
        behavior: 'allow',
        updatedInput: input
      };
    };
  }

  /**
   * Create a promise that can be resolved externally (for permission requests)
   */
  createPermissionPromise(requestId) {
    let resolve;
    const promise = new Promise(r => { resolve = r; });
    return { promise, resolve };
  }

  /**
   * Grant a pending permission request (called from API when user approves)
   */
  grantPermission(requestId) {
    const request = this.pendingPermissions.get(requestId);
    if (request && request.status === 'pending') {
      request.status = 'granted';
      // Resolve the waiting promise
      if (request.resolve) {
        request.resolve('granted');
      }
      this.pendingPermissions.set(requestId, request);
      this.emit('permissionGranted', request);
      console.log(`[Orchestrator] Permission GRANTED: ${requestId}`);
      return true;
    }
    return false;
  }

  /**
   * Deny a pending permission request
   */
  denyPermission(requestId) {
    const request = this.pendingPermissions.get(requestId);
    if (request && request.status === 'pending') {
      request.status = 'denied';
      // Resolve the waiting promise
      if (request.resolve) {
        request.resolve('denied');
      }
      this.pendingPermissions.set(requestId, request);
      this.emit('permissionDenied', request);
      console.log(`[Orchestrator] Permission DENIED: ${requestId}`);
      return true;
    }
    return false;
  }

  /**
   * Get all pending permission requests
   */
  getPendingPermissions() {
    return Array.from(this.pendingPermissions.values())
      .filter(p => p.status === 'pending');
  }

  /**
   * Clean up stale permission requests (older than maxAge)
   * @param {number} maxAge - Maximum age in milliseconds (default 5 minutes)
   * @returns {number} Number of cleaned up requests
   */
  cleanupStalePermissions(maxAge = 5 * 60 * 1000) {
    const now = Date.now();
    let cleaned = 0;

    for (const [id, request] of this.pendingPermissions) {
      const age = now - request.timestamp;

      // Remove requests older than maxAge, or completed/denied requests older than 1 minute
      if (age > maxAge || (request.status !== 'pending' && age > 60000)) {
        this.pendingPermissions.delete(id);
        cleaned++;
      }
    }

    if (cleaned > 0) {
      console.log(`[Orchestrator] Cleaned up ${cleaned} stale permission requests`);
    }

    return cleaned;
  }

  /**
   * Start periodic permission cleanup
   */
  startPermissionCleanupLoop() {
    // Clean up every 2 minutes
    this.permissionCleanupInterval = setInterval(() => {
      this.cleanupStalePermissions();
    }, 2 * 60 * 1000);

    // Also run cleanup on startup (after 30 seconds)
    setTimeout(() => this.cleanupStalePermissions(), 30000);
  }

  /**
   * Initialize the orchestrator
   */
  async initialize() {
    // Load persisted queue
    await this.queue.load();

    // Initialize session manager
    await this.sessionManager.initialize();

    // Start processing loop
    this.startProcessingLoop();

    // Start document trigger loop
    this.startTriggerLoop();

    // Start session cleanup loop
    this.startSessionCleanupLoop();

    // Start permission cleanup loop (prevents memory leaks)
    this.startPermissionCleanupLoop();

    log.info('Initialized', { vaultPath: this.vaultPath });
  }

  /**
   * Enqueue an agent for execution
   *
   * @param {string} agentPath - Path to agent markdown file
   * @param {object} context - Execution context
   * @param {object} options - Queue options
   * @returns {Promise<string>} Queue item ID
   */
  async enqueue(agentPath, context = {}, options = {}) {
    // Check depth limit
    const depth = options.depth || 0;
    if (depth >= this.config.maxDepth) {
      throw new Error(`Max spawn depth (${this.config.maxDepth}) reached`);
    }

    // Load agent definition
    const agent = await loadAgent(agentPath, this.vaultPath);

    // Add to queue
    const item = this.queue.enqueue({
      agentPath,
      agent,
      context,
      priority: options.priority || Priority.NORMAL,
      depth,
      spawnedBy: options.spawnedBy || null,
      scheduledFor: options.scheduledFor || null
    });

    console.log(`[Orchestrator] Enqueued: ${agent.name} (${item.id})`);

    // Trigger processing
    this.processQueue();

    return item.id;
  }

  /**
   * Run an agent immediately (bypass queue)
   *
   * @param {string} agentPath - Path to agent or null for vault agent
   * @param {string} message - User message
   * @param {object} additionalContext - Extra context (documentPath for doc agents)
   * @returns {Promise<object>} Execution result
   */
  async runImmediate(agentPath, message, additionalContext = {}) {
    let agent;
    let systemPrompt;

    // Use built-in vault agent if path is null/undefined or explicitly "vault-agent"
    const useBuiltinVaultAgent = !agentPath || agentPath === 'vault-agent';

    if (!useBuiltinVaultAgent) {
      // Load specific agent from file
      agent = await loadAgent(agentPath, this.vaultPath);
      log.info('Loaded agent', {
        name: agent.name,
        path: agentPath,
        tools: agent.permissions?.tools || agent.tools
      });
      systemPrompt = buildSystemPrompt(agent, additionalContext);

      // Load context/knowledge if agent has context configuration
      if (agent.context && (agent.context.knowledge_file || agent.context.include)) {
        try {
          const contextResult = await loadAgentContext(agent.context, this.vaultPath, {
            max_tokens: agent.context.max_tokens
          });
          if (contextResult.content) {
            systemPrompt += formatContextForPrompt(contextResult);
            console.log(`[Orchestrator] Loaded ${contextResult.files.length} context files (~${contextResult.totalTokens} tokens)`);
          }
        } catch (e) {
          console.warn(`[Orchestrator] Failed to load context for ${agent.name}:`, e.message);
        }
      }
    } else {
      // Use default vault agent
      agent = this.createVaultAgent();
      systemPrompt = await this.buildVaultSystemPrompt(additionalContext);
    }

    // Determine agent type - default to chatbot for interactive use
    const agentType = agent.type || AgentType.CHATBOT;

    switch (agentType) {
      case AgentType.CHATBOT:
        // Use session-based execution for conversation continuity
        return this.executeChatbotAgent(agent, agentPath, message, systemPrompt, additionalContext);

      case AgentType.DOC:
        // Doc agents require a document - include document content in message
        if (additionalContext.documentPath) {
          const doc = await this.readDocument(additionalContext.documentPath);
          if (doc) {
            const docMessage = `Process this document: ${additionalContext.documentPath}\n\n---\n${doc.body}\n---\n\n${message || 'Process this document.'}`;
            return this.executeAgent(agent, docMessage, systemPrompt, 0);
          }
        }
        // Fall through if no document provided
        return this.executeAgent(agent, message, systemPrompt, 0);

      case AgentType.STANDALONE:
      default:
        // Standalone agents run independently
        return this.executeAgent(agent, message || 'Execute your primary function.', systemPrompt, 0);
    }
  }

  /**
   * Execute a chatbot agent with streaming (yields events for SSE)
   * This is a generator function that yields events as they happen.
   *
   * SIMPLIFIED: Uses SDK session ID as the only session identifier.
   * - If context.sessionId is provided, it's the SDK session ID to resume
   * - If not provided, this is a new session and we get SDK ID from response
   */
  async *executeChatbotAgentStreaming(agent, agentPath, message, systemPrompt, context) {
    const effectivePath = agentPath || 'vault-agent';

    // Get or create session using SDK session ID as primary key
    const { session, resumeInfo, isNew } = await this.sessionManager.getSession(
      context.sessionId, // SDK session ID if resuming, null if new
      effectivePath,
      {
        workingDirectory: context.workingDirectory,
        continuedFrom: context.continuedFrom
      }
    );

    // Determine the working directory for this session
    const effectiveCwd = session.workingDirectory || this.vaultPath;

    log.info('Streaming chat session', {
      sdkSessionId: session.sdkSessionId ? session.sdkSessionId.slice(0, 8) + '...' : 'pending',
      agentPath: effectivePath,
      cwd: effectiveCwd,
      isNew
    });

    // Yield session info (SDK session ID may be null for new sessions - will be updated after response)
    yield {
      type: 'session',
      sessionId: session.sdkSessionId, // Will be null for new sessions
      workingDirectory: session.workingDirectory || null,
      resumeInfo: resumeInfo.toJSON()
    };

    // Handle initial context for new sessions
    let actualMessage = message;
    if (context.initialContext && session.messages.length === 0) {
      if (!message || message.trim() === '') {
        actualMessage = context.initialContext;
        console.log(`[Orchestrator] Using initial context as message (${context.initialContext.length} chars)`);
      } else {
        actualMessage = `## Context\n\n${context.initialContext}\n\n---\n\n## Request\n\n${message}`;
        console.log(`[Orchestrator] Prepending initial context (${context.initialContext.length} chars)`);
      }
    }

    // Handle recovery mode (user chose how to proceed after session_unavailable)
    let forceNewSession = false;
    if (context.recoveryMode === 'inject_context' && session.messages.length > 0) {
      // User chose to continue with context injection from markdown history
      // Format prior messages like we do for imported conversations
      const priorContext = this.formatMessagesForContextInjection(session.messages);
      if (priorContext) {
        actualMessage = `## Prior Conversation\n\n${priorContext}\n\n---\n\n## Current Message\n\n${message}`;
        console.log(`[Orchestrator] Injecting ${session.messages.length} messages from markdown history`);
      }
      forceNewSession = true; // Don't try to resume, start fresh with injected context
      // Clear the old SDK session ID since we're starting fresh
      session.sdkSessionId = null;
    } else if (context.recoveryMode === 'fresh_start') {
      // User chose to start completely fresh
      console.log(`[Orchestrator] Fresh start - no context injection`);
      forceNewSession = true;
      session.sdkSessionId = null;
      session.messages = []; // Clear message history for fresh start
    }

    const startTime = Date.now();
    let result = '';
    const textBlocks = [];
    let toolCalls = [];
    const requestPermissionDenials = [];

    try {
      const agentTools = agent.permissions?.tools || agent.tools || [];

      // Load global MCP servers and resolve agent references
      const globalMcpServers = await loadMcpServers(this.vaultPath);
      const resolvedMcpServers = resolveMcpServers(agent.mcpServers, globalMcpServers);

      const queryOptions = {
        systemPrompt,
        cwd: effectiveCwd,
        permissionMode: 'default',
        canUseTool: this.createPermissionHandler(agent, session.sdkSessionId || 'new', (denial) => {
          requestPermissionDenials.push(denial);
        }),
        tools: agentTools.length > 0 ? agentTools : undefined,
        settingSources: ['project'],
        mcpServers: resolvedMcpServers
      };

      // SIMPLIFIED: If we have an SDK session ID, just pass resume option
      // The SDK handles all context rebuilding from its own storage
      if (session.sdkSessionId && !forceNewSession) {
        queryOptions.resume = session.sdkSessionId;
        console.log(`[Orchestrator] Resuming SDK session: ${session.sdkSessionId.slice(0, 8)}...`);
      } else {
        console.log(`[Orchestrator] Starting new SDK session${forceNewSession ? ' (recovery mode)' : ''}`);
      }

      console.log(`[Orchestrator] Streaming query for ${agent.name}`);
      if (resolvedMcpServers && Object.keys(resolvedMcpServers).length > 0) {
        console.log(`[Orchestrator] MCP servers for ${agent.name}:`, Object.keys(resolvedMcpServers));
      }

      const response = query({
        prompt: actualMessage,
        options: queryOptions
      });

      let capturedSessionId = null;
      let currentText = '';
      let lastTextBlockIndex = -1; // Track which text block we're updating

      for await (const msg of response) {
        // Debug: log all message types to understand SDK output
        if (msg.type === 'user') {
          const contentTypes = msg.message?.content?.map(c => c.type) || [];
          console.log(`[Orchestrator] SDK user msg:`, JSON.stringify({
            hasMessage: !!msg.message,
            contentTypes,
            parentToolUseId: msg.parent_tool_use_id,
            keys: Object.keys(msg)
          }));
        } else if (msg.type !== 'assistant') {
          console.log(`[Orchestrator] SDK msg type=${msg.type} subtype=${msg.subtype}`);
        }

        if (msg.session_id) {
          capturedSessionId = msg.session_id;
        }

        if (msg.type === 'system' && msg.subtype === 'init') {
          yield {
            type: 'init',
            tools: msg.tools || [],
            permissionMode: msg.permissionMode
          };
        }

        if (msg.type === 'assistant' && msg.message?.content) {
          for (const block of msg.message.content) {
            // Handle thinking blocks (extended thinking / chain of thought)
            if (block.type === 'thinking') {
              yield {
                type: 'thinking',
                content: block.thinking
              };
              // Thinking is NOT included in the final result text
            }
            // Handle regular text output
            else if (block.type === 'text') {
              const newText = block.text;
              if (newText !== currentText) {
                yield {
                  type: 'text',
                  content: newText,
                  delta: newText.slice(currentText.length)
                };
                currentText = newText;
                // In streaming, block.text is the FULL accumulated text, not a delta
                // So we update/replace the current text block, not push a new one
                if (lastTextBlockIndex === -1 || textBlocks.length === 0) {
                  textBlocks.push(newText);
                  lastTextBlockIndex = 0;
                } else {
                  textBlocks[lastTextBlockIndex] = newText;
                }
                result = textBlocks.join('\n\n');
              }
            }
            // Handle tool use
            else if (block.type === 'tool_use') {
              const toolCall = {
                id: block.id,
                name: block.name,
                input: block.input
              };
              toolCalls.push(toolCall);
              yield {
                type: 'tool_use',
                tool: toolCall
              };
              // Reset for next text block (after tool result)
              currentText = '';
              lastTextBlockIndex = -1;
            }
          }
        } else if (msg.type === 'user' && msg.message?.content) {
          // Tool results come inside user messages as tool_result blocks in message.content
          // Format: { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id, content }] } }
          for (const block of msg.message.content) {
            if (block.type === 'tool_result') {
              const toolUseId = block.tool_use_id;
              console.log(`[Orchestrator] Tool result received for ${toolUseId}:`,
                typeof block.content === 'string'
                  ? block.content.substring(0, 100) + '...'
                  : JSON.stringify(block.content).substring(0, 200));

              // Format the result content
              let resultContent;
              if (typeof block.content === 'string') {
                resultContent = block.content;
              } else if (Array.isArray(block.content)) {
                // Content array like [{ type: 'text', text: '...' }]
                resultContent = block.content
                  .map(c => c.text || c.toString())
                  .join('\n');
              } else if (block.content) {
                resultContent = JSON.stringify(block.content, null, 2);
              } else {
                resultContent = '';
              }

              console.log(`[Orchestrator] Yielding tool_result for ${toolUseId}, content length: ${resultContent.length}`);
              yield {
                type: 'tool_result',
                toolUseId: toolUseId,
                content: resultContent,
                isError: block.is_error || false
              };
            }
          }
        } else if (msg.type === 'result') {
          if (msg.result) {
            result = msg.result;
            yield {
              type: 'text',
              content: result,
              delta: result.slice(currentText.length)
            };
          }
          if (msg.session_id) {
            capturedSessionId = msg.session_id;
          }
        }
      }

      // For new sessions, finalize with the SDK session ID we captured
      if (isNew && capturedSessionId) {
        await this.sessionManager.finalizeSession(session, capturedSessionId);
        console.log(`[Orchestrator] Finalized new session: ${capturedSessionId.slice(0, 8)}...`);
      }

      // Add messages to our markdown mirror (for human readability)
      console.log(`[Orchestrator] Saving to markdown: user msg=${actualMessage.length} chars, assistant result=${result.length} chars`);
      console.log(`[Orchestrator] textBlocks count=${textBlocks.length}, first 200 chars of result:`, result.substring(0, 200));
      await this.sessionManager.addMessage(session, 'user', actualMessage);
      await this.sessionManager.addMessage(session, 'assistant', result);

      // Generate title asynchronously
      const agentName = agent.name || effectivePath.replace('agents/', '').replace('.md', '');
      this.sessionManager.maybeGenerateTitle(session, agentName).catch(err => {
        console.error(`[Orchestrator] Title generation error:`, err.message);
      });

      const spawnRequests = this.parseSpawnRequests(result, agent, 0);

      for (const spawn of spawnRequests) {
        if (this.config.maxDepth > 1) {
          await this.enqueue(spawn.agent, {
            userMessage: spawn.message,
            parentContext: { parentAgent: agent.name, parentResult: result }
          }, {
            depth: 1,
            priority: spawn.priority || Priority.NORMAL
          });
        }
      }

      const duration = Date.now() - startTime;

      // Clean up pending permissions
      if (session.sdkSessionId) {
        for (const [key, _] of this.pendingPermissions) {
          if (key.startsWith(session.sdkSessionId)) {
            this.pendingPermissions.delete(key);
          }
        }
      }

      // Yield final completion event - now includes the SDK session ID for the app to store
      yield {
        type: 'done',
        response: result,
        spawned: spawnRequests.map(s => s.agent),
        durationMs: duration,
        sessionId: session.sdkSessionId, // THE session ID for future requests
        workingDirectory: session.workingDirectory || null,
        messageCount: session.messages.length,
        toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
        permissionDenials: requestPermissionDenials.length > 0 ? requestPermissionDenials : undefined,
        sessionResume: resumeInfo.toJSON()
      };

    } catch (error) {
      // Check if this is a session-not-found error (SDK can't find the JSONL file)
      const isSessionNotFound = error.message?.includes('ENOENT') ||
                                 error.message?.includes('no such file') ||
                                 error.message?.includes('session') && error.message?.includes('not found');

      if (isSessionNotFound && session.sdkSessionId) {
        log.warn('SDK session not found', {
          sdkSessionId: session.sdkSessionId.slice(0, 8) + '...',
          error: error.message
        });

        // Check if we have markdown history we could use for recovery
        const hasMarkdownHistory = session.messages && session.messages.length > 0;

        yield {
          type: 'session_unavailable',
          reason: 'sdk_session_not_found',
          sessionId: session.sdkSessionId,
          hasMarkdownHistory,
          messageCount: session.messages?.length || 0,
          message: 'The conversation history could not be loaded from the SDK. ' +
                   (hasMarkdownHistory
                     ? 'You can continue with context from saved history, or start fresh.'
                     : 'You can start a new conversation.')
        };
        return; // Don't yield error, let client handle recovery choice
      }

      log.error('Streaming error', { agentPath: effectivePath, error: error.message });

      yield {
        type: 'error',
        error: error.message,
        sessionId: session.sdkSessionId
      };
    }
  }

  /**
   * Execute a chatbot agent with session continuity
   *
   * SIMPLIFIED: Uses SDK session ID as the only session identifier.
   */
  async executeChatbotAgent(agent, agentPath, message, systemPrompt, context) {
    const effectivePath = agentPath || 'vault-agent';

    // Get or create session using SDK session ID as primary key
    const { session, resumeInfo, isNew } = await this.sessionManager.getSession(
      context.sessionId, // SDK session ID if resuming, null if new
      effectivePath,
      {
        workingDirectory: context.workingDirectory,
        continuedFrom: context.continuedFrom
      }
    );

    const effectiveCwd = session.workingDirectory || this.vaultPath;

    log.info('Chat session', {
      sdkSessionId: session.sdkSessionId ? session.sdkSessionId.slice(0, 8) + '...' : 'pending',
      agentPath: effectivePath,
      cwd: effectiveCwd,
      isNew
    });

    // Handle initial context for new sessions
    let actualMessage = message;
    if (context.initialContext && session.messages.length === 0) {
      if (!message || message.trim() === '') {
        actualMessage = context.initialContext;
        console.log(`[Orchestrator] Using initial context as message (${context.initialContext.length} chars)`);
      } else {
        actualMessage = `## Context\n\n${context.initialContext}\n\n---\n\n## Request\n\n${message}`;
        console.log(`[Orchestrator] Prepending initial context (${context.initialContext.length} chars)`);
      }
    }

    const startTime = Date.now();
    let result = '';
    const textBlocks = [];
    let spawnRequests = [];
    let toolCalls = [];
    const requestPermissionDenials = [];

    try {
      const agentTools = agent.permissions?.tools || agent.tools || [];

      // Load global MCP servers and resolve agent references
      const globalMcpServers = await loadMcpServers(this.vaultPath);
      const resolvedMcpServers = resolveMcpServers(agent.mcpServers, globalMcpServers);

      const queryOptions = {
        systemPrompt,
        cwd: effectiveCwd,
        permissionMode: 'default',
        canUseTool: this.createPermissionHandler(agent, session.sdkSessionId || 'new', (denial) => {
          requestPermissionDenials.push(denial);
        }),
        tools: agentTools.length > 0 ? agentTools : undefined,
        settingSources: ['project'],
        mcpServers: resolvedMcpServers
      };

      // SIMPLIFIED: If we have an SDK session ID, just pass resume option
      // The SDK handles all context rebuilding from its own storage
      if (session.sdkSessionId) {
        queryOptions.resume = session.sdkSessionId;
        console.log(`[Orchestrator] Resuming SDK session: ${session.sdkSessionId.slice(0, 8)}...`);
      } else {
        console.log(`[Orchestrator] Starting new SDK session`);
      }

      if (agentTools.length > 0) {
        console.log(`[Orchestrator] Tools for ${agent.name}: ${agentTools.join(', ')}`);
      }

      if (resolvedMcpServers) {
        console.log(`[Orchestrator] MCP servers for ${agent.name}: ${Object.keys(resolvedMcpServers).join(', ')}`);
      }

      // Execute via Claude Agent SDK
      const response = query({
        prompt: actualMessage,
        options: queryOptions
      });

      let capturedSessionId = null;

      for await (const msg of response) {
        if (msg.session_id) {
          capturedSessionId = msg.session_id;
        }

        if (msg.type === 'system' && msg.subtype === 'init') {
          console.log(`[Orchestrator] SDK initialized with tools: ${msg.tools?.join(', ') || 'none'}`);
        }

        if (msg.type === 'assistant' && msg.message?.content) {
          for (const block of msg.message.content) {
            if (block.type === 'text') {
              textBlocks.push(block.text);
              result = textBlocks.join('\n\n');
            }
            if (block.type === 'tool_use') {
              toolCalls.push({ name: block.name, input: block.input });
            }
          }
        } else if (msg.type === 'result') {
          if (msg.result) result = msg.result;
          if (msg.session_id) capturedSessionId = msg.session_id;
        }
      }

      // For new sessions, finalize with the SDK session ID we captured
      if (isNew && capturedSessionId) {
        await this.sessionManager.finalizeSession(session, capturedSessionId);
        console.log(`[Orchestrator] Finalized new session: ${capturedSessionId.slice(0, 8)}...`);
      }

      // Add messages to our markdown mirror
      await this.sessionManager.addMessage(session, 'user', actualMessage);
      await this.sessionManager.addMessage(session, 'assistant', result);

      // Generate title asynchronously
      const agentName = agent.name || effectivePath.replace('agents/', '').replace('.md', '');
      this.sessionManager.maybeGenerateTitle(session, agentName).catch(err => {
        console.error(`[Orchestrator] Title generation error:`, err.message);
      });

      spawnRequests = this.parseSpawnRequests(result, agent, 0);

      for (const spawn of spawnRequests) {
        if (this.config.maxDepth > 1) {
          await this.enqueue(spawn.agent, {
            userMessage: spawn.message,
            parentContext: { parentAgent: agent.name, parentResult: result }
          }, {
            depth: 1,
            priority: spawn.priority || Priority.NORMAL
          });
        }
      }

      const duration = Date.now() - startTime;
      log.info('Chat completed', {
        agentPath: effectivePath,
        durationMs: duration,
        toolCalls: toolCalls.length
      });

      // Clean up pending permissions
      if (session.sdkSessionId) {
        for (const [key, _] of this.pendingPermissions) {
          if (key.startsWith(session.sdkSessionId)) {
            this.pendingPermissions.delete(key);
          }
        }
      }

      return {
        success: true,
        response: result,
        spawned: spawnRequests.map(s => s.agent),
        durationMs: duration,
        sessionId: session.sdkSessionId, // THE session ID for future requests
        workingDirectory: session.workingDirectory || null,
        messageCount: session.messages.length,
        toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
        permissionDenials: requestPermissionDenials.length > 0 ? requestPermissionDenials : undefined,
        sessionResume: resumeInfo.toJSON()
      };

    } catch (error) {
      log.error('Chat error', {
        agentPath: effectivePath,
        error: error.message,
        stack: error.stack
      });

      return {
        success: false,
        error: error.message,
        response: '',
        spawned: [],
        durationMs: Date.now() - startTime,
        sessionId: session.sdkSessionId
      };
    }
  }

  /**
   * Delete a chat session by SDK session ID
   */
  async deleteChatSession(sdkSessionId) {
    return this.sessionManager.deleteSession(sdkSessionId);
  }

  /**
   * List all chat sessions
   */
  listChatSessions() {
    return this.sessionManager.listSessions();
  }

  /**
   * Get a specific session by SDK session ID
   */
  async getSessionById(sdkSessionId) {
    return this.sessionManager.getSessionById(sdkSessionId);
  }

  /**
   * Archive a session by SDK session ID
   */
  async archiveSession(sdkSessionId) {
    return this.sessionManager.archiveSession(sdkSessionId);
  }

  /**
   * Unarchive a session by SDK session ID
   */
  async unarchiveSession(sdkSessionId) {
    return this.sessionManager.unarchiveSession(sdkSessionId);
  }

  /**
   * Delete a session by SDK session ID
   */
  async deleteSessionById(sdkSessionId) {
    return this.sessionManager.deleteSession(sdkSessionId);
  }

  /**
   * Get session manager stats for debugging
   */
  getSessionStats() {
    return this.sessionManager.getStats();
  }

  /**
   * Reload the session index from disk
   * Call this when session files have been modified externally
   */
  async reloadSessionIndex() {
    return this.sessionManager.reloadSessionIndex();
  }

  // ============================================================================
  // MCP SERVER MANAGEMENT
  // ============================================================================

  /**
   * List all configured MCP servers
   */
  async listMcpServers() {
    return listMcpServers(this.vaultPath);
  }

  /**
   * Add or update an MCP server
   */
  async addMcpServer(name, config) {
    return addMcpServer(this.vaultPath, name, config);
  }

  /**
   * Remove an MCP server
   */
  async removeMcpServer(name) {
    return removeMcpServer(this.vaultPath, name);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Skills Management
  // ─────────────────────────────────────────────────────────────────────────

  /**
   * List all available skills in the vault
   * Skills are discovered from .claude/skills/ directory
   */
  async listSkills() {
    return discoverSkills(this.vaultPath);
  }

  /**
   * Get full content of a specific skill
   * @param {string} skillName - Name of the skill directory
   */
  async getSkill(skillName) {
    return loadSkill(this.vaultPath, skillName);
  }

  /**
   * Create a new skill
   * @param {string} skillName - Directory name for the skill
   * @param {object} skillData - { name, description, content, allowedTools? }
   */
  async createSkill(skillName, skillData) {
    return createSkill(this.vaultPath, skillName, skillData);
  }

  /**
   * Delete a skill
   * @param {string} skillName - Name of the skill directory to delete
   */
  async deleteSkill(skillName) {
    return deleteSkill(this.vaultPath, skillName);
  }

  /**
   * Ensure skills directory exists
   */
  async ensureSkillsDir() {
    return ensureSkillsDir(this.vaultPath);
  }

  /**
   * Run an agent with streaming (yields SSE events)
   * Use this for real-time UI updates
   */
  async *runImmediateStreaming(agentPath, message, additionalContext = {}) {
    let agent;
    let systemPrompt;

    // Use built-in vault agent if path is null/undefined or explicitly "vault-agent"
    const useBuiltinVaultAgent = !agentPath || agentPath === 'vault-agent';

    if (!useBuiltinVaultAgent) {
      // Load specific agent from file
      agent = await loadAgent(agentPath, this.vaultPath);
      console.log(`[Orchestrator] Streaming agent: ${agent.name} from ${agentPath}`);
      systemPrompt = buildSystemPrompt(agent, additionalContext);

      if (agent.context && (agent.context.knowledge_file || agent.context.include)) {
        try {
          const contextResult = await loadAgentContext(agent.context, this.vaultPath, {
            max_tokens: agent.context.max_tokens
          });
          if (contextResult.content) {
            systemPrompt += formatContextForPrompt(contextResult);
          }
        } catch (e) {
          console.warn(`[Orchestrator] Failed to load context for ${agent.name}:`, e.message);
        }
      }
    } else {
      agent = this.createVaultAgent();
      systemPrompt = await this.buildVaultSystemPrompt(additionalContext);
    }

    const agentType = agent.type || AgentType.CHATBOT;

    // Use streaming execution for chatbot and doc agents
    // Standalone agents may have different requirements
    if (agentType === AgentType.CHATBOT || agentType === AgentType.DOC) {
      yield* this.executeChatbotAgentStreaming(agent, agentPath, message, systemPrompt, additionalContext);
    } else {
      // For other agent types (e.g., standalone), fall back to non-streaming execution
      const result = await this.runImmediate(agentPath, message, additionalContext);
      yield {
        type: 'done',
        ...result
      };
    }
  }

  /**
   * Create a default vault agent for general queries
   */
  createVaultAgent() {
    // Full tool set - let the permission handler gate dangerous operations
    // Claude Code tools: https://docs.anthropic.com/en/docs/claude-code
    const fullToolSet = [
      // File operations
      'Read', 'Write', 'Edit', 'MultiEdit',
      // Search & navigation
      'Glob', 'Grep', 'LS',
      // Execution
      'Bash', 'Task',
      // Notebook support
      'NotebookRead', 'NotebookEdit',
      // Web access
      'WebSearch', 'WebFetch',
      // Skills (custom vault extensions)
      'Skill'
    ];

    return {
      name: 'vault-agent',
      description: 'General vault assistant',
      model: 'sonnet',
      tools: fullToolSet,
      // Load all MCP servers from .mcp.json by default
      mcpServers: 'all',
      // Load general context by default (user can configure additional contexts)
      // Other context files in Chat/contexts/ are available for the agent to read on-demand
      context: {
        include: ['Chat/contexts/general-context.md'],
        max_tokens: 10000
      },
      permissions: {
        read: ['*'],
        write: ['*'],
        spawn: ['agents/*'],
        tools: fullToolSet
      },
      constraints: {
        max_spawns: 3,
        timeout: 300
      },
      spawns: [],
      systemPrompt: ''
    };
  }

  /**
   * Load AGENTS.md from vault root if it exists
   * @returns {Promise<string|null>} Content of AGENTS.md or null
   */
  async loadAgentsMd() {
    const agentsMdPath = path.join(this.vaultPath, 'AGENTS.md');
    try {
      const content = await fs.readFile(agentsMdPath, 'utf-8');
      log.info('Loaded AGENTS.md', { path: agentsMdPath, length: content.length });
      return content;
    } catch (e) {
      if (e.code === 'ENOENT') {
        log.debug('No AGENTS.md found', { path: agentsMdPath });
        return null;
      }
      log.error('Error loading AGENTS.md', { error: e.message });
      return null;
    }
  }

  /**
   * Build system prompt for vault agent
   * Uses AGENTS.md if present, otherwise falls back to default prompt
   * Also loads context files from Chat/contexts/ folder
   */
  async buildVaultSystemPrompt(context = {}) {
    // Try to load AGENTS.md first - this is the preferred source
    const agentsMd = await this.loadAgentsMd();

    let prompt;
    if (agentsMd) {
      // AGENTS.md is the system prompt
      prompt = agentsMd;
    } else {
      // Fallback: default prompt when no AGENTS.md exists
      prompt = await this.buildDefaultVaultPrompt(context);
    }

    // Determine which context files to load
    // If context.contexts is provided, use those
    // Otherwise, fall back to default (Chat/contexts/general-context.md)
    let contextPaths = context.contexts;
    if (!contextPaths || contextPaths.length === 0) {
      // Default: load general-context.md from Chat module
      contextPaths = ['Chat/contexts/general-context.md'];
    }

    // Load specified context files
    try {
      const contextConfig = {
        include: contextPaths,
        max_tokens: 50000
      };
      const contextResult = await loadAgentContext(contextConfig, this.vaultPath, {
        max_tokens: contextConfig.max_tokens
      });
      if (contextResult.content && contextResult.files.length > 0) {
        prompt += formatContextForPrompt(contextResult);
        log.info('Loaded vault context', {
          files: contextResult.files,
          tokens: contextResult.totalTokens,
          requested: contextPaths
        });
      }
    } catch (e) {
      log.warn('Failed to load vault context', { error: e.message, requested: contextPaths });
    }

    // Add vault location for context
    prompt += `\n\n---\n\n## Environment\n\nVault location: ${this.vaultPath}`;

    // Add prior conversation context if provided (for continued conversations)
    if (context.priorConversation) {
      prompt += `\n\n---\n\n## Prior Conversation (IMPORTANT)

**The user is continuing a previous conversation they had with you (or another AI assistant).**
The messages below are from that earlier session. Treat them as if they happened in THIS conversation -
the user said what "Human:" shows, and you (or a previous assistant) responded with what "Assistant:" shows.

When the user asks about "what we discussed" or "what I said", refer to this prior conversation as your shared history.

<prior_conversation>
${context.priorConversation}
</prior_conversation>

The user is now continuing this conversation with you. Respond naturally as if you remember the above exchange.`;
      log.info('Added prior conversation to system prompt', {
        length: context.priorConversation.length
      });
    }

    return prompt;
  }

  /**
   * Build default vault prompt (fallback when no AGENTS.md)
   *
   * Uses the built-in Parachute default prompt constant.
   * Users can override this entirely by creating AGENTS.md in their vault.
   */
  async buildDefaultVaultPrompt(context = {}) {
    let prompt = PARACHUTE_DEFAULT_PROMPT;

    // Add specialized agents if any exist
    const agents = await loadAllAgents(this.vaultPath);
    if (agents.length > 0) {
      prompt += `\n\n## Specialized Agents Available\n\nYou can suggest these agents for specific tasks:\n${agents.map(a => `- ${a.path}: ${a.description || a.name}`).join('\n')}`;
    }

    return prompt;
  }

  /**
   * Execute an agent
   *
   * @param {AgentDefinition} agent
   * @param {string} message
   * @param {string} systemPrompt
   * @param {number} depth
   * @returns {Promise<object>}
   */
  async executeAgent(agent, message, systemPrompt, depth) {
    console.log(`[Orchestrator] Executing: ${agent.name} (depth: ${depth})`);

    const startTime = Date.now();
    let result = '';
    const textBlocks = [];  // Accumulate text across multiple assistant messages
    let spawnRequests = [];

    try {
      // Build query options
      const queryOptions = {
        systemPrompt,
        cwd: this.vaultPath,
        allowedTools: agent.permissions?.tools || agent.tools,
        permissionMode: 'acceptEdits'
      };

      // Pass model if specified in agent definition
      if (agent.model) {
        queryOptions.model = agent.model;
      }

      // Execute via Claude Agent SDK
      const response = query({
        prompt: message,
        options: queryOptions
      });

      // Collect response
      for await (const msg of response) {
        if (msg.type === 'assistant' && msg.message?.content) {
          for (const block of msg.message.content) {
            if (block.type === 'text') {
              // Accumulate text blocks (each assistant text message is a separate block)
              textBlocks.push(block.text);
              result = textBlocks.join('\n\n');
            }
          }
        } else if (msg.type === 'result') {
          if (msg.result) {
            result = msg.result;
          }
        }
      }

      // Parse spawn requests from response
      spawnRequests = this.parseSpawnRequests(result, agent, depth);

      // Process spawn requests
      for (const spawn of spawnRequests) {
        if (depth + 1 < this.config.maxDepth) {
          await this.enqueue(spawn.agent, {
            userMessage: spawn.message,
            parentContext: { parentAgent: agent.name, parentResult: result }
          }, {
            depth: depth + 1,
            priority: spawn.priority || Priority.NORMAL
          });
        } else {
          console.warn(`[Orchestrator] Spawn blocked: max depth reached`);
        }
      }

      const duration = Date.now() - startTime;
      console.log(`[Orchestrator] Completed: ${agent.name} in ${duration}ms`);

      return {
        success: true,
        response: result,
        spawned: spawnRequests.map(s => s.agent),
        durationMs: duration
      };

    } catch (error) {
      console.error(`[Orchestrator] Error executing ${agent.name}:`, error);

      return {
        success: false,
        error: error.message,
        response: '',
        spawned: [],
        durationMs: Date.now() - startTime
      };
    }
  }

  /**
   * Parse spawn requests from agent response
   *
   * @param {string} response
   * @param {AgentDefinition} agent
   * @param {number} depth
   * @returns {SpawnRequest[]}
   */
  parseSpawnRequests(response, agent, depth) {
    const requests = [];
    const spawnRegex = /```spawn\n([\s\S]*?)```/g;

    let match;
    while ((match = spawnRegex.exec(response)) !== null) {
      try {
        const spawnData = JSON.parse(match[1].trim());

        // Validate spawn permission
        if (!hasPermission(agent, 'spawn', spawnData.agent)) {
          console.warn(`[Orchestrator] Spawn denied: ${agent.name} cannot spawn ${spawnData.agent}`);
          continue;
        }

        requests.push({
          agent: spawnData.agent,
          message: spawnData.message || 'Execute your primary function',
          priority: spawnData.priority || Priority.NORMAL,
          context: spawnData.context || {}
        });

      } catch (e) {
        console.warn('[Orchestrator] Failed to parse spawn request:', e.message);
      }
    }

    return requests;
  }

  /**
   * Process the queue
   */
  async processQueue() {
    if (this.isProcessing) return;
    if (this.running.size >= this.config.maxConcurrent) return;
    if (!this.queue.hasPending()) return;

    this.isProcessing = true;

    try {
      while (
        this.running.size < this.config.maxConcurrent &&
        this.queue.hasPending()
      ) {
        const item = this.queue.getNext();
        if (!item) break;

        // Mark as running
        this.queue.markRunning(item.id);
        this.running.set(item.id, item);

        // Execute (don't await - allow concurrent processing)
        this.executeQueueItem(item).finally(() => {
          this.running.delete(item.id);
          // Trigger next processing
          setTimeout(() => this.processQueue(), 100);
        });
      }
    } finally {
      this.isProcessing = false;
    }
  }

  /**
   * Get or create an event emitter for streaming a queue item's execution
   * @param {string} itemId - The queue item ID
   * @returns {EventEmitter} - The event emitter for this queue item
   */
  getQueueStream(itemId) {
    if (!this.queueStreams.has(itemId)) {
      // Check bounds before adding new stream
      if (!this.canAddQueueStream()) {
        return null; // Caller should handle null gracefully
      }
      this.queueStreams.set(itemId, new EventEmitter());
    }
    return this.queueStreams.get(itemId);
  }

  /**
   * Emit an event for a queue item (used during execution)
   * @param {string} itemId - The queue item ID
   * @param {string} type - Event type (text, tool_use, done, error)
   * @param {object} data - Event data
   */
  emitQueueEvent(itemId, type, data) {
    const stream = this.queueStreams.get(itemId);
    if (stream) {
      stream.emit('event', { type, ...data });
    }
  }

  /**
   * Clean up event emitter for a queue item
   * @param {string} itemId - The queue item ID
   */
  cleanupQueueStream(itemId) {
    const stream = this.queueStreams.get(itemId);
    if (stream) {
      stream.emit('event', { type: 'close' });
      stream.removeAllListeners();
      this.queueStreams.delete(itemId);
    }
  }

  /**
   * Execute a queue item with streaming events
   */
  async executeQueueItem(item) {
    const { agent, context, depth } = item;

    // Create event stream for this queue item
    this.getQueueStream(item.id);

    try {
      let systemPrompt = buildSystemPrompt(agent, context);

      // Emit init event
      this.emitQueueEvent(item.id, 'init', {
        agentName: agent.name,
        agentPath: item.agentPath,
        documentPath: context.documentPath
      });

      // Load context/knowledge if agent has context configuration
      if (agent.context && (agent.context.knowledge_file || agent.context.include)) {
        try {
          const contextResult = await loadAgentContext(agent.context, this.vaultPath, {
            max_tokens: agent.context.max_tokens
          });
          if (contextResult.content) {
            systemPrompt += formatContextForPrompt(contextResult);
            console.log(`[Orchestrator] Loaded ${contextResult.files.length} context files for ${agent.name}`);
          }
        } catch (e) {
          console.warn(`[Orchestrator] Failed to load context for ${agent.name}:`, e.message);
        }
      }

      let message = context.userMessage || 'Execute your primary function.';

      // Handle doc agents - include document content in message
      const agentType = agent.type || AgentType.STANDALONE;
      if (agentType === AgentType.DOC && context.documentPath) {
        const doc = await this.readDocument(context.documentPath);
        if (doc) {
          message = `Process this document: ${context.documentPath}\n\n---\n${doc.body}\n---\n\n${message}`;
          console.log(`[Orchestrator] Doc agent processing: ${context.documentPath}`);
        }
      }

      // Execute with streaming events
      const result = await this.executeAgentWithEvents(agent, message, systemPrompt, depth, item.id);

      if (result.success) {
        this.queue.markCompleted(item.id, result);
        // Save as markdown log
        await this.saveAgentLog(item, result);
        this.emitQueueEvent(item.id, 'done', result);
      } else {
        this.queue.markFailed(item.id, result.error);
        this.emitQueueEvent(item.id, 'error', { error: result.error });
      }

      // Cleanup stream after a short delay to allow final events to be read
      setTimeout(() => this.cleanupQueueStream(item.id), 5000);

      return result;

    } catch (error) {
      this.queue.markFailed(item.id, error);
      this.emitQueueEvent(item.id, 'error', { error: error.message });
      setTimeout(() => this.cleanupQueueStream(item.id), 5000);
      throw error;
    }
  }

  /**
   * Execute an agent with streaming events for queue watching
   *
   * @param {AgentDefinition} agent
   * @param {string} message
   * @param {string} systemPrompt
   * @param {number} depth
   * @param {string} queueItemId - The queue item ID for event emission
   * @returns {Promise<object>}
   */
  async executeAgentWithEvents(agent, message, systemPrompt, depth, queueItemId) {
    console.log(`[Orchestrator] Executing with events: ${agent.name} (depth: ${depth})`);

    const startTime = Date.now();
    let result = '';
    const textBlocks = [];  // Accumulate text across multiple assistant messages
    let spawnRequests = [];
    let currentText = '';
    let toolCalls = [];

    try {
      // Load global MCP servers and resolve agent references
      const globalMcpServers = await loadMcpServers(this.vaultPath);
      const resolvedMcpServers = resolveMcpServers(agent.mcpServers, globalMcpServers);

      if (resolvedMcpServers && Object.keys(resolvedMcpServers).length > 0) {
        console.log(`[Orchestrator] Resolved MCP servers for ${agent.name}:`, Object.keys(resolvedMcpServers));
      }

      // Build query options
      const queryOptions = {
        systemPrompt,
        cwd: this.vaultPath,
        allowedTools: agent.permissions?.tools || agent.tools,
        permissionMode: 'acceptEdits',
        // Enable skills from the vault's .claude/skills directory
        settingSources: ['project'],
        // MCP servers (resolved from .mcp.json or inline)
        mcpServers: resolvedMcpServers
      };

      // Pass model if specified in agent definition
      if (agent.model) {
        queryOptions.model = agent.model;
      }

      // Execute via Claude Agent SDK
      const response = query({
        prompt: message,
        options: queryOptions
      });

      // Collect response with event emission
      for await (const msg of response) {
        if (msg.type === 'assistant' && msg.message?.content) {
          for (const block of msg.message.content) {
            if (block.type === 'text') {
              const newText = block.text;
              if (newText !== currentText) {
                this.emitQueueEvent(queueItemId, 'text', {
                  content: newText,
                  delta: newText.slice(currentText.length)
                });
                currentText = newText;
                // Accumulate text blocks (each assistant text message is a separate block)
                textBlocks.push(newText);
                result = textBlocks.join('\n\n');
              }
            }
            if (block.type === 'tool_use') {
              const toolCall = {
                id: block.id,
                name: block.name,
                input: block.input
              };
              toolCalls.push(toolCall);
              this.emitQueueEvent(queueItemId, 'tool_use', { tool: toolCall });
            }
          }
        } else if (msg.type === 'result') {
          if (msg.result) {
            result = msg.result;
            if (result !== currentText) {
              this.emitQueueEvent(queueItemId, 'text', {
                content: result,
                delta: result.slice(currentText.length)
              });
            }
          }
        }
      }

      // Parse spawn requests from response
      spawnRequests = this.parseSpawnRequests(result, agent, depth);

      // Process spawn requests
      for (const spawn of spawnRequests) {
        if (depth + 1 < this.config.maxDepth) {
          await this.enqueue(spawn.agent, {
            userMessage: spawn.message,
            parentContext: { parentAgent: agent.name, parentResult: result }
          }, {
            depth: depth + 1,
            priority: spawn.priority || Priority.NORMAL
          });
        } else {
          console.warn(`[Orchestrator] Spawn blocked: max depth reached`);
        }
      }

      const duration = Date.now() - startTime;
      console.log(`[Orchestrator] Completed: ${agent.name} in ${duration}ms`);

      return {
        success: true,
        response: result,
        spawned: spawnRequests.map(s => s.agent),
        durationMs: duration,
        toolCalls: toolCalls.length > 0 ? toolCalls : undefined
      };

    } catch (error) {
      console.error(`[Orchestrator] Error executing ${agent.name}:`, error);

      return {
        success: false,
        error: error.message,
        response: '',
        spawned: [],
        durationMs: Date.now() - startTime
      };
    }
  }

  /**
   * Save an agent run as a markdown log file
   */
  async saveAgentLog(item, result) {
    try {
      const logsPath = path.join(this.vaultPath, 'agent-logs');
      const today = new Date().toISOString().split('T')[0];
      const dayPath = path.join(logsPath, today);

      await fs.mkdir(dayPath, { recursive: true });

      const agentName = item.agentPath.replace('agents/', '').replace('.md', '');
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);

      let fileName = `${timestamp}-${agentName}`;
      if (item.context?.documentPath) {
        const docName = item.context.documentPath.replace(/\//g, '-').replace('.md', '');
        fileName += `-on-${docName}`;
      }
      fileName += '.md';

      const filePath = path.join(dayPath, fileName);

      const durationMs = result.durationMs || 0;
      const durationSec = (durationMs / 1000).toFixed(1);

      let markdown = `---
run_id: "${item.id}"
agent: "${item.agentPath}"
agent_name: "${agentName}"
type: "${item.agent?.type || 'standalone'}"
status: "${result.success ? 'completed' : 'failed'}"
timestamp: "${new Date().toISOString()}"
duration_ms: ${durationMs}
duration: "${durationSec}s"
`;

      if (item.context?.documentPath) {
        markdown += `target_document: "${item.context.documentPath}"\n`;
      }

      markdown += `---

# Agent Run: ${agentName}

`;

      if (item.context?.documentPath) {
        markdown += `> Target: [[${item.context.documentPath}]]\n\n`;
      }

      markdown += `## Result

${result.response || 'No response'}

---

*Completed in ${durationSec}s*
`;

      await fs.writeFile(filePath, markdown, 'utf-8');
      console.log(`[Orchestrator] Saved log: ${filePath}`);

    } catch (e) {
      console.error('[Orchestrator] Failed to save agent log:', e.message);
    }
  }

  /**
   * Start background processing loop
   */
  startProcessingLoop() {
    setInterval(() => {
      this.processQueue();
    }, 5000); // Check every 5 seconds
  }

  /**
   * List vault files with depth protection
   * @param {string} dir - Directory to list
   * @param {string[]} files - Accumulator array
   * @param {number} depth - Current recursion depth
   * @returns {Promise<string[]>} List of relative file paths
   */
  async listVaultFiles(dir = this.vaultPath, files = [], depth = 0) {
    // Prevent infinite recursion from symlink loops or deeply nested directories
    const MAX_DEPTH = 20;
    if (depth > MAX_DEPTH) {
      console.warn(`[Orchestrator] Max directory depth (${MAX_DEPTH}) exceeded at: ${dir}`);
      return files;
    }

    const entries = await fs.readdir(dir, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);

      if (entry.isDirectory() && !entry.name.startsWith('.')) {
        await this.listVaultFiles(fullPath, files, depth + 1);
      } else if (entry.name.endsWith('.md')) {
        files.push(path.relative(this.vaultPath, fullPath));
      }
    }

    return files;
  }

  /**
   * Read a document
   */
  async readDocument(relativePath) {
    const fullPath = path.join(this.vaultPath, relativePath);
    try {
      const content = await fs.readFile(fullPath, 'utf-8');
      const matter = await import('gray-matter');
      const { data: frontmatter, content: body } = matter.default(content);
      return { path: relativePath, frontmatter, body, raw: content };
    } catch (e) {
      return null;
    }
  }

  /**
   * Get queue state
   */
  getQueueState() {
    return this.queue.getState();
  }

  /**
   * Get all loaded agents
   */
  async getAgents() {
    return loadAllAgents(this.vaultPath);
  }

  /**
   * Format messages for context injection (when SDK session is unavailable)
   * Similar to how we format imported conversations
   *
   * @param {Array} messages - Array of {role, content, timestamp} objects
   * @returns {string} Formatted conversation context
   */
  formatMessagesForContextInjection(messages) {
    if (!messages || messages.length === 0) {
      return null;
    }

    // Limit to last N messages to avoid token overflow (~50k tokens max)
    const MAX_MESSAGES = 50;
    const MAX_CHARS = 100000; // ~25k tokens

    let relevantMessages = messages.slice(-MAX_MESSAGES);
    let formatted = '';

    for (const msg of relevantMessages) {
      const role = msg.role === 'assistant' ? 'Assistant' : 'Human';
      const content = msg.content || '';

      // Truncate very long messages
      const truncated = content.length > 2000
        ? content.slice(0, 2000) + '... [truncated]'
        : content;

      formatted += `**${role}**: ${truncated}\n\n`;

      // Stop if we exceed max chars
      if (formatted.length > MAX_CHARS) {
        formatted = formatted.slice(0, MAX_CHARS) + '\n\n[Earlier messages truncated for context limit]';
        break;
      }
    }

    return formatted.trim();
  }

  // ============================================================================
  // DOCUMENT PROCESSING
  // ============================================================================

  /**
   * Start the trigger check loop
   * Checks documents with waiting status for trigger conditions
   */
  startTriggerLoop() {
    setInterval(async () => {
      await this.checkTriggers();
    }, 60000); // Check every minute

    // Also check immediately on startup
    setTimeout(() => this.checkTriggers(), 5000);
  }

  /**
   * Start the session cleanup loop
   * Cleans up old/stale chat sessions periodically
   */
  startSessionCleanupLoop() {
    // Run cleanup once per hour
    setInterval(async () => {
      try {
        const cleaned = await this.sessionManager.cleanupOldSessions();
        if (cleaned > 0) {
          console.log(`[Orchestrator] Cleaned up ${cleaned} old sessions`);
        }
      } catch (error) {
        console.error('[Orchestrator] Error cleaning sessions:', error);
      }
    }, 60 * 60 * 1000); // Every hour

    // Also run cleanup on startup (after 30 seconds)
    setTimeout(async () => {
      try {
        const cleaned = await this.sessionManager.cleanupOldSessions();
        if (cleaned > 0) {
          console.log(`[Orchestrator] Initial cleanup: ${cleaned} old sessions`);
        }
      } catch (error) {
        console.error('[Orchestrator] Error in initial cleanup:', error);
      }
    }, 30000);
  }

  /**
   * Check all document triggers and update statuses
   */
  async checkTriggers() {
    try {
      // Find all agent-document pairs whose triggers should fire
      const triggered = await this.documentScanner.findTriggeredAgents();

      for (const pair of triggered) {
        console.log(`[Orchestrator] Trigger fired: ${pair.agentPath} on ${pair.documentPath}`);
        await this.documentScanner.updateAgentStatus(
          pair.documentPath,
          pair.agentPath,
          AgentStatus.NEEDS_RUN
        );
      }

      // Process any agents that need running
      await this.processTriggeredAgents();

    } catch (error) {
      console.error('[Orchestrator] Error checking triggers:', error);
    }
  }

  /**
   * Process all agent-document pairs with needs_run status
   */
  async processTriggeredAgents() {
    const pairs = await this.documentScanner.findNeedsRun();

    for (const pair of pairs) {
      console.log(`[Orchestrator] Queueing: ${pair.agentPath} for ${pair.documentPath}`);

      // Update status to running
      await this.documentScanner.updateAgentStatus(
        pair.documentPath,
        pair.agentPath,
        AgentStatus.RUNNING
      );

      // Queue the agent to run on this document
      await this.enqueue(pair.agentPath, {
        documentPath: pair.documentPath,
        documentContent: pair.document.body,
        documentFrontmatter: pair.document.frontmatter,
        userMessage: `Process the document at: ${pair.documentPath}`
      }, {
        priority: Priority.NORMAL,
        documentPath: pair.documentPath,  // Track for status updates
        agentPath: pair.agentPath
      });
    }
  }

  /**
   * Run all pending agents on a document
   */
  async runAllAgentsOnDocument(documentPath) {
    const pending = await this.documentScanner.getPendingAgents(documentPath);
    const results = [];

    for (const agentConfig of pending) {
      results.push(await this.runAgentOnDocument(documentPath, agentConfig.path));
    }

    return results;
  }

  /**
   * Run specific agents on a document
   */
  async runAgentsOnDocument(documentPath, agentPaths) {
    const results = [];

    for (const agentPath of agentPaths) {
      results.push(await this.runAgentOnDocument(documentPath, agentPath));
    }

    return results;
  }

  /**
   * Run a single agent on a document
   */
  async runAgentOnDocument(documentPath, agentPath) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const doc = await this.documentScanner.parseDocument(fullPath);

    // Update status to running
    await this.documentScanner.updateAgentStatus(documentPath, agentPath, AgentStatus.RUNNING);

    try {
      // Load the agent
      const agent = await loadAgent(agentPath, this.vaultPath);

      // Build context with the document content
      const systemPrompt = buildSystemPrompt(agent, {
        documentPath,
        documentContent: doc.body,
        documentFrontmatter: doc.frontmatter
      });

      // Execute
      const result = await this.executeAgent(
        agent,
        `Process the document at: ${documentPath}\n\nDocument content:\n${doc.body}`,
        systemPrompt,
        0
      );

      // Update status to completed
      await this.documentScanner.updateAgentStatus(documentPath, agentPath, AgentStatus.COMPLETED, {
        last_result: result.success ? 'success' : 'error'
      });

      return { documentPath, agentPath, ...result };

    } catch (error) {
      await this.documentScanner.updateAgentStatus(documentPath, agentPath, AgentStatus.ERROR, {
        last_error: error.message
      });
      return { documentPath, agentPath, success: false, error: error.message };
    }
  }

  /**
   * Process a specific document with its first/primary agent (legacy support)
   */
  async processDocument(documentPath) {
    const doc = await this.documentScanner.parseDocument(
      path.join(this.vaultPath, documentPath)
    );

    if (!doc.agent) {
      throw new Error(`Document ${documentPath} has no agent assigned`);
    }

    return this.runAgentOnDocument(documentPath, doc.agent);
  }

  /**
   * Manually trigger all agents on a document
   */
  async triggerDocument(documentPath) {
    const triggered = await this.documentScanner.triggerAllAgents(documentPath);
    if (triggered.length > 0) {
      await this.processTriggeredAgents();
    }
    return triggered;
  }

  /**
   * Manually trigger specific agents on a document
   */
  async triggerDocumentAgents(documentPath, agentPaths) {
    const triggered = await this.documentScanner.triggerAgents(documentPath, agentPaths);
    if (triggered.length > 0) {
      await this.processTriggeredAgents();
    }
    return triggered;
  }

  /**
   * Reset agents on a document to pending
   */
  async resetDocumentAgents(documentPath, agentPaths = null) {
    return this.documentScanner.resetAgents(documentPath, agentPaths);
  }

  /**
   * Get pending agents for a document
   */
  async getPendingAgents(documentPath) {
    return this.documentScanner.getPendingAgents(documentPath);
  }

  /**
   * Get document statistics
   */
  async getDocumentStats() {
    return this.documentScanner.getStats();
  }

  /**
   * Get all documents with agent configurations
   */
  async getAgentDocuments() {
    return this.documentScanner.scanAll();
  }

  /**
   * Get agents configured for a specific document
   */
  async getDocumentAgents(documentPath) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const doc = await this.documentScanner.parseDocument(fullPath);
    return doc.agents;
  }

  /**
   * Update agents configured for a document
   */
  async updateDocumentAgents(documentPath, agents) {
    return this.documentScanner.updateDocumentAgents(documentPath, agents);
  }
}

export default Orchestrator;
