import { generateText, tool, stepCountIs, type ToolSet } from "ai";
import { createOpenAI } from "@ai-sdk/openai";
import { z } from "zod";
import type { Env, Note, AgentConfig, Card } from "../types";
import type { DailyVault } from "../agents/daily-vault";

/**
 * Run an agent against a scope (date and/or entry).
 * Uses Vercel AI SDK v6 with Groq (or Workers AI fallback).
 */
export async function runAgent(
  vault: DailyVault,
  agentName: string,
  scope: { date?: string; entryId?: string; event?: string },
  env: Env,
) {
  // Load agent config
  const agents = [...vault.sql<AgentConfig>`
    SELECT * FROM agents WHERE name = ${agentName}
  `];
  if (agents.length === 0) {
    throw new Error(`Agent not found: ${agentName}`);
  }
  const agent = agents[0];

  // Determine date
  const date = scope.date || new Date().toISOString().split("T")[0];

  // Check for duplicate run today (skip for event-triggered agents)
  if (!scope.event) {
    const existing = [...vault.sql<{ c: number }>`
      SELECT COUNT(*) as c FROM agent_runs
      WHERE agent_name = ${agentName} AND date = ${date} AND status = 'completed'
    `];
    if (existing[0].c > 0) {
      console.log(`Agent ${agentName} already ran for ${date}, skipping`);
      return;
    }
  }

  // Check if there are notes for this date (for day-scoped agents)
  if (!scope.entryId) {
    const noteCount = [...vault.sql<{ c: number }>`
      SELECT COUNT(*) as c FROM notes WHERE date = ${date} AND status = 'active'
    `];
    if (noteCount[0].c === 0) {
      console.log(`No notes for ${date}, skipping agent ${agentName}`);
      return;
    }
  }

  // Create agent run record
  const runId = crypto.randomUUID();
  const now = new Date().toISOString();
  const trigger = scope.event ? "event" : "scheduled";

  vault.sql`
    INSERT INTO agent_runs (run_id, agent_name, display_name, entry_id, date, trigger, status, started_at)
    VALUES (${runId}, ${agentName}, ${agent.display_name}, ${scope.entryId || null}, ${date}, ${trigger}, ${"running"}, ${now})
  `;

  // Parse and validate tool names against server-side allowlist
  const AVAILABLE_TOOLS = new Set([
    "read_days_notes", "read_this_note", "update_this_note",
    "write_card", "read_recent_journals",
  ]);
  const toolNames = (JSON.parse(agent.tools || "[]") as string[])
    .filter(t => AVAILABLE_TOOLS.has(t));
  const writesCards = toolNames.includes("write_card");
  let cardId: string | null = null;

  if (writesCards) {
    cardId = `${agentName}:default:${date}`;
    vault.sql`
      INSERT OR REPLACE INTO cards (card_id, agent_name, card_type, display_name, content, status, date, generated_at)
      VALUES (${cardId}, ${agentName}, ${"default"}, ${agent.display_name}, ${""}, ${"running"}, ${date}, ${now})
    `;
  }

  try {
    // Build tools
    const tools = bindTools(vault, toolNames, scope, date);

    // Build prompts
    const systemPrompt = agent.system_prompt;
    const userPrompt = buildUserPrompt(scope, date);

    // Choose model — Groq if key available, otherwise Workers AI
    const model = getModel(env);

    const startTime = Date.now();

    const result = await generateText({
      model,
      system: systemPrompt,
      prompt: userPrompt,
      tools,
      stopWhen: stepCountIs(5),
    });

    const durationSeconds = (Date.now() - startTime) / 1000;

    // Update card status if applicable
    if (writesCards && cardId) {
      vault.sql`UPDATE cards SET status = 'done' WHERE card_id = ${cardId}`;
    }

    // Complete agent run
    const completedAt = new Date().toISOString();
    vault.sql`
      UPDATE agent_runs SET status = 'completed', completed_at = ${completedAt},
        duration_seconds = ${durationSeconds}, card_id = ${cardId}
      WHERE run_id = ${runId}
    `;

    console.log(`Agent ${agentName} completed in ${durationSeconds.toFixed(1)}s`);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Unknown error";
    console.error(`Agent ${agentName} failed:`, message);

    // Mark run as error
    vault.sql`
      UPDATE agent_runs SET status = 'error', error = ${message},
        completed_at = ${new Date().toISOString()}
      WHERE run_id = ${runId}
    `;

    // Mark card as failed
    if (writesCards && cardId) {
      vault.sql`UPDATE cards SET status = 'failed' WHERE card_id = ${cardId}`;
    }
  }
}

// --- Tool Binding ---

function bindTools(
  vault: DailyVault,
  toolNames: string[],
  scope: { date?: string; entryId?: string; event?: string },
  date: string,
) {
  const tools: ToolSet = {};

  for (const name of toolNames) {
    switch (name) {
      case "read_days_notes":
        tools.read_days_notes = tool({
          description: "Read all journal entries for a given date. Defaults to today.",
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
          description: "Read the current journal entry that triggered this agent.",
          inputSchema: z.object({}),
          execute: async () => {
            if (!scope.entryId) return "No entry in scope";
            const notes = [...vault.sql<Note>`
              SELECT * FROM notes WHERE entry_id = ${scope.entryId}
            `];
            if (notes.length === 0) return "Entry not found";
            return notes[0].content;
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
          description: "Write a reflection card for the day.",
          inputSchema: z.object({
            content: z.string().describe("The reflection text"),
            card_type: z.string().optional().describe("Card type (default: 'default')"),
          }),
          execute: async ({ content, card_type }: { content: string; card_type?: string }) => {
            const ct = card_type || "default";
            const cards = [...vault.sql<Card>`
              SELECT card_id FROM cards WHERE date = ${date} AND status = 'running'
              ORDER BY generated_at DESC LIMIT 1
            `];
            if (cards.length > 0) {
              vault.sql`
                UPDATE cards SET content = ${content}, card_type = ${ct}
                WHERE card_id = ${cards[0].card_id}
              `;
            }
            return "Card written";
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
    }
  }

  return tools;
}

// --- Helpers ---

function buildUserPrompt(scope: { date?: string; entryId?: string; event?: string }, date: string): string {
  if (scope.entryId && scope.event) {
    return `A journal entry has just been transcribed (entry_id: ${scope.entryId}). Please read it and process it.`;
  }
  return `Please review today's journal entries for ${date} and generate your output.`;
}

function getModel(env: Env) {
  if (env.GROQ_API_KEY) {
    const groq = createOpenAI({
      baseURL: "https://api.groq.com/openai/v1",
      apiKey: env.GROQ_API_KEY,
    });
    return groq("llama-3.3-70b-versatile");
  }

  // Fallback: Workers AI via OpenAI-compatible endpoint
  // This requires the AI binding, accessed differently
  // For now, require GROQ_API_KEY and throw if missing
  throw new Error("GROQ_API_KEY is required. Workers AI integration coming soon.");
}
