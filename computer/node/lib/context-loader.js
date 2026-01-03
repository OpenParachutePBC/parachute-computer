/**
 * Context Loader
 *
 * Loads context/knowledge for agents:
 * - Reads knowledge files that define what an agent "knows"
 * - Resolves [[wiki-links]] in knowledge files
 * - Loads files matching include patterns
 * - Respects max_tokens limits
 */

import fs from 'fs/promises';
import path from 'path';
import { glob } from 'glob';

/**
 * Load context for an agent based on its context configuration
 *
 * @param {object} contextConfig - Agent's context configuration
 * @param {string} vaultPath - Base vault path
 * @param {object} options - Options like max_tokens
 * @returns {Promise<{files: Array, totalTokens: number, content: string}>}
 */
export async function loadAgentContext(contextConfig, vaultPath, options = {}) {
  const maxTokens = options.max_tokens || contextConfig.max_tokens || 50000;
  const loadedFiles = [];
  let totalContent = '';
  let estimatedTokens = 0;

  // 1. Load knowledge file if specified
  if (contextConfig.knowledge_file) {
    const knowledgeResult = await loadKnowledgeFile(
      contextConfig.knowledge_file,
      vaultPath,
      maxTokens - estimatedTokens
    );
    loadedFiles.push(...knowledgeResult.files);
    totalContent += knowledgeResult.content;
    estimatedTokens += knowledgeResult.estimatedTokens;
  }

  // 2. Load files matching include patterns
  if (contextConfig.include && Array.isArray(contextConfig.include)) {
    for (const pattern of contextConfig.include) {
      if (estimatedTokens >= maxTokens) break;

      const files = await resolveGlobPattern(pattern, vaultPath);
      for (const file of files) {
        if (estimatedTokens >= maxTokens) break;
        if (loadedFiles.some(f => f.path === file)) continue; // Skip duplicates

        const fileResult = await loadFile(file, vaultPath, maxTokens - estimatedTokens);
        if (fileResult) {
          loadedFiles.push(fileResult);
          totalContent += `\n\n---\n## ${file}\n\n${fileResult.content}`;
          estimatedTokens += fileResult.estimatedTokens;
        }
      }
    }
  }

  return {
    files: loadedFiles,
    totalTokens: estimatedTokens,
    content: totalContent
  };
}

/**
 * Load a knowledge file and resolve its [[wiki-links]]
 *
 * @param {string} knowledgePath - Path to the knowledge file
 * @param {string} vaultPath - Base vault path
 * @param {number} remainingTokens - Token budget remaining
 * @returns {Promise<{files: Array, content: string, estimatedTokens: number}>}
 */
async function loadKnowledgeFile(knowledgePath, vaultPath, remainingTokens) {
  const fullPath = path.join(vaultPath, knowledgePath);
  const loadedFiles = [];
  let content = '';
  let estimatedTokens = 0;

  try {
    const knowledgeContent = await fs.readFile(fullPath, 'utf-8');

    // Add the knowledge file itself as context header
    content += `## Knowledge: ${knowledgePath}\n\n${knowledgeContent}\n`;
    estimatedTokens += estimateTokens(knowledgeContent);
    loadedFiles.push({
      path: knowledgePath,
      type: 'knowledge',
      content: knowledgeContent,
      estimatedTokens: estimateTokens(knowledgeContent)
    });

    // Extract and resolve [[wiki-links]]
    const wikiLinks = extractWikiLinks(knowledgeContent);

    for (const link of wikiLinks) {
      if (estimatedTokens >= remainingTokens) break;

      const resolvedPath = resolveWikiLink(link, vaultPath);
      if (!resolvedPath) continue;
      if (loadedFiles.some(f => f.path === resolvedPath)) continue;

      const fileResult = await loadFile(resolvedPath, vaultPath, remainingTokens - estimatedTokens);
      if (fileResult) {
        loadedFiles.push(fileResult);
        content += `\n\n---\n## ${resolvedPath}\n\n${fileResult.content}`;
        estimatedTokens += fileResult.estimatedTokens;
      }
    }

  } catch (e) {
    console.warn(`[ContextLoader] Could not load knowledge file ${knowledgePath}:`, e.message);
  }

  return { files: loadedFiles, content, estimatedTokens };
}

/**
 * Extract [[wiki-links]] from content
 *
 * Supports:
 * - [[simple-link]]
 * - [[link|display text]]
 * - [[folder/nested-link]]
 *
 * @param {string} content
 * @returns {string[]} Array of link targets (without [[ ]])
 */
function extractWikiLinks(content) {
  const linkRegex = /\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/g;
  const links = [];
  let match;

  while ((match = linkRegex.exec(content)) !== null) {
    links.push(match[1].trim());
  }

  return [...new Set(links)]; // Remove duplicates
}

/**
 * Resolve a wiki-link to an actual file path
 *
 * @param {string} link - The wiki link target
 * @param {string} vaultPath - Base vault path
 * @returns {string|null} Resolved path or null if not found
 */
function resolveWikiLink(link, vaultPath) {
  // Add .md if not present
  const linkWithExt = link.endsWith('.md') ? link : `${link}.md`;

  // Try exact path first
  const exactPath = path.join(vaultPath, linkWithExt);
  try {
    // Use sync check for simplicity (will be called rarely)
    const stats = require('fs').statSync(exactPath);
    if (stats.isFile()) {
      return linkWithExt;
    }
  } catch {
    // File doesn't exist at exact path
  }

  // Could add fuzzy matching here later (search for file by name in vault)
  return null;
}

/**
 * Resolve a glob pattern to actual file paths
 *
 * @param {string} pattern - Glob pattern
 * @param {string} vaultPath - Base vault path
 * @returns {Promise<string[]>} Array of matching file paths (relative to vault)
 */
async function resolveGlobPattern(pattern, vaultPath) {
  try {
    const matches = await glob(pattern, {
      cwd: vaultPath,
      nodir: true,
      ignore: ['**/node_modules/**', '**/.obsidian/**']
    });
    return matches;
  } catch (e) {
    console.warn(`[ContextLoader] Error resolving pattern ${pattern}:`, e.message);
    return [];
  }
}

/**
 * Load a single file
 *
 * @param {string} filePath - Relative path to file
 * @param {string} vaultPath - Base vault path
 * @param {number} maxTokens - Max tokens to include
 * @returns {Promise<{path: string, content: string, estimatedTokens: number, truncated: boolean}|null>}
 */
async function loadFile(filePath, vaultPath, maxTokens) {
  const fullPath = path.join(vaultPath, filePath);

  try {
    let content = await fs.readFile(fullPath, 'utf-8');
    let truncated = false;
    let tokens = estimateTokens(content);

    // Truncate if necessary
    if (tokens > maxTokens) {
      const ratio = maxTokens / tokens;
      const charLimit = Math.floor(content.length * ratio * 0.9); // 90% to be safe
      content = content.substring(0, charLimit) + '\n\n[... truncated ...]';
      tokens = maxTokens;
      truncated = true;
    }

    return {
      path: filePath,
      type: 'file',
      content,
      estimatedTokens: tokens,
      truncated
    };

  } catch (e) {
    console.warn(`[ContextLoader] Could not load file ${filePath}:`, e.message);
    return null;
  }
}

/**
 * Rough token estimation (~4 chars per token for English text)
 *
 * @param {string} text
 * @returns {number}
 */
function estimateTokens(text) {
  return Math.ceil(text.length / 4);
}

/**
 * Format loaded context as a system prompt section
 *
 * @param {object} contextResult - Result from loadAgentContext
 * @returns {string}
 */
export function formatContextForPrompt(contextResult) {
  if (!contextResult.content || contextResult.files.length === 0) {
    return '';
  }

  let prompt = `\n\n## Project Knowledge\n`;
  prompt += `The following context has been loaded for your reference (${contextResult.files.length} files, ~${contextResult.totalTokens} tokens):\n`;
  prompt += contextResult.content;

  return prompt;
}

export default {
  loadAgentContext,
  formatContextForPrompt,
  extractWikiLinks
};
