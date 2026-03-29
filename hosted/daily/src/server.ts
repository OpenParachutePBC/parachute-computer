import { Hono } from "hono";
import { cors } from "hono/cors";
import type { Env } from "./types";
import { requireAuth, type AuthContext } from "./auth/middleware";
import { getVault } from "./lib/vault";
import authRoutes from "./routes/auth";
import storageRoutes from "./routes/storage";

// Re-export DO class for wrangler
export { DailyVault } from "./agents/daily-vault";

const app = new Hono<{ Bindings: Env }>();

// --- Global middleware ---

app.use("*", cors({
  origin: ["https://daily.parachute.computer", "http://localhost:8787"],
  allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  allowHeaders: ["Content-Type", "Authorization"],
  credentials: true,
}));

// --- Health ---

app.get("/api/health", (c) => {
  return c.json({
    status: "ok",
    service: "parachute-daily",
    timestamp: new Date().toISOString(),
  });
});

// --- Auth (no session required) ---

app.route("/auth", authRoutes);

// --- Storage (presign + voice entry, needs special handling) ---

app.route("/api/storage", storageRoutes);

// --- Generic proxy: all other /api/* routes forward to user's DailyVault DO ---
// The DO's onRequest handles its own routing. We just authenticate
// and forward the path, query string, method, and body.

const api = new Hono<{ Bindings: Env; Variables: AuthContext }>();
api.use("*", requireAuth);

api.all("/*", async (c) => {
  const vault = getVault(c.env, c.get("userId"));
  const url = new URL(c.req.url);

  // Strip /api prefix — the DO routes on /entries, /cards, /tools, /triggers, /tags, etc.
  const doPath = url.pathname.replace(/^\/api/, "");
  const doUrl = `http://do${doPath}${url.search}`;

  const isBodyMethod = !["GET", "HEAD"].includes(c.req.method);
  const res = await vault.fetch(new Request(doUrl, {
    method: c.req.method,
    headers: isBodyMethod ? { "Content-Type": c.req.header("Content-Type") || "application/json" } : {},
    body: isBodyMethod ? c.req.raw.body : undefined,
  }));

  return new Response(res.body, { status: res.status, headers: res.headers });
});

app.route("/api", api);

export default app;
