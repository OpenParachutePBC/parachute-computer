import { Agent } from "agents";
import { SCHEMA_SQL, MIGRATION_SQL, BUILTIN_TOOLS, BUILTIN_TRIGGERS } from "../db/schema";
import { runTool } from "../ai/agent-runner";
import type { Env, Note, Card, ToolConfig, TriggerConfig, ToolRun, Tag, NoteTag, EntryResponse } from "../types";

/**
 * DailyVault — one per user. Owns all journal data, tool configs, and cards.
 * Extends CF Agents SDK Agent class which wraps a Durable Object with SQLite.
 */
export class DailyVault extends Agent<Env> {
  /** Random per-instance secret for authenticating internal callbacks. */
  private internalSecret: string | null = null;

  // --- Lifecycle ---

  async onStart() {
    // Migrate from v1 schema (drop old agents/agent_runs tables)
    try {
      (this.sql as unknown as { exec: (sql: string) => void }).exec(MIGRATION_SQL);
    } catch {
      // Tables may not exist — that's fine
    }

    // Create tables (idempotent)
    (this.sql as unknown as { exec: (sql: string) => void }).exec(SCHEMA_SQL);

    // Generate internal secret for this DO instance
    this.internalSecret = crypto.randomUUID();

    // Seed builtin tools and triggers
    this.seedBuiltins();

    // Set up scheduled triggers
    await this.setupSchedules();
  }

  private seedBuiltins() {
    const now = new Date().toISOString();

    for (const tmpl of BUILTIN_TOOLS) {
      const existing = [...this.sql<ToolConfig>`
        SELECT name, template_version, user_modified FROM tools WHERE name = ${tmpl.name}
      `];

      if (existing.length === 0) {
        // New tool — insert
        this.sql`
          INSERT INTO tools (name, display_name, description, system_prompt, callable_tools,
            scope_keys, enabled, builtin, template_version, user_modified, created_at)
          VALUES (${tmpl.name}, ${tmpl.display_name}, ${tmpl.description}, ${tmpl.system_prompt},
            ${tmpl.callable_tools}, ${tmpl.scope_keys}, ${"true"}, ${"true"},
            ${tmpl.template_version}, ${"false"}, ${now})
        `;
      } else if (existing[0].user_modified === "true") {
        // User has customized — don't overwrite
        console.log(`Tool ${tmpl.name}: user-modified, skipping update`);
      } else if (existing[0].template_version !== tmpl.template_version) {
        // Outdated builtin — auto-update
        this.sql`
          UPDATE tools SET display_name = ${tmpl.display_name}, description = ${tmpl.description},
            system_prompt = ${tmpl.system_prompt}, callable_tools = ${tmpl.callable_tools},
            scope_keys = ${tmpl.scope_keys}, template_version = ${tmpl.template_version},
            updated_at = ${now}
          WHERE name = ${tmpl.name}
        `;
      }
    }

    for (const tmpl of BUILTIN_TRIGGERS) {
      const existing = [...this.sql<TriggerConfig>`
        SELECT name, template_version, user_modified FROM triggers WHERE name = ${tmpl.name}
      `];

      if (existing.length === 0) {
        this.sql`
          INSERT INTO triggers (name, type, tool_name, schedule_time, event, scope,
            enabled, builtin, template_version, user_modified, created_at)
          VALUES (${tmpl.name}, ${tmpl.type}, ${tmpl.tool_name}, ${tmpl.schedule_time},
            ${tmpl.event}, ${tmpl.scope}, ${"true"}, ${"true"},
            ${tmpl.template_version}, ${"false"}, ${now})
        `;
      } else if (existing[0].user_modified === "true") {
        console.log(`Trigger ${tmpl.name}: user-modified, skipping update`);
      } else if (existing[0].template_version !== tmpl.template_version) {
        this.sql`
          UPDATE triggers SET type = ${tmpl.type}, tool_name = ${tmpl.tool_name},
            schedule_time = ${tmpl.schedule_time}, event = ${tmpl.event},
            scope = ${tmpl.scope}, template_version = ${tmpl.template_version},
            updated_at = ${now}
          WHERE name = ${tmpl.name}
        `;
      }
    }
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
      if (path === "/entries" && method === "GET") return this.handleGetEntries(url);
      if (path === "/entries" && method === "POST") return this.handleCreateEntry(request);
      if (path === "/entries/search" && method === "GET") return this.handleSearchEntries(url);
      if (path === "/entries/voice" && method === "POST") return this.handleCreateVoiceEntry(request);

      const entryMatch = path.match(/^\/entries\/([^/]+)$/);
      if (entryMatch) {
        const entryId = decodeURIComponent(entryMatch[1]);
        if (method === "GET") return this.handleGetEntry(entryId);
        if (method === "PATCH") return this.handleUpdateEntry(entryId, request);
        if (method === "DELETE") return this.handleDeleteEntry(entryId);
      }

      // Entry sub-routes
      if (path.match(/^\/entries\/[^/]+\/tool-activity$/) && method === "GET") {
        const entryId = decodeURIComponent(path.split("/entries/")[1].split("/tool-activity")[0]);
        return this.handleGetToolActivity(entryId);
      }
      // Backward compat alias
      if (path.match(/^\/entries\/[^/]+\/agent-activity$/) && method === "GET") {
        const entryId = decodeURIComponent(path.split("/entries/")[1].split("/agent-activity")[0]);
        return this.handleGetToolActivity(entryId);
      }
      if (path.match(/^\/entries\/[^/]+\/cleanup$/) && method === "POST") {
        const entryId = decodeURIComponent(path.split("/entries/")[1].split("/cleanup")[0]);
        return this.handleCleanupEntry(entryId);
      }

      // Entry tags
      if (path.match(/^\/entries\/[^/]+\/tags$/) && method === "GET") {
        const entryId = decodeURIComponent(path.split("/entries/")[1].split("/tags")[0]);
        return this.handleGetEntryTags(entryId);
      }
      if (path.match(/^\/entries\/[^/]+\/tags$/) && method === "POST") {
        const entryId = decodeURIComponent(path.split("/entries/")[1].split("/tags")[0]);
        return this.handleSetEntryTags(entryId, request);
      }

      // --- Transcription callback (internal only) ---
      if (path === "/transcription-complete" && method === "POST") {
        const secret = request.headers.get("X-Internal-Secret");
        if (!this.internalSecret || secret !== this.internalSecret) {
          return Response.json({ error: "Forbidden" }, { status: 403 });
        }
        return this.handleTranscriptionComplete(request);
      }
      if (path === "/internal/secret" && method === "GET") {
        return Response.json({ secret: this.getInternalSecret() });
      }

      // --- Cards ---
      if (path === "/cards" && method === "GET") return this.handleGetCards(url);
      if (path === "/cards/unread" && method === "GET") return this.handleGetUnreadCards();

      if (path.match(/^\/cards\/[^/]+\/read$/) && method === "POST") {
        const cardId = decodeURIComponent(path.split("/cards/")[1].split("/read")[0]);
        return this.handleMarkCardRead(cardId);
      }
      if (path.match(/^\/cards\/[^/]+\/run$/) && method === "POST") {
        const toolName = decodeURIComponent(path.split("/cards/")[1].split("/run")[0]);
        return this.handleRunTool(toolName, url);
      }

      // --- Tools ---
      if (path === "/tools" && method === "GET") return this.handleGetTools();
      if (path === "/tools" && method === "POST") return this.handleCreateTool(request);
      if (path === "/tools/templates" && method === "GET") return this.handleGetToolTemplates();

      const toolMatch = path.match(/^\/tools\/([^/]+)$/);
      if (toolMatch) {
        const name = decodeURIComponent(toolMatch[1]);
        if (method === "GET") return this.handleGetTool(name);
        if (method === "PUT") return this.handleUpdateTool(name, request);
        if (method === "DELETE") return this.handleDeleteTool(name);
      }
      if (path.match(/^\/tools\/[^/]+\/run$/) && method === "POST") {
        const name = decodeURIComponent(path.split("/tools/")[1].split("/run")[0]);
        return this.handleRunTool(name, url);
      }
      if (path.match(/^\/tools\/[^/]+\/runs\/latest$/) && method === "GET") {
        const name = decodeURIComponent(path.split("/tools/")[1].split("/runs/latest")[0]);
        return this.handleGetLatestRun(name);
      }
      if (path.match(/^\/tools\/[^/]+\/reset-to-template$/) && method === "POST") {
        const name = decodeURIComponent(path.split("/tools/")[1].split("/reset-to-template")[0]);
        return this.handleResetToolToTemplate(name);
      }

      // --- Triggers ---
      if (path === "/triggers" && method === "GET") return this.handleGetTriggers();
      if (path === "/triggers" && method === "POST") return this.handleCreateTrigger(request);
      if (path === "/triggers/templates" && method === "GET") return this.handleGetTriggerTemplates();

      const triggerMatch = path.match(/^\/triggers\/([^/]+)$/);
      if (triggerMatch) {
        const name = decodeURIComponent(triggerMatch[1]);
        if (method === "GET") return this.handleGetTrigger(name);
        if (method === "PUT") return this.handleUpdateTrigger(name, request);
        if (method === "DELETE") return this.handleDeleteTrigger(name);
      }

      // --- Tags ---
      if (path === "/tags" && method === "GET") return this.handleGetTags();

      // --- Backward compat: /agents → /tools ---
      if (path === "/agents" && method === "GET") return this.handleGetTools();
      if (path.match(/^\/agents\/[^/]+$/) && method === "PUT") {
        const name = decodeURIComponent(path.split("/agents/")[1]);
        return this.handleUpdateTool(name, request);
      }
      if (path.match(/^\/agents\/[^/]+\/runs\/latest$/) && method === "GET") {
        const name = decodeURIComponent(path.split("/agents/")[1].split("/runs/latest")[0]);
        return this.handleGetLatestRun(name);
      }

      return Response.json({ error: "Not found" }, { status: 404 });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal error";
      console.error("DailyVault error:", message);
      return Response.json({ error: message }, { status: 500 });
    }
  }

  // =====================
  // Entry Handlers
  // =====================

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
      entries: rows.map(n => this.noteToResponse(n)),
      count: rows.length,
      offset,
    });
  }

  private handleGetEntry(entryId: string): Response {
    const rows = [...this.sql<Note>`SELECT * FROM notes WHERE entry_id = ${entryId}`];
    if (rows.length === 0) {
      return Response.json({ error: "Entry not found" }, { status: 404 });
    }
    return Response.json(this.noteToResponse(rows[0]));
  }

  private async handleCreateEntry(request: Request): Promise<Response> {
    const body = await request.json() as { content: string; metadata?: Record<string, unknown>; tags?: string[] };
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

    // Set tags if provided
    if (body.tags?.length) {
      this.setNoteTags(entryId, body.tags);
    }

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
    const body = await request.json() as { content?: string; metadata?: Record<string, unknown>; tags?: string[] };
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

    if (body.tags !== undefined) {
      this.setNoteTags(entryId, body.tags);
    }

    const updated = [...this.sql<Note>`SELECT * FROM notes WHERE entry_id = ${entryId}`];
    return Response.json(this.noteToResponse(updated[0]));
  }

  private handleDeleteEntry(entryId: string): Response {
    this.sql`DELETE FROM notes WHERE entry_id = ${entryId}`;
    this.sql`DELETE FROM tool_runs WHERE entry_id = ${entryId}`;
    this.sql`DELETE FROM note_tags WHERE entry_id = ${entryId}`;
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
      results: rows.map(n => this.noteToResponse(n)),
      query,
      count: rows.length,
    });
  }

  private handleGetToolActivity(entryId: string): Response {
    const rows = [...this.sql<ToolRun>`
      SELECT * FROM tool_runs WHERE entry_id = ${entryId}
      ORDER BY started_at DESC
    `];
    return Response.json({
      activity: rows.map(r => ({
        tool_name: r.tool_name,
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

    // Dispatch event for tools
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

  // =====================
  // Card Handlers
  // =====================

  private handleGetCards(url: URL): Response {
    const date = url.searchParams.get("date");
    let rows: Card[];
    if (date) {
      rows = [...this.sql<Card>`SELECT * FROM cards WHERE date = ${date} ORDER BY generated_at DESC`];
    } else {
      rows = [...this.sql<Card>`SELECT * FROM cards ORDER BY generated_at DESC LIMIT 50`];
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

  // =====================
  // Tool Handlers
  // =====================

  private handleGetTools(): Response {
    const rows = [...this.sql<ToolConfig>`SELECT * FROM tools ORDER BY name`];
    return Response.json({ tools: rows, count: rows.length });
  }

  private handleGetTool(name: string): Response {
    const rows = [...this.sql<ToolConfig>`SELECT * FROM tools WHERE name = ${name}`];
    if (rows.length === 0) {
      return Response.json({ error: "Tool not found" }, { status: 404 });
    }
    return Response.json(rows[0]);
  }

  private async handleCreateTool(request: Request): Promise<Response> {
    const body = await request.json() as Partial<ToolConfig> & { name: string };
    if (!body.name) {
      return Response.json({ error: "name is required" }, { status: 400 });
    }

    const existing = [...this.sql<ToolConfig>`SELECT name FROM tools WHERE name = ${body.name}`];
    if (existing.length > 0) {
      return Response.json({ error: "Tool already exists" }, { status: 409 });
    }

    const now = new Date().toISOString();
    this.sql`
      INSERT INTO tools (name, display_name, description, system_prompt, callable_tools,
        scope_keys, enabled, builtin, template_version, user_modified, created_at)
      VALUES (${body.name}, ${body.display_name || ""}, ${body.description || ""},
        ${body.system_prompt || ""}, ${body.callable_tools || "[]"},
        ${body.scope_keys || "[]"}, ${body.enabled || "true"}, ${"false"},
        ${""}, ${"true"}, ${now})
    `;

    const created = [...this.sql<ToolConfig>`SELECT * FROM tools WHERE name = ${body.name}`];
    return Response.json(created[0], { status: 201 });
  }

  private async handleUpdateTool(name: string, request: Request): Promise<Response> {
    const body = await request.json() as Partial<ToolConfig>;
    const rows = [...this.sql<ToolConfig>`SELECT * FROM tools WHERE name = ${name}`];
    if (rows.length === 0) {
      return Response.json({ error: "Tool not found" }, { status: 404 });
    }

    const now = new Date().toISOString();

    if (body.display_name !== undefined)
      this.sql`UPDATE tools SET display_name = ${body.display_name}, updated_at = ${now} WHERE name = ${name}`;
    if (body.description !== undefined)
      this.sql`UPDATE tools SET description = ${body.description}, updated_at = ${now} WHERE name = ${name}`;
    if (body.system_prompt !== undefined)
      this.sql`UPDATE tools SET system_prompt = ${body.system_prompt}, updated_at = ${now} WHERE name = ${name}`;
    if (body.callable_tools !== undefined)
      this.sql`UPDATE tools SET callable_tools = ${body.callable_tools}, updated_at = ${now} WHERE name = ${name}`;
    if (body.scope_keys !== undefined)
      this.sql`UPDATE tools SET scope_keys = ${body.scope_keys}, updated_at = ${now} WHERE name = ${name}`;
    if (body.enabled !== undefined)
      this.sql`UPDATE tools SET enabled = ${body.enabled}, updated_at = ${now} WHERE name = ${name}`;

    // Mark as user-modified if it's a builtin
    if (rows[0].builtin === "true") {
      this.sql`UPDATE tools SET user_modified = ${"true"}, updated_at = ${now} WHERE name = ${name}`;
    }

    const updated = [...this.sql<ToolConfig>`SELECT * FROM tools WHERE name = ${name}`];
    return Response.json(updated[0]);
  }

  private handleDeleteTool(name: string): Response {
    const rows = [...this.sql<ToolConfig>`SELECT builtin FROM tools WHERE name = ${name}`];
    if (rows.length === 0) {
      return Response.json({ error: "Tool not found" }, { status: 404 });
    }
    if (rows[0].builtin === "true") {
      return Response.json({ error: "Cannot delete builtin tool — use reset-to-template instead" }, { status: 400 });
    }
    this.sql`DELETE FROM tools WHERE name = ${name}`;
    this.sql`DELETE FROM triggers WHERE tool_name = ${name}`;
    return new Response(null, { status: 204 });
  }

  private handleResetToolToTemplate(name: string): Response {
    const tmpl = BUILTIN_TOOLS.find(t => t.name === name);
    if (!tmpl) {
      return Response.json({ error: "No template for this tool" }, { status: 404 });
    }

    const now = new Date().toISOString();
    this.sql`
      UPDATE tools SET display_name = ${tmpl.display_name}, description = ${tmpl.description},
        system_prompt = ${tmpl.system_prompt}, callable_tools = ${tmpl.callable_tools},
        scope_keys = ${tmpl.scope_keys}, template_version = ${tmpl.template_version},
        user_modified = ${"false"}, updated_at = ${now}
      WHERE name = ${name}
    `;

    const updated = [...this.sql<ToolConfig>`SELECT * FROM tools WHERE name = ${name}`];
    return Response.json(updated[0]);
  }

  private handleGetToolTemplates(): Response {
    return Response.json({ templates: BUILTIN_TOOLS });
  }

  private async handleRunTool(toolName: string, url: URL): Promise<Response> {
    const date = url.searchParams.get("date") || new Date().toISOString().split("T")[0];

    this.ctx.waitUntil(
      runTool(this, toolName, { date }, this.env)
    );

    return Response.json({ status: "started", tool: toolName, date }, { status: 202 });
  }

  private handleGetLatestRun(toolName: string): Response {
    const rows = [...this.sql<ToolRun>`
      SELECT * FROM tool_runs WHERE tool_name = ${toolName}
      ORDER BY started_at DESC LIMIT 1
    `];
    if (rows.length === 0) {
      return Response.json({ error: "No runs found" }, { status: 404 });
    }
    return Response.json({
      status: rows[0].status,
      error: rows[0].error,
      trigger_name: rows[0].trigger_name,
    });
  }

  // =====================
  // Trigger Handlers
  // =====================

  private handleGetTriggers(): Response {
    const rows = [...this.sql<TriggerConfig>`SELECT * FROM triggers ORDER BY name`];
    return Response.json({ triggers: rows, count: rows.length });
  }

  private handleGetTrigger(name: string): Response {
    const rows = [...this.sql<TriggerConfig>`SELECT * FROM triggers WHERE name = ${name}`];
    if (rows.length === 0) {
      return Response.json({ error: "Trigger not found" }, { status: 404 });
    }
    return Response.json(rows[0]);
  }

  private async handleCreateTrigger(request: Request): Promise<Response> {
    const body = await request.json() as Partial<TriggerConfig> & { name: string; tool_name: string };
    if (!body.name || !body.tool_name) {
      return Response.json({ error: "name and tool_name are required" }, { status: 400 });
    }

    // Verify tool exists
    const toolRows = [...this.sql<ToolConfig>`SELECT name FROM tools WHERE name = ${body.tool_name}`];
    if (toolRows.length === 0) {
      return Response.json({ error: `Tool not found: ${body.tool_name}` }, { status: 400 });
    }

    const now = new Date().toISOString();
    this.sql`
      INSERT INTO triggers (name, type, tool_name, schedule_time, event, event_filter, scope,
        enabled, builtin, template_version, user_modified, created_at)
      VALUES (${body.name}, ${body.type || "event"}, ${body.tool_name},
        ${body.schedule_time || ""}, ${body.event || ""}, ${body.event_filter || "{}"},
        ${body.scope || "{}"}, ${body.enabled || "true"}, ${"false"}, ${""}, ${"true"}, ${now})
    `;

    // Re-setup schedules if this is a schedule trigger
    if (body.type === "schedule") {
      await this.setupSchedules();
    }

    const created = [...this.sql<TriggerConfig>`SELECT * FROM triggers WHERE name = ${body.name}`];
    return Response.json(created[0], { status: 201 });
  }

  private async handleUpdateTrigger(name: string, request: Request): Promise<Response> {
    const body = await request.json() as Partial<TriggerConfig>;
    const rows = [...this.sql<TriggerConfig>`SELECT * FROM triggers WHERE name = ${name}`];
    if (rows.length === 0) {
      return Response.json({ error: "Trigger not found" }, { status: 404 });
    }

    const now = new Date().toISOString();

    if (body.type !== undefined)
      this.sql`UPDATE triggers SET type = ${body.type}, updated_at = ${now} WHERE name = ${name}`;
    if (body.tool_name !== undefined)
      this.sql`UPDATE triggers SET tool_name = ${body.tool_name}, updated_at = ${now} WHERE name = ${name}`;
    if (body.schedule_time !== undefined)
      this.sql`UPDATE triggers SET schedule_time = ${body.schedule_time}, updated_at = ${now} WHERE name = ${name}`;
    if (body.event !== undefined)
      this.sql`UPDATE triggers SET event = ${body.event}, updated_at = ${now} WHERE name = ${name}`;
    if (body.event_filter !== undefined)
      this.sql`UPDATE triggers SET event_filter = ${body.event_filter}, updated_at = ${now} WHERE name = ${name}`;
    if (body.scope !== undefined)
      this.sql`UPDATE triggers SET scope = ${body.scope}, updated_at = ${now} WHERE name = ${name}`;
    if (body.enabled !== undefined)
      this.sql`UPDATE triggers SET enabled = ${body.enabled}, updated_at = ${now} WHERE name = ${name}`;

    // Mark as user-modified if builtin
    if (rows[0].builtin === "true") {
      this.sql`UPDATE triggers SET user_modified = ${"true"}, updated_at = ${now} WHERE name = ${name}`;
    }

    // Refresh schedules
    await this.setupSchedules();

    const updated = [...this.sql<TriggerConfig>`SELECT * FROM triggers WHERE name = ${name}`];
    return Response.json(updated[0]);
  }

  private handleDeleteTrigger(name: string): Response {
    const rows = [...this.sql<TriggerConfig>`SELECT builtin FROM triggers WHERE name = ${name}`];
    if (rows.length === 0) {
      return Response.json({ error: "Trigger not found" }, { status: 404 });
    }
    if (rows[0].builtin === "true") {
      return Response.json({ error: "Cannot delete builtin trigger — disable it instead" }, { status: 400 });
    }
    this.sql`DELETE FROM triggers WHERE name = ${name}`;
    return new Response(null, { status: 204 });
  }

  private handleGetTriggerTemplates(): Response {
    return Response.json({ templates: BUILTIN_TRIGGERS });
  }

  // =====================
  // Tag Handlers
  // =====================

  private handleGetTags(): Response {
    const rows = [...this.sql<Tag & { count: number }>`
      SELECT t.name, t.created_at, COUNT(nt.entry_id) as count
      FROM tags t LEFT JOIN note_tags nt ON t.name = nt.tag_name
      GROUP BY t.name ORDER BY t.name
    `];
    return Response.json({ tags: rows, count: rows.length });
  }

  private handleGetEntryTags(entryId: string): Response {
    const rows = [...this.sql<NoteTag>`
      SELECT * FROM note_tags WHERE entry_id = ${entryId}
    `];
    return Response.json({ tags: rows.map(r => r.tag_name) });
  }

  private async handleSetEntryTags(entryId: string, request: Request): Promise<Response> {
    const body = await request.json() as { tags: string[] };
    this.setNoteTags(entryId, body.tags || []);
    return Response.json({ tags: body.tags || [] });
  }

  private setNoteTags(entryId: string, tags: string[]) {
    const now = new Date().toISOString();

    // Clear existing tags for this entry
    this.sql`DELETE FROM note_tags WHERE entry_id = ${entryId}`;

    for (const tag of tags) {
      // Validate tag format
      const normalized = tag.toLowerCase().replace(/[^a-z0-9-]/g, "");
      if (!normalized) continue;

      // Ensure tag exists
      this.sql`INSERT OR IGNORE INTO tags (name, created_at) VALUES (${normalized}, ${now})`;
      // Link
      this.sql`INSERT OR IGNORE INTO note_tags (entry_id, tag_name, tagged_at) VALUES (${entryId}, ${normalized}, ${now})`;
    }
  }

  // =====================
  // Event Dispatch
  // =====================

  async dispatchEvent(event: string, data: { entry_id: string; entry_type?: string }) {
    // Find triggers matching this event, then run their tools
    const triggers = [...this.sql<TriggerConfig>`
      SELECT * FROM triggers WHERE enabled = 'true' AND type = 'event' AND event = ${event}
    `];

    for (const trigger of triggers) {
      // Check event_filter if present
      const filter = JSON.parse(trigger.event_filter || "{}");
      if (filter.entry_type && filter.entry_type !== data.entry_type) continue;

      const scope = {
        date: data.entry_id.slice(0, 10),
        entryId: data.entry_id,
        event,
      };

      this.ctx.waitUntil(
        runTool(this, trigger.tool_name, scope, this.env, trigger.name).catch(err => {
          console.error(`Tool ${trigger.tool_name} (trigger: ${trigger.name}) failed:`, err);
        })
      );
    }
  }

  // =====================
  // Scheduling
  // =====================

  private async setupSchedules() {
    const triggers = [...this.sql<TriggerConfig>`
      SELECT * FROM triggers WHERE type = 'schedule' AND enabled = 'true'
    `];

    for (const trigger of triggers) {
      if (!trigger.schedule_time) continue;
      const [hour, minute] = trigger.schedule_time.split(":").map(Number);
      try {
        await this.schedule(`${minute || 0} ${hour} * * *`, "runScheduledTrigger", {
          triggerName: trigger.name,
          toolName: trigger.tool_name,
          scope: trigger.scope,
        });
      } catch (err) {
        console.error(`Failed to schedule trigger ${trigger.name}:`, err);
      }
    }
  }

  async runScheduledTrigger({ triggerName, toolName, scope: scopeJson }: {
    triggerName: string;
    toolName: string;
    scope: string;
  }) {
    const scopeConfig = JSON.parse(scopeJson || "{}");
    let date: string;

    if (scopeConfig.date === "yesterday") {
      const d = new Date();
      d.setDate(d.getDate() - 1);
      date = d.toISOString().split("T")[0];
    } else {
      date = new Date().toISOString().split("T")[0];
    }

    await runTool(this, toolName, { date }, this.env, triggerName);
  }

  // =====================
  // Helpers
  // =====================

  private noteToResponse(note: Note): EntryResponse {
    const meta = JSON.parse(note.metadata_json || "{}");

    // Fetch tags
    const tagRows = [...this.sql<NoteTag>`
      SELECT tag_name FROM note_tags WHERE entry_id = ${note.entry_id}
    `];

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
      tags: tagRows.map(t => t.tag_name),
    };
  }
}

// --- Standalone Helpers ---

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
