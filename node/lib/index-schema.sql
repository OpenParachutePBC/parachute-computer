-- Common Module Index Schema
-- Used by all Parachute modules (Daily, Chat, Build, etc.)
-- Located at: {module}/index.db
--
-- Indexers:
--   - Daily: Flutter client (EmbeddingGemma)
--   - Chat: Base server (Ollama)
--   - Build: Base server (Ollama)
--
-- Embedding model: embeddinggemma (256 dimensions after Matryoshka truncation)

-- Schema version for migrations
PRAGMA user_version = 1;

-- Content chunks with embeddings
CREATE TABLE IF NOT EXISTS chunks (
    id TEXT PRIMARY KEY,                    -- chunk:{content_id}:{chunk_index}
    content_id TEXT NOT NULL,               -- parent content identifier
    content_type TEXT NOT NULL,             -- module-specific: journal, session, artifact, etc.
    field TEXT DEFAULT 'content',           -- which field: content, title, summary, etc.
    chunk_index INTEGER NOT NULL,           -- order within content (0-based)
    chunk_text TEXT NOT NULL,               -- actual text content
    embedding BLOB,                         -- 256-dim float64 vector (2048 bytes) or NULL if not embedded
    created_at TEXT NOT NULL,               -- ISO 8601 timestamp

    UNIQUE(content_id, field, chunk_index)
);

-- Index manifest for tracking what's indexed
CREATE TABLE IF NOT EXISTS manifest (
    content_id TEXT PRIMARY KEY,            -- unique identifier for content
    content_type TEXT NOT NULL,             -- type of content
    source_path TEXT,                       -- relative path to source file
    content_hash TEXT,                      -- hash for change detection
    title TEXT,                             -- display title
    date TEXT,                              -- content date (ISO 8601)
    indexed_at TEXT NOT NULL,               -- when indexed (ISO 8601)
    chunk_count INTEGER NOT NULL,           -- number of chunks
    metadata TEXT                           -- JSON blob for type-specific data
);

-- Module metadata
CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TEXT NOT NULL
);

-- Indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_chunks_content ON chunks(content_id);
CREATE INDEX IF NOT EXISTS idx_chunks_type ON chunks(content_type);
CREATE INDEX IF NOT EXISTS idx_manifest_type ON manifest(content_type);
CREATE INDEX IF NOT EXISTS idx_manifest_date ON manifest(date DESC);
CREATE INDEX IF NOT EXISTS idx_manifest_indexed ON manifest(indexed_at DESC);

-- Initial metadata
INSERT OR REPLACE INTO metadata (key, value, updated_at) VALUES
    ('schema_version', '1', datetime('now')),
    ('embedding_model', 'embeddinggemma', datetime('now')),
    ('embedding_dimensions', '256', datetime('now'));
