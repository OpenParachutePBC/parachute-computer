/**
 * Ollama Service
 *
 * Provides embedding generation and health checking for Ollama.
 * Used by vault-search MCP for semantic search capability.
 *
 * Configuration:
 * - Model: embeddinggemma (same as Flutter app for compatibility)
 * - Dimensions: 256 (truncated from 768 via Matryoshka)
 * - Ollama URL: http://localhost:11434 (default)
 */

// Configuration - must match Flutter app's DesktopEmbeddingConfig
const CONFIG = {
  modelName: 'embeddinggemma',
  nativeDimensions: 768,
  targetDimensions: 256,
  ollamaUrl: process.env.OLLAMA_URL || 'http://localhost:11434',
};

/**
 * Check if Ollama is running
 * @returns {Promise<boolean>}
 */
export async function isOllamaRunning() {
  try {
    const response = await fetch(`${CONFIG.ollamaUrl}/api/tags`, {
      method: 'GET',
      signal: AbortSignal.timeout(5000),
    });
    return response.ok;
  } catch (e) {
    return false;
  }
}

/**
 * Check if the embedding model is available
 * @returns {Promise<{available: boolean, models: string[]}>}
 */
export async function checkEmbeddingModel() {
  try {
    const response = await fetch(`${CONFIG.ollamaUrl}/api/tags`, {
      method: 'GET',
      signal: AbortSignal.timeout(5000),
    });

    if (!response.ok) {
      return { available: false, models: [] };
    }

    const data = await response.json();
    const models = (data.models || []).map(m => m.name || m.model || '');

    // Check for embeddinggemma (with or without :latest tag)
    const hasModel = models.some(
      m => m === CONFIG.modelName || m.startsWith(`${CONFIG.modelName}:`)
    );

    return { available: hasModel, models };
  } catch (e) {
    return { available: false, models: [], error: e.message };
  }
}

/**
 * Get full Ollama setup status
 * @returns {Promise<OllamaStatus>}
 */
export async function getOllamaStatus() {
  const status = {
    ollamaRunning: false,
    modelAvailable: false,
    modelName: CONFIG.modelName,
    ollamaUrl: CONFIG.ollamaUrl,
    ready: false,
    setupInstructions: null,
  };

  // Check if Ollama is running
  status.ollamaRunning = await isOllamaRunning();

  if (!status.ollamaRunning) {
    status.setupInstructions = getOllamaInstallInstructions();
    return status;
  }

  // Check if model is available
  const modelCheck = await checkEmbeddingModel();
  status.modelAvailable = modelCheck.available;

  if (!status.modelAvailable) {
    status.setupInstructions = getModelInstallInstructions();
    return status;
  }

  status.ready = true;
  return status;
}

/**
 * Generate embedding for a text query
 * @param {string} text - Text to embed
 * @returns {Promise<number[]>} - 256-dimensional embedding vector
 */
export async function generateEmbedding(text) {
  if (!text || text.trim() === '') {
    throw new Error('Text cannot be empty');
  }

  const response = await fetch(`${CONFIG.ollamaUrl}/api/embeddings`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: CONFIG.modelName,
      prompt: text,
    }),
    signal: AbortSignal.timeout(30000),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Ollama embedding failed: ${error}`);
  }

  const data = await response.json();

  if (!data.embedding || data.embedding.length === 0) {
    throw new Error('Ollama returned empty embedding');
  }

  // Truncate to 256 dimensions (Matryoshka) and normalize
  const truncated = truncateAndNormalize(data.embedding, CONFIG.targetDimensions);
  return truncated;
}

/**
 * Truncate embedding to target dimensions and renormalize
 * @param {number[]} embedding - Full embedding vector
 * @param {number} targetDimensions - Target size
 * @returns {number[]} - Truncated and normalized vector
 */
function truncateAndNormalize(embedding, targetDimensions) {
  if (embedding.length < targetDimensions) {
    throw new Error(
      `Cannot truncate embedding of length ${embedding.length} to ${targetDimensions}`
    );
  }

  // Take first N dimensions (Matryoshka property)
  const truncated = embedding.slice(0, targetDimensions);

  // Renormalize to unit length (L2 norm = 1)
  let sumSquares = 0;
  for (const value of truncated) {
    sumSquares += value * value;
  }
  const magnitude = Math.sqrt(sumSquares);

  if (magnitude === 0) {
    return truncated;
  }

  return truncated.map(v => v / magnitude);
}

/**
 * Calculate cosine similarity between two vectors
 * @param {number[]} a - First vector (normalized)
 * @param {number[]} b - Second vector (normalized)
 * @returns {number} - Similarity score between -1 and 1
 */
export function cosineSimilarity(a, b) {
  if (a.length !== b.length) {
    throw new Error(`Vector length mismatch: ${a.length} vs ${b.length}`);
  }

  let dotProduct = 0;
  for (let i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
  }

  // For normalized vectors, dot product = cosine similarity
  return dotProduct;
}

/**
 * Get installation instructions for Ollama
 */
function getOllamaInstallInstructions() {
  return {
    title: 'Ollama Not Running',
    message: 'Ollama is required for semantic search (finding similar content).',
    steps: [
      {
        platform: 'macOS',
        commands: [
          'brew install ollama',
          '# Ollama starts automatically after install',
        ],
      },
      {
        platform: 'Linux',
        commands: [
          'curl -fsSL https://ollama.com/install.sh | sh',
          'ollama serve',
        ],
      },
      {
        platform: 'Windows',
        commands: [
          'Download from https://ollama.com/download',
          'Run the installer and start Ollama',
        ],
      },
    ],
    docsUrl: 'https://ollama.com',
  };
}

/**
 * Get instructions for installing the embedding model
 */
function getModelInstallInstructions() {
  return {
    title: 'Embedding Model Not Found',
    message: `The '${CONFIG.modelName}' model is required for semantic search.`,
    steps: [
      {
        platform: 'All platforms',
        commands: [
          `ollama pull ${CONFIG.modelName}`,
        ],
      },
    ],
    note: 'This downloads ~200MB. You can also download via the Flutter app (Search tab).',
  };
}

export default {
  isOllamaRunning,
  checkEmbeddingModel,
  getOllamaStatus,
  generateEmbedding,
  cosineSimilarity,
  CONFIG,
};
