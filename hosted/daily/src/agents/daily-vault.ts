import { Agent } from "agents";
import { SCHEMA_SQL, BUILTIN_AGENTS } from "../db/schema";
import { runAgent } from "../ai/agent-runner";
import type { Env, Note, Card, AgentConfig, AgentRun, EntryResponse } from "../types";

/**
 * DailyVault — one per user. Owns all journal data, agent configs, and cards.
 * Extends CF Agents SDK Agent class which wraps a Durable Object with SQLite.
 */
export class DailyVault extends Agent<Env> {
  /** Random per-instance secret for authenticating internal callbacks. */
  private internalSecret: string | null = null;

  // --- Lifecycle ---

  async onStart() {
    // Create tables (idempotent)
    (this.sql as unknown as { exec: (sql: string) => void }).exec(SCHEMA_SQL);

    // Generate internal secret for this DO instance (survives hibernation via getter)
    this.internalSecret = crypto.randomUUID();

    // Seed builtin agents if empty
    const agentCount = [...this.sql`SELECT COUNT(*) as c FROM agents`][0] as { c: number };
    if (agentCount.c === 0) {
      const now = new Date().toISOString();
      for (const agent of BUILTIN_AGENTS) {
        this.sql`
          INSERT INTO agents (name, display_name, description, system_prompt, tools,
            schedule_enabled, schedule_time, trigger_event, created_at)
          VALUES (${agent.name}, ${agent.display_name}, ${agent.description},
            ${agent.system_prompt}, ${agent.tools}, ${agent.schedule_enabled},
            ${agent.schedule_time}, ${agent.trigger_event}, ${now})
        `;
      }
    }

    // Set up scheduled agents
    await this.setupSchedules();
  }

  /** Expose the internal secret so storage routes can pass it in headers. */
  getInternalSecret(): string {
    if (!this.internalSecret) {
      this.internalSecret = crypto.randomUUID();
    }
    return this.internalSecret;
  }

  async onRequest(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    try {
      // --- Entries ---
      if (path === "/entries" && method === "GET") {
        return this.handleGetEntries(url);
      }
      if (path === "/entries" && method === "POST") {
        return this.handleCreateEntry(request);
      }
      if (path === "/entries/search" && method === "GET") {
        return this.handleSearchEntries(url);
      }
      if (path.match(/^\/entries\/[^/]+$/) && method === "GET") {
        const entryId = path.split("/entries/")[1];
        return this.handleGetEntry(entryId);
      }
      if (path.match(/^\/entries\/[^/]+$/) && method === "PATCH") {
        const entryId = path.split("/entries/")[1];
        return this.handleUpdateEntry(entryId, request);
      }
      if (path.match(/^\/entries\/[^/]+$/) && method === "DELETE") {
        const entryId = path.split("/entries/")[1];
        return this.handleDeleteEntry(entryId);
      }
      if (path.match(/^\/entries\/[^/]+\/agent-activity$/) && method === "GET") {
        const entryId = path.split("/entries/")[1].split("/agent-activity")[0];
        return this.handleGetAgentActivity(entryId);
      }
      if (path.match(/^\/entries\/[^/]+\/cleanup$/) && method === "POST") {
        const entryId = path.split("/entries/")[1].split("/cleanup")[0];
        return this.handleCleanupEntry(entryId);
      }

      // --- Voice entries ---
      if (path === "/entries/voice" && method === "POST") {
        return this.handleCreateVoiceEntry(request);
      }

      // --- Transcription callback (internal only — requires secret) ---
      if (path === "/transcription-complete" && method === "POST") {
        const secret = request.headers.get("X-Internal-Secret");
        if (!this.internalSecret || secret !== this.internalSecret) {
          return Response.json({ error: "Forbidden" }, { status: 403 });
        }
        return this.handleTranscriptionComplete(request);
      }

      // --- Internal: get secret (only callable from within the same worker) ---
      if (path === "/internal/secret" && method === "GET") {
        return Response.json({ secret: this.getInternalSecret() });
      }

      // --- Cards ---
      if (path === "/cards" && method === "GET") {
        return this.handleGetCards(url);
      }
      if (path === "/cards/unread" && method === "GET") {
        return this.handleGetUnreadCards();
      }
      if (path.match(/^\/cards\/[^/]+\/read$/) && method === "POST") {
        const cardId = decodeURIComponent(path.split("/cards/")[1].split("/read")[0]);
        return this.handleMarkCardRead(cardId);
      }
      if (path.match(/^\/cards\/[^/]+\/run$/) && method === "POST") {
        const agentName = path.split("/cards/")[1].split("/run")[0];
        return this.handleRunAgent(agentName, url);
      }

      // --- Agents ---
      if (path === "/agents" && method === "GET") {
        return this.handleGetAgents();
      }
      if (path.match(/^\/agents\/[^/]+$/) && method === "PUT") {
        const name = path.split("/agents/")[1];
        return this.handleUpdateAgent(name, request);
      }
      if (path.match(/^\/agents\/[^/]+\/runs\/latest$/) && method === "GET") {
        const name = path.split("/agents/")[1].split("/runs/latest")[0];
        return this.handleGetLatestRun(name);
      }

      return Response.json({ error: "Not found" }, { status: 404 });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal error";
      console.error("DailyVault error:", message);
      return Response.json({ error: message }, { status: 500 });
    }
  }

  // --- Entry Handlers ---

  private handleGetEntries(url: URL): Response {
    const date = url.searchParams.get("date");
    const limit = Math.min(parseInt(url.searchParams.get("limit") || "20"), 100);
    const offset = parseInt(url.searchParams.get("offset") || "0");

    let rows: Note[];
    if (date) {
      rows = [...this.sql<Note>`
        SELECT * FROM notes WHERE date = ${date} AND status = 'active'
        ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}
      `];
    } else {
      rows = [...this.sql<Note>`
        SELECT * FROM notes WHERE status = 'active'
        ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}
      `];
    }

    return Response.json({
      entries: rows.map(noteToResponse),
      count: rows.length,
      offset,
    });
  }

  private handleGetEntry(entryId: string): Response {
    const rows = [...this.sql<Note>`
      SELECT * FROM notes WHERE entry_id = ${entryId}
    `];
    if (rows.length === 0) {
      return Response.json({ error: "Entry not found" }, { status: 404 });
    }
    return Response.json(noteToResponse(rows[0]));
  }

  private async handleCreateEntry(request: Request): Promise<Response> {
    const body = await request.json() as { content: string; metadata?: Record<string, unknown> };
    const now = new Date();
    const date = now.toISOString().split("T")[0];
    const entryId = formatEntryId(now);
    const title = `${now.getHours().toString().padStart(2, "0")}:${now.getMinutes().toString().padStart(2, "0")}`;
    const snippet = (body.content || "").slice(0, 200);
    const metadata = JSON.stringify({
      entry_id: entryId,
      created_at: now.toISOString(),
      title,
      type: "text",
      ...body.metadata,
    });

    this.sql`
      INSERT INTO notes (entry_id, date, content, snippet, title, entry_type, metadata_json, created_at)
      VALUES (${entryId}, ${date}, ${body.content || ""}, ${snippet}, ${title}, ${"text"}, ${metadata}, ${now.toISOString()})
    `;

    // Dispatch note.created event
    await this.dispatchEvent("note.created", { entry_id: entryId, entry_type: "text" });

    return Response.json({ id: entryId, created_at: now.toISOString() }, { status: 201 });
  }

  private async handleCreateVoiceEntry(request: Request): Promise<Response> {
    const body = await request.json() as {
      objectKey: string;
      date?: string;
      durationSeconds?: number;
    };

    const now = new Date();
    const date = body.date || now.toISOString().split("T")[0];
    const entryId = formatEntryId(now);
    const title = `${now.getHours().toString().padStart(2, "0")}:${now.getMinutes().toString().padStart(2, "0")}`;
    const metadata = JSON.stringify({
      entry_id: entryId,
      created_at: now.toISOString(),
      title,
      type: "voice",
      audio_key: body.objectKey,
      duration_seconds: body.durationSeconds || 0,
      transcription_status: "processing",
    });

    this.sql`
      INSERT INTO notes (entry_id, date, content, snippet, title, entry_type, audio_key, metadata_json, created_at)
      VALUES (${entryId}, ${date}, ${""}, ${""}, ${title}, ${"voice"}, ${body.objectKey}, ${metadata}, ${now.toISOString()})
    `;

    return Response.json({
      entry_id: entryId,
      status: "processing",
      audio_key: body.objectKey,
    }, { status: 201 });
  }

  private async handleUpdateEntry(entryId: string, request: Request): Promise<Response> {
    const body = await request.json() as { content?: string; metadata?: Record<string, unknown> };
    const rows = [...this.sql<Note>`SELECT * FROM notes WHERE entry_id = ${entryId}`];
    if (rows.length === 0) {
      return Response.json({ error: "Entry not found" }, { status: 404 });
    }

    const existing = rows[0];
    const now = new Date().toISOString();

    if (body.content !== undefined) {
      const snippet = body.content.slice(0, 200);
      this.sql`
        UPDATE notes SET content = ${body.content}, snippet = ${snippet}, updated_at = ${now}
        WHERE entry_id = ${entryId}
      `;
    }

    if (body.metadata !== undefined) {
      const existingMeta = JSON.parse(existing.metadata_json || "{}");
      const merged = JSON.stringify({ ...existingMeta, ...body.metadata });
      this.sql`
        UPDATE notes SET metadata_json = ${merged}, updated_at = ${now}
        WHERE entry_id = ${entryId}
      `;
    }

    const updated = [...this.sql<Note>`SELECT * FROM notes WHERE entry_id = ${entryId}`];
    return Response.json(noteToResponse(updated[0]));
  }

  private handleDeleteEntry(entryId: string): Response {
    this.sql`DELETE FROM notes WHERE entry_id = ${entryId}`;
    this.sql`DELETE FROM agent_runs WHERE entry_id = ${entryId}`;
    return new Response(null, { status: 204 });
  }

  private handleSearchEntries(url: URL): Response {
    const query = url.searchParams.get("q") || "";
    const limit = Math.min(parseInt(url.searchParams.get("limit") || "30"), 100);

    if (!query) {
      return Response.json({ error: "Query parameter 'q' is required" }, { status: 400 });
    }

    const pattern = `%${query}%`;
    const rows = [...this.sql<Note>`
      SELECT * FROM notes WHERE content LIKE ${pattern} AND status = 'active'
      ORDER BY created_at DESC LIMIT ${limit}
    `];

    return Response.json({
      results: rows.map(noteToResponse),
      query,
      count: rows.length,
    });
  }

  private handleGetAgentActivity(entryId: string): Response {
    const rows = [...this.sql<AgentRun>`
      SELECT * FROM agent_runs WHERE entry_id = ${entryId}
      ORDER BY started_at DESC
    `];
    return Response.json({
      activity: rows.map(r => ({
        agent_name: r.agent_name,
        display_name: r.display_name,
        status: r.status,
        ran_at: r.started_at,
      })),
      count: rows.length,
    });
  }

  // --- Transcription ---

  private async handleTranscriptionComplete(request: Request): Promise<Response> {
    const body = await request.json() as { entry_id: string; transcript: string };
    const { entry_id, transcript } = body;

    const rows = [...this.sql<Note>`SELECT * FROM notes WHERE entry_id = ${entry_id}`];
    if (rows.length === 0) {
      return Response.json({ error: "Entry not found" }, { status: 404 });
    }

    const snippet = transcript.slice(0, 200);
    const now = new Date().toISOString();
    const existingMeta = JSON.parse(rows[0].metadata_json || "{}");
    const updatedMeta = JSON.stringify({
      ...existingMeta,
      transcription_status: "transcribed",
      transcription_raw: transcript,
    });

    this.sql`
      UPDATE notes SET content = ${transcript}, snippet = ${snippet},
        metadata_json = ${updatedMeta}, updated_at = ${now}
      WHERE entry_id = ${entry_id}
    `;

    // Dispatch event for agents
    await this.dispatchEvent("note.transcription_complete", {
      entry_id,
      entry_type: "voice",
    });

    return Response.json({ entry_id, status: "transcribed" });
  }

  private async handleCleanupEntry(entryId: string): Promise<Response> {
    await this.dispatchEvent("note.transcription_complete", {
      entry_id: entryId,
      entry_type: "text",
    });
    return Response.json({ entry_id: entryId, status: "cleanup_triggered" });
  }

  // --- Card Handlers ---

  private handleGetCards(url: URL): Response {
    const date = url.searchParams.get("date");

    let rows: Card[];
    if (date) {
      rows = [...this.sql<Card>`
        SELECT * FROM cards WHERE date = ${date} ORDER BY generated_at DESC
      `];
    } else {
      rows = [...this.sql<Card>`
        SELECT * FROM cards ORDER BY generated_at DESC LIMIT 50
      `];
    }

    return Response.json({ cards: rows, count: rows.length });
  }

  private handleGetUnreadCards(): Response {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 7);
    const cutoffStr = cutoff.toISOString().split("T")[0];

    const rows = [...this.sql<Card>`
      SELECT * FROM cards
      WHERE (read_at IS NULL OR read_at = '') AND status = 'done' AND date >= ${cutoffStr}
      ORDER BY generated_at DESC
    `];

    return Response.json({ cards: rows, count: rows.length });
  }

  private handleMarkCardRead(cardId: string): Response {
    const now = new Date().toISOString();
    this.sql`UPDATE cards SET read_at = ${now} WHERE card_id = ${cardId}`;
    return Response.json({ card_id: cardId, read_at: now });
  }

  private async handleRunAgent(agentName: string, url: URL): Promise<Response> {
    const date = url.searchParams.get("date") || new Date().toISOString().split("T")[0];

    this.ctx.waitUntil(
      runAgent(this, agentName, { date }, this.env)
    );

    return Response.json({ status: "started", agent: agentName, date }, { status: 202 });
  }

  // --- Agent Handlers ---

  private handleGetAgents(): Response {
    const rows = [...this.sql<AgentConfig>`SELECT * FROM agents ORDER BY name`];
    return Response.json({ agents: rows, count: rows.length });
  }

  /**
   * Update agent config. Uses static SQL per field — no dynamic column construction.
   */
  private async handleUpdateAgent(name: string, request: Request): Promise<Response> {
    const body = await request.json() as Partial<AgentConfig>;
    const rows = [...this.sql<AgentConfig>`SELECT * FROM agents WHERE name = ${name}`];
    if (rows.length === 0) {
      return Response.json({ error: "Agent not found" }, { status: 404 });
    }

    const now = new Date().toISOString();

    // Static updates — one parameterized statement per field, no dynamic SQL
    if (body.display_name !== undefined)
      this.sql`UPDATE agents SET display_name = ${body.display_name}, updated_at = ${now} WHERE name = ${name}`;
    if (body.description !== undefined)
      this.sql`UPDATE agents SET description = ${body.description}, updated_at = ${now} WHERE name = ${name}`;
    if (body.system_prompt !== undefined)
      this.sql`UPDATE agents SET system_prompt = ${body.system_prompt}, updated_at = ${now} WHERE name = ${name}`;
    if (body.tools !== undefined)
      this.sql`UPDATE agents SET tools = ${body.tools}, updated_at = ${now} WHERE name = ${name}`;
    if (body.schedule_enabled !== undefined)
      this.sql`UPDATE agents SET schedule_enabled = ${body.schedule_enabled}, updated_at = ${now} WHERE name = ${name}`;
    if (body.schedule_time !== undefined)
      this.sql`UPDATE agents SET schedule_time = ${body.schedule_time}, updated_at = ${now} WHERE name = ${name}`;
    if (body.enabled !== undefined)
      this.sql`UPDATE agents SET enabled = ${body.enabled}, updated_at = ${now} WHERE name = ${name}`;
    if (body.trigger_event !== undefined)
      this.sql`UPDATE agents SET trigger_event = ${body.trigger_event}, updated_at = ${now} WHERE name = ${name}`;

    // Refresh schedules if schedule settings changed
    if (body.schedule_enabled !== undefined || body.schedule_time !== undefined) {
      await this.setupSchedules();
    }

    const updated = [...this.sql<AgentConfig>`SELECT * FROM agents WHERE name = ${name}`];
    return Response.json(updated[0]);
  }

  private handleGetLatestRun(agentName: string): Response {
    const rows = [...this.sql<AgentRun>`
      SELECT * FROM agent_runs WHERE agent_name = ${agentName}
      ORDER BY started_at DESC LIMIT 1
    `];
    if (rows.length === 0) {
      return Response.json({ error: "No runs found" }, { status: 404 });
    }
    return Response.json({
      status: rows[0].status,
      error: rows[0].error,
      trigger: rows[0].trigger,
    });
  }

  // --- Event Dispatch ---

  async dispatchEvent(event: string, data: { entry_id: string; entry_type?: string }) {
    const agents = [...this.sql<AgentConfig>`
      SELECT * FROM agents WHERE enabled = 'true' AND trigger_event = ${event}
    `];

    for (const agent of agents) {
      const scope = {
        date: data.entry_id.slice(0, 10), // YYYY-MM-DD from entry_id
        entryId: data.entry_id,
        event,
      };

      this.ctx.waitUntil(
        runAgent(this, agent.name, scope, this.env).catch(err => {
          console.error(`Agent ${agent.name} failed:`, err);
        })
      );
    }
  }

  // --- Scheduling ---

  private async setupSchedules() {
    const scheduled = [...this.sql<AgentConfig>`
      SELECT * FROM agents WHERE schedule_enabled = 'true' AND enabled = 'true'
    `];

    for (const agent of scheduled) {
      if (!agent.schedule_time) continue;
      const [hour, minute] = agent.schedule_time.split(":").map(Number);
      try {
        await this.schedule(`${minute} ${hour} * * *`, "runScheduledAgent", {
          agentName: agent.name,
        });
      } catch (err) {
        console.error(`Failed to schedule ${agent.name}:`, err);
      }
    }
  }

  async runScheduledAgent({ agentName }: { agentName: string }) {
    const date = new Date().toISOString().split("T")[0];
    await runAgent(this, agentName, { date }, this.env);
  }
}

// --- Helpers ---

function formatEntryId(date: Date): string {
  const pad = (n: number, w = 2) => n.toString().padStart(w, "0");
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds()),
    pad(date.getMilliseconds() * 1000, 6),
  ].join("-");
}

function noteToResponse(note: Note): EntryResponse {
  const meta = JSON.parse(note.metadata_json || "{}");
  return {
    id: note.entry_id,
    created_at: note.created_at,
    content: note.content,
    snippet: note.snippet,
    metadata: {
      entry_id: note.entry_id,
      created_at: note.created_at,
      title: note.title,
      type: note.entry_type,
      audio_key: note.audio_key,
      ...meta,
    },
  };
}
