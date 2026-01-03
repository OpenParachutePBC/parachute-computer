import { App, Plugin, PluginSettingTab, Setting, WorkspaceLeaf, ItemView, Notice, TFile, Modal, MarkdownView, MarkdownRenderer, Component } from 'obsidian';

// ============================================================================
// SETTINGS
// ============================================================================

interface AgentPilotSettings {
  orchestratorUrl: string;
  showAgentBadges: boolean;
  autoRefreshQueue: boolean;
  refreshInterval: number;
}

const DEFAULT_SETTINGS: AgentPilotSettings = {
  orchestratorUrl: 'http://localhost:3333',
  showAgentBadges: true,
  autoRefreshQueue: true,
  refreshInterval: 3000,
};

// Forward declaration of PermissionRequest interface (full definition below)
interface PermissionRequest {
  id: string;
  toolName: string;
  filePath: string;
  agentName: string;
  allowedPatterns: string[];
  status: 'pending' | 'granted' | 'denied';
}

// ============================================================================
// PERMISSION REQUEST MODAL
// ============================================================================

class PermissionRequestModal extends Modal {
  private request: PermissionRequest;
  private plugin: AgentPilotPlugin;
  private onDecision: (granted: boolean) => void;

  constructor(app: App, plugin: AgentPilotPlugin, request: PermissionRequest, onDecision: (granted: boolean) => void) {
    super(app);
    this.plugin = plugin;
    this.request = request;
    this.onDecision = onDecision;
  }

  onOpen() {
    const { contentEl } = this;
    contentEl.addClass('permission-request-modal');

    contentEl.createEl('h2', { text: 'Permission Request' });

    const infoEl = contentEl.createDiv({ cls: 'permission-info' });
    infoEl.createEl('p', {
      text: `Agent "${this.request.agentName}" wants to write to a file outside its allowed paths.`
    });

    const detailsEl = contentEl.createDiv({ cls: 'permission-details' });
    detailsEl.createEl('div', { cls: 'permission-label', text: 'Tool:' });
    detailsEl.createEl('div', { cls: 'permission-value', text: this.request.toolName });

    detailsEl.createEl('div', { cls: 'permission-label', text: 'File:' });
    detailsEl.createEl('div', { cls: 'permission-value permission-path', text: this.request.filePath });

    detailsEl.createEl('div', { cls: 'permission-label', text: 'Allowed paths:' });
    detailsEl.createEl('div', {
      cls: 'permission-value',
      text: this.request.allowedPatterns.join(', ')
    });

    const warningEl = contentEl.createDiv({ cls: 'permission-warning' });
    warningEl.createEl('p', {
      text: 'Do you want to allow this write operation?'
    });

    const buttonsEl = contentEl.createDiv({ cls: 'permission-buttons' });

    const denyBtn = buttonsEl.createEl('button', { text: 'Deny', cls: 'mod-warning' });
    denyBtn.addEventListener('click', () => {
      this.onDecision(false);
      this.close();
    });

    const allowBtn = buttonsEl.createEl('button', { text: 'Allow', cls: 'mod-cta' });
    allowBtn.addEventListener('click', () => {
      this.onDecision(true);
      this.close();
    });
  }

  onClose() {
    const { contentEl } = this;
    contentEl.empty();
  }
}

// ============================================================================
// MAIN VIEW (Tabbed: Chat | Agents | Activity)
// ============================================================================

const PILOT_VIEW_TYPE = 'agent-pilot-view';

type ViewTab = 'chat' | 'agents' | 'activity';

interface ToolCall {
  name: string;
  input?: Record<string, any>;
  result?: string;
}

// Stream event for sequential rendering
type StreamEvent =
  | { type: 'text'; content: string }
  | { type: 'tool'; tool: ToolCall };

// PermissionRequest interface is defined above (near the Modal class)

interface DebugInfo {
  systemPromptLength: number;
  messageLength: number;
  agentPath: string;
  model: string;
  toolsAvailable: string[];
  writePermissions?: string[];
  resumedSession: boolean;
  durationMs?: number;
}

interface ChatMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: Date;
  agentPath?: string;
  toolCalls?: ToolCall[];
  stream?: StreamEvent[];  // Sequential stream of events for real-time display
  permissionDenials?: { toolName: string; filePath: string; reason: string }[];
  debug?: DebugInfo;
}

interface ChatSession {
  id: string;           // Session ID used in API calls (sessionId for routing)
  serverId?: string;    // Server's internal session ID (for fetching history)
  name: string;
  agentPath: string | null;
  messages: ChatMessage[];
  createdAt: Date;
  archived?: boolean;
}

interface QueueItem {
  id: string;
  agentPath: string;
  status: string;
  createdAt: string;
  startedAt?: string;
  completedAt?: string;
  context?: {
    documentPath?: string;
    userMessage?: string;
  };
  result?: {
    success: boolean;
    response: string;
    durationMs: number;
  };
  error?: string;
}

interface AgentInfo {
  name: string;
  path: string;
  description: string;
  type?: string;
  model: string;
}

class AgentPilotView extends ItemView {
  private plugin: AgentPilotPlugin;
  private currentTab: ViewTab = 'chat';
  private containerEl: HTMLElement;

  // Chat state - sessions
  private sessions: ChatSession[] = [];
  private currentSessionId: string | null = null;
  private isLoading: boolean = false;

  // Queue state
  private queueState: { running: QueueItem[]; completed: QueueItem[]; pending: QueueItem[] } = {
    running: [],
    completed: [],
    pending: []
  };

  // Agents state
  private agents: AgentInfo[] = [];

  // Refresh interval
  private refreshTimer: number | null = null;

  // Permission request SSE connection
  private permissionEventSource: EventSource | null = null;
  private pendingPermissionRequests: Map<string, PermissionRequest> = new Map();

  constructor(leaf: WorkspaceLeaf, plugin: AgentPilotPlugin) {
    super(leaf);
    this.plugin = plugin;
  }

  getViewType(): string {
    return PILOT_VIEW_TYPE;
  }

  getDisplayText(): string {
    return 'Agent Pilot';
  }

  getIcon(): string {
    return 'bot';
  }

  async onOpen(): Promise<void> {
    console.log('[Agent Pilot] View onOpen called');
    this.containerEl = this.contentEl;
    this.containerEl.empty();
    this.containerEl.addClass('agent-pilot-view');

    this.addStyles();
    this.render();

    // Start auto-refresh
    if (this.plugin.settings.autoRefreshQueue) {
      this.startAutoRefresh();
    }

    // Connect to permission request stream
    console.log('[Agent Pilot] About to connect permission stream');
    this.connectPermissionStream();

    // Initial data load
    await this.loadAgents();
    await this.loadSessions();
    await this.refreshQueue();
    console.log('[Agent Pilot] View onOpen complete');
  }

  async onClose(): Promise<void> {
    this.stopAutoRefresh();
    this.disconnectPermissionStream();
  }

  private connectPermissionStream(): void {
    const url = `${this.plugin.settings.orchestratorUrl}/api/permissions/stream`;
    console.log('[Agent Pilot] Connecting to permission stream:', url);
    this.permissionEventSource = new EventSource(url);

    this.permissionEventSource.onopen = () => {
      console.log('[Agent Pilot] Permission stream connected');
    };

    this.permissionEventSource.onmessage = (event) => {
      console.log('[Agent Pilot] SSE message received:', event.data);
      try {
        const data = JSON.parse(event.data);

        if (data.type === 'permissionRequest') {
          console.log('[Agent Pilot] Permission request received:', data.request);
          this.handlePermissionRequest(data.request);
        } else if (data.type === 'permissionGranted' || data.type === 'permissionDenied') {
          this.pendingPermissionRequests.delete(data.request.id);
        }
      } catch (e) {
        console.error('[Agent Pilot] Error parsing SSE message:', e);
      }
    };

    this.permissionEventSource.onerror = (e) => {
      console.error('[Agent Pilot] Permission stream error:', e);
      // Reconnect after a delay
      setTimeout(() => {
        if (this.permissionEventSource) {
          this.connectPermissionStream();
        }
      }, 5000);
    };
  }

  private disconnectPermissionStream(): void {
    if (this.permissionEventSource) {
      this.permissionEventSource.close();
      this.permissionEventSource = null;
    }
  }

  private handlePermissionRequest(request: PermissionRequest): void {
    this.pendingPermissionRequests.set(request.id, request);

    // Show a prominent notice to alert the user
    new Notice(`Permission request from ${request.agentName}: Write to ${request.filePath}`, 10000);

    // Switch to chat tab if not already there
    if (this.currentTab !== 'chat') {
      this.currentTab = 'chat';
    }

    // Re-render to show inline permission request
    this.render();
  }

  private async respondToPermission(requestId: string, granted: boolean): Promise<void> {
    try {
      const endpoint = granted ? 'grant' : 'deny';
      await fetch(`${this.plugin.settings.orchestratorUrl}/api/permissions/${requestId}/${endpoint}`, {
        method: 'POST'
      });
      this.pendingPermissionRequests.delete(requestId);
      this.render();
    } catch (e) {
      new Notice(`Failed to ${granted ? 'grant' : 'deny'} permission: ${(e as Error).message}`);
    }
  }

  private startAutoRefresh(): void {
    this.refreshTimer = window.setInterval(() => {
      this.refreshQueue();
    }, this.plugin.settings.refreshInterval);
  }

  private stopAutoRefresh(): void {
    if (this.refreshTimer) {
      window.clearInterval(this.refreshTimer);
      this.refreshTimer = null;
    }
  }

  private render(): void {
    this.containerEl.empty();

    // Header with tabs
    const header = this.containerEl.createDiv({ cls: 'pilot-header' });

    const tabs = header.createDiv({ cls: 'pilot-tabs' });
    this.createTab(tabs, 'chat', 'Chat');
    this.createTab(tabs, 'agents', 'Agents');
    this.createTab(tabs, 'activity', 'Activity');

    // Content area
    const content = this.containerEl.createDiv({ cls: 'pilot-content' });

    switch (this.currentTab) {
      case 'chat':
        this.renderChatTab(content);
        break;
      case 'agents':
        this.renderAgentsTab(content);
        break;
      case 'activity':
        this.renderActivityTab(content);
        break;
    }
  }

  private createTab(container: HTMLElement, tab: ViewTab, label: string): void {
    const tabEl = container.createEl('button', {
      cls: `pilot-tab ${this.currentTab === tab ? 'active' : ''}`,
      text: label
    });

    // Add badge for activity tab
    if (tab === 'activity' && this.queueState.running.length > 0) {
      tabEl.createEl('span', {
        cls: 'pilot-badge',
        text: String(this.queueState.running.length)
      });
    }

    tabEl.addEventListener('click', () => {
      this.currentTab = tab;
      this.render();
    });
  }

  // ============================================================================
  // CHAT TAB - Session Management
  // ============================================================================

  private getCurrentSession(): ChatSession | null {
    if (!this.currentSessionId) return null;
    return this.sessions.find(s => s.id === this.currentSessionId) || null;
  }

  private createSession(agentPath: string | null): ChatSession {
    const agent = this.agents.find(a => a.path === agentPath);
    const agentName = agent?.name || (agentPath ? agentPath.replace('agents/', '').replace('.md', '') : 'Vault Agent');

    const session: ChatSession = {
      id: Date.now().toString(36) + Math.random().toString(36).substr(2),
      name: agentName,
      agentPath,
      messages: [],
      createdAt: new Date()
    };

    this.sessions.push(session);
    this.currentSessionId = session.id;
    return session;
  }

  private deleteSession(sessionId: string): void {
    const idx = this.sessions.findIndex(s => s.id === sessionId);
    if (idx >= 0) {
      this.sessions.splice(idx, 1);
      if (this.currentSessionId === sessionId) {
        this.currentSessionId = this.sessions.length > 0 ? this.sessions[0].id : null;
      }
    }
  }

  private async archiveSession(session: ChatSession): Promise<void> {
    const sessionIdToArchive = session.serverId || session.id;
    try {
      await fetch(`${this.plugin.settings.orchestratorUrl}/api/chat/session/${encodeURIComponent(sessionIdToArchive)}/archive`, {
        method: 'POST'
      });
      session.archived = true;
      if (this.currentSessionId === session.id) {
        // Select the next active session
        const activeSessions = this.sessions.filter(s => !s.archived && s.id !== session.id);
        this.currentSessionId = activeSessions.length > 0 ? activeSessions[0].id : null;
      }
      this.render();
    } catch (e) {
      new Notice(`Failed to archive session: ${(e as Error).message}`);
    }
  }

  private async unarchiveSession(session: ChatSession): Promise<void> {
    const sessionIdToUnarchive = session.serverId || session.id;
    try {
      await fetch(`${this.plugin.settings.orchestratorUrl}/api/chat/session/${encodeURIComponent(sessionIdToUnarchive)}/unarchive`, {
        method: 'POST'
      });
      session.archived = false;
      this.render();
    } catch (e) {
      new Notice(`Failed to unarchive session: ${(e as Error).message}`);
    }
  }

  private async deleteSessionPermanently(session: ChatSession): Promise<void> {
    const sessionIdToDelete = session.serverId || session.id;
    try {
      await fetch(`${this.plugin.settings.orchestratorUrl}/api/chat/session/${encodeURIComponent(sessionIdToDelete)}`, {
        method: 'DELETE'
      });
      this.deleteSession(session.id);
      this.render();
    } catch (e) {
      new Notice(`Failed to delete session: ${(e as Error).message}`);
    }
  }

  /**
   * Load existing sessions from the server
   */
  private async loadSessions(): Promise<void> {
    try {
      const response = await fetch(`${this.plugin.settings.orchestratorUrl}/api/chat/sessions`);
      const serverSessions = await response.json();

      // Convert server sessions to plugin format
      // Use context.sessionId for API routing, and s.id for fetching history
      this.sessions = serverSessions.map((s: any) => ({
        id: s.context?.sessionId || s.id,  // For API calls (sendMessage)
        serverId: s.id,                     // For fetching history
        name: s.agentName || 'Chat',
        agentPath: s.agentPath === 'vault-agent' ? null : s.agentPath,
        messages: [], // Messages are loaded on-demand when switching to the session
        createdAt: new Date(s.createdAt),
        archived: s.archived || false
      }));

      // Sort by most recent first
      this.sessions.sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());

      console.log(`[Agent Pilot] Loaded ${this.sessions.length} sessions from server`);
      this.render();
    } catch (e) {
      console.error('Failed to load sessions:', e);
    }
  }

  /**
   * Load message history for a session from the server by session ID
   */
  private async loadSessionHistory(session: ChatSession): Promise<void> {
    try {
      // Use serverId if available (for server-loaded sessions), otherwise id (for newly created)
      const sessionIdForHistory = session.serverId || session.id;
      const response = await fetch(
        `${this.plugin.settings.orchestratorUrl}/api/chat/session/${encodeURIComponent(sessionIdForHistory)}`
      );

      if (!response.ok) {
        console.error('Failed to load session:', response.status);
        return;
      }

      const data = await response.json();

      // Convert server history to plugin format
      session.messages = (data.messages || []).map((msg: any) => ({
        role: msg.role,
        content: msg.content,
        timestamp: new Date(msg.timestamp || Date.now()),
        agentPath: msg.agentPath
      }));

      console.log(`[Agent Pilot] Loaded ${session.messages.length} messages for session ${session.id}`);
      this.render();
    } catch (e) {
      console.error('Failed to load session history:', e);
    }
  }

  private renderSessionItem(container: HTMLElement, s: ChatSession, isArchived: boolean): void {
    const sessionItem = container.createDiv({
      cls: `pilot-session-item ${s.id === this.currentSessionId ? 'active' : ''} ${isArchived ? 'pilot-session-archived' : ''}`
    });

    const sessionInfo = sessionItem.createDiv({ cls: 'pilot-session-info' });
    sessionInfo.createEl('span', { text: s.name, cls: 'pilot-session-name' });

    const msgCount = s.messages.filter(m => m.role !== 'system').length;
    if (msgCount > 0) {
      sessionInfo.createEl('span', {
        text: `${msgCount} msg${msgCount > 1 ? 's' : ''}`,
        cls: 'pilot-session-count'
      });
    }

    sessionItem.addEventListener('click', async () => {
      this.currentSessionId = s.id;
      // Load history if not already loaded
      if (s.messages.length === 0) {
        await this.loadSessionHistory(s);
      } else {
        this.render();
      }
    });

    // Action buttons container
    const actionsEl = sessionItem.createDiv({ cls: 'pilot-session-actions' });

    if (isArchived) {
      // Unarchive button for archived sessions
      const unarchiveBtn = actionsEl.createEl('button', {
        cls: 'pilot-session-action',
        attr: { 'aria-label': 'Restore', title: 'Restore from archive' }
      });
      unarchiveBtn.textContent = '↩';
      unarchiveBtn.addEventListener('click', async (e) => {
        e.stopPropagation();
        await this.unarchiveSession(s);
      });

      // Delete button for archived sessions
      const deleteBtn = actionsEl.createEl('button', {
        cls: 'pilot-session-action pilot-session-action-delete',
        attr: { 'aria-label': 'Delete permanently', title: 'Delete permanently' }
      });
      deleteBtn.textContent = '🗑';
      deleteBtn.addEventListener('click', async (e) => {
        e.stopPropagation();
        await this.deleteSessionPermanently(s);
      });
    } else {
      // Archive button for active sessions
      const archiveBtn = actionsEl.createEl('button', {
        cls: 'pilot-session-action',
        attr: { 'aria-label': 'Archive', title: 'Archive chat' }
      });
      archiveBtn.textContent = '📦';
      archiveBtn.addEventListener('click', async (e) => {
        e.stopPropagation();
        await this.archiveSession(s);
      });
    }
  }

  private renderChatTab(container: HTMLElement): void {
    const chatbotAgents = this.agents.filter(a => a.type === 'chatbot' || !a.type);
    const session = this.getCurrentSession();

    // Session sidebar
    const chatLayout = container.createDiv({ cls: 'pilot-chat-layout' });

    // Left: Session list
    const sessionList = chatLayout.createDiv({ cls: 'pilot-session-list' });

    // New chat button
    const newChatBtn = sessionList.createEl('button', {
      text: '+ New Chat',
      cls: 'pilot-new-chat-btn'
    });
    newChatBtn.addEventListener('click', () => {
      this.createSession(null);
      this.render();
    });

    // Separate active and archived sessions
    const activeSessions = this.sessions.filter(s => !s.archived);
    const archivedSessions = this.sessions.filter(s => s.archived);

    // Active sessions section
    const sessionsContainer = sessionList.createDiv({ cls: 'pilot-sessions' });

    if (activeSessions.length === 0) {
      sessionsContainer.createDiv({ cls: 'pilot-sessions-empty', text: 'No active chats' });
    } else {
      for (const s of activeSessions) {
        this.renderSessionItem(sessionsContainer, s, false);
      }
    }

    // Archived sessions section (collapsible)
    if (archivedSessions.length > 0) {
      const archivedSection = sessionList.createDiv({ cls: 'pilot-archived-section' });
      const archivedHeader = archivedSection.createDiv({ cls: 'pilot-archived-header' });
      archivedHeader.createEl('span', { text: `Archived (${archivedSessions.length})`, cls: 'pilot-archived-label' });

      const archivedToggle = archivedHeader.createEl('span', { cls: 'pilot-archived-toggle', text: '▼' });
      const archivedList = archivedSection.createDiv({ cls: 'pilot-archived-list' });
      archivedList.style.display = 'none';  // Start collapsed

      archivedHeader.addEventListener('click', () => {
        const isHidden = archivedList.style.display === 'none';
        archivedList.style.display = isHidden ? 'flex' : 'none';
        archivedToggle.textContent = isHidden ? '▲' : '▼';
      });

      for (const s of archivedSessions) {
        this.renderSessionItem(archivedList, s, true);
      }
    }

    // Right: Chat area
    const chatArea = chatLayout.createDiv({ cls: 'pilot-chat-area' });

    if (!session) {
      // No session selected - show welcome / agent picker
      const welcome = chatArea.createDiv({ cls: 'pilot-welcome' });
      welcome.createEl('h3', { text: 'Start a new chat' });
      welcome.createEl('p', { text: 'Select an agent to begin:', cls: 'pilot-welcome-hint' });

      const agentGrid = welcome.createDiv({ cls: 'pilot-agent-grid' });

      // Default vault agent
      const vaultCard = agentGrid.createDiv({ cls: 'pilot-agent-pick' });
      vaultCard.createEl('span', { text: 'Vault Agent', cls: 'pilot-pick-name' });
      vaultCard.createEl('span', { text: 'General assistant', cls: 'pilot-pick-desc' });
      vaultCard.addEventListener('click', () => {
        this.createSession(null);
        this.render();
      });

      // Chatbot agents
      for (const agent of chatbotAgents) {
        const card = agentGrid.createDiv({ cls: 'pilot-agent-pick' });
        card.createEl('span', { text: agent.name, cls: 'pilot-pick-name' });
        card.createEl('span', { text: agent.description?.substring(0, 60) || '', cls: 'pilot-pick-desc' });
        card.addEventListener('click', () => {
          this.createSession(agent.path);
          this.render();
        });
      }
      return;
    }

    // Current session header
    const sessionHeader = chatArea.createDiv({ cls: 'pilot-session-header' });
    sessionHeader.createEl('span', { text: session.name, cls: 'pilot-session-title' });

    // Show agent description
    if (session.agentPath) {
      const agent = this.agents.find(a => a.path === session.agentPath);
      if (agent?.description) {
        sessionHeader.createEl('span', { text: agent.description, cls: 'pilot-session-desc' });
      }
    }

    // Messages
    const messagesEl = chatArea.createDiv({ cls: 'pilot-messages' });

    if (session.messages.length === 0 && !this.isLoading) {
      messagesEl.createDiv({
        cls: 'pilot-empty',
        text: `Start chatting with ${session.name}`
      });
    } else {
      for (const msg of session.messages) {
        const msgEl = messagesEl.createDiv({
          cls: `pilot-message pilot-message-${msg.role}`
        });
        if (msg.agentPath && msg.role === 'assistant') {
          msgEl.createEl('div', {
            cls: 'pilot-message-agent',
            text: msg.agentPath.replace('agents/', '').replace('.md', '')
          });
        }

        // Render debug info if present (at top, collapsible)
        if (msg.debug) {
          const debugContainer = msgEl.createDiv({ cls: 'pilot-debug-container' });
          const debugToggle = debugContainer.createEl('button', {
            cls: 'pilot-debug-toggle',
            text: `⏱ ${(msg.debug.durationMs! / 1000).toFixed(1)}s`
          });
          const debugContent = debugContainer.createDiv({ cls: 'pilot-debug-content' });
          debugContent.style.display = 'none'; // Start collapsed

          debugToggle.addEventListener('click', () => {
            const isHidden = debugContent.style.display === 'none';
            debugContent.style.display = isHidden ? 'block' : 'none';
            debugToggle.classList.toggle('pilot-debug-expanded', isHidden);
          });

          const debugLines = [
            `Model: ${msg.debug.model}`,
            `Prompt: ${msg.debug.systemPromptLength.toLocaleString()} chars`,
            `Resumed: ${msg.debug.resumedSession ? 'yes' : 'no'}`
          ];

          if (msg.debug.toolsAvailable && msg.debug.toolsAvailable.length > 0) {
            debugLines.push(`Tools: ${msg.debug.toolsAvailable.join(', ')}`);
          }

          if (msg.debug.writePermissions && msg.debug.writePermissions.length > 0) {
            debugLines.push(`Write: ${msg.debug.writePermissions.join(', ')}`);
          }

          for (const line of debugLines) {
            debugContent.createDiv({ cls: 'pilot-debug-line', text: line });
          }
        }

        // Render permission denials summary (deduplicated)
        if (msg.permissionDenials && msg.permissionDenials.length > 0) {
          const uniquePaths = [...new Set(msg.permissionDenials.map(d => d.filePath))];
          const permEl = msgEl.createDiv({ cls: 'pilot-permission-denials' });
          permEl.createEl('span', {
            cls: 'pilot-permission-summary',
            text: `⚠️ ${msg.permissionDenials.length} write(s) blocked: ${uniquePaths.map(p => p.split('/').pop()).join(', ')}`
          });
        }

        // Render message content - use sequential stream if available, otherwise legacy rendering
        const contentEl = msgEl.createDiv({ cls: 'pilot-message-content' });
        const sourcePath = this.app.workspace.getActiveFile()?.path ?? 'agent-pilot-chat';

        if (msg.stream && msg.stream.length > 0 && msg.role === 'assistant') {
          // Sequential stream rendering - interleaved tool calls and text
          for (const event of msg.stream) {
            if (event.type === 'tool') {
              // Render inline collapsible tool call
              const toolEl = contentEl.createDiv({ cls: 'pilot-stream-tool' });
              const toolHeader = toolEl.createDiv({ cls: 'pilot-stream-tool-header' });
              toolHeader.createEl('span', { cls: 'pilot-stream-tool-icon', text: '▶' });
              toolHeader.createEl('span', { cls: 'pilot-stream-tool-name', text: event.tool.name });

              // Show input summary if present
              if (event.tool.input) {
                const fullPath = this.summarizeToolInput(event.tool.name, event.tool.input);
                if (fullPath) {
                  const shortName = fullPath.split('/').pop() || fullPath;
                  toolHeader.createEl('span', {
                    cls: 'pilot-stream-tool-input',
                    text: shortName,
                    attr: { title: fullPath }
                  });
                }
              }

              // Expandable details (initially collapsed)
              const toolDetails = toolEl.createDiv({ cls: 'pilot-stream-tool-details pilot-collapsed' });
              if (event.tool.input) {
                toolDetails.createEl('pre', {
                  cls: 'pilot-stream-tool-json',
                  text: JSON.stringify(event.tool.input, null, 2)
                });
              }

              // Toggle on header click
              toolHeader.addEventListener('click', () => {
                const icon = toolHeader.querySelector('.pilot-stream-tool-icon');
                if (toolDetails.hasClass('pilot-collapsed')) {
                  toolDetails.removeClass('pilot-collapsed');
                  if (icon) icon.textContent = '▼';
                } else {
                  toolDetails.addClass('pilot-collapsed');
                  if (icon) icon.textContent = '▶';
                }
              });
            } else if (event.type === 'text') {
              // Render text block as markdown
              const textEl = contentEl.createDiv({ cls: 'pilot-stream-text pilot-markdown' });
              MarkdownRenderer.render(this.app, event.content, textEl, sourcePath, this)
                .catch((e: Error) => {
                  console.error('[Agent Pilot] Markdown render failed:', e);
                  textEl.textContent = event.content;
                });
            }
          }
        } else if (msg.role === 'assistant') {
          // Legacy rendering for messages without stream data
          // Render tool calls first (collapsible block)
          if (msg.toolCalls && msg.toolCalls.length > 0) {
            const toolsContainer = contentEl.createDiv({ cls: 'pilot-tool-calls-container' });
            const toolsHeader = toolsContainer.createDiv({ cls: 'pilot-tool-calls-header' });
            toolsHeader.createEl('span', { cls: 'pilot-tool-calls-icon', text: '▶' });
            toolsHeader.createEl('span', {
              cls: 'pilot-tool-calls-label',
              text: `${msg.toolCalls.length} tool call${msg.toolCalls.length > 1 ? 's' : ''}`
            });

            const toolsEl = toolsContainer.createDiv({ cls: 'pilot-tool-calls pilot-tool-calls-collapsed' });

            toolsHeader.addEventListener('click', () => {
              const icon = toolsHeader.querySelector('.pilot-tool-calls-icon');
              if (toolsEl.hasClass('pilot-tool-calls-collapsed')) {
                toolsEl.removeClass('pilot-tool-calls-collapsed');
                if (icon) icon.textContent = '▼';
              } else {
                toolsEl.addClass('pilot-tool-calls-collapsed');
                if (icon) icon.textContent = '▶';
              }
            });

            for (const tool of msg.toolCalls) {
              const toolEl = toolsEl.createDiv({ cls: 'pilot-tool-call' });
              const toolHeader = toolEl.createDiv({ cls: 'pilot-tool-header' });
              toolHeader.createEl('span', { cls: 'pilot-tool-icon', text: '⚡' });
              toolHeader.createEl('span', { cls: 'pilot-tool-name', text: tool.name });

              if (tool.input) {
                const fullPath = this.summarizeToolInput(tool.name, tool.input);
                if (fullPath) {
                  const shortName = fullPath.split('/').pop() || fullPath;
                  toolHeader.createEl('span', {
                    cls: 'pilot-tool-input',
                    text: shortName,
                    attr: { title: fullPath }
                  });
                }
              }
            }
          }

          // Render content as markdown
          if (msg.content) {
            const markdownContainer = contentEl.createDiv({ cls: 'pilot-markdown' });
            MarkdownRenderer.render(this.app, msg.content, markdownContainer, sourcePath, this)
              .catch((e: Error) => {
                console.error('[Agent Pilot] Markdown render failed:', e);
                markdownContainer.textContent = msg.content;
              });
          }
        } else {
          // User messages - plain text
          contentEl.textContent = msg.content;
        }

        // Footer with time and copy button
        const footerEl = msgEl.createDiv({ cls: 'pilot-message-footer' });

        footerEl.createEl('span', {
          cls: 'pilot-message-time',
          text: msg.timestamp.toLocaleTimeString()
        });

        // Add copy button for assistant messages
        if (msg.role === 'assistant') {
          const copyBtn = footerEl.createEl('button', {
            cls: 'pilot-copy-btn',
            attr: { 'aria-label': 'Copy message' }
          });
          copyBtn.innerHTML = '📋';
          copyBtn.addEventListener('click', async () => {
            try {
              await navigator.clipboard.writeText(msg.content);
              copyBtn.innerHTML = '✓';
              setTimeout(() => { copyBtn.innerHTML = '📋'; }, 1500);
            } catch (e) {
              new Notice('Failed to copy to clipboard');
            }
          });
        }
      }

      // Show loading indicator
      if (this.isLoading) {
        const loadingEl = messagesEl.createDiv({ cls: 'pilot-message pilot-message-loading' });
        loadingEl.createDiv({ cls: 'pilot-typing-indicator' });
      }

      // Show pending permission requests inline
      if (this.pendingPermissionRequests.size > 0) {
        for (const [id, request] of this.pendingPermissionRequests) {
          const permEl = messagesEl.createDiv({ cls: 'pilot-message pilot-permission-request' });

          permEl.createEl('div', {
            cls: 'pilot-permission-title',
            text: '🔐 Permission Request'
          });

          permEl.createEl('div', {
            cls: 'pilot-permission-desc',
            text: `Agent wants to write outside allowed paths:`
          });

          permEl.createEl('div', {
            cls: 'pilot-permission-path',
            text: request.filePath
          });

          permEl.createEl('div', {
            cls: 'pilot-permission-allowed',
            text: `Allowed: ${request.allowedPatterns.join(', ')}`
          });

          const btnContainer = permEl.createDiv({ cls: 'pilot-permission-actions' });

          const denyBtn = btnContainer.createEl('button', {
            cls: 'pilot-permission-deny',
            text: 'Deny'
          });
          denyBtn.addEventListener('click', () => this.respondToPermission(id, false));

          const allowBtn = btnContainer.createEl('button', {
            cls: 'pilot-permission-allow',
            text: 'Allow'
          });
          allowBtn.addEventListener('click', () => this.respondToPermission(id, true));
        }
      }
    }

    // Scroll to bottom
    setTimeout(() => { messagesEl.scrollTop = messagesEl.scrollHeight; }, 10);

    // Input
    const inputArea = chatArea.createDiv({ cls: 'pilot-input-area' });
    const textarea = inputArea.createEl('textarea', {
      cls: `pilot-input ${this.isLoading ? 'pilot-input-disabled' : ''}`,
      attr: {
        placeholder: this.isLoading ? 'Waiting for response...' : 'Ask your agents anything...'
      }
    });
    textarea.disabled = this.isLoading;

    textarea.addEventListener('keydown', async (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !this.isLoading) {
        e.preventDefault();
        await this.sendMessage(textarea.value);
        textarea.value = '';
      }
    });

    const sendBtn = inputArea.createEl('button', {
      text: this.isLoading ? 'Sending...' : 'Send',
      cls: `pilot-send ${this.isLoading ? 'pilot-send-disabled' : ''}`
    });
    sendBtn.disabled = this.isLoading;

    sendBtn.addEventListener('click', async () => {
      if (!this.isLoading) {
        await this.sendMessage(textarea.value);
        textarea.value = '';
      }
    });
  }

  private addSystemMessage(content: string): void {
    const session = this.getCurrentSession();
    if (session) {
      session.messages.push({ role: 'system', content, timestamp: new Date() });
    }
    this.render();
  }

  private async sendMessage(content: string): Promise<void> {
    if (!content.trim() || this.isLoading) return;

    const session = this.getCurrentSession();
    if (!session) return;

    session.messages.push({ role: 'user', content, timestamp: new Date() });
    this.isLoading = true;
    this.render();

    // Create a placeholder message for streaming content
    const assistantMessage: ChatMessage = {
      role: 'assistant',
      content: '',
      timestamp: new Date(),
      toolCalls: []
    };
    session.messages.push(assistantMessage);

    // Track streaming state
    let currentToolCalls: ToolCall[] = [];
    let finalData: any = null;

    try {
      const response = await fetch(`${this.plugin.settings.orchestratorUrl}/api/chat/stream`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          message: content,
          agentPath: session.agentPath,
          sessionId: session.id
        })
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      const reader = response.body?.getReader();
      if (!reader) {
        throw new Error('No response body');
      }

      const decoder = new TextDecoder();
      let buffer = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });

        // Process complete SSE events
        const lines = buffer.split('\n');
        buffer = lines.pop() || ''; // Keep incomplete line in buffer

        for (const line of lines) {
          if (line.startsWith('data: ')) {
            try {
              const event = JSON.parse(line.slice(6));
              this.handleStreamEvent(event, assistantMessage, currentToolCalls, session);
              if (event.type === 'done' || event.type === 'error') {
                finalData = event;
              }
            } catch (e) {
              console.error('[Agent Pilot] Failed to parse SSE event:', e);
            }
          }
        }
      }

      // Handle final data
      if (finalData) {
        if (finalData.type === 'done') {
          // Update with final data
          assistantMessage.toolCalls = finalData.toolCalls || currentToolCalls;
          assistantMessage.permissionDenials = finalData.permissionDenials;
          assistantMessage.debug = {
            systemPromptLength: 0,
            messageLength: content.length,
            agentPath: session.agentPath || 'vault-agent',
            model: 'default',
            toolsAvailable: [],
            resumedSession: finalData.sessionResume?.method !== 'new',
            durationMs: finalData.durationMs
          };

          if (finalData.spawned?.length > 0) {
            session.messages.push({
              role: 'system',
              content: `Spawned ${finalData.spawned.length} sub-agent(s)`,
              timestamp: new Date()
            });
          }

          if (finalData.permissionDenials?.length > 0) {
            new Notice(`${finalData.permissionDenials.length} write operation(s) were blocked by permissions`);
          }
        } else if (finalData.type === 'error') {
          assistantMessage.content = `Error: ${finalData.error}`;
        }
      }

    } catch (e) {
      // Update the assistant message with error
      assistantMessage.content = `Error: ${e.message}`;
    } finally {
      this.isLoading = false;
    }

    this.render();
  }

  /**
   * Send a message with additional context (e.g., document content for doc agents)
   */
  private async sendMessageWithContext(
    content: string,
    context: { documentPath?: string; documentContent?: string }
  ): Promise<void> {
    if (!content.trim() || this.isLoading) return;

    const session = this.getCurrentSession();
    if (!session) return;

    // Build the full message including document context
    let fullMessage = content;
    if (context.documentContent) {
      fullMessage = `${content}\n\n---\n\n# Document Content\n\n${context.documentContent}`;
    }

    session.messages.push({ role: 'user', content, timestamp: new Date() });
    this.isLoading = true;
    this.render();

    // Create a placeholder message for streaming content
    const assistantMessage: ChatMessage = {
      role: 'assistant',
      content: '',
      timestamp: new Date(),
      toolCalls: []
    };
    session.messages.push(assistantMessage);

    // Track streaming state
    let currentToolCalls: ToolCall[] = [];
    let finalData: any = null;

    try {
      const response = await fetch(`${this.plugin.settings.orchestratorUrl}/api/chat/stream`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          message: fullMessage,
          agentPath: session.agentPath,
          sessionId: session.id,
          initialContext: context.documentContent ? {
            documentPath: context.documentPath,
            documentContent: context.documentContent
          } : undefined
        })
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      const reader = response.body?.getReader();
      if (!reader) {
        throw new Error('No response body');
      }

      const decoder = new TextDecoder();
      let buffer = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });

        // Process complete SSE events
        const lines = buffer.split('\n');
        buffer = lines.pop() || ''; // Keep incomplete line in buffer

        for (const line of lines) {
          if (line.startsWith('data: ')) {
            try {
              const event = JSON.parse(line.slice(6));
              this.handleStreamEvent(event, assistantMessage, currentToolCalls, session);
              if (event.type === 'done' || event.type === 'error') {
                finalData = event;
              }
            } catch (e) {
              console.error('[Agent Pilot] Failed to parse SSE event:', e);
            }
          }
        }
      }

      // Handle final data
      if (finalData) {
        if (finalData.type === 'done') {
          assistantMessage.toolCalls = finalData.toolCalls || currentToolCalls;
          assistantMessage.permissionDenials = finalData.permissionDenials;
          assistantMessage.debug = {
            systemPromptLength: 0,
            messageLength: content.length,
            agentPath: session.agentPath || 'vault-agent',
            model: 'default',
            toolsAvailable: [],
            resumedSession: finalData.sessionResume?.method !== 'new',
            durationMs: finalData.durationMs
          };

          if (finalData.spawned?.length > 0) {
            session.messages.push({
              role: 'system',
              content: `Spawned ${finalData.spawned.length} sub-agent(s)`,
              timestamp: new Date()
            });
          }

          if (finalData.permissionDenials?.length > 0) {
            new Notice(`${finalData.permissionDenials.length} write operation(s) were blocked by permissions`);
          }
        } else if (finalData.type === 'error') {
          assistantMessage.content = `Error: ${finalData.error}`;
        }
      }

    } catch (e) {
      assistantMessage.content = `Error: ${(e as Error).message}`;
    } finally {
      this.isLoading = false;
    }

    this.render();
  }

  /**
   * Handle individual streaming events
   * Builds a sequential stream of events for proper timeline display
   */
  private handleStreamEvent(
    event: any,
    message: ChatMessage,
    toolCalls: ToolCall[],
    session: ChatSession
  ): void {
    // Initialize stream if not present
    if (!message.stream) {
      message.stream = [];
    }

    switch (event.type) {
      case 'session':
        // Session info received
        console.log(`[Agent Pilot] Session: ${event.sessionId}, resume: ${event.resumeInfo?.method}`);
        break;

      case 'init':
        // SDK initialized
        console.log(`[Agent Pilot] Tools available: ${event.tools?.join(', ')}`);
        break;

      case 'text':
        // Text content - update the last text event or add new one
        // We update in place because text arrives incrementally
        const lastEvent = message.stream[message.stream.length - 1];
        if (lastEvent && lastEvent.type === 'text') {
          lastEvent.content = event.content;
        } else {
          message.stream.push({ type: 'text', content: event.content });
        }
        message.content = event.content;
        this.render();
        break;

      case 'tool_use':
        // Tool being used - add to stream as a new event
        const tool: ToolCall = {
          name: event.tool.name,
          input: event.tool.input
        };
        toolCalls.push(tool);
        message.toolCalls = [...toolCalls];
        // Add tool to stream - this creates the sequential ordering
        message.stream.push({ type: 'tool', tool });
        this.render();
        break;

      case 'error':
        message.content = `Error: ${event.error}`;
        message.stream.push({ type: 'text', content: `Error: ${event.error}` });
        this.render();
        break;

      case 'done':
        // Final message - will be processed after stream ends
        break;
    }
  }

  private async clearSession(): Promise<void> {
    const session = this.getCurrentSession();
    if (!session) return;

    try {
      await fetch(`${this.plugin.settings.orchestratorUrl}/api/chat/session?agentPath=${session.agentPath || ''}`, {
        method: 'DELETE'
      });
      session.messages = [];
      this.addSystemMessage('Session cleared');
    } catch (e) {
      new Notice(`Error: ${e.message}`);
    }
  }

  /**
   * Generate a human-readable summary of tool input based on tool type
   */
  private summarizeToolInput(toolName: string, input: Record<string, any>): string {
    const name = toolName.toLowerCase();

    // File operations
    if (name === 'read' || name.includes('read')) {
      return input.file_path || input.path || '';
    }

    if (name === 'write' || name.includes('write')) {
      return input.file_path || input.path || '';
    }

    if (name === 'edit' || name.includes('edit')) {
      return input.file_path || input.path || '';
    }

    // Search operations
    if (name === 'glob' || name.includes('glob')) {
      return input.pattern || '';
    }

    if (name === 'grep' || name.includes('grep')) {
      return input.pattern || '';
    }

    // Bash commands
    if (name === 'bash' || name.includes('bash')) {
      const cmd = input.command || '';
      // Truncate long commands
      return cmd.length > 50 ? cmd.substring(0, 47) + '...' : cmd;
    }

    // Web operations
    if (name.includes('web') || name.includes('fetch')) {
      return input.url || '';
    }

    // Default: try common field names
    return input.file_path || input.path || input.pattern || input.query || '';
  }

  // ============================================================================
  // AGENTS TAB
  // ============================================================================

  private renderAgentsTab(container: HTMLElement): void {
    const header = container.createDiv({ cls: 'pilot-section-header' });
    header.createEl('h3', { text: 'Available Agents' });

    const refreshBtn = header.createEl('button', { text: 'Refresh', cls: 'pilot-btn-small' });
    refreshBtn.addEventListener('click', () => this.loadAgents());

    if (this.agents.length === 0) {
      container.createDiv({ cls: 'pilot-empty', text: 'No agents found in vault' });
      return;
    }

    // Group agents by type
    const docAgents = this.agents.filter(a => a.type === 'doc');
    const standaloneAgents = this.agents.filter(a => a.type === 'standalone');
    const chatbotAgents = this.agents.filter(a => a.type === 'chatbot' || !a.type);

    // Doc agents section
    if (docAgents.length > 0) {
      const section = container.createDiv({ cls: 'pilot-agent-section' });
      section.createEl('h4', { text: 'Document Agents', cls: 'pilot-section-title' });
      section.createEl('p', { text: 'Run on the current document', cls: 'pilot-section-hint' });

      for (const agent of docAgents) {
        this.renderAgentCard(section, agent, 'doc');
      }
    }

    // Standalone agents section
    if (standaloneAgents.length > 0) {
      const section = container.createDiv({ cls: 'pilot-agent-section' });
      section.createEl('h4', { text: 'Standalone Agents', cls: 'pilot-section-title' });
      section.createEl('p', { text: 'Run independently', cls: 'pilot-section-hint' });

      for (const agent of standaloneAgents) {
        this.renderAgentCard(section, agent, 'standalone');
      }
    }

    // Chatbot agents section
    if (chatbotAgents.length > 0) {
      const section = container.createDiv({ cls: 'pilot-agent-section' });
      section.createEl('h4', { text: 'Chatbot Agents', cls: 'pilot-section-title' });
      section.createEl('p', { text: 'Interactive conversation', cls: 'pilot-section-hint' });

      for (const agent of chatbotAgents) {
        this.renderAgentCard(section, agent, 'chatbot');
      }
    }
  }

  private renderAgentCard(container: HTMLElement, agent: AgentInfo, type: string): void {
    const card = container.createDiv({ cls: 'pilot-agent-card' });

    const cardHeader = card.createDiv({ cls: 'pilot-agent-header' });
    cardHeader.createEl('span', { text: agent.name, cls: 'pilot-agent-name' });

    const typeBadge = cardHeader.createEl('span', {
      cls: `pilot-type-badge pilot-type-${type}`,
      text: type
    });

    card.createEl('div', {
      cls: 'pilot-agent-desc',
      text: agent.description?.substring(0, 100) || 'No description'
    });

    const actions = card.createDiv({ cls: 'pilot-agent-actions' });

    switch (type) {
      case 'doc':
        const runDocBtn = actions.createEl('button', { text: 'Run on Current Doc', cls: 'pilot-btn-primary' });
        runDocBtn.addEventListener('click', () => this.runDocAgent(agent.path));
        break;

      case 'standalone':
        const runBtn = actions.createEl('button', { text: 'Run', cls: 'pilot-btn-primary' });
        runBtn.addEventListener('click', () => this.spawnAgent(agent.path));
        break;

      case 'chatbot':
      default:
        const chatBtn = actions.createEl('button', { text: 'Chat', cls: 'pilot-btn-primary' });
        chatBtn.addEventListener('click', () => {
          this.createSession(agent.path);
          this.currentTab = 'chat';
          this.render();
        });
        break;
    }
  }

  /**
   * Start a follow-up conversation from a completed agent run
   */
  private startFollowUp(item: QueueItem): void {
    // Create a new session for this follow-up
    const session = this.createSession(item.agentPath);

    // Build context message about what was processed
    let contextMsg = `Following up on ${item.agentPath.replace('agents/', '').replace('.md', '')}`;
    if (item.context?.documentPath) {
      contextMsg += ` for document: ${item.context.documentPath}`;
    }

    // Add system message about context
    session.messages.push({
      role: 'system',
      content: contextMsg,
      timestamp: new Date()
    });

    // Add the original result as assistant message
    if (item.result?.response) {
      session.messages.push({
        role: 'assistant',
        content: item.result.response,
        timestamp: new Date(item.completedAt || Date.now()),
        agentPath: item.agentPath
      });
    }

    // Switch to chat tab
    this.currentTab = 'chat';
    this.render();

    new Notice('Ready to follow up - type your message below');
  }

  private async runDocAgent(agentPath: string): Promise<void> {
    const activeFile = this.app.workspace.getActiveFile();
    if (!activeFile || !activeFile.path.endsWith('.md')) {
      new Notice('Please open a markdown file first');
      return;
    }

    try {
      // Read the document content
      const content = await this.app.vault.read(activeFile);

      // Create a chat session for this agent
      const session = this.createSession(agentPath);

      // Switch to chat tab to show streaming UI
      this.currentTab = 'chat';
      this.render();

      // Send the initial message with document context
      await this.sendMessageWithContext(
        `Process this document: ${activeFile.path}`,
        {
          documentPath: activeFile.path,
          documentContent: content
        }
      );
    } catch (e) {
      new Notice(`Error: ${(e as Error).message}`);
    }
  }

  private async loadAgents(): Promise<void> {
    try {
      const response = await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents`);
      this.agents = await response.json();
      // Always re-render to update agent dropdowns
      this.render();
    } catch (e) {
      console.error('Failed to load agents:', e);
    }
  }

  private async spawnAgent(agentPath: string): Promise<void> {
    try {
      const response = await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents/spawn`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ agentPath })
      });

      const data = await response.json();
      new Notice(`Agent queued: ${data.queueId?.substring(0, 8)}...`);

      // Switch to activity tab
      this.currentTab = 'activity';
      await this.refreshQueue();

    } catch (e) {
      new Notice(`Error: ${e.message}`);
    }
  }

  // ============================================================================
  // ACTIVITY TAB
  // ============================================================================

  private renderActivityTab(container: HTMLElement): void {
    const header = container.createDiv({ cls: 'pilot-section-header' });
    header.createEl('h3', { text: 'Agent Activity' });

    const refreshBtn = header.createEl('button', { text: 'Refresh', cls: 'pilot-btn-small' });
    refreshBtn.addEventListener('click', () => this.refreshQueue());

    // Running agents
    if (this.queueState.running.length > 0) {
      const runningSection = container.createDiv({ cls: 'pilot-section' });
      runningSection.createEl('h4', { text: `Running (${this.queueState.running.length})`, cls: 'pilot-section-title running' });

      for (const item of this.queueState.running) {
        this.renderQueueItem(runningSection, item, 'running');
      }
    }

    // Pending agents
    if (this.queueState.pending.length > 0) {
      const pendingSection = container.createDiv({ cls: 'pilot-section' });
      pendingSection.createEl('h4', { text: `Pending (${this.queueState.pending.length})`, cls: 'pilot-section-title pending' });

      for (const item of this.queueState.pending) {
        this.renderQueueItem(pendingSection, item, 'pending');
      }
    }

    // Completed agents
    const completedSection = container.createDiv({ cls: 'pilot-section' });
    completedSection.createEl('h4', { text: `Completed (${this.queueState.completed.length})`, cls: 'pilot-section-title completed' });

    if (this.queueState.completed.length === 0) {
      completedSection.createDiv({ cls: 'pilot-empty', text: 'No completed agents yet' });
    } else {
      // Show most recent first, limit to 10
      const recent = [...this.queueState.completed].reverse().slice(0, 10);
      for (const item of recent) {
        this.renderQueueItem(completedSection, item, 'completed');
      }
    }
  }

  private renderQueueItem(container: HTMLElement, item: QueueItem, status: string): void {
    const card = container.createDiv({ cls: `pilot-queue-item pilot-queue-${status}` });

    const cardHeader = card.createDiv({ cls: 'pilot-queue-header' });

    const agentName = item.agentPath.replace('agents/', '').replace('.md', '');
    cardHeader.createEl('span', { text: agentName, cls: 'pilot-queue-name' });

    const statusBadge = cardHeader.createEl('span', {
      cls: `pilot-status-badge pilot-status-${status}`,
      text: status
    });

    // Show spinner for running
    if (status === 'running') {
      statusBadge.addClass('pilot-spinning');
    }

    // Show target document for doc agents
    if (item.context?.documentPath) {
      card.createEl('div', {
        cls: 'pilot-queue-target',
        text: `→ ${item.context.documentPath}`
      });
    }

    // Timing info
    const timing = card.createDiv({ cls: 'pilot-queue-timing' });
    if (item.result?.durationMs) {
      timing.createEl('span', { text: `${(item.result.durationMs / 1000).toFixed(1)}s` });
    } else if (item.startedAt) {
      const elapsed = Math.floor((Date.now() - new Date(item.startedAt).getTime()) / 1000);
      timing.createEl('span', { text: `${elapsed}s elapsed...`, cls: 'pilot-elapsed' });
    }

    // Result preview for completed
    if (status === 'completed' && item.result?.response) {
      const preview = card.createDiv({ cls: 'pilot-queue-preview' });
      preview.createEl('div', {
        text: item.result.response.substring(0, 200) + (item.result.response.length > 200 ? '...' : ''),
        cls: 'pilot-preview-text'
      });

      // Action buttons
      const btnRow = card.createDiv({ cls: 'pilot-queue-actions' });

      // Expand button
      const expandBtn = btnRow.createEl('button', { text: 'View Full', cls: 'pilot-btn-small' });
      expandBtn.addEventListener('click', () => {
        new ResultModal(this.app, agentName, item.result!.response).open();
      });

      // Follow up button - continue the conversation
      const followUpBtn = btnRow.createEl('button', { text: 'Follow Up', cls: 'pilot-btn-small pilot-btn-followup' });
      followUpBtn.addEventListener('click', () => {
        this.startFollowUp(item);
      });
    }

    // Error for failed
    if (item.error) {
      card.createDiv({ cls: 'pilot-queue-error', text: `Error: ${item.error}` });
    }
  }

  private async refreshQueue(): Promise<void> {
    try {
      const response = await fetch(`${this.plugin.settings.orchestratorUrl}/api/queue`);
      const data = await response.json();

      this.queueState = {
        running: data.running || [],
        completed: data.completed || [],
        pending: data.pending || []
      };

      if (this.currentTab === 'activity') {
        // Preserve scroll position before re-render
        const content = this.containerEl.querySelector('.pilot-content');
        const scrollTop = content?.scrollTop || 0;

        this.render();

        // Restore scroll position after re-render
        const newContent = this.containerEl.querySelector('.pilot-content');
        if (newContent) {
          newContent.scrollTop = scrollTop;
        }
      } else {
        // Just update the badge
        const tabs = this.containerEl.querySelector('.pilot-tabs');
        if (tabs) {
          const activityTab = tabs.querySelectorAll('.pilot-tab')[2];
          const badge = activityTab?.querySelector('.pilot-badge');
          if (badge) {
            badge.textContent = String(this.queueState.running.length);
            badge.toggleClass('hidden', this.queueState.running.length === 0);
          }
        }
      }

    } catch (e) {
      console.error('Failed to refresh queue:', e);
    }
  }

  // ============================================================================
  // STYLES
  // ============================================================================

  private addStyles(): void {
    const styleId = 'agent-pilot-styles';
    if (document.getElementById(styleId)) return;

    const style = document.createElement('style');
    style.id = styleId;
    style.textContent = `
      .agent-pilot-view {
        display: flex;
        flex-direction: column;
        height: 100%;
      }

      /* Enable text selection - use !important to override Obsidian defaults */
      .agent-pilot-view,
      .agent-pilot-view *,
      .agent-pilot-view .pilot-message-content,
      .agent-pilot-view .pilot-markdown,
      .agent-pilot-view .pilot-markdown * {
        -webkit-user-select: text !important;
        user-select: text !important;
        cursor: auto;
      }

      /* Keep buttons non-selectable for better UX */
      .agent-pilot-view button,
      .agent-pilot-view .pilot-tab,
      .agent-pilot-view .pilot-send-btn {
        -webkit-user-select: none !important;
        user-select: none !important;
        cursor: pointer;
      }

      .pilot-header {
        padding: 8px;
        border-bottom: 1px solid var(--background-modifier-border);
      }

      .pilot-tabs {
        display: flex;
        gap: 4px;
      }

      .pilot-tab {
        flex: 1;
        padding: 8px 12px;
        background: var(--background-secondary);
        border: none;
        border-radius: 4px;
        cursor: pointer;
        font-size: 13px;
        position: relative;
      }

      .pilot-tab.active {
        background: var(--interactive-accent);
        color: var(--text-on-accent);
      }

      .pilot-badge {
        position: absolute;
        top: -4px;
        right: -4px;
        background: var(--text-error);
        color: white;
        font-size: 10px;
        padding: 2px 6px;
        border-radius: 10px;
        min-width: 16px;
        text-align: center;
      }

      .pilot-badge.hidden {
        display: none;
      }

      .pilot-content {
        flex: 1;
        overflow-y: auto;
        padding: 12px;
      }

      /* Chat layout with sessions */
      .pilot-chat-layout {
        display: flex;
        flex-direction: column;
        height: 100%;
        gap: 8px;
      }

      .pilot-session-list {
        display: flex;
        gap: 8px;
        align-items: center;
        flex-wrap: wrap;
        padding-bottom: 8px;
        border-bottom: 1px solid var(--background-modifier-border);
      }

      .pilot-new-chat-btn {
        padding: 6px 12px;
        background: var(--interactive-accent);
        color: var(--text-on-accent);
        border: none;
        border-radius: 6px;
        cursor: pointer;
        font-size: 12px;
        white-space: nowrap;
      }

      .pilot-sessions {
        display: flex;
        gap: 6px;
        flex-wrap: wrap;
        flex: 1;
      }

      .pilot-sessions-empty {
        color: var(--text-muted);
        font-size: 11px;
        padding: 4px 8px;
      }

      .pilot-session-item {
        display: flex;
        align-items: center;
        gap: 6px;
        padding: 6px 10px;
        background: var(--background-secondary);
        border-radius: 6px;
        cursor: pointer;
        font-size: 12px;
        border: 2px solid transparent;
      }

      .pilot-session-item:hover {
        background: var(--background-modifier-hover);
      }

      .pilot-session-item.active {
        border-color: var(--interactive-accent);
        background: var(--background-secondary-alt);
      }

      .pilot-session-info {
        display: flex;
        align-items: center;
        gap: 6px;
      }

      .pilot-session-name {
        font-weight: 500;
        white-space: nowrap;
      }

      .pilot-session-count {
        font-size: 10px;
        opacity: 0.6;
      }

      .pilot-session-delete {
        background: none;
        border: none;
        color: inherit;
        opacity: 0.4;
        cursor: pointer;
        padding: 0;
        font-size: 14px;
        line-height: 1;
      }

      .pilot-session-delete:hover {
        opacity: 1;
      }

      /* Session action buttons */
      .pilot-session-actions {
        display: flex;
        gap: 4px;
        margin-left: auto;
        opacity: 0;
        transition: opacity 0.15s;
      }

      .pilot-session-item:hover .pilot-session-actions {
        opacity: 1;
      }

      .pilot-session-action {
        background: none;
        border: none;
        cursor: pointer;
        padding: 2px 4px;
        font-size: 12px;
        opacity: 0.6;
        border-radius: 4px;
      }

      .pilot-session-action:hover {
        opacity: 1;
        background: var(--background-modifier-hover);
      }

      .pilot-session-action-delete:hover {
        color: var(--text-error);
      }

      .pilot-session-archived {
        opacity: 0.7;
      }

      /* Archived section */
      .pilot-archived-section {
        width: 100%;
        margin-top: 8px;
        padding-top: 8px;
        border-top: 1px solid var(--background-modifier-border);
      }

      .pilot-archived-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 6px 10px;
        cursor: pointer;
        font-size: 11px;
        color: var(--text-muted);
        border-radius: 4px;
      }

      .pilot-archived-header:hover {
        background: var(--background-modifier-hover);
      }

      .pilot-archived-label {
        font-weight: 500;
      }

      .pilot-archived-toggle {
        font-size: 10px;
      }

      .pilot-archived-list {
        display: flex;
        flex-direction: column;
        gap: 4px;
        margin-top: 6px;
      }

      .pilot-chat-area {
        flex: 1;
        display: flex;
        flex-direction: column;
        min-height: 0;
      }

      .pilot-welcome {
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        flex: 1;
        text-align: center;
        padding: 20px;
      }

      .pilot-welcome h3 {
        margin: 0 0 8px 0;
      }

      .pilot-welcome-hint {
        color: var(--text-muted);
        margin-bottom: 16px;
      }

      .pilot-agent-grid {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
        justify-content: center;
      }

      .pilot-agent-pick {
        display: flex;
        flex-direction: column;
        padding: 12px 16px;
        background: var(--background-secondary);
        border-radius: 8px;
        cursor: pointer;
        min-width: 100px;
        max-width: 160px;
        border: 2px solid transparent;
      }

      .pilot-agent-pick:hover {
        border-color: var(--interactive-accent);
      }

      .pilot-pick-name {
        font-weight: 600;
        margin-bottom: 4px;
        font-size: 13px;
      }

      .pilot-pick-desc {
        font-size: 10px;
        color: var(--text-muted);
        overflow: hidden;
        text-overflow: ellipsis;
        display: -webkit-box;
        -webkit-line-clamp: 2;
        -webkit-box-orient: vertical;
      }

      .pilot-session-header {
        padding: 8px 0;
        margin-bottom: 8px;
        border-bottom: 1px solid var(--background-modifier-border);
      }

      .pilot-session-title {
        font-weight: 600;
        font-size: 14px;
      }

      .pilot-session-desc {
        font-size: 11px;
        color: var(--text-muted);
        margin-top: 2px;
      }

      /* Chat styles */
      .pilot-selector-row {
        display: flex;
        align-items: center;
        gap: 8px;
        margin-bottom: 12px;
      }

      .pilot-label {
        font-size: 12px;
        color: var(--text-muted);
      }

      .pilot-select {
        flex: 1;
        padding: 4px 8px;
        border-radius: 4px;
        background: var(--background-secondary);
        border: 1px solid var(--background-modifier-border);
      }

      .pilot-messages {
        flex: 1;
        min-height: 100px;
        overflow-y: auto;
        margin-bottom: 12px;
        padding-right: 4px;
      }

      .pilot-message {
        margin-bottom: 12px;
        padding: 10px 12px;
        border-radius: 8px;
        max-width: 90%;
      }

      .pilot-message-user {
        background: var(--interactive-accent);
        color: var(--text-on-accent);
        margin-left: auto;
      }

      .pilot-message-assistant {
        background: var(--background-secondary);
      }

      .pilot-message-system {
        background: var(--background-modifier-border);
        font-size: 12px;
        opacity: 0.8;
        text-align: center;
        margin: 8px auto;
        max-width: 100%;
      }

      .pilot-message-agent {
        font-size: 11px;
        opacity: 0.7;
        margin-bottom: 4px;
      }

      .pilot-message-content {
        word-break: break-word;
      }

      /* User messages use pre-wrap for plain text */
      .pilot-message-user .pilot-message-content {
        white-space: pre-wrap;
      }

      /* Rendered markdown container */
      .pilot-markdown {
        line-height: 1.5;
      }

      .pilot-markdown > *:first-child {
        margin-top: 0;
      }

      .pilot-markdown > *:last-child {
        margin-bottom: 0;
      }

      .pilot-message-content p {
        margin: 0 0 8px 0;
      }

      .pilot-message-content p:last-child {
        margin-bottom: 0;
      }

      .pilot-message-content code {
        background: var(--background-primary);
        padding: 2px 6px;
        border-radius: 4px;
        font-size: 12px;
      }

      .pilot-message-content pre {
        background: var(--background-primary);
        padding: 12px;
        border-radius: 6px;
        overflow-x: auto;
        margin: 8px 0;
      }

      .pilot-message-content pre code {
        background: none;
        padding: 0;
      }

      /* Tool calls display */
      .pilot-tool-calls-container {
        margin-bottom: 8px;
      }

      .pilot-tool-calls-header {
        display: flex;
        align-items: center;
        gap: 6px;
        padding: 4px 8px;
        cursor: pointer;
        color: var(--text-muted);
        font-size: 12px;
        border-radius: 4px;
      }

      .pilot-tool-calls-header:hover {
        background: var(--background-modifier-hover);
      }

      .pilot-tool-calls-icon {
        font-size: 10px;
        width: 12px;
      }

      .pilot-tool-calls-label {
        font-weight: 500;
      }

      .pilot-tool-calls {
        display: flex;
        flex-direction: column;
        gap: 4px;
        padding-left: 8px;
        margin-top: 4px;
      }

      .pilot-tool-calls-collapsed {
        display: none;
      }

      .pilot-tool-call {
        display: flex;
        align-items: center;
        padding: 6px 10px;
        background: var(--background-primary);
        border-radius: 6px;
        border-left: 3px solid var(--interactive-accent);
        font-size: 12px;
      }

      .pilot-tool-header {
        display: flex;
        align-items: center;
        gap: 6px;
        flex-wrap: wrap;
      }

      .pilot-tool-icon {
        font-size: 12px;
        opacity: 0.8;
      }

      .pilot-tool-name {
        font-weight: 600;
        color: var(--interactive-accent);
      }

      .pilot-tool-input {
        color: var(--text-muted);
        font-family: monospace;
        font-size: 11px;
        max-width: 200px;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      /* Sequential stream rendering styles */
      .pilot-stream-tool {
        margin: 8px 0;
        border-radius: 6px;
        background: var(--background-primary);
        border-left: 3px solid var(--interactive-accent);
        overflow: hidden;
      }

      .pilot-stream-tool-header {
        display: flex;
        align-items: center;
        gap: 6px;
        padding: 6px 10px;
        cursor: pointer;
        font-size: 12px;
      }

      .pilot-stream-tool-header:hover {
        background: var(--background-modifier-hover);
      }

      .pilot-stream-tool-icon {
        font-size: 10px;
        width: 12px;
        color: var(--text-muted);
      }

      .pilot-stream-tool-name {
        font-weight: 600;
        color: var(--interactive-accent);
      }

      .pilot-stream-tool-input {
        color: var(--text-muted);
        font-family: monospace;
        font-size: 11px;
        max-width: 200px;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .pilot-stream-tool-details {
        padding: 8px 10px;
        border-top: 1px solid var(--background-modifier-border);
        background: var(--background-secondary);
      }

      .pilot-stream-tool-details.pilot-collapsed {
        display: none;
      }

      .pilot-stream-tool-json {
        margin: 0;
        padding: 8px;
        background: var(--background-primary);
        border-radius: 4px;
        font-size: 10px;
        overflow-x: auto;
        max-height: 150px;
        overflow-y: auto;
      }

      .pilot-stream-text {
        margin: 4px 0;
      }

      .pilot-collapsed {
        display: none;
      }

      /* Debug panel styles */
      .pilot-debug-container {
        margin-top: 8px;
      }

      .pilot-debug-toggle {
        background: none;
        border: 1px solid var(--background-modifier-border);
        border-radius: 4px;
        padding: 2px 8px;
        font-size: 10px;
        color: var(--text-muted);
        cursor: pointer;
        opacity: 0.6;
      }

      .pilot-debug-toggle:hover {
        opacity: 1;
        background: var(--background-primary);
      }

      .pilot-debug-toggle.pilot-debug-expanded {
        opacity: 1;
        border-color: var(--interactive-accent);
      }

      .pilot-debug-content {
        margin-top: 6px;
        padding: 8px;
        background: var(--background-primary);
        border-radius: 4px;
        font-size: 11px;
        font-family: monospace;
      }

      .pilot-debug-hidden {
        display: none;
      }

      .pilot-debug-line {
        color: var(--text-muted);
        margin-bottom: 2px;
      }

      .pilot-debug-tools {
        margin-top: 4px;
        padding-top: 4px;
        border-top: 1px solid var(--background-modifier-border);
        word-break: break-word;
      }

      /* Permission denial summary */
      .pilot-permission-denials {
        margin-top: 6px;
      }

      .pilot-permission-summary {
        font-size: 11px;
        color: var(--text-warning);
      }

      .pilot-message-footer {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-top: 4px;
      }

      .pilot-message-time {
        font-size: 10px;
        opacity: 0.5;
      }

      .pilot-copy-btn {
        background: none;
        border: none;
        padding: 2px 6px;
        cursor: pointer;
        opacity: 0.4;
        font-size: 12px;
        border-radius: 4px;
        transition: opacity 0.2s, background 0.2s;
      }

      .pilot-copy-btn:hover {
        opacity: 1;
        background: var(--background-modifier-hover);
      }

      /* Inline permission request styles */
      .pilot-permission-request {
        background: rgba(255, 200, 0, 0.1) !important;
        border: 1px solid rgba(255, 200, 0, 0.3) !important;
      }

      .pilot-permission-title {
        font-weight: 600;
        margin-bottom: 8px;
      }

      .pilot-permission-desc {
        font-size: 12px;
        color: var(--text-muted);
        margin-bottom: 4px;
      }

      .pilot-permission-path {
        font-family: monospace;
        font-size: 12px;
        color: var(--text-accent);
        word-break: break-all;
        margin-bottom: 4px;
        padding: 4px 8px;
        background: var(--background-primary);
        border-radius: 4px;
      }

      .pilot-permission-allowed {
        font-size: 11px;
        color: var(--text-muted);
        margin-bottom: 12px;
      }

      .pilot-permission-actions {
        display: flex;
        gap: 8px;
      }

      .pilot-permission-deny {
        padding: 6px 16px;
        border: 1px solid var(--background-modifier-border);
        border-radius: 4px;
        background: var(--background-secondary);
        cursor: pointer;
      }

      .pilot-permission-deny:hover {
        background: var(--background-modifier-hover);
      }

      .pilot-permission-allow {
        padding: 6px 16px;
        border: none;
        border-radius: 4px;
        background: var(--interactive-accent);
        color: var(--text-on-accent);
        cursor: pointer;
      }

      .pilot-permission-allow:hover {
        opacity: 0.9;
      }

      .pilot-message-loading {
        background: var(--background-secondary);
        padding: 16px;
      }

      .pilot-typing-indicator {
        display: inline-flex;
        gap: 6px;
        align-items: center;
        padding: 4px 0;
      }

      .pilot-typing-indicator::before {
        content: '●  ●  ●';
        font-size: 14px;
        color: var(--text-muted);
        animation: typing-pulse 1.4s infinite ease-in-out;
        letter-spacing: 2px;
      }

      @keyframes typing-pulse {
        0%, 100% {
          opacity: 0.3;
        }
        50% {
          opacity: 1;
        }
      }

      .pilot-agent-info {
        padding: 8px 12px;
        background: var(--background-secondary);
        border-radius: 6px;
        margin-bottom: 12px;
        font-size: 12px;
      }

      .pilot-agent-description {
        color: var(--text-muted);
        font-style: italic;
      }

      .pilot-input-disabled {
        opacity: 0.6;
        cursor: not-allowed;
      }

      .pilot-send-disabled {
        opacity: 0.6;
        cursor: not-allowed;
      }

      .pilot-input-area {
        display: flex;
        gap: 8px;
        align-items: flex-end;
      }

      .pilot-input {
        flex: 1;
        min-height: 44px;
        max-height: 120px;
        padding: 10px 12px;
        border-radius: 8px;
        background: var(--background-secondary);
        border: 1px solid var(--background-modifier-border);
        resize: none;
        font-size: 14px;
        line-height: 1.4;
      }

      .pilot-input:focus {
        outline: none;
        border-color: var(--interactive-accent);
      }

      .pilot-send {
        padding: 10px 20px;
        background: var(--interactive-accent);
        color: var(--text-on-accent);
        border: none;
        border-radius: 8px;
        cursor: pointer;
        font-size: 13px;
        font-weight: 500;
        white-space: nowrap;
      }

      .pilot-send:hover {
        opacity: 0.9;
      }

      /* Agent cards */
      .pilot-section-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 12px;
      }

      .pilot-section-header h3 {
        margin: 0;
        font-size: 14px;
      }

      .pilot-agent-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }

      .pilot-agent-card {
        padding: 12px;
        background: var(--background-secondary);
        border-radius: 8px;
        border: 1px solid var(--background-modifier-border);
      }

      .pilot-agent-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 8px;
      }

      .pilot-agent-name {
        font-weight: 600;
      }

      .pilot-type-badge {
        font-size: 10px;
        padding: 2px 8px;
        border-radius: 10px;
        text-transform: uppercase;
      }

      .pilot-type-chatbot {
        background: var(--interactive-accent);
        color: var(--text-on-accent);
      }

      .pilot-type-doc {
        background: #22c55e;
        color: white;
      }

      .pilot-type-standalone {
        background: #f59e0b;
        color: white;
      }

      .pilot-agent-section {
        margin-bottom: 20px;
      }

      .pilot-section-hint {
        font-size: 11px;
        color: var(--text-muted);
        margin-bottom: 8px;
      }

      .pilot-agent-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }

      .pilot-agent-desc {
        font-size: 12px;
        color: var(--text-muted);
        margin-bottom: 8px;
      }

      .pilot-agent-path {
        font-size: 11px;
        font-family: monospace;
        opacity: 0.6;
        margin-bottom: 8px;
      }

      .pilot-agent-actions {
        display: flex;
        gap: 8px;
      }

      /* Activity/Queue styles */
      .pilot-section {
        margin-bottom: 16px;
      }

      .pilot-section-title {
        font-size: 12px;
        text-transform: uppercase;
        margin-bottom: 8px;
        padding-bottom: 4px;
        border-bottom: 2px solid var(--background-modifier-border);
      }

      .pilot-section-title.running {
        border-color: var(--text-accent);
        color: var(--text-accent);
      }

      .pilot-section-title.completed {
        border-color: var(--text-success);
        color: var(--text-success);
      }

      .pilot-section-title.pending {
        border-color: var(--text-muted);
      }

      .pilot-queue-item {
        padding: 10px;
        background: var(--background-secondary);
        border-radius: 6px;
        margin-bottom: 8px;
        border-left: 3px solid var(--background-modifier-border);
      }

      .pilot-queue-running {
        border-left-color: var(--text-accent);
      }

      .pilot-queue-completed {
        border-left-color: var(--text-success);
      }

      .pilot-queue-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 4px;
      }

      .pilot-queue-name {
        font-weight: 500;
      }

      .pilot-status-badge {
        font-size: 10px;
        padding: 2px 8px;
        border-radius: 10px;
      }

      .pilot-status-running {
        background: var(--text-accent);
        color: white;
      }

      .pilot-status-completed {
        background: var(--text-success);
        color: white;
      }

      .pilot-status-pending {
        background: var(--text-muted);
        color: white;
      }

      .pilot-spinning::before {
        content: '';
        display: inline-block;
        width: 8px;
        height: 8px;
        border: 2px solid white;
        border-top-color: transparent;
        border-radius: 50%;
        margin-right: 4px;
        animation: spin 1s linear infinite;
      }

      @keyframes spin {
        to { transform: rotate(360deg); }
      }

      .pilot-queue-timing {
        font-size: 11px;
        color: var(--text-muted);
      }

      .pilot-elapsed {
        color: var(--text-accent);
      }

      .pilot-queue-preview {
        margin-top: 8px;
        padding: 8px;
        background: var(--background-primary);
        border-radius: 4px;
        font-size: 12px;
      }

      .pilot-preview-text {
        color: var(--text-muted);
        white-space: pre-wrap;
      }

      .pilot-queue-error {
        margin-top: 8px;
        padding: 8px;
        background: rgba(255, 0, 0, 0.1);
        border-radius: 4px;
        font-size: 12px;
        color: var(--text-error);
      }

      .pilot-queue-target {
        font-size: 11px;
        color: var(--text-muted);
        font-family: monospace;
        margin-top: 4px;
      }

      .pilot-queue-actions {
        display: flex;
        gap: 8px;
        margin-top: 8px;
      }

      .pilot-btn-followup {
        background: var(--interactive-accent);
        color: var(--text-on-accent);
      }

      /* Buttons */
      .pilot-btn-small {
        padding: 4px 12px;
        font-size: 11px;
        background: var(--background-modifier-border);
        border: none;
        border-radius: 4px;
        cursor: pointer;
      }

      .pilot-btn-primary {
        padding: 6px 16px;
        background: var(--interactive-accent);
        color: var(--text-on-accent);
        border: none;
        border-radius: 4px;
        cursor: pointer;
      }

      .pilot-empty {
        text-align: center;
        color: var(--text-muted);
        padding: 20px;
        font-size: 13px;
      }
    `;
    document.head.appendChild(style);
  }
}

// ============================================================================
// RESULT MODAL
// ============================================================================

class ResultModal extends Modal {
  private agentName: string;
  private response: string;

  constructor(app: App, agentName: string, response: string) {
    super(app);
    this.agentName = agentName;
    this.response = response;
  }

  onOpen(): void {
    const { contentEl } = this;
    contentEl.empty();

    contentEl.createEl('h2', { text: `${this.agentName} Result` });

    const responseEl = contentEl.createDiv({ cls: 'result-response' });
    responseEl.style.cssText = `
      white-space: pre-wrap;
      background: var(--background-secondary);
      padding: 16px;
      border-radius: 8px;
      max-height: 400px;
      overflow-y: auto;
      font-size: 13px;
    `;
    responseEl.textContent = this.response;

    const closeBtn = contentEl.createEl('button', { text: 'Close' });
    closeBtn.style.cssText = `margin-top: 16px; padding: 8px 24px;`;
    closeBtn.addEventListener('click', () => this.close());
  }

  onClose(): void {
    const { contentEl } = this;
    contentEl.empty();
  }
}

// ============================================================================
// MCP SERVER MANAGEMENT
// ============================================================================

interface McpServer {
  name: string;
  command?: string;
  args?: string[];
  type?: string;
  url?: string;
  displayType: string;
  displayCommand: string;
}

class McpServerModal extends Modal {
  private plugin: AgentPilotPlugin;
  private serverName: string = '';
  private serverType: 'stdio' | 'sse' = 'stdio';
  private command: string = '';
  private args: string = '';
  private url: string = '';
  private isEdit: boolean = false;
  private onSave: () => void;

  constructor(app: App, plugin: AgentPilotPlugin, onSave: () => void, existing?: McpServer) {
    super(app);
    this.plugin = plugin;
    this.onSave = onSave;
    if (existing) {
      this.isEdit = true;
      this.serverName = existing.name;
      if (existing.command) {
        this.serverType = 'stdio';
        this.command = existing.command;
        this.args = (existing.args || []).join(' ');
      } else if (existing.url) {
        this.serverType = 'sse';
        this.url = existing.url;
      }
    }
  }

  onOpen(): void {
    const { contentEl } = this;
    contentEl.empty();
    contentEl.addClass('mcp-server-modal');

    contentEl.createEl('h2', { text: this.isEdit ? 'Edit MCP Server' : 'Add MCP Server' });

    // Server Name
    const nameContainer = contentEl.createDiv({ cls: 'setting-item' });
    nameContainer.createEl('div', { cls: 'setting-item-info' })
      .createEl('div', { cls: 'setting-item-name', text: 'Server Name' });
    const nameInput = nameContainer.createEl('input', {
      type: 'text',
      placeholder: 'e.g., browser',
      value: this.serverName
    });
    nameInput.style.width = '100%';
    if (this.isEdit) nameInput.disabled = true;
    nameInput.addEventListener('input', (e) => {
      this.serverName = (e.target as HTMLInputElement).value;
    });

    // Server Type
    const typeContainer = contentEl.createDiv({ cls: 'setting-item' });
    typeContainer.createEl('div', { cls: 'setting-item-info' })
      .createEl('div', { cls: 'setting-item-name', text: 'Server Type' });
    const typeSelect = typeContainer.createEl('select');
    typeSelect.style.width = '100%';
    const stdioOption = typeSelect.createEl('option', { text: 'Stdio (command)', value: 'stdio' });
    const sseOption = typeSelect.createEl('option', { text: 'SSE (URL)', value: 'sse' });
    if (this.serverType === 'sse') sseOption.selected = true;
    else stdioOption.selected = true;

    // Stdio fields container
    const stdioContainer = contentEl.createDiv({ cls: 'mcp-stdio-fields' });

    const cmdContainer = stdioContainer.createDiv({ cls: 'setting-item' });
    cmdContainer.createEl('div', { cls: 'setting-item-info' })
      .createEl('div', { cls: 'setting-item-name', text: 'Command' });
    const cmdInput = cmdContainer.createEl('input', {
      type: 'text',
      placeholder: 'e.g., npx',
      value: this.command
    });
    cmdInput.style.width = '100%';
    cmdInput.addEventListener('input', (e) => {
      this.command = (e.target as HTMLInputElement).value;
    });

    const argsContainer = stdioContainer.createDiv({ cls: 'setting-item' });
    argsContainer.createEl('div', { cls: 'setting-item-info' })
      .createEl('div', { cls: 'setting-item-name', text: 'Arguments (space-separated)' });
    const argsInput = argsContainer.createEl('input', {
      type: 'text',
      placeholder: 'e.g., @browsermcp/mcp@latest',
      value: this.args
    });
    argsInput.style.width = '100%';
    argsInput.addEventListener('input', (e) => {
      this.args = (e.target as HTMLInputElement).value;
    });

    // SSE fields container
    const sseContainer = contentEl.createDiv({ cls: 'mcp-sse-fields' });

    const urlContainer = sseContainer.createDiv({ cls: 'setting-item' });
    urlContainer.createEl('div', { cls: 'setting-item-info' })
      .createEl('div', { cls: 'setting-item-name', text: 'Server URL' });
    const urlInput = urlContainer.createEl('input', {
      type: 'text',
      placeholder: 'e.g., http://localhost:8080',
      value: this.url
    });
    urlInput.style.width = '100%';
    urlInput.addEventListener('input', (e) => {
      this.url = (e.target as HTMLInputElement).value;
    });

    // Show/hide based on type
    const updateVisibility = () => {
      if (this.serverType === 'stdio') {
        stdioContainer.style.display = 'block';
        sseContainer.style.display = 'none';
      } else {
        stdioContainer.style.display = 'none';
        sseContainer.style.display = 'block';
      }
    };
    updateVisibility();

    typeSelect.addEventListener('change', (e) => {
      this.serverType = (e.target as HTMLSelectElement).value as 'stdio' | 'sse';
      updateVisibility();
    });

    // Buttons
    const buttonContainer = contentEl.createDiv({ cls: 'modal-button-container' });
    buttonContainer.style.marginTop = '16px';
    buttonContainer.style.display = 'flex';
    buttonContainer.style.justifyContent = 'flex-end';
    buttonContainer.style.gap = '8px';

    const cancelBtn = buttonContainer.createEl('button', { text: 'Cancel' });
    cancelBtn.addEventListener('click', () => this.close());

    const saveBtn = buttonContainer.createEl('button', { text: 'Save', cls: 'mod-cta' });
    saveBtn.addEventListener('click', async () => {
      if (!this.serverName.trim()) {
        new Notice('Server name is required');
        return;
      }

      let config: any;
      if (this.serverType === 'stdio') {
        if (!this.command.trim()) {
          new Notice('Command is required');
          return;
        }
        config = {
          command: this.command.trim(),
          args: this.args.trim() ? this.args.trim().split(/\s+/) : []
        };
      } else {
        if (!this.url.trim()) {
          new Notice('URL is required');
          return;
        }
        config = {
          type: 'sse',
          url: this.url.trim()
        };
      }

      try {
        const response = await fetch(
          `${this.plugin.settings.orchestratorUrl}/api/mcp/${encodeURIComponent(this.serverName.trim())}`,
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(config)
          }
        );

        if (!response.ok) {
          const err = await response.json();
          throw new Error(err.error || 'Failed to save server');
        }

        new Notice(`MCP server "${this.serverName}" saved`);
        this.onSave();
        this.close();
      } catch (e) {
        new Notice(`Error: ${e.message}`);
      }
    });

    // Add styles
    const style = contentEl.createEl('style');
    style.textContent = `
      .mcp-server-modal .setting-item { margin-bottom: 12px; }
      .mcp-server-modal .setting-item-name { font-weight: 500; margin-bottom: 4px; }
      .mcp-server-modal input, .mcp-server-modal select {
        padding: 8px;
        border-radius: 4px;
        border: 1px solid var(--background-modifier-border);
      }
    `;
  }

  onClose(): void {
    this.contentEl.empty();
  }
}

// ============================================================================
// SETTINGS TAB
// ============================================================================

class AgentPilotSettingTab extends PluginSettingTab {
  plugin: AgentPilotPlugin;

  constructor(app: App, plugin: AgentPilotPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();

    containerEl.createEl('h2', { text: 'Agent Pilot Settings' });

    new Setting(containerEl)
      .setName('Orchestrator URL')
      .setDesc('URL of your Agent Pilot orchestrator server')
      .addText(text => text
        .setPlaceholder('http://localhost:3333')
        .setValue(this.plugin.settings.orchestratorUrl)
        .onChange(async (value) => {
          this.plugin.settings.orchestratorUrl = value;
          await this.plugin.saveSettings();
        }));

    new Setting(containerEl)
      .setName('Auto-refresh Activity')
      .setDesc('Automatically refresh agent activity status')
      .addToggle(toggle => toggle
        .setValue(this.plugin.settings.autoRefreshQueue)
        .onChange(async (value) => {
          this.plugin.settings.autoRefreshQueue = value;
          await this.plugin.saveSettings();
        }));

    new Setting(containerEl)
      .setName('Refresh Interval')
      .setDesc('How often to refresh activity (in milliseconds)')
      .addText(text => text
        .setValue(String(this.plugin.settings.refreshInterval))
        .onChange(async (value) => {
          this.plugin.settings.refreshInterval = parseInt(value) || 3000;
          await this.plugin.saveSettings();
        }));

    // Connection test
    const testContainer = containerEl.createDiv({ cls: 'setting-item' });
    const testBtn = testContainer.createEl('button', { text: 'Test Connection' });
    const statusEl = testContainer.createEl('span');
    statusEl.style.marginLeft = '10px';

    testBtn.addEventListener('click', async () => {
      statusEl.textContent = 'Testing...';
      try {
        const response = await fetch(`${this.plugin.settings.orchestratorUrl}/api/vault`);
        if (response.ok) {
          const data = await response.json();
          statusEl.textContent = `Connected! ${data.totalDocuments} docs, ${data.totalAgents} agents`;
          statusEl.style.color = 'var(--text-success)';
        } else {
          throw new Error(`HTTP ${response.status}`);
        }
      } catch (e) {
        statusEl.textContent = `Failed: ${e.message}`;
        statusEl.style.color = 'var(--text-error)';
      }
    });

    // MCP Servers section
    containerEl.createEl('h2', { text: 'MCP Servers', cls: 'mcp-settings-header' });
    containerEl.createEl('p', {
      text: 'Configure MCP servers for browser automation and other capabilities. These are stored in .mcp.json at your vault root.',
      cls: 'setting-item-description'
    });

    const mcpContainer = containerEl.createDiv({ cls: 'mcp-servers-container' });
    const mcpListEl = mcpContainer.createDiv({ cls: 'mcp-servers-list' });

    // Add Server button
    const addBtnContainer = containerEl.createDiv({ cls: 'mcp-add-container' });
    const addBtn = addBtnContainer.createEl('button', { text: 'Add MCP Server', cls: 'mod-cta' });
    addBtn.addEventListener('click', () => {
      new McpServerModal(this.app, this.plugin, () => this.loadMcpServers(mcpListEl)).open();
    });

    // Load servers initially
    this.loadMcpServers(mcpListEl);

    // Add styles for MCP section
    const mcpStyle = containerEl.createEl('style');
    mcpStyle.textContent = `
      .mcp-settings-header { margin-top: 32px; }
      .mcp-servers-list { margin: 16px 0; }
      .mcp-server-item {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 12px;
        background: var(--background-secondary);
        border-radius: 6px;
        margin-bottom: 8px;
      }
      .mcp-server-info { flex: 1; }
      .mcp-server-name { font-weight: 600; }
      .mcp-server-details { font-size: 12px; color: var(--text-muted); margin-top: 4px; }
      .mcp-server-actions { display: flex; gap: 8px; }
      .mcp-server-actions button { padding: 4px 8px; font-size: 12px; }
      .mcp-add-container { margin-top: 8px; }
      .mcp-empty { color: var(--text-muted); font-style: italic; padding: 16px; text-align: center; }
    `;
  }

  private async loadMcpServers(listEl: HTMLElement): Promise<void> {
    listEl.empty();

    try {
      const response = await fetch(`${this.plugin.settings.orchestratorUrl}/api/mcp`);
      if (!response.ok) throw new Error('Failed to fetch MCP servers');

      const servers: McpServer[] = await response.json();

      if (servers.length === 0) {
        listEl.createDiv({ cls: 'mcp-empty', text: 'No MCP servers configured yet.' });
        return;
      }

      for (const server of servers) {
        const itemEl = listEl.createDiv({ cls: 'mcp-server-item' });

        const infoEl = itemEl.createDiv({ cls: 'mcp-server-info' });
        infoEl.createDiv({ cls: 'mcp-server-name', text: server.name });
        infoEl.createDiv({
          cls: 'mcp-server-details',
          text: `${server.displayType}: ${server.displayCommand}`
        });

        const actionsEl = itemEl.createDiv({ cls: 'mcp-server-actions' });

        const editBtn = actionsEl.createEl('button', { text: 'Edit' });
        editBtn.addEventListener('click', () => {
          new McpServerModal(this.app, this.plugin, () => this.loadMcpServers(listEl), server).open();
        });

        const deleteBtn = actionsEl.createEl('button', { text: 'Delete', cls: 'mod-warning' });
        deleteBtn.addEventListener('click', async () => {
          if (confirm(`Delete MCP server "${server.name}"?`)) {
            try {
              await fetch(
                `${this.plugin.settings.orchestratorUrl}/api/mcp/${encodeURIComponent(server.name)}`,
                { method: 'DELETE' }
              );
              new Notice(`Deleted MCP server "${server.name}"`);
              this.loadMcpServers(listEl);
            } catch (e) {
              new Notice(`Error: ${e.message}`);
            }
          }
        });
      }
    } catch (e) {
      listEl.createDiv({
        cls: 'mcp-empty',
        text: `Error loading servers: ${e.message}. Make sure the orchestrator is running.`
      });
    }
  }
}

// ============================================================================
// MAIN PLUGIN
// ============================================================================

export default class AgentPilotPlugin extends Plugin {
  settings: AgentPilotSettings;

  async onload(): Promise<void> {
    await this.loadSettings();

    // Register main view
    this.registerView(
      PILOT_VIEW_TYPE,
      (leaf) => new AgentPilotView(leaf, this)
    );

    // Add ribbon icon
    this.addRibbonIcon('bot', 'Agent Pilot', () => {
      this.activateView();
    });

    // Commands
    this.addCommand({
      id: 'open-pilot',
      name: 'Open Agent Pilot',
      callback: () => this.activateView()
    });

    this.addCommand({
      id: 'run-agent',
      name: 'Run Agent',
      callback: () => new QuickSpawnModal(this.app, this).open()
    });

    this.addCommand({
      id: 'run-agents',
      name: 'Run Agents on Current Document',
      callback: () => {
        const activeFile = this.app.workspace.getActiveFile();
        if (!activeFile || !activeFile.path.endsWith('.md')) {
          new Notice('Please open a markdown file first');
          return;
        }
        new RunAgentsModal(this.app, this, activeFile.path).open();
      }
    });

    this.addCommand({
      id: 'manage-agents',
      name: 'Manage Document Agents',
      callback: () => {
        const activeFile = this.app.workspace.getActiveFile();
        if (!activeFile || !activeFile.path.endsWith('.md')) {
          new Notice('Please open a markdown file first');
          return;
        }
        new ManageAgentsModal(this.app, this, activeFile.path).open();
      }
    });

    // Settings tab
    this.addSettingTab(new AgentPilotSettingTab(this.app, this));

    console.log('Agent Pilot plugin loaded');
  }

  async onunload(): Promise<void> {
    console.log('Agent Pilot plugin unloaded');
  }

  async loadSettings(): Promise<void> {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }

  async saveSettings(): Promise<void> {
    await this.saveData(this.settings);
  }

  async activateView(): Promise<void> {
    const { workspace } = this.app;

    let leaf = workspace.getLeavesOfType(PILOT_VIEW_TYPE)[0];

    if (!leaf) {
      const rightLeaf = workspace.getRightLeaf(false);
      if (rightLeaf) {
        leaf = rightLeaf;
        await leaf.setViewState({ type: PILOT_VIEW_TYPE, active: true });
      }
    }

    if (leaf) {
      workspace.revealLeaf(leaf);
    }
  }

}

// ============================================================================
// QUICK SPAWN MODAL
// ============================================================================

class QuickSpawnModal extends Modal {
  private plugin: AgentPilotPlugin;

  constructor(app: App, plugin: AgentPilotPlugin) {
    super(app);
    this.plugin = plugin;
  }

  async onOpen(): Promise<void> {
    const { contentEl } = this;
    contentEl.empty();
    contentEl.createEl('h2', { text: 'Run Agent' });

    const activeFile = this.app.workspace.getActiveFile();

    try {
      const response = await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents`);
      const agents = await response.json();

      const docAgents = agents.filter((a: any) => a.type === 'doc');
      const standaloneAgents = agents.filter((a: any) => a.type === 'standalone');

      // Doc agents section
      if (docAgents.length > 0) {
        contentEl.createEl('h3', { text: 'Document Agents', cls: 'quick-spawn-section' });
        if (activeFile) {
          contentEl.createEl('p', {
            text: `Will run on: ${activeFile.name}`,
            cls: 'quick-spawn-hint'
          });
        } else {
          contentEl.createEl('p', {
            text: 'Open a document first to run these',
            cls: 'quick-spawn-hint'
          });
        }

        for (const agent of docAgents) {
          const btn = contentEl.createEl('button', {
            text: agent.name,
            cls: activeFile ? 'mod-cta' : ''
          });
          btn.style.cssText = 'display: block; width: 100%; margin-bottom: 8px;';
          if (!activeFile) btn.disabled = true;

          btn.addEventListener('click', async () => {
            if (!activeFile) return;
            // Use spawn endpoint so doc agents appear in activity queue
            await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents/spawn`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                agentPath: agent.path,
                message: 'Process this document.',
                context: { documentPath: activeFile.path }
              })
            });
            new Notice(`Running ${agent.name} on ${activeFile.name}`);
            this.close();
          });
        }
      }

      // Standalone agents section
      if (standaloneAgents.length > 0) {
        contentEl.createEl('h3', { text: 'Standalone Agents', cls: 'quick-spawn-section' });

        for (const agent of standaloneAgents) {
          const btn = contentEl.createEl('button', {
            text: agent.name,
            cls: 'mod-cta'
          });
          btn.style.cssText = 'display: block; width: 100%; margin-bottom: 8px;';
          btn.addEventListener('click', async () => {
            await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents/spawn`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ agentPath: agent.path })
            });
            new Notice(`Running: ${agent.name}`);
            this.close();
          });
        }
      }

      if (docAgents.length === 0 && standaloneAgents.length === 0) {
        contentEl.createEl('p', { text: 'No doc or standalone agents available' });
      }

      // Add styles
      const style = contentEl.createEl('style');
      style.textContent = `
        .quick-spawn-section { margin-top: 16px; margin-bottom: 8px; font-size: 14px; }
        .quick-spawn-hint { font-size: 12px; color: var(--text-muted); margin-bottom: 8px; }
      `;

    } catch (e) {
      contentEl.createEl('p', { text: `Error: ${e.message}` });
    }
  }

  onClose(): void {
    const { contentEl } = this;
    contentEl.empty();
  }
}

// ============================================================================
// RUN AGENTS MODAL
// ============================================================================

interface DocumentAgent {
  path: string;
  status: string;
  trigger: any;
  triggerRaw: string | null;
  lastRun: string | null;
  enabled: boolean;
}

class RunAgentsModal extends Modal {
  private plugin: AgentPilotPlugin;
  private documentPath: string;
  private agents: DocumentAgent[] = [];
  private selectedAgents: Set<string> = new Set();

  constructor(app: App, plugin: AgentPilotPlugin, documentPath: string) {
    super(app);
    this.plugin = plugin;
    this.documentPath = documentPath;
  }

  async onOpen(): Promise<void> {
    const { contentEl } = this;
    contentEl.empty();
    contentEl.addClass('run-agents-modal');

    contentEl.createEl('h2', { text: 'Run Agents' });
    contentEl.createEl('p', {
      text: `Document: ${this.documentPath}`,
      cls: 'run-agents-path'
    });

    const loadingEl = contentEl.createDiv({ text: 'Loading agents...' });

    try {
      const response = await fetch(
        `${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/agents`
      );
      const agents = await response.json();
      this.agents = agents;

      loadingEl.remove();

      if (agents.length === 0) {
        contentEl.createEl('p', {
          text: 'No agents configured for this document.',
          cls: 'run-agents-empty'
        });
        contentEl.createEl('p', {
          text: 'Add an "agents" array to the document frontmatter to configure agents.',
          cls: 'run-agents-hint'
        });
        return;
      }

      // Agent list with checkboxes
      const listEl = contentEl.createDiv({ cls: 'run-agents-list' });

      for (const agent of agents) {
        const row = listEl.createDiv({ cls: 'run-agents-row' });

        const checkbox = row.createEl('input', { type: 'checkbox' });
        checkbox.checked = agent.status === 'pending' || agent.status === 'needs_run';
        if (checkbox.checked) {
          this.selectedAgents.add(agent.path);
        }

        checkbox.addEventListener('change', () => {
          if (checkbox.checked) {
            this.selectedAgents.add(agent.path);
          } else {
            this.selectedAgents.delete(agent.path);
          }
        });

        const label = row.createDiv({ cls: 'run-agents-label' });
        const agentName = agent.path.replace('agents/', '').replace('.md', '');
        label.createEl('span', { text: agentName, cls: 'run-agents-name' });

        const statusBadge = label.createEl('span', {
          cls: `run-agents-status run-agents-status-${agent.status}`,
          text: agent.status
        });

        if (agent.triggerRaw) {
          label.createEl('span', {
            cls: 'run-agents-trigger',
            text: agent.triggerRaw
          });
        }

        if (agent.lastRun) {
          const lastRun = new Date(agent.lastRun);
          label.createEl('span', {
            cls: 'run-agents-lastrun',
            text: `Last: ${lastRun.toLocaleDateString()} ${lastRun.toLocaleTimeString()}`
          });
        }
      }

      // Actions
      const actionsEl = contentEl.createDiv({ cls: 'run-agents-actions' });

      const selectAllBtn = actionsEl.createEl('button', { text: 'Select All', cls: 'mod-cta' });
      selectAllBtn.addEventListener('click', () => {
        this.selectedAgents.clear();
        for (const agent of this.agents) {
          this.selectedAgents.add(agent.path);
        }
        listEl.querySelectorAll('input[type="checkbox"]').forEach((cb: HTMLInputElement) => {
          cb.checked = true;
        });
      });

      const selectNoneBtn = actionsEl.createEl('button', { text: 'Select None' });
      selectNoneBtn.addEventListener('click', () => {
        this.selectedAgents.clear();
        listEl.querySelectorAll('input[type="checkbox"]').forEach((cb: HTMLInputElement) => {
          cb.checked = false;
        });
      });

      const runBtn = actionsEl.createEl('button', { text: 'Run Selected', cls: 'mod-warning' });
      runBtn.addEventListener('click', () => this.runSelected());

      const runAllBtn = actionsEl.createEl('button', { text: 'Run All Pending', cls: 'mod-cta' });
      runAllBtn.addEventListener('click', () => this.runAllPending());

      // Add styles
      this.addModalStyles();

    } catch (e) {
      loadingEl.textContent = `Error: ${e.message}`;
    }
  }

  private async runSelected(): Promise<void> {
    if (this.selectedAgents.size === 0) {
      new Notice('No agents selected');
      return;
    }

    try {
      const response = await fetch(
        `${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/run-agents`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ agents: Array.from(this.selectedAgents) })
        }
      );

      const data = await response.json();
      new Notice(`Started ${data.ran} agent(s)`);
      this.close();

    } catch (e) {
      new Notice(`Error: ${e.message}`);
    }
  }

  private async runAllPending(): Promise<void> {
    try {
      const response = await fetch(
        `${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/run-agents`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({})
        }
      );

      const data = await response.json();
      new Notice(`Started ${data.ran} agent(s)`);
      this.close();

    } catch (e) {
      new Notice(`Error: ${e.message}`);
    }
  }

  private addModalStyles(): void {
    const styleId = 'run-agents-modal-styles';
    if (document.getElementById(styleId)) return;

    const style = document.createElement('style');
    style.id = styleId;
    style.textContent = `
      .run-agents-modal {
        max-width: 500px;
      }

      .run-agents-path {
        color: var(--text-muted);
        font-size: 12px;
        font-family: monospace;
      }

      .run-agents-empty {
        color: var(--text-muted);
        font-style: italic;
      }

      .run-agents-hint {
        font-size: 12px;
        color: var(--text-muted);
      }

      .run-agents-list {
        margin: 16px 0;
        max-height: 300px;
        overflow-y: auto;
      }

      .run-agents-row {
        display: flex;
        align-items: flex-start;
        gap: 12px;
        padding: 8px;
        background: var(--background-secondary);
        border-radius: 4px;
        margin-bottom: 8px;
      }

      .run-agents-row input[type="checkbox"] {
        margin-top: 4px;
      }

      .run-agents-label {
        flex: 1;
        display: flex;
        flex-direction: column;
        gap: 4px;
      }

      .run-agents-name {
        font-weight: 600;
      }

      .run-agents-status {
        display: inline-block;
        font-size: 10px;
        padding: 2px 8px;
        border-radius: 10px;
        text-transform: uppercase;
        margin-left: 8px;
      }

      .run-agents-status-pending {
        background: var(--text-muted);
        color: white;
      }

      .run-agents-status-needs_run {
        background: var(--text-accent);
        color: white;
      }

      .run-agents-status-running {
        background: var(--text-accent);
        color: white;
      }

      .run-agents-status-completed {
        background: var(--text-success);
        color: white;
      }

      .run-agents-status-error {
        background: var(--text-error);
        color: white;
      }

      .run-agents-trigger {
        font-size: 11px;
        color: var(--text-muted);
        font-family: monospace;
      }

      .run-agents-lastrun {
        font-size: 11px;
        color: var(--text-muted);
      }

      .run-agents-actions {
        display: flex;
        gap: 8px;
        flex-wrap: wrap;
        margin-top: 16px;
      }

      .run-agents-actions button {
        padding: 8px 16px;
      }
    `;
    document.head.appendChild(style);
  }

  onClose(): void {
    const { contentEl } = this;
    contentEl.empty();
  }
}

// ============================================================================
// MANAGE AGENTS MODAL
// ============================================================================

class ManageAgentsModal extends Modal {
  private plugin: AgentPilotPlugin;
  private documentPath: string;
  private documentAgents: DocumentAgent[] = [];
  private availableAgents: AgentInfo[] = [];

  constructor(app: App, plugin: AgentPilotPlugin, documentPath: string) {
    super(app);
    this.plugin = plugin;
    this.documentPath = documentPath;
  }

  async onOpen(): Promise<void> {
    const { contentEl } = this;
    contentEl.empty();
    contentEl.addClass('manage-agents-modal');

    contentEl.createEl('h2', { text: 'Manage Document Agents' });
    contentEl.createEl('p', {
      text: this.documentPath,
      cls: 'manage-agents-path'
    });

    const loadingEl = contentEl.createDiv({ text: 'Loading...' });

    try {
      const [docAgentsRes, availAgentsRes] = await Promise.all([
        fetch(`${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/agents`),
        fetch(`${this.plugin.settings.orchestratorUrl}/api/agents`)
      ]);

      this.documentAgents = await docAgentsRes.json();
      this.availableAgents = await availAgentsRes.json();

      loadingEl.remove();
      this.renderContent();

    } catch (e) {
      loadingEl.textContent = `Error: ${e.message}`;
    }
  }

  private renderContent(): void {
    const { contentEl } = this;

    const existingContent = contentEl.querySelector('.manage-agents-content');
    if (existingContent) existingContent.remove();

    const content = contentEl.createDiv({ cls: 'manage-agents-content' });

    // Current agents
    content.createEl('h3', { text: 'Configured Agents' });

    if (this.documentAgents.length === 0) {
      content.createEl('p', {
        text: 'No agents configured. Add one below!',
        cls: 'manage-agents-empty'
      });
    } else {
      const agentsList = content.createDiv({ cls: 'manage-agents-list' });

      for (let i = 0; i < this.documentAgents.length; i++) {
        const agent = this.documentAgents[i];
        this.renderAgentRow(agentsList, agent, i);
      }
    }

    // Add agent section
    content.createEl('h3', { text: 'Add Agent', cls: 'manage-agents-add-header' });

    const addRow = content.createDiv({ cls: 'manage-agents-add-row' });

    const select = addRow.createEl('select', { cls: 'manage-agents-select' });
    select.createEl('option', { value: '', text: 'Select an agent...' });

    const configuredPaths = new Set(this.documentAgents.map(a => a.path));
    for (const agent of this.availableAgents) {
      if (!configuredPaths.has(agent.path)) {
        select.createEl('option', {
          value: agent.path,
          text: `${agent.name} (${agent.type || 'chatbot'})`
        });
      }
    }

    const triggerInput = addRow.createEl('input', {
      type: 'text',
      placeholder: 'Trigger (optional)',
      cls: 'manage-agents-trigger-input'
    });

    const addBtn = addRow.createEl('button', { text: 'Add', cls: 'mod-cta' });
    addBtn.addEventListener('click', () => {
      if (!select.value) {
        new Notice('Please select an agent');
        return;
      }

      this.documentAgents.push({
        path: select.value,
        status: 'pending',
        trigger: null,
        triggerRaw: triggerInput.value || null,
        lastRun: null,
        enabled: true
      });

      this.renderContent();
    });

    // Actions
    const actions = content.createDiv({ cls: 'manage-agents-actions' });

    const saveBtn = actions.createEl('button', { text: 'Save Changes', cls: 'mod-cta' });
    saveBtn.addEventListener('click', () => this.saveChanges());

    const cancelBtn = actions.createEl('button', { text: 'Cancel' });
    cancelBtn.addEventListener('click', () => this.close());

    this.addModalStyles();
  }

  private renderAgentRow(container: HTMLElement, agent: DocumentAgent, index: number): void {
    const row = container.createDiv({ cls: 'manage-agents-row' });

    const info = row.createDiv({ cls: 'manage-agents-info' });
    const agentName = agent.path.replace('agents/', '').replace('.md', '');
    info.createEl('span', { text: agentName, cls: 'manage-agents-name' });

    const triggerContainer = row.createDiv({ cls: 'manage-agents-trigger-container' });
    triggerContainer.createEl('span', { text: 'Trigger:', cls: 'manage-agents-label' });

    const triggerInput = triggerContainer.createEl('input', {
      type: 'text',
      value: agent.triggerRaw || '',
      placeholder: 'manual',
      cls: 'manage-agents-trigger-edit'
    });

    triggerInput.addEventListener('change', () => {
      this.documentAgents[index].triggerRaw = triggerInput.value || null;
    });

    const removeBtn = row.createEl('button', { text: 'Remove', cls: 'manage-agents-remove' });
    removeBtn.addEventListener('click', () => {
      this.documentAgents.splice(index, 1);
      this.renderContent();
    });
  }

  private async saveChanges(): Promise<void> {
    try {
      const agents = this.documentAgents.map(a => ({
        path: a.path,
        status: a.status || 'pending',
        trigger: a.triggerRaw || null,
        enabled: a.enabled !== false
      }));

      const response = await fetch(
        `${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/agents`,
        {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ agents })
        }
      );

      if (response.ok) {
        new Notice('Agents saved!');
        this.close();
      } else {
        const data = await response.json();
        new Notice(`Error: ${data.error}`);
      }
    } catch (e) {
      new Notice(`Error: ${e.message}`);
    }
  }

  private addModalStyles(): void {
    const styleId = 'manage-agents-modal-styles';
    if (document.getElementById(styleId)) return;

    const style = document.createElement('style');
    style.id = styleId;
    style.textContent = `
      .manage-agents-modal { max-width: 600px; }
      .manage-agents-path { color: var(--text-muted); font-size: 12px; font-family: monospace; margin-bottom: 16px; }
      .manage-agents-content h3 { margin-top: 16px; margin-bottom: 8px; font-size: 14px; }
      .manage-agents-empty { color: var(--text-muted); font-style: italic; }
      .manage-agents-list { display: flex; flex-direction: column; gap: 8px; }
      .manage-agents-row { display: flex; align-items: center; gap: 12px; padding: 10px; background: var(--background-secondary); border-radius: 6px; }
      .manage-agents-info { flex: 1; }
      .manage-agents-name { font-weight: 600; }
      .manage-agents-trigger-container { display: flex; align-items: center; gap: 8px; }
      .manage-agents-label { font-size: 12px; color: var(--text-muted); }
      .manage-agents-trigger-edit { width: 120px; padding: 4px 8px; font-size: 12px; font-family: monospace; }
      .manage-agents-remove { padding: 4px 12px; background: var(--background-modifier-error); color: white; border: none; border-radius: 4px; font-size: 11px; cursor: pointer; }
      .manage-agents-add-header { margin-top: 24px !important; border-top: 1px solid var(--background-modifier-border); padding-top: 16px; }
      .manage-agents-add-row { display: flex; gap: 8px; align-items: center; }
      .manage-agents-select { flex: 1; padding: 8px; }
      .manage-agents-trigger-input { width: 140px; padding: 8px; font-family: monospace; font-size: 12px; }
      .manage-agents-actions { display: flex; gap: 8px; margin-top: 24px; padding-top: 16px; border-top: 1px solid var(--background-modifier-border); }
      .manage-agents-actions button { padding: 8px 20px; }
    `;
    document.head.appendChild(style);
  }

  onClose(): void {
    const { contentEl } = this;
    contentEl.empty();
  }
}
