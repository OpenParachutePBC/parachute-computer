// Environment bindings — generated types supplement this
export interface Env {
  AI: Ai;
  DAILY_VAULT: DurableObjectNamespace;
  AUTH_KV: KVNamespace;
  AUDIO_BUCKET: R2Bucket;
  RESEND_API_KEY: string;
  GROQ_API_KEY?: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  CLOUDFLARE_ACCOUNT_ID: string;
  MAGIC_LINK_BASE_URL?: string; // defaults to worker URL
}

// --- Data models ---

export interface Note {
  entry_id: string;
  date: string;
  content: string;
  snippet: string;
  title: string;
  entry_type: string;
  audio_key: string | null;
  status: string;
  metadata_json: string;
  created_at: string;
  updated_at: string | null;
}

export interface Card {
  card_id: string;
  tool_name: string;
  card_type: string;
  display_name: string;
  content: string;
  generated_at: string | null;
  status: string;
  date: string;
  read_at: string | null;
}

export interface ToolConfig {
  name: string;
  display_name: string;
  description: string;
  system_prompt: string;
  callable_tools: string; // JSON array of tool name strings (kebab-case)
  scope_keys: string; // JSON array of required scope keys
  enabled: string;
  builtin: string;
  template_version: string;
  user_modified: string;
  created_at: string;
  updated_at: string | null;
}

export interface TriggerConfig {
  name: string;
  type: string; // "schedule" | "event"
  tool_name: string;
  schedule_time: string;
  event: string;
  event_filter: string; // JSON
  scope: string; // JSON
  enabled: string;
  builtin: string;
  template_version: string;
  user_modified: string;
  created_at: string;
  updated_at: string | null;
}

export interface ToolRun {
  run_id: string;
  tool_name: string;
  display_name: string;
  trigger_name: string;
  entry_id: string | null;
  date: string;
  status: string;
  error: string | null;
  card_id: string | null;
  scope: string; // JSON
  started_at: string;
  completed_at: string | null;
  duration_seconds: number | null;
}

export interface Tag {
  name: string;
  created_at: string;
}

export interface NoteTag {
  entry_id: string;
  tag_name: string;
  tagged_at: string;
}

// --- API shapes ---

export interface EntryResponse {
  id: string;
  created_at: string;
  content: string;
  snippet: string;
  metadata: Record<string, unknown>;
  tags?: string[];
}

// --- Auth ---

export interface AuthSession {
  email: string;
  userId: string;
}

export interface MagicToken {
  email: string;
  createdAt: number;
}
