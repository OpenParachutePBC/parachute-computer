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
  agent_name: string;
  card_type: string;
  display_name: string;
  content: string;
  generated_at: string | null;
  status: string;
  date: string;
  read_at: string | null;
}

export interface AgentConfig {
  name: string;
  display_name: string;
  description: string;
  system_prompt: string;
  tools: string; // JSON array
  schedule_enabled: string;
  schedule_time: string;
  enabled: string;
  trigger_event: string;
  created_at: string;
  updated_at: string | null;
}

export interface AgentRun {
  run_id: string;
  agent_name: string;
  display_name: string;
  entry_id: string | null;
  date: string;
  trigger: string;
  status: string;
  error: string | null;
  card_id: string | null;
  started_at: string;
  completed_at: string | null;
  duration_seconds: number | null;
}

// --- API shapes ---

export interface EntryResponse {
  id: string;
  created_at: string;
  content: string;
  snippet: string;
  metadata: Record<string, unknown>;
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
