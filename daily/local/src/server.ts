import { Hono } from "hono";
import { cors } from "hono/cors";
import { serve } from "@hono/node-server";
import { createRoutes } from "./routes.js";
import { createStore } from "./db.js";
import path from "node:path";
import os from "node:os";

const PORT = parseInt(process.env.PORT ?? "3334", 10);
const DB_PATH = process.env.PARACHUTE_DB ?? path.join(os.homedir(), ".parachute", "daily.db");
const ASSETS_DIR = process.env.PARACHUTE_ASSETS ?? path.join(os.homedir(), ".parachute", "daily", "assets");

// Ensure directories exist
import fs from "node:fs";
fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });
fs.mkdirSync(ASSETS_DIR, { recursive: true });

const store = createStore(DB_PATH);

const app = new Hono();

// CORS for Flutter app
app.use("/*", cors({
  origin: "*",
  allowMethods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
  allowHeaders: ["Content-Type", "Authorization"],
}));

// Health check
app.get("/api/health", (c) => {
  return c.json({
    status: "ok",
    version: "0.1.0",
    schema_version: 1,
  });
});

// Mount graph API routes
const routes = createRoutes(store, ASSETS_DIR);
app.route("/api", routes);

serve({ fetch: app.fetch, port: PORT }, (info) => {
  console.log(`Parachute Daily server listening on http://localhost:${info.port}`);
  console.log(`Database: ${DB_PATH}`);
  console.log(`Assets: ${ASSETS_DIR}`);
});

export { app };
