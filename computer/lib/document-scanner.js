/**
 * Document Scanner
 *
 * Scans vault for documents with agent configurations,
 * checks triggers, and queues documents for processing.
 *
 * Supports multiple agents per document with independent statuses.
 */

import fs from 'fs/promises';
import path from 'path';
import matter from 'gray-matter';

// Agent status values for each agent-document relationship
export const AgentStatus = {
  PENDING: 'pending',       // Waiting for trigger or manual run
  NEEDS_RUN: 'needs_run',   // Trigger fired, ready to run
  RUNNING: 'running',       // Currently executing
  COMPLETED: 'completed',   // Finished successfully
  ERROR: 'error'            // Failed
};

/**
 * Parse trigger expression
 * Formats:
 *   - "daily@22:00" - Every day at 22:00
 *   - "hourly" - Every hour
 *   - "on_save" - When document is saved (handled by plugin)
 *   - "manual" - Only when manually triggered
 *   - "weekly@monday" - Every week on Monday
 *   - "cron:0 22 * * *" - Cron expression
 */
function parseTrigger(triggerStr) {
  if (!triggerStr) return null;

  const [type, value] = triggerStr.split(/[@:]/);

  switch (type) {
    case 'daily':
      return { type: 'daily', time: value || '00:00' };
    case 'hourly':
      return { type: 'hourly' };
    case 'on_save':
      return { type: 'on_save' };
    case 'manual':
      return { type: 'manual' };
    case 'weekly':
      return { type: 'weekly', day: value || 'monday' };
    case 'cron':
      return { type: 'cron', expression: value };
    default:
      return { type: 'unknown', raw: triggerStr };
  }
}

/**
 * Check if a trigger should fire
 */
function shouldTriggerFire(trigger, lastRun) {
  if (!trigger) return false;

  const now = new Date();
  const lastRunDate = lastRun ? new Date(lastRun) : null;

  switch (trigger.type) {
    case 'daily': {
      const [hours, minutes] = trigger.time.split(':').map(Number);
      const triggerTime = new Date(now);
      triggerTime.setHours(hours, minutes, 0, 0);

      // If we're past trigger time today and haven't run today
      if (now >= triggerTime) {
        if (!lastRunDate || lastRunDate < triggerTime) {
          return true;
        }
      }
      return false;
    }

    case 'hourly': {
      if (!lastRunDate) return true;
      const hourAgo = new Date(now - 60 * 60 * 1000);
      return lastRunDate < hourAgo;
    }

    case 'weekly': {
      const dayMap = {
        'sunday': 0, 'monday': 1, 'tuesday': 2, 'wednesday': 3,
        'thursday': 4, 'friday': 5, 'saturday': 6
      };
      const targetDay = dayMap[trigger.day.toLowerCase()] || 1;
      const today = now.getDay();

      if (today === targetDay) {
        // Check if we've already run this week
        if (!lastRunDate) return true;
        const weekAgo = new Date(now - 7 * 24 * 60 * 60 * 1000);
        return lastRunDate < weekAgo;
      }
      return false;
    }

    case 'manual':
    case 'on_save':
      return false; // These are triggered externally

    default:
      return false;
  }
}

export { parseTrigger, shouldTriggerFire };

/**
 * Normalize agent config to array format
 * Supports both old single-agent and new multi-agent schema
 */
function normalizeAgentsConfig(frontmatter) {
  // New schema: agents array
  if (Array.isArray(frontmatter.agents)) {
    return frontmatter.agents.map(a => ({
      path: a.path,
      status: a.status || AgentStatus.PENDING,
      trigger: a.trigger ? parseTrigger(a.trigger) : null,
      triggerRaw: a.trigger || null,
      lastRun: a.last_run || null,
      enabled: a.enabled !== false
    }));
  }

  // Old schema: single agent field
  if (frontmatter.agent) {
    return [{
      path: frontmatter.agent,
      status: frontmatter.agent_status || AgentStatus.PENDING,
      trigger: parseTrigger(frontmatter.agent_trigger),
      triggerRaw: frontmatter.agent_trigger || null,
      lastRun: frontmatter.agent_last_run || null,
      enabled: true
    }];
  }

  return [];
}

export class DocumentScanner {
  constructor(vaultPath) {
    this.vaultPath = vaultPath;
  }

  /**
   * Scan all documents in vault
   */
  async scanAll() {
    const documents = [];
    await this._scanDirectory(this.vaultPath, documents);
    return documents;
  }

  async _scanDirectory(dir, documents) {
    const entries = await fs.readdir(dir, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);

      if (entry.isDirectory() && !entry.name.startsWith('.')) {
        await this._scanDirectory(fullPath, documents);
      } else if (entry.name.endsWith('.md')) {
        const doc = await this.parseDocument(fullPath);
        if (doc.agents.length > 0) {
          documents.push(doc);
        }
      }
    }
  }

  /**
   * Parse a document's agent configuration
   * Returns document with agents array (supports multiple agents per doc)
   */
  async parseDocument(fullPath) {
    const relativePath = path.relative(this.vaultPath, fullPath);
    const content = await fs.readFile(fullPath, 'utf-8');
    const { data: frontmatter, content: body } = matter(content);

    const agents = normalizeAgentsConfig(frontmatter);

    return {
      path: relativePath,
      fullPath,
      agents,
      hasAgentConfig: agents.length > 0,
      frontmatter,
      body,
      // Legacy compat - first agent
      agent: agents[0]?.path || null,
      status: agents[0]?.status || null,
      trigger: agents[0]?.trigger || null,
      triggerRaw: agents[0]?.triggerRaw || null,
      lastRun: agents[0]?.lastRun || null,
      context: frontmatter.agent_context || []
    };
  }

  /**
   * Find all agent-document pairs that need running
   */
  async findNeedsRun() {
    const docs = await this.scanAll();
    const pairs = [];

    for (const doc of docs) {
      for (const agent of doc.agents) {
        if (agent.status === AgentStatus.NEEDS_RUN && agent.enabled) {
          pairs.push({
            documentPath: doc.path,
            agentPath: agent.path,
            agent,
            document: doc
          });
        }
      }
    }

    return pairs;
  }

  /**
   * Find agent-document pairs whose triggers should fire
   */
  async findTriggeredAgents() {
    const docs = await this.scanAll();
    const pairs = [];

    for (const doc of docs) {
      for (const agent of doc.agents) {
        if (
          agent.enabled &&
          agent.status === AgentStatus.PENDING &&
          agent.trigger &&
          shouldTriggerFire(agent.trigger, agent.lastRun)
        ) {
          pairs.push({
            documentPath: doc.path,
            agentPath: agent.path,
            agent,
            document: doc
          });
        }
      }
    }

    return pairs;
  }

  /**
   * Get all pending agents for a specific document
   */
  async getPendingAgents(documentPath) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const doc = await this.parseDocument(fullPath);

    return doc.agents.filter(a =>
      a.enabled &&
      (a.status === AgentStatus.PENDING || a.status === AgentStatus.NEEDS_RUN)
    );
  }

  /**
   * Update a specific agent's status on a document
   */
  async updateAgentStatus(documentPath, agentPath, newStatus, additionalFields = {}) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const content = await fs.readFile(fullPath, 'utf-8');
    const { data: frontmatter, content: body } = matter(content);

    // Check if using new schema (agents array)
    if (Array.isArray(frontmatter.agents)) {
      const agentIndex = frontmatter.agents.findIndex(a => a.path === agentPath);
      if (agentIndex >= 0) {
        frontmatter.agents[agentIndex].status = newStatus;

        if (newStatus === AgentStatus.COMPLETED || newStatus === AgentStatus.RUNNING) {
          frontmatter.agents[agentIndex].last_run = new Date().toISOString();
        }

        // Merge additional fields
        Object.assign(frontmatter.agents[agentIndex], additionalFields);
      }
    } else if (frontmatter.agent === agentPath) {
      // Old schema - update flat fields
      frontmatter.agent_status = newStatus;

      if (newStatus === AgentStatus.COMPLETED || newStatus === AgentStatus.RUNNING) {
        frontmatter.agent_last_run = new Date().toISOString();
      }

      Object.assign(frontmatter, additionalFields);
    }

    // Rebuild document
    const newContent = matter.stringify(body, frontmatter);
    await fs.writeFile(fullPath, newContent);

    return { path: documentPath, agentPath, status: newStatus };
  }

  /**
   * Set all pending agents on a document to needs_run status
   */
  async triggerAllAgents(documentPath) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const content = await fs.readFile(fullPath, 'utf-8');
    const { data: frontmatter, content: body } = matter(content);

    let triggered = [];

    if (Array.isArray(frontmatter.agents)) {
      for (const agent of frontmatter.agents) {
        if (agent.status === AgentStatus.PENDING) {
          agent.status = AgentStatus.NEEDS_RUN;
          triggered.push(agent.path);
        }
      }
    } else if (frontmatter.agent && frontmatter.agent_status === AgentStatus.PENDING) {
      frontmatter.agent_status = AgentStatus.NEEDS_RUN;
      triggered.push(frontmatter.agent);
    }

    if (triggered.length > 0) {
      const newContent = matter.stringify(body, frontmatter);
      await fs.writeFile(fullPath, newContent);
    }

    return triggered;
  }

  /**
   * Trigger specific agents on a document
   */
  async triggerAgents(documentPath, agentPaths) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const content = await fs.readFile(fullPath, 'utf-8');
    const { data: frontmatter, content: body } = matter(content);

    let triggered = [];

    if (Array.isArray(frontmatter.agents)) {
      for (const agent of frontmatter.agents) {
        if (agentPaths.includes(agent.path) && agent.status === AgentStatus.PENDING) {
          agent.status = AgentStatus.NEEDS_RUN;
          triggered.push(agent.path);
        }
      }
    } else if (frontmatter.agent && agentPaths.includes(frontmatter.agent)) {
      if (frontmatter.agent_status === AgentStatus.PENDING) {
        frontmatter.agent_status = AgentStatus.NEEDS_RUN;
        triggered.push(frontmatter.agent);
      }
    }

    if (triggered.length > 0) {
      const newContent = matter.stringify(body, frontmatter);
      await fs.writeFile(fullPath, newContent);
    }

    return triggered;
  }

  /**
   * Reset agents to pending status (for re-running)
   */
  async resetAgents(documentPath, agentPaths = null) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const content = await fs.readFile(fullPath, 'utf-8');
    const { data: frontmatter, content: body } = matter(content);

    let reset = [];

    if (Array.isArray(frontmatter.agents)) {
      for (const agent of frontmatter.agents) {
        if (!agentPaths || agentPaths.includes(agent.path)) {
          agent.status = AgentStatus.PENDING;
          reset.push(agent.path);
        }
      }
    } else if (frontmatter.agent) {
      if (!agentPaths || agentPaths.includes(frontmatter.agent)) {
        frontmatter.agent_status = AgentStatus.PENDING;
        reset.push(frontmatter.agent);
      }
    }

    if (reset.length > 0) {
      const newContent = matter.stringify(body, frontmatter);
      await fs.writeFile(fullPath, newContent);
    }

    return reset;
  }

  /**
   * Update all agents on a document (replaces existing agents array)
   */
  async updateDocumentAgents(documentPath, agents) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const content = await fs.readFile(fullPath, 'utf-8');
    const { data: frontmatter, content: body } = matter(content);

    // Convert to the new agents array format
    frontmatter.agents = agents.map(a => ({
      path: a.path,
      status: a.status || AgentStatus.PENDING,
      trigger: a.trigger || null,
      enabled: a.enabled !== false
    }));

    // Remove old single-agent fields if present
    delete frontmatter.agent;
    delete frontmatter.agent_status;
    delete frontmatter.agent_trigger;
    delete frontmatter.agent_last_run;
    delete frontmatter.agent_context;

    // Rebuild document
    const newContent = matter.stringify(body, frontmatter);
    await fs.writeFile(fullPath, newContent);

    return frontmatter.agents;
  }

  /**
   * Add an agent to a document
   */
  async addAgentToDocument(documentPath, agentPath, options = {}) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const doc = await this.parseDocument(fullPath);

    // Check if agent already exists
    if (doc.agents.some(a => a.path === agentPath)) {
      return { added: false, reason: 'Agent already configured' };
    }

    const newAgent = {
      path: agentPath,
      status: AgentStatus.PENDING,
      trigger: options.trigger || null,
      enabled: true
    };

    const updatedAgents = [...doc.agents.map(a => ({
      path: a.path,
      status: a.status,
      trigger: a.triggerRaw,
      enabled: a.enabled
    })), newAgent];

    await this.updateDocumentAgents(documentPath, updatedAgents);
    return { added: true, agent: newAgent };
  }

  /**
   * Remove an agent from a document
   */
  async removeAgentFromDocument(documentPath, agentPath) {
    const fullPath = path.join(this.vaultPath, documentPath);
    const doc = await this.parseDocument(fullPath);

    const updatedAgents = doc.agents
      .filter(a => a.path !== agentPath)
      .map(a => ({
        path: a.path,
        status: a.status,
        trigger: a.triggerRaw,
        enabled: a.enabled
      }));

    await this.updateDocumentAgents(documentPath, updatedAgents);
    return { removed: true };
  }

  /**
   * Get document statistics
   */
  async getStats() {
    const docs = await this.scanAll();

    const stats = {
      totalDocuments: docs.length,
      totalAgentRelationships: 0,
      byStatus: {},
      byAgent: {},
      withTriggers: 0
    };

    for (const doc of docs) {
      for (const agent of doc.agents) {
        stats.totalAgentRelationships++;

        // By status
        const status = agent.status || 'pending';
        stats.byStatus[status] = (stats.byStatus[status] || 0) + 1;

        // By agent
        stats.byAgent[agent.path] = (stats.byAgent[agent.path] || 0) + 1;

        // With triggers
        if (agent.trigger) {
          stats.withTriggers++;
        }
      }
    }

    return stats;
  }
}

export default DocumentScanner;
