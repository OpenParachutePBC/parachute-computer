#!/usr/bin/env node
/**
 * Vault Search MCP Server
 *
 * Provides search tools over indexed vault content via MCP protocol.
 * Uses per-module indexes (Chat/index.db, Daily/index.db, etc.) for search.
 *
 * Search Modes:
 * - Keyword search: Always available, finds exact text matches
 * - Semantic search: Requires Ollama + embeddinggemma, finds similar meaning
 * - Hybrid search: Combines both for best results (default when Ollama available)
 *
 * Tools:
 * - vault_search: Search across all modules (hybrid when available)
 * - vault_search_module: Search within a specific module
 * - vault_get_content: Get truncated content for a specific item
 * - vault_recent: Get recent content by module
 * - vault_stats: Get index statistics per module
 * - vault_modules: List available modules and their status
 * - vault_semantic_status: Check if semantic search is available
 *
 * Usage:
 *   VAULT_PATH=/path/to/vault node mcp-vault-search.js
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { getModuleSearchService } from "./lib/module-search.js";
import { getOllamaStatus } from "./lib/ollama-service.js";

// Get vault path from environment
const VAULT_PATH = process.env.VAULT_PATH || "./sample-vault";

// Token limit for content retrieval (roughly 4 chars per token)
const MAX_CONTENT_CHARS = 16000; // ~4000 tokens

// Initialize the module search service
let moduleSearch;
try {
  moduleSearch = getModuleSearchService(VAULT_PATH);
  const modules = moduleSearch.listModules();
  const available = modules.filter(m => m.hasIndex);
  console.error(`[MCP-VaultSearch] Initialized with ${available.length} indexed modules`);
} catch (e) {
  console.error(`[MCP-VaultSearch] Failed to initialize: ${e.message}`);
}

// Create MCP server
const server = new McpServer({
  name: "vault-search",
  version: "2.0.0",
});

/**
 * vault_modules - List available modules and their index status
 */
server.tool(
  "vault_modules",
  {},
  async () => {
    if (!moduleSearch) {
      return {
        content: [{
          type: "text",
          text: "Module search service not initialized."
        }]
      };
    }

    try {
      const modules = moduleSearch.listModules();

      const formatted = modules.map(m => {
        const status = m.hasIndex ? "✅ Indexed" : m.exists ? "⚠️ Not indexed" : "❌ Not found";
        const canIndex = m.canIndex ? "(server-indexable)" : "(client-indexed)";
        return `- **${m.name}** (${m.folder}/): ${status} ${canIndex}`;
      }).join("\n");

      return {
        content: [{
          type: "text",
          text: `## Available Modules\n\n${formatted}\n\n*Use \`vault_search\` to search across modules, or \`vault_search_module\` for a specific module.*`
        }]
      };
    } catch (e) {
      return {
        content: [{
          type: "text",
          text: `Error listing modules: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

/**
 * vault_search - Search across all indexed modules
 *
 * Uses hybrid search (keyword + semantic) when Ollama is available.
 * Falls back to keyword-only search otherwise.
 *
 * Returns snippets (not full content) to preserve context window.
 * Use vault_get_content to retrieve more detail for specific items.
 */
server.tool(
  "vault_search",
  {
    query: z.string().describe("Search query - keywords or natural language to find across all modules"),
    modules: z.array(z.string()).optional().describe("Specific modules to search (e.g., ['chat', 'daily']). Default: all"),
    limit: z.number().min(1).max(30).optional().describe("Max results to return (default: 10, max: 30)"),
  },
  async ({ query, modules: targetModules, limit = 10 }) => {
    if (!moduleSearch) {
      return {
        content: [{
          type: "text",
          text: "Module search service not initialized."
        }]
      };
    }

    try {
      const options = {
        limit,
        modules: targetModules,
      };

      const { combined, byModule, totalCount } = await moduleSearch.searchAll(query, options);

      if (combined.length === 0) {
        return {
          content: [{
            type: "text",
            text: `No results found for "${query}" across any modules.`
          }]
        };
      }

      // Format results with module indicators
      const formatted = combined.slice(0, limit).map((r, i) => {
        const moduleLabel = r.module === 'chat' ? "💬 Chat"
                          : r.module === 'daily' ? "📓 Daily"
                          : `📁 ${r.module}`;
        const matchType = r.matchType === 'both' ? "🎯"
                        : r.matchType === 'semantic' ? "🔮"
                        : "";
        const similarity = r.similarity ? ` (${(r.similarity * 100).toFixed(0)}%)` : "";

        return `### ${i + 1}. ${moduleLabel} ${matchType}${similarity}\n**ID:** \`${r.id}\`\n**Title:** ${r.title || 'Untitled'}\n**Snippet:** ${r.snippet || r.content?.substring(0, 200) || 'No preview'}\n`;
      }).join("\n");

      // Module breakdown
      const moduleBreakdown = Object.entries(byModule)
        .filter(([_, data]) => data.count > 0)
        .map(([mod, data]) => `${mod}: ${data.count}`)
        .join(", ");

      return {
        content: [{
          type: "text",
          text: `Found ${totalCount} results for "${query}":\n\n${formatted}\n\n**By module:** ${moduleBreakdown}\n\n*🔮 = semantic match, 🎯 = matched both. Use \`vault_get_content\` with an ID for full content.*`
        }]
      };
    } catch (e) {
      return {
        content: [{
          type: "text",
          text: `Search error: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

/**
 * vault_search_module - Search within a specific module
 */
server.tool(
  "vault_search_module",
  {
    module: z.string().describe("Module to search (e.g., 'chat', 'daily')"),
    query: z.string().describe("Search query"),
    limit: z.number().min(1).max(30).optional().describe("Max results (default: 10)"),
  },
  async ({ module, query, limit = 10 }) => {
    if (!moduleSearch) {
      return {
        content: [{
          type: "text",
          text: "Module search service not initialized."
        }]
      };
    }

    try {
      const result = await moduleSearch.searchModule(module, query, { limit });

      if (result.error) {
        return {
          content: [{
            type: "text",
            text: `Error searching ${module}: ${result.error}`
          }]
        };
      }

      if (result.results.length === 0) {
        return {
          content: [{
            type: "text",
            text: `No results found for "${query}" in ${module}.`
          }]
        };
      }

      const formatted = result.results.map((r, i) => {
        const matchType = r.matchType === 'both' ? "🎯"
                        : r.matchType === 'semantic' ? "🔮"
                        : "";
        return `${i + 1}. ${matchType} **${r.title || r.id}**\n   ${r.snippet || r.content?.substring(0, 150) || 'No preview'}`;
      }).join("\n\n");

      return {
        content: [{
          type: "text",
          text: `## ${module} Search Results\n\nFound ${result.count} results for "${query}":\n\n${formatted}`
        }]
      };
    } catch (e) {
      return {
        content: [{
          type: "text",
          text: `Search error: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

/**
 * vault_get_content - Get content for a specific indexed item
 *
 * Returns truncated content to preserve context window.
 * Large content is cut off with a note about the truncation.
 */
server.tool(
  "vault_get_content",
  {
    module: z.string().describe("Module containing the content (e.g., 'chat', 'daily')"),
    content_id: z.string().describe("Content ID from search results"),
    max_length: z.number().min(500).max(20000).optional().describe("Max characters to return (default: 8000, max: 20000)"),
  },
  async ({ module, content_id, max_length = 8000 }) => {
    if (!moduleSearch) {
      return {
        content: [{
          type: "text",
          text: "Module search service not initialized."
        }]
      };
    }

    try {
      const content = moduleSearch.getContent(module, content_id);

      if (!content) {
        return {
          content: [{
            type: "text",
            text: `Content not found: ${content_id} in module ${module}`
          }]
        };
      }

      // Get full text from chunks
      let fullText = content.title ? `# ${content.title}\n\n` : "";

      if (content.chunks) {
        fullText += content.chunks
          .sort((a, b) => a.chunkIndex - b.chunkIndex)
          .map(c => c.text)
          .join("\n\n");
      }

      // Truncate if needed
      const wasTruncated = fullText.length > max_length;
      if (wasTruncated) {
        fullText = fullText.substring(0, max_length);
        // Try to cut at a sentence or paragraph boundary
        const lastPeriod = fullText.lastIndexOf(". ");
        const lastNewline = fullText.lastIndexOf("\n");
        const cutPoint = Math.max(lastPeriod, lastNewline);
        if (cutPoint > max_length * 0.8) {
          fullText = fullText.substring(0, cutPoint + 1);
        }
        fullText += "\n\n---\n*[Content truncated. Use a more specific search to find relevant sections.]*";
      }

      const moduleLabel = module === 'chat' ? "Chat Session"
                        : module === 'daily' ? "Journal Entry"
                        : `${module} Content`;

      return {
        content: [{
          type: "text",
          text: `## ${moduleLabel}: ${content_id}\n\n${fullText}`
        }]
      };
    } catch (e) {
      return {
        content: [{
          type: "text",
          text: `Error retrieving content: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

/**
 * vault_recent - Get recent content from a module
 */
server.tool(
  "vault_recent",
  {
    module: z.string().describe("Module to get recent content from (e.g., 'chat', 'daily')"),
    limit: z.number().min(1).max(30).optional().describe("Max items to return (default: 10)"),
  },
  async ({ module, limit = 10 }) => {
    if (!moduleSearch) {
      return {
        content: [{
          type: "text",
          text: "Module search service not initialized."
        }]
      };
    }

    try {
      const items = moduleSearch.listRecent(module, { limit });

      if (items.length === 0) {
        return {
          content: [{
            type: "text",
            text: `No indexed content found in ${module}.`
          }]
        };
      }

      const formatted = items.map((item, i) => {
        const date = item.date ? new Date(item.date).toLocaleDateString() : "unknown date";
        return `${i + 1}. **${item.title || item.id}** (${date})\n   ${item.chunkCount || 0} chunks`;
      }).join("\n\n");

      return {
        content: [{
          type: "text",
          text: `## Recent ${module} Content\n\n${formatted}`
        }]
      };
    } catch (e) {
      return {
        content: [{
          type: "text",
          text: `Error: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

/**
 * vault_stats - Get search index statistics
 */
server.tool(
  "vault_stats",
  {},
  async () => {
    if (!moduleSearch) {
      return {
        content: [{
          type: "text",
          text: "Module search service not initialized."
        }]
      };
    }

    try {
      const stats = moduleSearch.getStats();

      const moduleStats = Object.entries(stats.modules)
        .map(([mod, s]) => {
          if (s.error) {
            return `- **${mod}:** ${s.error}`;
          }
          return `- **${mod}:** ${s.contentCount} items, ${s.chunkCount} chunks (${s.embeddedCount} with embeddings)`;
        })
        .join("\n");

      return {
        content: [{
          type: "text",
          text: `## Vault Search Index Stats\n\n**Totals:**\n- Content items: ${stats.total.contentCount}\n- Chunks: ${stats.total.chunkCount}\n- With embeddings: ${stats.total.embeddedCount}\n\n**By Module:**\n${moduleStats}`
        }]
      };
    } catch (e) {
      return {
        content: [{
          type: "text",
          text: `Error: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

/**
 * vault_semantic_status - Check if semantic search is available
 *
 * Returns Ollama status and setup instructions if not configured.
 */
server.tool(
  "vault_semantic_status",
  {},
  async () => {
    try {
      const status = await getOllamaStatus();

      if (status.ready) {
        return {
          content: [{
            type: "text",
            text: `## Semantic Search Status: ✅ Ready\n\n- Ollama: Running at ${status.ollamaUrl}\n- Model: ${status.modelName} installed\n\nSemantic search is fully operational. Your searches will find content by meaning, not just keywords.`
          }]
        };
      }

      // Build setup instructions
      let instructions = `## Semantic Search Status: ⚠️ Not Available\n\n`;

      if (!status.ollamaRunning) {
        instructions += `### Ollama Not Running\n\n`;
        instructions += `Ollama is required for semantic search (finding content by meaning).\n\n`;
        instructions += `**Installation:**\n`;
        for (const step of status.setupInstructions.steps) {
          instructions += `\n**${step.platform}:**\n`;
          for (const cmd of step.commands) {
            instructions += `\`\`\`\n${cmd}\n\`\`\`\n`;
          }
        }
      } else if (!status.modelAvailable) {
        instructions += `### Embedding Model Not Installed\n\n`;
        instructions += `Ollama is running, but the \`${status.modelName}\` model is not installed.\n\n`;
        instructions += `**Install the model:**\n`;
        instructions += `\`\`\`\nollama pull ${status.modelName}\n\`\`\`\n`;
      }

      instructions += `\n\n---\n*Without Ollama, search will still work using keyword matching.*`;

      return {
        content: [{
          type: "text",
          text: instructions
        }]
      };
    } catch (e) {
      return {
        content: [{
          type: "text",
          text: `Error checking semantic status: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

// Start the server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("[MCP-VaultSearch] Server started (v2.0 - per-module search)");
}

main().catch((e) => {
  console.error("[MCP-VaultSearch] Fatal error:", e);
  process.exit(1);
});
