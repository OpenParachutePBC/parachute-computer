/**
 * Claude Code Session Browser
 *
 * Reads and parses Claude Code terminal sessions from ~/.claude/projects/
 * These use the same SDK JSONL format that Parachute uses, so we can
 * directly resume them by session ID.
 */

import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import readline from 'readline';
import { createReadStream } from 'fs';

const CLAUDE_DIR = path.join(os.homedir(), '.claude');
const PROJECTS_DIR = path.join(CLAUDE_DIR, 'projects');

/**
 * Decode a project directory name back to the original path
 * e.g., "-Users-unforced-Parachute" -> "/Users/unforced/Parachute"
 */
function decodeProjectPath(encodedName) {
  // Replace leading dash and all dashes with /
  return encodedName.replace(/^-/, '/').replace(/-/g, '/');
}

/**
 * Encode a path to the project directory name format
 * e.g., "/Users/unforced/Parachute" -> "-Users-unforced-Parachute"
 */
function encodeProjectPath(projectPath) {
  return projectPath.replace(/\//g, '-');
}

/**
 * Get the real cwd path from a session file
 * This is more reliable than decoding the directory name (which has dash ambiguity)
 */
async function getCwdFromSessionFile(filePath) {
  return new Promise((resolve) => {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = readline.createInterface({ input: stream });
    let found = false;

    rl.on('line', (line) => {
      if (found) return;
      try {
        const event = JSON.parse(line);
        if (event.cwd) {
          found = true;
          rl.close();
          resolve(event.cwd);
        }
      } catch (e) {
        // Skip malformed lines
      }
    });

    rl.on('close', () => {
      stream.close();
      if (!found) resolve(null);
    });

    rl.on('error', () => {
      stream.close();
      resolve(null);
    });
  });
}

/**
 * List all Claude Code projects (working directories)
 */
export async function listProjects() {
  try {
    const entries = await fs.readdir(PROJECTS_DIR, { withFileTypes: true });
    const projects = [];

    for (const entry of entries) {
      if (entry.isDirectory() && entry.name.startsWith('-')) {
        const projectDir = path.join(PROJECTS_DIR, entry.name);

        // Count sessions in this project
        try {
          const files = await fs.readdir(projectDir);
          const jsonlFiles = files.filter(f => f.endsWith('.jsonl'));
          const sessionCount = jsonlFiles.length;

          // Get the real path from session files (more reliable than decoding)
          // Try multiple files since some may not have cwd (e.g., summary-only files)
          let realPath = null;
          for (const jsonlFile of jsonlFiles.slice(0, 5)) { // Try up to 5 files
            realPath = await getCwdFromSessionFile(path.join(projectDir, jsonlFile));
            if (realPath) break;
          }

          // Fall back to decoded path if no cwd found in any file
          if (!realPath) {
            realPath = decodeProjectPath(entry.name);
          }

          projects.push({
            encodedName: entry.name,
            path: realPath,
            sessionCount,
            projectDir
          });
        } catch (e) {
          // Skip inaccessible directories
        }
      }
    }

    return projects.sort((a, b) => b.sessionCount - a.sessionCount);
  } catch (e) {
    console.error('[ClaudeCode] Error listing projects:', e.message);
    return [];
  }
}

/**
 * Parse a single JSONL session file to extract metadata
 * Reads only first few lines for efficiency
 */
async function parseSessionMetadata(filePath) {
  return new Promise((resolve, reject) => {
    const metadata = {
      sessionId: path.basename(filePath, '.jsonl'),
      filePath,
      title: null,
      firstMessage: null,
      messageCount: 0,
      createdAt: null,
      lastTimestamp: null,
      model: null,
      cwd: null
    };

    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = readline.createInterface({ input: stream });

    let lineCount = 0;
    const maxLines = 50; // Read enough to get good metadata

    rl.on('line', (line) => {
      lineCount++;

      try {
        const event = JSON.parse(line);

        // Track message count
        if (event.type === 'user' || event.type === 'assistant') {
          metadata.messageCount++;
        }

        // Get cwd from first message
        if (!metadata.cwd && event.cwd) {
          metadata.cwd = event.cwd;
        }

        // Get created timestamp from first message
        if (!metadata.createdAt && event.timestamp) {
          metadata.createdAt = event.timestamp;
        }

        // Track last timestamp
        if (event.timestamp) {
          metadata.lastTimestamp = event.timestamp;
        }

        // Get model from assistant message
        if (!metadata.model && event.message?.model) {
          metadata.model = event.message.model;
        }

        // Get first user message as preview
        if (!metadata.firstMessage && event.type === 'user' && event.message) {
          const content = event.message.content;
          if (typeof content === 'string') {
            metadata.firstMessage = content.slice(0, 200);
          } else if (Array.isArray(content)) {
            const textBlock = content.find(b => b.type === 'text');
            if (textBlock?.text) {
              metadata.firstMessage = textBlock.text.slice(0, 200);
            }
          }
        }

        // Check for summary (title)
        if (event.type === 'summary' && event.summary) {
          metadata.title = event.summary;
        }

      } catch (e) {
        // Skip malformed lines
      }

      if (lineCount >= maxLines) {
        rl.close();
      }
    });

    rl.on('close', () => {
      stream.close();
      resolve(metadata);
    });

    rl.on('error', (err) => {
      stream.close();
      reject(err);
    });
  });
}

/**
 * Get full message count by scanning entire file
 */
async function getFullMessageCount(filePath) {
  return new Promise((resolve) => {
    let count = 0;
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    const rl = readline.createInterface({ input: stream });

    rl.on('line', (line) => {
      try {
        const event = JSON.parse(line);
        if (event.type === 'user' || event.type === 'assistant') {
          count++;
        }
      } catch (e) {}
    });

    rl.on('close', () => {
      stream.close();
      resolve(count);
    });

    rl.on('error', () => {
      stream.close();
      resolve(count);
    });
  });
}

/**
 * List sessions in a specific project
 */
export async function listSessions(projectPath) {
  const encodedName = encodeProjectPath(projectPath);
  const projectDir = path.join(PROJECTS_DIR, encodedName);

  try {
    const files = await fs.readdir(projectDir);
    const jsonlFiles = files.filter(f => f.endsWith('.jsonl'));

    const sessions = [];

    for (const file of jsonlFiles) {
      const filePath = path.join(projectDir, file);
      try {
        const metadata = await parseSessionMetadata(filePath);
        sessions.push(metadata);
      } catch (e) {
        console.error(`[ClaudeCode] Error parsing ${file}:`, e.message);
      }
    }

    // Sort by last activity (most recent first)
    sessions.sort((a, b) => {
      const dateA = a.lastTimestamp ? new Date(a.lastTimestamp) : new Date(0);
      const dateB = b.lastTimestamp ? new Date(b.lastTimestamp) : new Date(0);
      return dateB - dateA;
    });

    return sessions;
  } catch (e) {
    console.error('[ClaudeCode] Error listing sessions:', e.message);
    return [];
  }
}

/**
 * Get full session details including all messages
 */
export async function getSession(sessionId, projectPath) {
  const encodedName = encodeProjectPath(projectPath);
  const filePath = path.join(PROJECTS_DIR, encodedName, `${sessionId}.jsonl`);

  try {
    await fs.access(filePath);
  } catch (e) {
    throw new Error(`Session not found: ${sessionId}`);
  }

  const messages = [];
  const metadata = {
    sessionId,
    filePath,
    cwd: null,
    model: null,
    createdAt: null,
    title: null
  };

  const content = await fs.readFile(filePath, 'utf8');
  const lines = content.split('\n').filter(l => l.trim());

  for (const line of lines) {
    try {
      const event = JSON.parse(line);

      if (!metadata.cwd && event.cwd) metadata.cwd = event.cwd;
      if (!metadata.createdAt && event.timestamp) metadata.createdAt = event.timestamp;
      if (!metadata.model && event.message?.model) metadata.model = event.message.model;
      if (event.type === 'summary') metadata.title = event.summary;

      if (event.type === 'user' || event.type === 'assistant') {
        const message = {
          type: event.type,
          timestamp: event.timestamp,
          uuid: event.uuid
        };

        // Extract content
        const content = event.message?.content;
        if (typeof content === 'string') {
          message.content = content;
        } else if (Array.isArray(content)) {
          // Combine text blocks
          message.content = content
            .filter(b => b.type === 'text')
            .map(b => b.text)
            .join('\n');

          // Track tool uses
          const toolUses = content.filter(b => b.type === 'tool_use');
          if (toolUses.length > 0) {
            message.toolUses = toolUses.map(t => ({
              id: t.id,
              name: t.name,
              input: t.input
            }));
          }
        }

        messages.push(message);
      }
    } catch (e) {
      // Skip malformed lines
    }
  }

  return { ...metadata, messages };
}

/**
 * Check if a session ID exists in any project
 */
export async function findSession(sessionId) {
  const projects = await listProjects();

  for (const project of projects) {
    const filePath = path.join(project.projectDir, `${sessionId}.jsonl`);
    try {
      await fs.access(filePath);
      return {
        found: true,
        projectPath: project.path,
        filePath
      };
    } catch (e) {
      // Continue searching
    }
  }

  return { found: false };
}

/**
 * Get the JSONL file path for a session
 */
export function getSessionFilePath(sessionId, projectPath) {
  const encodedName = encodeProjectPath(projectPath);
  return path.join(PROJECTS_DIR, encodedName, `${sessionId}.jsonl`);
}

/**
 * List recent sessions across ALL projects, sorted by last activity
 * @param {number} limit - Maximum sessions to return (default 100)
 * @returns {Array} Sessions with projectPath added
 */
export async function listRecentSessions(limit = 100) {
  const projects = await listProjects();
  const allSessions = [];

  for (const project of projects) {
    if (project.sessionCount === 0) continue;

    try {
      const sessions = await listSessions(project.path);
      // Add project info to each session
      for (const session of sessions) {
        allSessions.push({
          ...session,
          projectPath: project.path,
          projectDisplayName: project.displayName
        });
      }
    } catch (e) {
      console.error(`[ClaudeCode] Error loading sessions from ${project.path}:`, e.message);
      // Continue with other projects
    }
  }

  // Sort by lastTimestamp descending (most recent first)
  allSessions.sort((a, b) => {
    const dateA = a.lastTimestamp ? new Date(a.lastTimestamp) : new Date(0);
    const dateB = b.lastTimestamp ? new Date(b.lastTimestamp) : new Date(0);
    return dateB - dateA;
  });

  // Return limited results
  return allSessions.slice(0, limit);
}

/**
 * Migrate a session to a new project path
 * Creates a symlink from new encoded path to old encoded path
 * @param {string} sessionId - The session ID
 * @param {string} originalPath - Original project path where session was created
 * @param {string} newPath - New project path to access session from
 * @returns {object} Migration result
 */
export async function migrateSessionPath(sessionId, originalPath, newPath) {
  const originalEncoded = encodeProjectPath(originalPath);
  const newEncoded = encodeProjectPath(newPath);

  const originalDir = path.join(PROJECTS_DIR, originalEncoded);
  const newDir = path.join(PROJECTS_DIR, newEncoded);
  const sessionFile = `${sessionId}.jsonl`;

  // Verify session exists at original location
  const originalFile = path.join(originalDir, sessionFile);
  try {
    await fs.access(originalFile);
  } catch {
    throw new Error(`Session not found at original path: ${originalPath}`);
  }

  // Create new directory if it doesn't exist
  try {
    await fs.mkdir(newDir, { recursive: true });
  } catch {
    // May already exist
  }

  // Check if file already exists at new location
  const newFile = path.join(newDir, sessionFile);
  try {
    await fs.access(newFile);
    return {
      success: true,
      alreadyExists: true,
      message: 'Session already accessible from new path'
    };
  } catch {
    // Doesn't exist, we'll create it
  }

  // Create symlink from new location to original file
  try {
    await fs.symlink(originalFile, newFile);
    return {
      success: true,
      alreadyExists: false,
      message: `Session now accessible from ${newPath}`,
      symlinkCreated: newFile
    };
  } catch (e) {
    throw new Error(`Failed to create symlink: ${e.message}`);
  }
}
