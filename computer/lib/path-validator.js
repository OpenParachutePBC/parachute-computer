/**
 * Path Validator
 *
 * Shared path validation utilities to prevent path traversal attacks.
 * Used by both the server and agent-loader for consistent security.
 */

import path from 'path';

/**
 * Validate a vault-relative path to prevent path traversal attacks.
 * Returns the normalized path if valid, null if invalid.
 *
 * @param {string} relativePath - The path to validate (should be relative)
 * @param {string} basePath - The base path (vault path) to validate against
 * @returns {string|null} - Normalized path if valid, null if invalid
 */
export function validateRelativePath(relativePath, basePath) {
  if (!relativePath || typeof relativePath !== 'string') return null;
  if (!basePath || typeof basePath !== 'string') return null;

  // Reject empty paths
  if (relativePath.trim() === '') return null;

  // Reject absolute paths
  if (path.isAbsolute(relativePath)) return null;

  // Normalize and check for traversal
  const normalized = path.normalize(relativePath);

  // After normalization, check if it tries to escape
  if (normalized.startsWith('..') || normalized.includes('/../')) return null;

  // Reject null bytes (common attack vector)
  if (relativePath.includes('\0')) return null;

  // Resolve the full path and ensure it's within the base path
  const fullPath = path.resolve(basePath, normalized);
  const baseResolved = path.resolve(basePath);

  if (!fullPath.startsWith(baseResolved + path.sep) && fullPath !== baseResolved) {
    return null;
  }

  return normalized;
}

/**
 * Sanitize a filename to prevent path traversal attacks.
 * Only allows alphanumeric, dash, underscore, and dot characters.
 *
 * @param {string} filename - The filename to sanitize
 * @returns {string|null} - Sanitized filename if valid, null if invalid
 */
export function sanitizeFilename(filename) {
  if (!filename || typeof filename !== 'string') return null;

  // Reject path traversal attempts
  if (filename.includes('..') || filename.includes('/') || filename.includes('\\')) {
    return null;
  }

  // Only allow safe characters
  if (!/^[a-zA-Z0-9_\-\.]+$/.test(filename)) {
    return null;
  }

  return filename;
}

/**
 * Check if a path is safe to use within a vault.
 * Throws an error with a descriptive message if invalid.
 *
 * @param {string} relativePath - The path to validate
 * @param {string} basePath - The base path to validate against
 * @throws {Error} - If the path is invalid
 * @returns {string} - The normalized path
 */
export function assertValidPath(relativePath, basePath) {
  const normalized = validateRelativePath(relativePath, basePath);

  if (normalized === null) {
    if (!relativePath || typeof relativePath !== 'string') {
      throw new Error('Path is required and must be a string');
    }
    if (path.isAbsolute(relativePath)) {
      throw new Error(`Absolute paths are not allowed: ${relativePath}`);
    }
    if (relativePath.includes('..')) {
      throw new Error(`Path traversal not allowed: ${relativePath}`);
    }
    throw new Error(`Path must be within the vault: ${relativePath}`);
  }

  return normalized;
}

/**
 * Validate a session ID.
 * Session IDs are opaque strings from the SDK, but we validate they're safe.
 *
 * @param {string} id - The session ID to validate
 * @returns {string|null} - The session ID if valid, null if invalid
 */
export function validateSessionId(id) {
  if (!id || typeof id !== 'string') return null;

  // Must be non-empty after trimming
  if (id.trim() === '') return null;

  // Reject path traversal attempts
  if (id.includes('..') || id.includes('/') || id.includes('\\')) return null;

  // Reject null bytes
  if (id.includes('\0')) return null;

  // Session IDs should be reasonably sized (max 200 chars)
  if (id.length > 200) return null;

  return id;
}

export default {
  validateRelativePath,
  sanitizeFilename,
  assertValidPath,
  validateSessionId
};
