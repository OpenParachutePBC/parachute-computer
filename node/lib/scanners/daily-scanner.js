/**
 * Daily Module Content Scanner
 *
 * Scans Daily/journals/ for journal markdown files
 * and extracts content for indexing.
 *
 * Supports two formats:
 * 1. Simple text files (older format)
 * 2. YAML frontmatter with entries (newer format)
 */

import { readdirSync, readFileSync, statSync, existsSync } from 'fs';
import { join, relative } from 'path';
import { createLogger } from '../logger.js';

const log = createLogger('DailyScanner');

/**
 * Parse journal markdown file
 * @param {string} content - Raw markdown content
 * @param {string} filename - Filename for date extraction
 * @returns {Object} Parsed journal data
 */
function parseJournalMarkdown(content, filename) {
  const result = {
    frontmatter: {},
    entries: [],
    rawContent: content,
    date: null,
  };

  // Extract date from filename (YYYY-MM-DD.md format)
  const dateMatch = filename.match(/(\d{4}-\d{2}-\d{2})\.md$/);
  if (dateMatch) {
    result.date = dateMatch[1];
  }

  // Check for YAML frontmatter
  const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---\n/);
  if (frontmatterMatch) {
    const yamlStr = frontmatterMatch[1];
    // Parse date if present
    const dateLineMatch = yamlStr.match(/^date:\s*(.+)$/m);
    if (dateLineMatch) {
      result.frontmatter.date = dateLineMatch[1].trim();
      result.date = result.date || result.frontmatter.date;
    }

    // Parse entries from frontmatter
    const entriesMatch = yamlStr.match(/entries:\n([\s\S]*?)(?=\n\w|\Z|$)/);
    if (entriesMatch) {
      // Extract entry IDs
      const entryIds = entriesMatch[1].match(/^\s+(daily:[a-z0-9]+):/gm);
      if (entryIds) {
        for (const id of entryIds) {
          const cleanId = id.trim().replace(':', '');
          result.frontmatter[cleanId] = true;
        }
      }
    }
  }

  // Extract individual entries (# para:daily:xxx or ## Entry format)
  // Format: # para:daily:id timestamp\n content \n---
  const entryPattern = /^#+ (?:para:)?(daily:[a-z0-9]+)\s+([^\n]*)\n([\s\S]*?)(?=\n---|\n#+ (?:para:)?daily:|$)/gm;
  let match;
  while ((match = entryPattern.exec(content)) !== null) {
    result.entries.push({
      id: match[1],
      timestamp: match[2].trim(),
      content: match[3].trim(),
    });
  }

  // If no structured entries found, treat entire content as single entry
  if (result.entries.length === 0) {
    // Remove frontmatter if present
    let textContent = content;
    if (frontmatterMatch) {
      textContent = content.slice(frontmatterMatch[0].length).trim();
    }

    if (textContent.length > 0) {
      result.entries.push({
        id: `journal:${result.date || 'unknown'}`,
        timestamp: '',
        content: textContent,
      });
    }
  }

  return result;
}

/**
 * Extract indexable text from a journal
 * @param {Object} journal - Parsed journal
 * @returns {string} Combined text content
 */
function extractJournalText(journal) {
  const parts = [];

  // Add date
  if (journal.date) {
    parts.push(`Date: ${journal.date}`);
  }

  // Add all entry content
  for (const entry of journal.entries) {
    if (entry.content) {
      parts.push(entry.content);
    }
  }

  return parts.join('\n\n');
}

/**
 * Create a Daily module content scanner
 * @param {string} dailyPath - Path to Daily module (e.g., /vault/Daily)
 * @returns {ContentScanner}
 */
export function createDailyScanner(dailyPath) {
  const journalsPath = join(dailyPath, 'journals');

  /**
   * Find all markdown files in journals directory
   * @returns {string[]}
   */
  function findJournalFiles() {
    if (!existsSync(journalsPath)) return [];

    const files = [];
    const entries = readdirSync(journalsPath, { withFileTypes: true });

    for (const entry of entries) {
      if (entry.isFile() && entry.name.endsWith('.md')) {
        files.push(join(journalsPath, entry.name));
      }
    }

    return files;
  }

  return {
    /**
     * Scan all journal entries
     * @returns {Promise<ContentItem[]>}
     */
    async scan() {
      const items = [];
      const files = findJournalFiles();

      log.debug(`Found ${files.length} journal files`);

      for (const filePath of files) {
        try {
          const content = readFileSync(filePath, 'utf-8');
          const filename = filePath.split('/').pop();
          const journal = parseJournalMarkdown(content, filename);
          const stat = statSync(filePath);

          // Skip empty journals
          const text = extractJournalText(journal);
          if (!text || text.length < 20) {
            continue;
          }

          // Create a single item per journal file (one per day)
          const journalId = journal.date || filename.replace('.md', '');

          items.push({
            id: `journal:${journalId}`,
            type: 'journal',
            sourcePath: relative(dailyPath, filePath),
            title: `Journal - ${journalId}`,
            date: journal.date ? `${journal.date}T00:00:00Z` : stat.mtime.toISOString(),
            content: text,
            metadata: {
              entryCount: journal.entries.length,
              filename: filename,
            },
          });
        } catch (err) {
          log.warn(`Failed to parse ${filePath}: ${err.message}`);
        }
      }

      log.info(`Scanned ${items.length} journals`);
      return items;
    },

    /**
     * Get a single journal by ID
     * @param {string} id
     * @returns {Promise<ContentItem|null>}
     */
    async getById(id) {
      // Remove 'journal:' prefix if present
      const journalId = id.replace(/^journal:/, '');

      // Look for matching file
      const filePath = join(journalsPath, `${journalId}.md`);

      if (!existsSync(filePath)) {
        return null;
      }

      try {
        const content = readFileSync(filePath, 'utf-8');
        const filename = filePath.split('/').pop();
        const journal = parseJournalMarkdown(content, filename);
        const stat = statSync(filePath);
        const text = extractJournalText(journal);

        return {
          id: `journal:${journalId}`,
          type: 'journal',
          sourcePath: relative(dailyPath, filePath),
          title: `Journal - ${journalId}`,
          date: journal.date ? `${journal.date}T00:00:00Z` : stat.mtime.toISOString(),
          content: text,
          metadata: {
            entryCount: journal.entries.length,
            filename: filename,
          },
        };
      } catch (err) {
        log.warn(`Failed to get journal ${journalId}: ${err.message}`);
        return null;
      }
    },
  };
}

export default createDailyScanner;
