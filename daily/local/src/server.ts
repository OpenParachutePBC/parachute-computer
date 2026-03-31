import { Hono } from "hono";
import { cors } from "hono/cors";
import { serve } from "@hono/node-server";
import { createRoutes } from "./routes.js";
import { createStore } from "./db.js";
import { authMiddleware, authRoutes, getAuthMode } from "./auth.js";
import { TranscriptionService } from "./transcription.js";
import { transcribeRoutes } from "./routes/transcribe.js";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";

const PORT = parseInt(process.env.PORT ?? "1940", 10);
const DB_PATH = process.env.PARACHUTE_DB ?? path.join(os.homedir(), ".parachute", "daily.db");
const ASSETS_DIR = process.env.PARACHUTE_ASSETS ?? path.join(os.homedir(), ".parachute", "daily", "assets");

// Ensure directories exist
fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });
fs.mkdirSync(ASSETS_DIR, { recursive: true });

const store = createStore(DB_PATH);
const transcription = new TranscriptionService();

const app = new Hono();

// CORS for Flutter app
app.use("/*", cors({
  origin: "*",
  allowMethods: ["GET", "POST", "PATCH", "PUT", "DELETE", "OPTIONS"],
  allowHeaders: ["Content-Type", "Authorization", "X-API-Key"],
}));

// Auth middleware (before routes, after CORS)
app.use("/*", authMiddleware());

// Health check (auth skipped via SKIP_PATHS in middleware)
app.get("/api/health", async (c) => {
  const transcriptionAvailable = await transcription.isAvailable();
  return c.json({
    status: "ok",
    version: "0.1.0",
    schema_version: 1,
    auth_mode: getAuthMode(),
    transcription_available: transcriptionAvailable,
  });
});

// Auth management routes (localhost-only)
app.route("/api/auth", authRoutes());

// Transcription route
app.route("/api/transcribe", transcribeRoutes(store, transcription, ASSETS_DIR));

// Mount graph API routes with auto-transcription hook
const routes = createRoutes(store, ASSETS_DIR, (thing) => {
  // Auto-transcribe voice entries when created with processing status
  const noteTag = (thing.tags ?? []).find((t: any) => t.tagName === "daily-note");
  if (!noteTag) return;
  const fields = noteTag.fieldValues ?? {};
  if (fields.transcription_status !== "processing") return;
  if (!fields.audio_url) return;

  // Fire-and-forget transcription
  const audioPath = path.isAbsolute(fields.audio_url)
    ? fields.audio_url
    : path.join(ASSETS_DIR, fields.audio_url);

  transcription.isAvailable().then((ok) => {
    if (!ok) return;
    console.log(`[auto-transcribe] Starting for ${thing.id}`);
    transcription.transcribe(audioPath).then((result) => {
      store.updateThing(thing.id, {
        content: result.text,
        tags: [{ name: "daily-note", fields: { transcription_status: "transcribed" } }],
      });
      console.log(`[auto-transcribe] Done for ${thing.id} (${result.backend})`);
    }).catch((err) => {
      console.error(`[auto-transcribe] Failed for ${thing.id}: ${err.message}`);
      store.updateThing(thing.id, {
        tags: [{ name: "daily-note", fields: { transcription_status: "failed" } }],
      });
    });
  });
});
app.route("/api", routes);

serve({ fetch: app.fetch, port: PORT }, async (info) => {
  const hasTranscription = await transcription.isAvailable();
  console.log(`Parachute Daily server listening on http://localhost:${info.port}`);
  console.log(`Database: ${DB_PATH}`);
  console.log(`Assets: ${ASSETS_DIR}`);
  console.log(`Auth mode: ${getAuthMode()}`);
  console.log(`Transcription: ${hasTranscription ? "available" : "not available"}`);
});

export { app };
