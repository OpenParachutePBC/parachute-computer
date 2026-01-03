#!/usr/bin/env node
/**
 * Parachute MCP Server
 *
 * Built-in MCP that provides search access to Parachute modules:
 * - Daily journals (search, list recent, get entry)
 * - Chat sessions (search, list recent, get session)
 *
 * This runs as an MCP server that Claude can connect to via stdio.
 * Can be used standalone or auto-configured by parachute-base.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { getModuleSearchService } from '../module-search.js';
import { createLogger } from '../logger.js';

const log = createLogger('ParachuteMCP');

// Get vault path from environment or args
const VAULT_PATH = process.env.PARACHUTE_VAULT_PATH || process.argv[2];

if (!VAULT_PATH) {
  console.error('Error: PARACHUTE_VAULT_PATH environment variable or path argument required');
  process.exit(1);
}

// Tool definitions
const TOOLS = [
  {
    name: 'search_journals',
    description: 'Search Daily journal entries by keyword or semantic similarity. Returns matching entries with snippets.',
    inputSchema: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Search query - keywords or natural language question',
        },
        limit: {
          type: 'number',
          description: 'Maximum number of results (default: 10)',
          default: 10,
        },
        date_from: {
          type: 'string',
          description: 'Filter by date - ISO date string (YYYY-MM-DD)',
        },
        date_to: {
          type: 'string',
          description: 'Filter by end date - ISO date string (YYYY-MM-DD)',
        },
      },
      required: ['query'],
    },
  },
  {
    name: 'list_recent_journals',
    description: 'List recent Daily journal entries, sorted by date (newest first).',
    inputSchema: {
      type: 'object',
      properties: {
        limit: {
          type: 'number',
          description: 'Maximum number of entries (default: 10)',
          default: 10,
        },
        days: {
          type: 'number',
          description: 'Only show entries from last N days',
        },
      },
    },
  },
  {
    name: 'get_journal_entry',
    description: 'Get the full content of a specific journal entry by its ID.',
    inputSchema: {
      type: 'object',
      properties: {
        entry_id: {
          type: 'string',
          description: 'The journal entry ID (content_id from search results)',
        },
      },
      required: ['entry_id'],
    },
  },
  {
    name: 'search_chats',
    description: 'Search Chat session history by keyword or semantic similarity. Returns matching messages with context.',
    inputSchema: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Search query - keywords or natural language question',
        },
        limit: {
          type: 'number',
          description: 'Maximum number of results (default: 10)',
          default: 10,
        },
        agent: {
          type: 'string',
          description: 'Filter by agent name (e.g., "vault-agent")',
        },
      },
      required: ['query'],
    },
  },
  {
    name: 'list_recent_chats',
    description: 'List recent Chat sessions, sorted by date (newest first).',
    inputSchema: {
      type: 'object',
      properties: {
        limit: {
          type: 'number',
          description: 'Maximum number of sessions (default: 10)',
          default: 10,
        },
        agent: {
          type: 'string',
          description: 'Filter by agent name',
        },
      },
    },
  },
  {
    name: 'get_chat_session',
    description: 'Get the full content of a specific chat session by its ID.',
    inputSchema: {
      type: 'object',
      properties: {
        session_id: {
          type: 'string',
          description: 'The chat session ID (content_id from search results)',
        },
      },
      required: ['session_id'],
    },
  },
  {
    name: 'get_index_stats',
    description: 'Get statistics about the Parachute module indexes (content count, chunk count, etc.).',
    inputSchema: {
      type: 'object',
      properties: {},
    },
  },
];

/**
 * Create and configure the MCP server
 */
function createServer() {
  const server = new Server(
    {
      name: 'parachute',
      version: '1.0.0',
    },
    {
      capabilities: {
        tools: {},
      },
    }
  );

  // Get the search service
  const searchService = getModuleSearchService(VAULT_PATH);

  // Handle list tools
  server.setRequestHandler(ListToolsRequestSchema, async () => {
    return { tools: TOOLS };
  });

  // Handle tool calls
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    try {
      switch (name) {
        case 'search_journals':
          return await handleSearchJournals(searchService, args);

        case 'list_recent_journals':
          return await handleListRecentJournals(searchService, args);

        case 'get_journal_entry':
          return await handleGetJournalEntry(searchService, args);

        case 'search_chats':
          return await handleSearchChats(searchService, args);

        case 'list_recent_chats':
          return await handleListRecentChats(searchService, args);

        case 'get_chat_session':
          return await handleGetChatSession(searchService, args);

        case 'get_index_stats':
          return await handleGetStats(searchService);

        default:
          throw new Error(`Unknown tool: ${name}`);
      }
    } catch (error) {
      log.error(`Tool ${name} failed: ${error.message}`);
      return {
        content: [
          {
            type: 'text',
            text: `Error: ${error.message}`,
          },
        ],
        isError: true,
      };
    }
  });

  return server;
}

// Tool handlers

async function handleSearchJournals(searchService, args) {
  const { query, limit = 10, date_from, date_to } = args;

  const result = await searchService.searchModule('daily', query, {
    limit,
    dateFrom: date_from,
    dateTo: date_to,
  });

  if (result.error) {
    return {
      content: [{ type: 'text', text: `Search error: ${result.error}` }],
      isError: true,
    };
  }

  const formatted = formatSearchResults(result.results, 'journal');

  return {
    content: [
      {
        type: 'text',
        text: `Found ${result.count} journal entries matching "${query}":\n\n${formatted}`,
      },
    ],
  };
}

async function handleListRecentJournals(searchService, args) {
  const { limit = 10, days } = args;

  const results = searchService.listRecent('daily', {
    limit,
    days,
  });

  if (!results || results.length === 0) {
    return {
      content: [{ type: 'text', text: 'No recent journal entries found.' }],
    };
  }

  const formatted = results
    .map((r, i) => `${i + 1}. [${r.date}] ${r.title || 'Untitled'}\n   ID: ${r.id}`)
    .join('\n\n');

  return {
    content: [
      {
        type: 'text',
        text: `Recent journal entries:\n\n${formatted}`,
      },
    ],
  };
}

async function handleGetJournalEntry(searchService, args) {
  const { entry_id } = args;

  const content = searchService.getContent('daily', entry_id);

  if (!content) {
    return {
      content: [{ type: 'text', text: `Journal entry not found: ${entry_id}` }],
      isError: true,
    };
  }

  return {
    content: [
      {
        type: 'text',
        text: `# ${content.title || 'Journal Entry'}\n\nDate: ${content.date}\nID: ${content.id}\n\n---\n\n${content.content || 'No content'}`,
      },
    ],
  };
}

async function handleSearchChats(searchService, args) {
  const { query, limit = 10, agent } = args;

  const result = await searchService.searchModule('chat', query, {
    limit,
    agent,
  });

  if (result.error) {
    return {
      content: [{ type: 'text', text: `Search error: ${result.error}` }],
      isError: true,
    };
  }

  const formatted = formatSearchResults(result.results, 'chat');

  return {
    content: [
      {
        type: 'text',
        text: `Found ${result.count} chat messages matching "${query}":\n\n${formatted}`,
      },
    ],
  };
}

async function handleListRecentChats(searchService, args) {
  const { limit = 10, agent } = args;

  const results = searchService.listRecent('chat', {
    limit,
    agent,
  });

  if (!results || results.length === 0) {
    return {
      content: [{ type: 'text', text: 'No recent chat sessions found.' }],
    };
  }

  const formatted = results
    .map((r, i) => `${i + 1}. [${r.date}] ${r.title || 'Untitled Session'}\n   Agent: ${r.metadata?.agent || 'unknown'}\n   ID: ${r.id}`)
    .join('\n\n');

  return {
    content: [
      {
        type: 'text',
        text: `Recent chat sessions:\n\n${formatted}`,
      },
    ],
  };
}

async function handleGetChatSession(searchService, args) {
  const { session_id } = args;

  const content = searchService.getContent('chat', session_id);

  if (!content) {
    return {
      content: [{ type: 'text', text: `Chat session not found: ${session_id}` }],
      isError: true,
    };
  }

  return {
    content: [
      {
        type: 'text',
        text: `# ${content.title || 'Chat Session'}\n\nDate: ${content.date}\nAgent: ${content.metadata?.agent || 'unknown'}\nID: ${content.id}\n\n---\n\n${content.content || 'No content'}`,
      },
    ],
  };
}

async function handleGetStats(searchService) {
  const stats = searchService.getStats();

  const formatted = Object.entries(stats.modules)
    .map(([name, s]) => {
      if (s.error) return `${name}: ${s.error}`;
      return `${name}: ${s.contentCount} items, ${s.chunkCount} chunks, ${s.embeddedCount} with embeddings`;
    })
    .join('\n');

  return {
    content: [
      {
        type: 'text',
        text: `Parachute Index Statistics:\n\n${formatted}\n\nTotal: ${stats.total.contentCount} items, ${stats.total.chunkCount} chunks`,
      },
    ],
  };
}

// Helpers

function formatSearchResults(results, type) {
  if (!results || results.length === 0) {
    return 'No results found.';
  }

  return results
    .map((r, i) => {
      const matchInfo = r.matchType === 'both' ? ' [keyword+semantic]' : r.matchType === 'semantic' ? ` [semantic: ${(r.similarity * 100).toFixed(0)}%]` : ' [keyword]';
      const snippet = r.snippet || r.chunks?.[0]?.text?.substring(0, 200) || '';
      const contentId = r.id || r.content_id;

      return `${i + 1}. [${r.date}] ${r.title || 'Untitled'}${matchInfo}\n   ID: ${contentId}\n   ${snippet}${snippet.length >= 200 ? '...' : ''}`;
    })
    .join('\n\n');
}

// Main entry point
async function main() {
  log.info(`Starting Parachute MCP server for vault: ${VAULT_PATH}`);

  const server = createServer();
  const transport = new StdioServerTransport();

  await server.connect(transport);

  log.info('Parachute MCP server running');
}

main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});
