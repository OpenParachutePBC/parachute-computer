import { generateText, tool, stepCountIs, type ToolSet } from "ai";
import { createOpenAI } from "@ai-sdk/openai";
import { z } from "zod";
import type { Env, Note, Card, ToolConfig } from "../types";
import type { DailyVault } from "../agents/daily-vault";

/**
 * Tool name mapping: kebab-case (stored in DB) → snake_case (Vercel AI SDK tool keys).
 * The DB stores callable_tools as kebab-case to match the Python backend.
 * The AI SDK tools use snake_case for function-call compatibility with LLMs.
 */
const KEBAB_TO_SNAKE: Record<string, string> = {
  "read-days-notes": "read_days_notes",
  "read-this-note": "read_this_note",
  "update-this-note": "update_this_note",
  "write-card": "write_card",
  "read-recent-journals": "read_recent_journals",
  "read-recent-cards": "read_recent_cards",
  "update-note-tags": "update_note_tags",
};

/**
 * Run a tool (agent-mode) against a scope (date and/or entry).
 * Uses Vercel AI SDK with Groq (or Workers AI fallback).
 */
export async function runTool(
  vault: DailyVault,
  toolName: string,
  scope: { date?: string; entryId?: string; event?: string },
  env: Env,
  triggerName?: string,
) {
  // Load tool config
  const tools = [...vault.sql<ToolConfig>`
    SELECT * FROM tools WHERE name = ${toolName}
  `];
  if (tools.length === 0) {
    throw new Error(`Tool not found: ${toolName}`);
  }
  const toolConfig = tools[0];

  // Determine date
  const date = scope.date || new Date().toISOString().split("T")[0];

  // Check for duplicate run today (skip for event-triggered tools)
  if (!scope.event) {
    const existing = [...vault.sql<{ c: number }>`
      SELECT COUNT(*) as c FROM tool_runs
      WHERE tool_name = ${toolName} AND date = ${date} AND status = 'completed'
    `];
    if (existing[0].c > 0) {
      console.log(`Tool ${toolName} already ran for ${date}, skipping`);
      return;
    }
  }

  // Check if there are notes for this date (for day-scoped tools)
  if (!scope.entryId) {
    const noteCount = [...vault.sql<{ c: number }>`
      SELECT COUNT(*) as c FROM notes WHERE date = ${date} AND status = 'active'
    `];
    if (noteCount[0].c === 0) {
      console.log(`No notes for ${date}, skipping tool ${toolName}`);
      return;
    }
  }

  // Create tool run record
  const runId = crypto.randomUUID();
  const now = new Date().toISOString();
  const trigger = triggerName || (scope.event ? "event" : "manual");

  vault.sql`
    INSERT INTO tool_runs (run_id, tool_name, display_name, trigger_name, entry_id, date,
      status, scope, started_at)
    VALUES (${runId}, ${toolName}, ${toolConfig.display_name}, ${trigger},
      ${scope.entryId || null}, ${date}, ${"running"}, ${JSON.stringify(scope)}, ${now})
  `;

  // Parse callable tools — stored as kebab-case, map to snake_case for SDK
  const callableToolNames = (JSON.parse(toolConfig.callable_tools || "[]") as string[])
    .map(name => KEBAB_TO_SNAKE[name] || name)
    .filter(name => AVAILABLE_TOOLS.has(name));

  const writesCards = callableToolNames.includes("write_card");
  let cardId: string | null = null;

  if (writesCards) {
    cardId = `${toolName}:default:${date}`;
    vault.sql`
      INSERT OR REPLACE INTO cards (card_id, tool_name, card_type, display_name, content, status, date, generated_at)
      VALUES (${cardId}, ${toolName}, ${"default"}, ${toolConfig.display_name}, ${""}, ${"running"}, ${date}, ${now})
    `;
  }

  try {
    // Build tools
    const boundTools = bindTools(vault, callableToolNames, scope, date, toolName);

    // Build prompts
    const systemPrompt = toolConfig.system_prompt;
    const userPrompt = buildUserPrompt(scope, date);

    const model = getModel(env);
    const startTime = Date.now();

    const result = await generateText({
      model,
      system: systemPrompt,
      prompt: userPrompt,
      tools: boundTools,
      stopWhen: stepCountIs(5),
    });

    const durationSeconds = (Date.now() - startTime) / 1000;

    // Update card status
    if (writesCards && cardId) {
      vault.sql`UPDATE cards SET status = 'done' WHERE card_id = ${cardId}`;
    }

    // Complete run
    const completedAt = new Date().toISOString();
    vault.sql`
      UPDATE tool_runs SET status = 'completed', completed_at = ${completedAt},
        duration_seconds = ${durationSeconds}, card_id = ${cardId}
      WHERE run_id = ${runId}
    `;

    console.log(`Tool ${toolName} completed in ${durationSeconds.toFixed(1)}s`);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Unknown error";
    console.error(`Tool ${toolName} failed:`, message);

    vault.sql`
      UPDATE tool_runs SET status = 'error', error = ${message},
        completed_at = ${new Date().toISOString()}
      WHERE run_id = ${runId}
    `;

    if (writesCards && cardId) {
      vault.sql`UPDATE cards SET status = 'failed' WHERE card_id = ${cardId}`;
    }
  }
}

// --- Tool Binding ---

const AVAILABLE_TOOLS = new Set([
  "read_days_notes", "read_this_note", "update_this_note",
  "write_card", "read_recent_journals", "read_recent_cards",
  "update_note_tags",
]);

function bindTools(
  vault: DailyVault,
  toolNames: string[],
  scope: { date?: string; entryId?: string; event?: string },
  date: string,
  agentToolName: string,
) {
  const tools: ToolSet = {};

  for (const name of toolNames) {
    switch (name) {
      case "read_days_notes":
        tools.read_days_notes = tool({
          description: "Read all journal entries for a given date. Defaults to the scoped date.",
          inputSchema: z.object({
            date: z.string().optional().describe("Date in YYYY-MM-DD format"),
          }),
          execute: async ({ date: queryDate }: { date?: string }) => {
            const d = queryDate || date;
            const notes = [...vault.sql<Note>`
              SELECT entry_id, date, content, title, entry_type, created_at
              FROM notes WHERE date = ${d} AND status = 'active'
              ORDER BY created_at ASC
            `];
            if (notes.length === 0) return `No entries for ${d}`;
            return notes.map(n =>
              `## ${n.title} (${n.entry_type})\n${n.content}`
            ).join("\n\n---\n\n");
          },
        });
        break;

      case "read_this_note":
        tools.read_this_note = tool({
          description: "Read the current journal entry that triggered this tool.",
          inputSchema: z.object({}),
          execute: async () => {
            if (!scope.entryId) return "No entry in scope";
            const notes = [...vault.sql<Note>`
              SELECT * FROM notes WHERE entry_id = ${scope.entryId}
            `];
            if (notes.length === 0) return "Entry not found";
            const meta = JSON.parse(notes[0].metadata_json || "{}");
            return JSON.stringify({
              content: notes[0].content,
              entry_type: notes[0].entry_type,
              title: notes[0].title,
              transcription_status: meta.transcription_status,
            });
          },
        });
        break;

      case "update_this_note":
        tools.update_this_note = tool({
          description: "Update the content of the current journal entry.",
          inputSchema: z.object({
            content: z.string().describe("The cleaned-up text to replace the entry content"),
          }),
          execute: async ({ content }: { content: string }) => {
            if (!scope.entryId) return "No entry in scope";
            const snippet = content.slice(0, 200);
            const now = new Date().toISOString();
            const rows = [...vault.sql<Note>`SELECT metadata_json FROM notes WHERE entry_id = ${scope.entryId}`];
            const existingMeta = rows.length > 0 ? JSON.parse(rows[0].metadata_json || "{}") : {};
            const updatedMeta = JSON.stringify({ ...existingMeta, cleanup_status: "completed" });

            vault.sql`
              UPDATE notes SET content = ${content}, snippet = ${snippet},
                metadata_json = ${updatedMeta}, updated_at = ${now}
              WHERE entry_id = ${scope.entryId}
            `;
            return "Note updated";
          },
        });
        break;

      case "write_card":
        tools.write_card = tool({
          description: "Write an output card (e.g. a daily reflection).",
          inputSchema: z.object({
            content: z.string().describe("The card content (markdown)"),
            card_type: z.string().optional().describe("Card type (default: 'default')"),
          }),
          execute: async ({ content, card_type }: { content: string; card_type?: string }) => {
            const ct = card_type || "default";
            const cardId = `${agentToolName}:${ct}:${date}`;
            const now = new Date().toISOString();

            // Upsert — if a running card exists from this run, fill it; otherwise create
            const existing = [...vault.sql<Card>`
              SELECT card_id FROM cards WHERE card_id = ${cardId}
            `];

            if (existing.length > 0) {
              vault.sql`
                UPDATE cards SET content = ${content}, card_type = ${ct}, status = 'done',
                  generated_at = ${now}, read_at = ${null}
                WHERE card_id = ${cardId}
              `;
            } else {
              vault.sql`
                INSERT INTO cards (card_id, tool_name, card_type, display_name, content, status, date, generated_at)
                VALUES (${cardId}, ${agentToolName}, ${ct}, ${""}, ${content}, ${"done"}, ${date}, ${now})
              `;
            }
            return `Card written: ${cardId}`;
          },
        });
        break;

      case "read_recent_journals":
        tools.read_recent_journals = tool({
          description: "Read journal entries from the past N days.",
          inputSchema: z.object({
            days: z.number().optional().describe("Number of days to look back (default 7)"),
          }),
          execute: async ({ days }: { days?: number }) => {
            const d = days || 7;
            const cutoff = new Date();
            cutoff.setDate(cutoff.getDate() - d);
            const cutoffStr = cutoff.toISOString().split("T")[0];

            const notes = [...vault.sql<Note>`
              SELECT entry_id, date, content, title, entry_type, created_at
              FROM notes WHERE date >= ${cutoffStr} AND status = 'active'
              ORDER BY created_at ASC
            `];
            if (notes.length === 0) return `No entries in the past ${d} days`;
            return notes.map(n =>
              `## ${n.date} — ${n.title} (${n.entry_type})\n${n.content}`
            ).join("\n\n---\n\n");
          },
        });
        break;

      case "read_recent_cards":
        tools.read_recent_cards = tool({
          description: "Read recent output cards (reflections, summaries) for continuity. Returns cards from the past N days.",
          inputSchema: z.object({
            days: z.number().optional().describe("Number of days to look back (default 7)"),
            card_type: z.string().optional().describe("Filter by card type (e.g. 'reflection')"),
          }),
          execute: async ({ days, card_type }: { days?: number; card_type?: string }) => {
            const d = days || 7;
            const cutoff = new Date();
            cutoff.setDate(cutoff.getDate() - d);
            const cutoffStr = cutoff.toISOString().split("T")[0];

            let cards: Card[];
            if (card_type) {
              cards = [...vault.sql<Card>`
                SELECT * FROM cards
                WHERE date >= ${cutoffStr} AND status = 'done' AND card_type = ${card_type}
                ORDER BY date DESC
              `];
            } else {
              cards = [...vault.sql<Card>`
                SELECT * FROM cards
                WHERE date >= ${cutoffStr} AND status = 'done'
                ORDER BY date DESC
              `];
            }

            if (cards.length === 0) return `No cards in the past ${d} days`;
            return cards.map(c =>
              `## ${c.date} — ${c.display_name || c.tool_name} (${c.card_type})\n${c.content}`
            ).join("\n\n---\n\n");
          },
        });
        break;

      case "update_note_tags":
        tools.update_note_tags = tool({
          description: "Set tags on the current journal entry.",
          inputSchema: z.object({
            tags: z.array(z.string()).describe("List of tags to set"),
          }),
          execute: async ({ tags }: { tags: string[] }) => {
            if (!scope.entryId) return "No entry in scope";
            const now = new Date().toISOString();

            vault.sql`DELETE FROM note_tags WHERE entry_id = ${scope.entryId}`;
            for (const tag of tags) {
              const normalized = tag.toLowerCase().replace(/[^a-z0-9-]/g, "");
              if (!normalized) continue;
              vault.sql`INSERT OR IGNORE INTO tags (name, created_at) VALUES (${normalized}, ${now})`;
              vault.sql`INSERT OR IGNORE INTO note_tags (entry_id, tag_name, tagged_at) VALUES (${scope.entryId}, ${normalized}, ${now})`;
            }
            return `Tags set: ${tags.join(", ")}`;
          },
        });
        break;
    }
  }

  return tools;
}

// --- Helpers ---

function buildUserPrompt(scope: { date?: string; entryId?: string; event?: string }, date: string): string {
  if (scope.entryId && scope.event) {
    return `A journal entry has just been transcribed (entry_id: ${scope.entryId}). Please read it and process it.`;
  }
  return `Please review the journal entries for ${date} and generate your output.`;
}

function getModel(env: Env) {
  if (env.GROQ_API_KEY) {
    const groq = createOpenAI({
      baseURL: "https://api.groq.com/openai/v1",
      apiKey: env.GROQ_API_KEY,
    });
    return groq("llama-3.3-70b-versatile");
  }

  throw new Error("GROQ_API_KEY is required. Workers AI integration coming soon.");
}
