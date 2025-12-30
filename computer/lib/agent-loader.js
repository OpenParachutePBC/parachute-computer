/**
 * Agent Loader
 *
 * Loads agent definitions from markdown files.
 * An agent is defined by YAML frontmatter + markdown body (system prompt).
 */

import fs from 'fs/promises';
import path from 'path';
import matter from 'gray-matter';
import { assertValidPath } from './path-validator.js';

/**
 * Agent types
 *
 * - chatbot: Interactive conversation with persistent session
 * - doc: Processes a specific document (one-shot, document injected)
 * - standalone: One-shot execution, gathers own context
 */
export const AgentType = {
  CHATBOT: 'chatbot',     // Interactive conversation - maintains session
  DOC: 'doc',             // Document processing - receives document as context
  STANDALONE: 'standalone' // One-shot execution - no session
};

/**
 * Default agent configuration
 */
const DEFAULT_AGENT_CONFIG = {
  type: AgentType.CHATBOT,  // Default to chatbot for interactive use
  // model: not set - use SDK default (opus)
  tools: ['Read', 'Write', 'Glob', 'Grep', 'Bash'],
  triggers: {},
  spawns: [],
  context: {
    include: ['*'],
    exclude: [],
    max_files: 20,
    max_tokens: 50000
  },
  permissions: {
    read: ['*'],
    write: ['*'],
    spawn: [],
    tools: ['Read', 'Write', 'Glob', 'Grep', 'Bash']
  },
  constraints: {
    max_spawns: 3,
    timeout: 300
  }
};

/**
 * Load an agent definition from a markdown file
 *
 * @param {string} agentPath - Path to the agent markdown file (must be relative)
 * @param {string} vaultPath - Base vault path
 * @returns {Promise<AgentDefinition>}
 */
export async function loadAgent(agentPath, vaultPath) {
  // Security: Use shared path validator (throws on invalid paths)
  const normalized = assertValidPath(agentPath, vaultPath);
  const fullPath = path.join(vaultPath, normalized);

  const content = await fs.readFile(fullPath, 'utf-8');
  const { data: frontmatter, content: body } = matter(content);

  // Check if this file has an agent definition
  if (!frontmatter.agent) {
    throw new Error(`No agent definition found in ${agentPath}`);
  }

  const agentConfig = frontmatter.agent;

  // Merge with defaults
  const agent = {
    // Identity
    name: agentConfig.name || path.basename(agentPath, '.md'),
    description: agentConfig.description || '',
    path: agentPath,

    // Agent type - chatbot, doc, or standalone
    type: agentConfig.type || DEFAULT_AGENT_CONFIG.type,

    // Model (optional - if not set, SDK default is used)
    model: agentConfig.model || null,

    // Tools
    tools: agentConfig.tools || DEFAULT_AGENT_CONFIG.tools,

    // Triggers
    triggers: {
      ...DEFAULT_AGENT_CONFIG.triggers,
      ...agentConfig.triggers
    },

    // Spawning
    spawns: agentConfig.spawns || DEFAULT_AGENT_CONFIG.spawns,

    // Context
    context: {
      ...DEFAULT_AGENT_CONFIG.context,
      ...agentConfig.context
    },

    // Permissions - deep merge to properly override tools array
    permissions: {
      read: agentConfig.permissions?.read || DEFAULT_AGENT_CONFIG.permissions.read,
      write: agentConfig.permissions?.write || DEFAULT_AGENT_CONFIG.permissions.write,
      spawn: agentConfig.permissions?.spawn || DEFAULT_AGENT_CONFIG.permissions.spawn,
      tools: agentConfig.permissions?.tools || DEFAULT_AGENT_CONFIG.permissions.tools
    },

    // Constraints
    constraints: {
      ...DEFAULT_AGENT_CONFIG.constraints,
      ...agentConfig.constraints
    },

    // MCP Servers (optional - for browser automation, etc.)
    mcpServers: agentConfig.mcpServers || null,

    // System prompt is the markdown body
    systemPrompt: body.trim()
  };

  return agent;
}

/**
 * Check if a path matches any of the given patterns
 *
 * @param {string} filePath - Path to check
 * @param {string[]} patterns - Glob-like patterns
 * @param {object} context - Optional context for special patterns like $self
 * @returns {boolean}
 */
export function matchesPatterns(filePath, patterns, context = {}) {
  for (const pattern of patterns) {
    if (pattern === '*') return true;

    // Handle $self - matches only the current document
    if (pattern === '$self') {
      if (context.documentPath && filePath === context.documentPath) {
        return true;
      }
      continue;
    }

    // Simple glob matching
    const regexPattern = pattern
      .replace(/\./g, '\\.')
      .replace(/\*/g, '.*')
      .replace(/\?/g, '.');

    const regex = new RegExp(`^${regexPattern}$`);
    if (regex.test(filePath)) return true;
  }
  return false;
}

/**
 * Check if agent has permission to perform an action
 *
 * @param {AgentDefinition} agent
 * @param {string} action - 'read' | 'write' | 'spawn'
 * @param {string} target - File path or agent path
 * @returns {boolean}
 */
export function hasPermission(agent, action, target) {
  const patterns = agent.permissions[action] || [];
  return matchesPatterns(target, patterns);
}

/**
 * Load all agents from the agents/ directory
 *
 * @param {string} vaultPath
 * @returns {Promise<AgentDefinition[]>}
 */
export async function loadAllAgents(vaultPath) {
  const agentsDir = path.join(vaultPath, 'agents');
  const agents = [];

  try {
    const files = await fs.readdir(agentsDir);

    for (const file of files) {
      if (!file.endsWith('.md')) continue;

      try {
        const agent = await loadAgent(path.join('agents', file), vaultPath);
        agents.push(agent);
      } catch (e) {
        console.warn(`Failed to load agent ${file}:`, e.message);
      }
    }
  } catch (e) {
    // agents directory doesn't exist yet
    console.log('No agents directory found');
  }

  return agents;
}

/**
 * Find agents that should trigger on a file event
 *
 * @param {AgentDefinition[]} agents
 * @param {string} eventType - 'on_create' | 'on_modify'
 * @param {string} filePath - The file that triggered the event
 * @returns {AgentDefinition[]}
 */
export function findTriggeredAgents(agents, eventType, filePath) {
  return agents.filter(agent => {
    const trigger = agent.triggers[eventType];
    if (!trigger) return false;

    const pattern = trigger.pattern || trigger;
    if (typeof pattern === 'boolean') return pattern;

    return matchesPatterns(filePath, [pattern]);
  });
}

/**
 * Build the full system prompt for an agent execution
 *
 * @param {AgentDefinition} agent
 * @param {object} context - Execution context
 * @returns {string}
 */
export function buildSystemPrompt(agent, context = {}) {
  let prompt = agent.systemPrompt;

  // For doc agents, add explicit instructions about using Write tool
  if (agent.type === 'doc' && context.documentPath) {
    prompt += `\n\n## IMPORTANT: Document Modification
You are processing the document at: ${context.documentPath}

To make changes to this document, you MUST use the Write tool to save your modifications.
The document content is provided to you - after processing, use the Write tool to save the updated content.

Example:
1. Read the document content provided to you
2. Compose your additions/modifications
3. Use the Write tool with the full updated document content

The vault path is the current working directory. Use the relative path: ${context.documentPath}`;
  }

  // Add spawn capability instructions
  if (agent.spawns.length > 0 || agent.permissions.spawn?.length > 0) {
    prompt += `\n\n## Spawning Other Agents\n`;
    prompt += `You can request to spawn other agents by including a spawn block:\n`;
    prompt += `\`\`\`spawn\n{"agent": "agents/name.md", "message": "task for the agent"}\n\`\`\`\n`;
    prompt += `\nAgents you can spawn:\n`;

    const spawnableAgents = [
      ...agent.spawns.map(s => s.agent),
      ...(agent.permissions.spawn || [])
    ];

    for (const spawnAgent of [...new Set(spawnableAgents)]) {
      prompt += `- ${spawnAgent}\n`;
    }
  }

  // Add write permissions info
  if (agent.permissions.write && agent.permissions.write[0] !== '*') {
    prompt += `\n\n## CRITICAL: Write Permissions\n`;
    prompt += `**You can ONLY write to these locations. Writing to any other path will be blocked:**\n`;
    for (const pattern of agent.permissions.write) {
      if (pattern === '$self' && context.documentPath) {
        prompt += `- ${context.documentPath} (the current document only)\n`;
      } else {
        prompt += `- ${pattern}\n`;
      }
    }
    prompt += `\nIMPORTANT: Always use the FULL path including the directory prefix (e.g., "Songs/my-song.md" not just "my-song.md"). Writes outside these paths will fail.\n`;
  }

  // Add parent context if provided
  if (context.parentContext) {
    prompt += `\n\n## Context from Parent Agent\n`;
    prompt += `\`\`\`json\n${JSON.stringify(context.parentContext, null, 2)}\n\`\`\`\n`;
  }

  // Add inherited data
  if (context.inheritedData) {
    prompt += `\n\n## Additional Context\n`;
    prompt += context.inheritedData;
  }

  return prompt;
}

export default {
  loadAgent,
  loadAllAgents,
  hasPermission,
  matchesPatterns,
  findTriggeredAgents,
  buildSystemPrompt
};
