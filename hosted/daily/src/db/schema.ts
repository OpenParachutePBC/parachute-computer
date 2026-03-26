/**
 * SQLite schema for DailyVault Durable Object.
 * Mirrors Kuzu node tables for migration compatibility.
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
  agent_name TEXT NOT NULL,
  card_type TEXT DEFAULT 'default',
  display_name TEXT DEFAULT '',
  content TEXT DEFAULT '',
  generated_at TEXT,
  status TEXT DEFAULT 'running',
  date TEXT NOT NULL,
  read_at TEXT
);

CREATE TABLE IF NOT EXISTS agents (
  name TEXT PRIMARY KEY,
  display_name TEXT DEFAULT '',
  description TEXT DEFAULT '',
  system_prompt TEXT DEFAULT '',
  tools TEXT DEFAULT '[]',
  schedule_enabled TEXT DEFAULT 'false',
  schedule_time TEXT DEFAULT '23:00',
  enabled TEXT DEFAULT 'true',
  trigger_event TEXT DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS agent_runs (
  run_id TEXT PRIMARY KEY,
  agent_name TEXT NOT NULL,
  display_name TEXT DEFAULT '',
  entry_id TEXT,
  date TEXT NOT NULL,
  trigger TEXT DEFAULT 'manual',
  status TEXT DEFAULT 'running',
  error TEXT,
  card_id TEXT,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  duration_seconds REAL
);

CREATE INDEX IF NOT EXISTS idx_notes_date ON notes(date);
CREATE INDEX IF NOT EXISTS idx_notes_status ON notes(status);
CREATE INDEX IF NOT EXISTS idx_cards_date ON cards(date);
CREATE INDEX IF NOT EXISTS idx_cards_agent ON cards(agent_name);
CREATE INDEX IF NOT EXISTS idx_runs_agent ON agent_runs(agent_name);
CREATE INDEX IF NOT EXISTS idx_runs_date ON agent_runs(date);
`;

/**
 * Builtin agent templates — seeded on first vault creation.
 */
export const BUILTIN_AGENTS = [
  {
    name: "process-note",
    display_name: "Note Processor",
    description: "Cleans up voice transcriptions — removes filler words, fixes grammar, adds punctuation while preserving the speaker's voice and meaning.",
    system_prompt: `You are a transcription cleanup assistant. Your job is to take raw voice transcriptions and clean them up while preserving the speaker's authentic voice.

Rules:
- Remove filler words (um, uh, like, you know) unless they carry meaning
- Fix obvious grammar errors
- Add proper punctuation and paragraph breaks
- Preserve the speaker's tone, vocabulary, and style
- Do not add content, opinions, or change meaning
- Do not summarize — keep the full content
- If the transcription is already clean, return it as-is

Read the note, clean it up, then update it with the cleaned version.`,
    tools: JSON.stringify(["read_this_note", "update_this_note"]),
    schedule_enabled: "false",
    schedule_time: "",
    trigger_event: "note.transcription_complete",
  },
  {
    name: "process-day",
    display_name: "Daily Reflection",
    description: "Reviews the day's journal entries and generates a thoughtful reflection with themes and insights.",
    system_prompt: `You are a reflective journaling partner. Review today's journal entries and write a thoughtful daily reflection.

Your reflection should:
- Identify key themes and emotional threads
- Notice patterns or connections between entries
- Offer a gentle, honest observation (not advice)
- Be 2-4 paragraphs, conversational tone
- End with a question or invitation for further reflection

Read today's notes, then write your reflection as a card.`,
    tools: JSON.stringify(["read_days_notes", "write_card"]),
    schedule_enabled: "true",
    schedule_time: "23:00",
    trigger_event: "",
  },
];
