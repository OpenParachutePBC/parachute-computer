import { Hono } from "hono";
import fs from "node:fs";
import path from "node:path";
import { createReadStream } from "node:fs";
import { Readable } from "node:stream";

export function storageRoutes(assetsDir: string): Hono {
  const app = new Hono();

  // POST /upload — Upload a file
  app.post("/upload", async (c) => {
    const formData = await c.req.formData();
    const file = formData.get("file") as File | null;
    if (!file) return c.json({ error: "file is required" }, 400);

    // Organize by date
    const date = new Date().toISOString().split("T")[0];
    const dir = path.join(assetsDir, date);
    fs.mkdirSync(dir, { recursive: true });

    // Write file
    const filename = `${Date.now()}-${file.name}`;
    const filePath = path.join(dir, filename);
    const buffer = Buffer.from(await file.arrayBuffer());
    fs.writeFileSync(filePath, buffer);

    const relativePath = `${date}/${filename}`;
    return c.json({ path: relativePath, size: buffer.length }, 201);
  });

  // GET /*path — Serve a stored file
  app.get("/*", (c) => {
    const reqPath = c.req.path.replace(/^\//, "");
    const filePath = path.join(assetsDir, reqPath);

    if (!fs.existsSync(filePath)) {
      return c.json({ error: "Not found" }, 404);
    }

    const stat = fs.statSync(filePath);
    const ext = path.extname(filePath).toLowerCase();
    const mimeTypes: Record<string, string> = {
      ".wav": "audio/wav",
      ".mp3": "audio/mpeg",
      ".m4a": "audio/mp4",
      ".ogg": "audio/ogg",
      ".webm": "audio/webm",
      ".png": "image/png",
      ".jpg": "image/jpeg",
      ".jpeg": "image/jpeg",
      ".gif": "image/gif",
      ".webp": "image/webp",
    };

    const contentType = mimeTypes[ext] ?? "application/octet-stream";
    const fileBuffer = fs.readFileSync(filePath);

    return new Response(fileBuffer, {
      headers: {
        "Content-Type": contentType,
        "Content-Length": String(stat.size),
      },
    });
  });

  return app;
}
