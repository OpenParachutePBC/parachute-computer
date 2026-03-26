import { Hono } from "hono";
import { AwsClient } from "aws4fetch";
import type { Env } from "../types";
import { requireAuth, type AuthContext } from "../auth/middleware";
import { getVault } from "../lib/vault";

const ALLOWED_AUDIO_TYPES = new Set([
  "audio/webm", "audio/mp4", "audio/ogg", "audio/wav",
  "audio/mpeg", "audio/aac", "audio/flac",
]);

/**
 * Storage routes — R2 presigned uploads + transcription.
 *
 * POST /api/storage/presign         — get presigned PUT URL for audio upload
 * POST /api/storage/voice-entry     — create voice entry + kick off transcription
 */
const storage = new Hono<{ Bindings: Env; Variables: AuthContext }>();
storage.use("*", requireAuth);

// Generate presigned PUT URL for direct audio upload to R2
storage.post("/presign", async (c) => {
  const body = await c.req.json<{
    filename: string;
    contentType?: string;
  }>();

  if (!body.filename) {
    return c.json({ error: "filename is required" }, 400);
  }

  const userId = c.get("userId");

  // Sanitize filename: strip path separators and special chars, limit length
  const safeFilename = body.filename
    .replace(/[^a-zA-Z0-9._-]/g, "_")
    .slice(0, 128);
  const objectKey = `${userId}/${Date.now()}-${safeFilename}`;

  // Allowlist content types — reject anything not audio
  const contentType = body.contentType && ALLOWED_AUDIO_TYPES.has(body.contentType)
    ? body.contentType
    : "audio/webm";

  // Build presigned URL with aws4fetch
  const r2 = new AwsClient({
    accessKeyId: c.env.R2_ACCESS_KEY_ID,
    secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
  });

  const bucketUrl = `https://${c.env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com/parachute-daily-audio/${objectKey}`;

  const signed = await r2.sign(
    new Request(bucketUrl, {
      method: "PUT",
      headers: { "Content-Type": contentType },
    }),
    { aws: { signQuery: true } },
  );

  return c.json({
    upload_url: signed.url,
    object_key: objectKey,
    expires_in: 3600,
  });
});

// Create voice entry and trigger transcription
storage.post("/voice-entry", async (c) => {
  const body = await c.req.json<{
    objectKey: string;
    date?: string;
    durationSeconds?: number;
  }>();

  const userId = c.get("userId");

  // Validate objectKey belongs to this user — prevent cross-user audio access
  if (!body.objectKey || !body.objectKey.startsWith(`${userId}/`)) {
    return c.json({ error: "Invalid object key" }, 400);
  }

  const vault = getVault(c.env, userId);

  // 1. Create the voice entry in the DO
  const entryRes = await vault.fetch(new Request("http://do/entries/voice", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }));

  const entryData = await entryRes.json<{ entry_id: string }>();

  // 2. Get the DO's internal secret for authenticated callback
  const secretRes = await vault.fetch(new Request("http://do/internal/secret", { method: "GET" }));
  const { secret } = await secretRes.json<{ secret: string }>();

  // 3. Kick off transcription (Workers AI Whisper)
  c.executionCtx.waitUntil(
    transcribeAudio(c.env, userId, entryData.entry_id, body.objectKey, secret)
  );

  return c.json({
    entry_id: entryData.entry_id,
    status: "processing",
  }, 201);
});

/**
 * Transcribe audio from R2 using Workers AI Whisper,
 * then notify the DO with the transcript via authenticated callback.
 */
async function transcribeAudio(
  env: Env,
  userId: string,
  entryId: string,
  objectKey: string,
  internalSecret: string,
): Promise<void> {
  try {
    // Fetch audio from R2
    const audioObj = await env.AUDIO_BUCKET.get(objectKey);
    if (!audioObj) {
      console.error(`Audio not found in R2: ${objectKey}`);
      return;
    }

    const audioBytes = await audioObj.arrayBuffer();

    // Workers AI Whisper transcription
    const result = await (env.AI as any).run("@cf/openai/whisper", {
      audio: [...new Uint8Array(audioBytes)],
    }) as { text?: string };

    const transcript = result.text || "";

    // Notify the DO with internal secret
    const vault = getVault(env, userId);
    await vault.fetch(new Request("http://do/transcription-complete", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Internal-Secret": internalSecret,
      },
      body: JSON.stringify({ entry_id: entryId, transcript }),
    }));
  } catch (err) {
    console.error(`Transcription failed for ${entryId}:`, err);
  }
}

export default storage;
