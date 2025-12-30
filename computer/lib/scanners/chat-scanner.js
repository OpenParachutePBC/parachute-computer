/**
 * Chat Module Content Scanner
 *
 * Scans Chat/sessions/ for chat session markdown files
 * and extracts content for indexing.
 */

import { readdirSync, readFileSync, statSync, existsSync } from 'fs';
import { join, relative } from 'path';
import { createLogger } from '../logger.js';

const log = createLogger('ChatScanner');

/**
 * Parse session markdown file
 * @param {string} content - Raw markdown content
 * @returns {Object} Parsed session data
 */
function parseSessionMarkdown(content) {
  const result = {
    frontmatter: {},
    messages: [],
    rawContent: content,
  };

  // Extract YAML frontmatter
  const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---\n/);
  if (frontmatterMatch) {
    const yamlStr = frontmatterMatch[1];
    // Simple YAML parsing for key: value pairs
    for (const line of yamlStr.split('\n')) {
      const match = line.match(/^(\w+):\s*(.*)$/);
      if (match) {
        let value = match[2].trim();
        // Remove quotes if present
        if ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'"))) {
          value = value.slice(1, -1);
        }
        result.frontmatter[match[1]] = value;
      }
    }
  }

  // Extract messages (### User | timestamp or ### Assistant | timestamp)
  const messagePattern = /### (User|Assistant)\s*\|\s*([^\n]+)\n([\s\S]*?)(?=\n### |\n---|\Z|$)/g;
  let match;
  while ((match = messagePattern.exec(content)) !== null) {
    result.messages.push({
      role: match[1].toLowerCase(),
      timestamp: match[2].trim(),
      content: match[3].trim(),
    });
  }

  return result;
}

/**
 * Extract indexable text from a session
 * @param {Object} session - Parsed session
 * @returns {string} Combined text content
 */
function extractSessionText(session) {
  const parts = [];

  // Add title if present
  if (session.frontmatter.title) {
    parts.push(`Title: ${session.frontmatter.title}`);
  }

  // Add message content
  for (const msg of session.messages) {
    parts.push(`${msg.role}: ${msg.content}`);
  }

  return parts.join('\n\n');
}

/**
 * Create a Chat module content scanner
 * @param {string} chatPath - Path to Chat module (e.g., /vault/Chat)
 * @returns {ContentScanner}
 */
export function createChatScanner(chatPath) {
  const sessionsPath = join(chatPath, 'sessions');

  /**
   * Recursively find all markdown files in sessions directory
   * @param {string} dir
   * @returns {string[]}
   */
  function findSessionFiles(dir) {
    if (!existsSync(dir)) return [];

    const files = [];
    const entries = readdirSync(dir, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        files.push(...findSessionFiles(fullPath));
      } else if (entry.name.endsWith('.md')) {
        files.push(fullPath);
      }
    }

    return files;
  }

  return {
    /**
     * Scan all chat sessions
     * @returns {Promise<ContentItem[]>}
     */
    async scan() {
      const items = [];
      const files = findSessionFiles(sessionsPath);

      log.debug(`Found ${files.length} session files`);

      for (const filePath of files) {
        try {
          const content = readFileSync(filePath, 'utf-8');
          const session = parseSessionMarkdown(content);
          const stat = statSync(filePath);

          // Generate session ID from frontmatter or filename
          const sessionId = session.frontmatter.session_id ||
            session.frontmatter.id ||
            filePath.replace(/\.md$/, '').split('/').pop();

          // Determine date from frontmatter or file stat
          const date = session.frontmatter.created_at ||
            session.frontmatter.date ||
            stat.mtime.toISOString();

          // Skip empty sessions
          const text = extractSessionText(session);
          if (!text || text.length < 50) {
            continue;
          }

          items.push({
            id: `session:${sessionId}`,
            type: 'session',
            sourcePath: relative(chatPath, filePath),
            title: session.frontmatter.title || `Session ${sessionId.slice(0, 8)}`,
            date: date,
            content: text,
            metadata: {
              agent: session.frontmatter.agent,
              messageCount: session.messages.length,
              archived: session.frontmatter.archived === 'true',
              workingDirectory: session.frontmatter.working_directory,
            },
          });
        } catch (err) {
          log.warn(`Failed to parse ${filePath}: ${err.message}`);
        }
      }

      log.info(`Scanned ${items.length} sessions`);
      return items;
    },

    /**
     * Get a single session by ID
     * @param {string} id
     * @returns {Promise<ContentItem|null>}
     */
    async getById(id) {
      // Remove 'session:' prefix if present
      const sessionId = id.replace(/^session:/, '');

      // Search for matching file
      const files = findSessionFiles(sessionsPath);
      for (const filePath of files) {
        try {
          const content = readFileSync(filePath, 'utf-8');
          const session = parseSessionMarkdown(content);

          const fileSessionId = session.frontmatter.session_id ||
            session.frontmatter.id ||
            filePath.replace(/\.md$/, '').split('/').pop();

          if (fileSessionId === sessionId) {
            const stat = statSync(filePath);
            const text = extractSessionText(session);

            return {
              id: `session:${sessionId}`,
              type: 'session',
              sourcePath: relative(chatPath, filePath),
              title: session.frontmatter.title || `Session ${sessionId.slice(0, 8)}`,
              date: session.frontmatter.created_at || stat.mtime.toISOString(),
              content: text,
              metadata: {
                agent: session.frontmatter.agent,
                messageCount: session.messages.length,
                archived: session.frontmatter.archived === 'true',
              },
            };
          }
        } catch (err) {
          // Continue searching
        }
      }

      return null;
    },
  };
}

export default createChatScanner;
