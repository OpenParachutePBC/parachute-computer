#!/usr/bin/env node
/**
 * Vault Search MCP Server
 *
 * Provides search tools over the indexed vault content via MCP protocol.
 * Designed to give agents access to past conversations, journals, and captures
 * with smart context management (returns snippets, truncates large content).
 *
 * Search Modes:
 * - Keyword search: Always available, finds exact text matches
 * - Semantic search: Requires Ollama + embeddinggemma, finds similar meaning
 * - Hybrid search: Combines both for best results (default when Ollama available)
 *
 * Tools:
 * - vault_search: Search across all indexed content (hybrid when available)
 * - vault_get_content: Get truncated content for a specific item
 * - vault_recent: Get recent content by type
 * - vault_stats: Get index statistics
 * - vault_semantic_status: Check if semantic search is available
 *
 * Usage:
 *   VAULT_PATH=/path/to/vault node mcp-vault-search.js
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { getVaultSearchService, ContentType } from "./lib/vault-search.js";

// Get vault path from environment
const VAULT_PATH = process.env.VAULT_PATH || "./sample-vault";

// Token limit for content retrieval (roughly 4 chars per token)
const MAX_CONTENT_CHARS = 16000; // ~4000 tokens

// Initialize the search service
let searchService;
try {
  searchService = getVaultSearchService(VAULT_PATH);
  if (!searchService.isAvailable()) {
    console.error(`[MCP-VaultSearch] Search database not found. Run the Flutter app to build the index first.`);
  }
} catch (e) {
  console.error(`[MCP-VaultSearch] Failed to initialize: ${e.message}`);
}

// Create MCP server
const server = new McpServer({
  name: "vault-search",
  version: "1.0.0",
});

/**
 * vault_search - Search across indexed vault content
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
    query: z.string().describe("Search query - keywords or natural language to find in journals, chats, and captures"),
    content_type: z.enum(["all", "journal", "chat", "recording"]).optional().describe("Filter by content type (default: all)"),
    limit: z.number().min(1).max(20).optional().describe("Max results to return (default: 10, max: 20)"),
  },
  async ({ query, content_type, limit = 10 }) => {
    if (!searchService || !searchService.isAvailable()) {
      return {
        content: [{
          type: "text",
          text: "Search index not available. The Flutter app needs to build the search index first (Search tab → Build Index)."
        }]
      };
    }

    try {
      const options = {
        limit,
        contentType: content_type === "all" ? null : content_type,
      };

      // Use hybrid search (keyword + semantic when available)
      const { results, searchTypes, semanticAvailable, semanticReason } = await searchService.hybridSearch(query, options);

      if (results.length === 0) {
        let msg = `No results found for "${query}".`;
        if (!semanticAvailable) {
          msg += `\n\n*Note: Semantic search unavailable (${semanticReason}). Only keyword matching was used.*`;
        }
        return {
          content: [{
            type: "text",
            text: msg
          }]
        };
      }

      // Format results with snippets and search type indicators
      const formatted = results.map((r, i) => {
        const typeLabel = r.contentType === "journal" ? "📓 Journal"
                        : r.contentType === "chat" ? "💬 Chat"
                        : "🎤 Recording";
        const matchType = r.searchType === "both" ? "🎯"
                        : r.searchType === "semantic" ? "🔮"
                        : "";
        return `### ${i + 1}. ${typeLabel} ${matchType}\n**ID:** \`${r.contentId}\`\n**Snippet:** ${r.snippet}\n`;
      }).join("\n");

      // Build status note
      let statusNote = "";
      if (searchTypes.includes("semantic")) {
        statusNote = "\n\n*🔮 = semantic match, 🎯 = matched both keyword and meaning*";
      } else if (!semanticAvailable) {
        statusNote = `\n\n*Keyword search only. Semantic search unavailable: ${semanticReason}*`;
      }

      return {
        content: [{
          type: "text",
          text: `Found ${results.length} results for "${query}":\n\n${formatted}\n\nUse \`vault_get_content\` with an ID to get more detail.${statusNote}`
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
    content_id: z.string().describe("Content ID from search results (e.g., 'chat:abc123' or 'journal:2025-01-15:entry1')"),
    max_length: z.number().min(500).max(20000).optional().describe("Max characters to return (default: 8000, max: 20000)"),
  },
  async ({ content_id, max_length = 8000 }) => {
    if (!searchService || !searchService.isAvailable()) {
      return {
        content: [{
          type: "text",
          text: "Search index not available."
        }]
      };
    }

    try {
      const content = searchService.getContent(content_id);

      if (!content) {
        return {
          content: [{
            type: "text",
            text: `Content not found for ID: ${content_id}`
          }]
        };
      }

      // Combine all fields into readable text
      let fullText = "";
      for (const [field, text] of Object.entries(content.fields)) {
        if (field === "title") {
          fullText += `# ${text}\n\n`;
        } else {
          fullText += `${text}\n\n`;
        }
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

      const typeLabel = content.contentType === "journal" ? "Journal Entry"
                      : content.contentType === "chat" ? "Chat Session"
                      : "Recording";

      return {
        content: [{
          type: "text",
          text: `## ${typeLabel}: ${content_id}\n\n${fullText}`
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
 * vault_recent - Get recent content by type
 *
 * Useful for seeing what's been recently indexed without searching.
 */
server.tool(
  "vault_recent",
  {
    content_type: z.enum(["all", "journal", "chat", "recording"]).optional().describe("Filter by content type (default: all)"),
    limit: z.number().min(1).max(20).optional().describe("Max items to return (default: 10)"),
  },
  async ({ content_type, limit = 10 }) => {
    if (!searchService || !searchService.isAvailable()) {
      return {
        content: [{
          type: "text",
          text: "Search index not available."
        }]
      };
    }

    try {
      const options = {
        limit,
        contentType: content_type === "all" ? null : content_type,
      };

      const items = searchService.listIndexedContent(options);

      if (items.length === 0) {
        return {
          content: [{
            type: "text",
            text: "No indexed content found."
          }]
        };
      }

      const formatted = items.map((item, i) => {
        const typeLabel = item.contentType === "journal" ? "📓"
                        : item.contentType === "chat" ? "💬"
                        : "🎤";
        const date = item.indexedAt ? new Date(item.indexedAt).toLocaleDateString() : "unknown";
        return `${i + 1}. ${typeLabel} \`${item.contentId}\` (${item.chunkCount} chunks, indexed ${date})`;
      }).join("\n");

      return {
        content: [{
          type: "text",
          text: `Recent indexed content:\n\n${formatted}`
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
    if (!searchService || !searchService.isAvailable()) {
      return {
        content: [{
          type: "text",
          text: "Search index not available. The Flutter app needs to build the search index first."
        }]
      };
    }

    try {
      const stats = searchService.getStats();

      if (!stats) {
        return {
          content: [{
            type: "text",
            text: "Could not retrieve stats."
          }]
        };
      }

      const byType = Object.entries(stats.byContentType)
        .map(([type, count]) => `- ${type}: ${count} chunks`)
        .join("\n");

      return {
        content: [{
          type: "text",
          text: `## Vault Search Index Stats\n\n- **Total content items:** ${stats.totalContent}\n- **Total chunks:** ${stats.totalChunks}\n\n**By type:**\n${byType}`
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
    if (!searchService) {
      return {
        content: [{
          type: "text",
          text: "Search service not initialized."
        }]
      };
    }

    try {
      const status = await searchService.getSemanticSearchStatus();

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
        instructions += `\`\`\`\nollama pull ${status.modelName}\n\`\`\`\n\n`;
        instructions += `*This downloads ~200MB. You can also install via the Flutter app (Search tab).*`;
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
  console.error("[MCP-VaultSearch] Server started");
}

main().catch((e) => {
  console.error("[MCP-VaultSearch] Fatal error:", e);
  process.exit(1);
});
