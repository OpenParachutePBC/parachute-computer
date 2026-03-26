import { Hono } from "hono";
import type { Env } from "../types";
import {
  sendMagicLink, verifyMagicToken, createSession,
  destroySession, getSession, extractToken, validateEmail,
} from "../auth/session";

/**
 * Auth routes — magic link flow.
 *
 * POST /auth/login        — send magic link
 * GET  /auth/verify       — verify token, create session
 * POST /auth/logout       — destroy session
 * GET  /auth/me           — check current session
 */
const auth = new Hono<{ Bindings: Env }>();

// Send magic link
auth.post("/login", async (c) => {
  const body = await c.req.json<{ email: string }>();
  const email = validateEmail(body.email);
  if (!email) {
    return c.json({ error: "Valid email required" }, 400);
  }

  await sendMagicLink(email, c.env);
  return c.json({ status: "sent" });
});

// Verify magic link token — creates session, sets cookie, redirects
auth.get("/verify", async (c) => {
  const token = c.req.query("token");
  if (!token) {
    return c.json({ error: "Token required" }, 400);
  }

  const email = await verifyMagicToken(token, c.env);
  if (!email) {
    return c.json({ error: "Invalid or expired link" }, 401);
  }

  const sessionToken = await createSession(email, c.env);

  // For API clients: return the token
  const accept = c.req.header("Accept") || "";
  if (accept.includes("application/json")) {
    return c.json({ session_token: sessionToken, email });
  }

  // For browser: set cookie and redirect to app
  return new Response(null, {
    status: 302,
    headers: {
      Location: "/?authenticated=true",
      "Set-Cookie": `session=${sessionToken}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${7 * 24 * 60 * 60}`,
    },
  });
});

// Logout
auth.post("/logout", async (c) => {
  const token = extractToken(c.req);
  if (token) {
    await destroySession(token, c.env);
  }

  return new Response(null, {
    status: 204,
    headers: {
      "Set-Cookie": "session=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0",
    },
  });
});

// Check session
auth.get("/me", async (c) => {
  const token = extractToken(c.req);
  if (!token) {
    return c.json({ authenticated: false }, 401);
  }

  const session = await getSession(token, c.env);
  if (!session) {
    return c.json({ authenticated: false }, 401);
  }

  return c.json({ authenticated: true, email: session.email });
});

export default auth;
