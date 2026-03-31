import { Hono } from "hono";
import type { SqliteStore } from "@parachute/core";
import type { TranscriptionService } from "../transcription.js";
import path from "node:path";

export function transcribeRoutes(
  store: SqliteStore,
  transcription: TranscriptionService,
  assetsDir: string,
): Hono {
  const app = new Hono();

  // POST / — Transcribe audio for a Thing
  //
  // Body: { thing_id: string, audio_path?: string }
  //   - thing_id: The Thing to update with transcription text
  //   - audio_path: Override audio path (optional, defaults to Thing's audio_url field)
  //
  // Flow:
  //   1. Reads audio_url from Thing's daily-note tag if audio_path not provided
  //   2. Resolves to absolute path (relative paths resolved against assetsDir)
  //   3. Transcribes audio
  //   4. Updates Thing content + transcription_status
  app.post("/", async (c) => {
    const body = await c.req.json<{
      thing_id: string;
      audio_path?: string;
    }>();

    if (!body.thing_id) {
      return c.json({ error: "thing_id is required" }, 400);
    }

    // Get the Thing
    const thing = store.getThing(body.thing_id, { includeTags: true });
    if (!thing) {
      return c.json({ error: "Thing not found" }, 404);
    }

    // Resolve audio path
    let audioPath = body.audio_path;
    if (!audioPath) {
      // Extract from daily-note tag
      const noteTag = (thing.tags ?? []).find(
        (t: any) => t.tagName === "daily-note",
      );
      const fields = noteTag?.fieldValues ?? {};
      audioPath = fields.audio_url as string | undefined;
    }

    if (!audioPath) {
      return c.json({ error: "No audio_path provided and Thing has no audio_url" }, 400);
    }

    // Resolve relative paths against assets directory
    if (!path.isAbsolute(audioPath)) {
      audioPath = path.join(assetsDir, audioPath);
    }

    // Check availability
    if (!(await transcription.isAvailable())) {
      // Update status to failed
      store.updateThing(body.thing_id, {
        tags: [{ name: "daily-note", fields: { transcription_status: "failed" } }],
      });
      return c.json({ error: "No transcription backend available" }, 503);
    }

    // Set status to processing
    store.updateThing(body.thing_id, {
      tags: [{ name: "daily-note", fields: { transcription_status: "processing" } }],
    });

    // Transcribe (async — but we await it here since the client polls)
    try {
      const result = await transcription.transcribe(audioPath);

      // Update Thing with transcription text
      store.updateThing(body.thing_id, {
        content: result.text,
        tags: [{ name: "daily-note", fields: { transcription_status: "transcribed" } }],
      });

      return c.json({
        thing_id: body.thing_id,
        text: result.text,
        backend: result.backend,
        status: "transcribed",
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "Transcription failed";
      console.error(`[transcribe] Error: ${message}`);

      // Update status to failed
      store.updateThing(body.thing_id, {
        tags: [{ name: "daily-note", fields: { transcription_status: "failed" } }],
      });

      return c.json({ error: message, status: "failed" }, 500);
    }
  });

  return app;
}
