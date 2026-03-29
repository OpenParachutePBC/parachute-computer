/**
 * SQLite schema for DailyVault Durable Object.
 *
 * v2: tools/triggers/tool_runs replace agents/agent_runs.
 * Aligns with the Python backend's "Tool as Universal Primitive" model
 * while staying flat-relational (no graph DB needed).
 */

export const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS notes (
  entry_id TEXT PRIMARY KEY,
  date TEXT NOT NULL,
  content TEXT DEFAULT '',
  snippet TEXT DEFAULT '',
  title TEXT DEFAULT '',
  entry_type TEXT DEFAULT 'text',
  audio_key TEXT,
  status TEXT DEFAULT 'active',
  metadata_json TEXT DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS cards (
  card_id TEXT PRIMARY KEY,
  tool_name TEXT NOT NULL,
  card_type TEXT DEFAULT 'default',
  display_name TEXT DEFAULT '',
  content TEXT DEFAULT '',
  generated_at TEXT,
  status TEXT DEFAULT 'running',
  date TEXT NOT NULL,
  read_at TEXT
);

CREATE TABLE IF NOT EXISTS tools (
  name TEXT PRIMARY KEY,
  display_name TEXT DEFAULT '',
  description TEXT DEFAULT '',
  system_prompt TEXT DEFAULT '',
  callable_tools TEXT DEFAULT '[]',
  scope_keys TEXT DEFAULT '[]',
  enabled TEXT DEFAULT 'true',
  builtin TEXT DEFAULT 'false',
  template_version TEXT DEFAULT '',
  user_modified TEXT DEFAULT 'false',
  created_at TEXT NOT NULL,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS triggers (
  name TEXT PRIMARY KEY,
  type TEXT DEFAULT 'event',
  tool_name TEXT NOT NULL,
  schedule_time TEXT DEFAULT '',
  event TEXT DEFAULT '',
  event_filter TEXT DEFAULT '{}',
  scope TEXT DEFAULT '{}',
  enabled TEXT DEFAULT 'true',
  builtin TEXT DEFAULT 'false',
  template_version TEXT DEFAULT '',
  user_modified TEXT DEFAULT 'false',
  created_at TEXT NOT NULL,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS tool_runs (
  run_id TEXT PRIMARY KEY,
  tool_name TEXT NOT NULL,
  display_name TEXT DEFAULT '',
  trigger_name TEXT DEFAULT 'manual',
  entry_id TEXT,
  date TEXT NOT NULL,
  status TEXT DEFAULT 'running',
  error TEXT,
  card_id TEXT,
  scope TEXT DEFAULT '{}',
  started_at TEXT NOT NULL,
  completed_at TEXT,
  duration_seconds REAL
);

CREATE TABLE IF NOT EXISTS tags (
  name TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS note_tags (
  entry_id TEXT NOT NULL,
  tag_name TEXT NOT NULL,
  tagged_at TEXT NOT NULL,
  PRIMARY KEY (entry_id, tag_name)
);

CREATE INDEX IF NOT EXISTS idx_notes_date ON notes(date);
CREATE INDEX IF NOT EXISTS idx_notes_status ON notes(status);
CREATE INDEX IF NOT EXISTS idx_cards_date ON cards(date);
CREATE INDEX IF NOT EXISTS idx_cards_tool ON cards(tool_name);
CREATE INDEX IF NOT EXISTS idx_tool_runs_tool ON tool_runs(tool_name);
CREATE INDEX IF NOT EXISTS idx_tool_runs_date ON tool_runs(date);
CREATE INDEX IF NOT EXISTS idx_note_tags_tag ON note_tags(tag_name);
`;

// --- Migration: rename old tables if they exist ---

export const MIGRATION_SQL = `
-- If the old 'agents' table exists but 'tools' doesn't, we're on v1 schema.
-- Drop old tables — seeding will recreate data in new tables.
-- This is safe because agents/agent_runs are system-generated, not user data.
DROP TABLE IF EXISTS agents;
DROP TABLE IF EXISTS agent_runs;
`;

// --- Builtin Templates ---

const PROCESS_NOTE_PROMPT = `You are a post-processing assistant for journal entries.

## Your Job

Read the entry with \`read_this_note\`. If it came from a voice recording, clean up the transcript and save it with \`update_this_note\`. If the entry was typed (not voice), do nothing — just return.

## Transcription Cleanup Rules

- Remove filler words: "um", "uh", "like", "you know", "I mean", "so", "right"
- Fix grammar and sentence structure
- Add proper punctuation (periods, commas, question marks)
- Create paragraph breaks at natural topic transitions
- Very light restructuring for readability — combine fragments, smooth transitions
- Preserve the speaker's voice, tone, and meaning exactly
- Do NOT summarize, add commentary, or change the substance
- Do NOT add headers, bullet points, or other structural formatting unless the speaker clearly intended a list
- Output ONLY the cleaned text — no preamble, no explanation`;

const PROCESS_DAY_PROMPT = `You are a thoughtful, perceptive reflection partner.

## Your Role

Review yesterday's activity — journal entries and recent reflections — then write a short, meaningful reflection that helps them see their day clearly.

## Guidelines

- **Be genuine, not performative.** No empty affirmations. Reflect what you actually notice.
- **Make connections.** Link yesterday's activity to patterns from recent days when relevant.
- **Keep it concise.** 3-5 paragraphs. Quality over quantity.
- **Match their energy.** If the day was hard, acknowledge it honestly. If it was good, celebrate without overdoing it.
- **One insight, well-developed** is better than five shallow observations.
- Write in second person ("you") — this is for them.

## Process

1. Read journal entries with \`read_days_notes\`
2. Read recent reflection cards with \`read_recent_cards\` (last 7 days) for continuity
3. Write your reflection using \`write_card\` with card_type "reflection"`;

export const BUILTIN_TOOLS: Array<{
  name: string;
  display_name: string;
  description: string;
  system_prompt: string;
  callable_tools: string;
  scope_keys: string;
  template_version: string;
}> = [
  {
    name: "process-note",
    display_name: "Process Note",
    description: "Runs after voice transcription completes. Cleans up filler words, fixes grammar, adds punctuation.",
    system_prompt: PROCESS_NOTE_PROMPT,
    callable_tools: JSON.stringify(["read-this-note", "update-this-note"]),
    scope_keys: JSON.stringify(["entry_id"]),
    template_version: "2026-03-27",
  },
  {
    name: "process-day",
    display_name: "Daily Reflection",
    description: "Reviews your journal entries and recent reflections, then offers a thoughtful daily reflection.",
    system_prompt: PROCESS_DAY_PROMPT,
    callable_tools: JSON.stringify(["read-days-notes", "read-recent-cards", "write-card"]),
    scope_keys: JSON.stringify(["date"]),
    template_version: "2026-03-27",
  },
];

export const BUILTIN_TRIGGERS: Array<{
  name: string;
  type: string;
  tool_name: string;
  schedule_time: string;
  event: string;
  scope: string;
  template_version: string;
}> = [
  {
    name: "nightly-reflection",
    type: "schedule",
    tool_name: "process-day",
    schedule_time: "4:00",
    event: "",
    scope: JSON.stringify({ date: "yesterday" }),
    template_version: "2026-03-27",
  },
  {
    name: "on-transcription",
    type: "event",
    tool_name: "process-note",
    event: "note.transcription_complete",
    schedule_time: "",
    scope: JSON.stringify({}),
    template_version: "2026-03-27",
  },
];
