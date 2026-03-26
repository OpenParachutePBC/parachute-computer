import type { Env, AuthSession, MagicToken } from "../types";

const MAGIC_LINK_TTL = 5 * 60; // 5 minutes
const SESSION_TTL = 7 * 24 * 60 * 60; // 7 days

// RFC 5321 simplified — rejects most garbage, allows normal addresses
const EMAIL_RE = /^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;

/**
 * Validate an email address. Returns the normalized (lowercase, trimmed) email
 * or null if invalid.
 */
export function validateEmail(raw: string): string | null {
  if (!raw || typeof raw !== "string") return null;
  const email = raw.toLowerCase().trim();
  if (email.length > 254) return null; // RFC 5321 max
  if (!EMAIL_RE.test(email)) return null;
  return email;
}

/**
 * Extract a session token from a request's Authorization header or cookie.
 * Returns null if no token found.
 */
export function extractToken(request: { header: (name: string) => string | undefined }): string | null {
  // Try Authorization: Bearer <token>
  const authHeader = request.header("Authorization");
  if (authHeader?.startsWith("Bearer ")) {
    const token = authHeader.slice(7).trim();
    if (token) return token;
  }

  // Fallback: cookie
  const cookie = request.header("Cookie") || "";
  const match = cookie.match(/session=([^;\s]+)/);
  if (match) return match[1].trim();

  return null;
}

/**
 * Send a magic link to the user's email via Resend.
 * Stores a short-lived token in KV.
 */
export async function sendMagicLink(email: string, env: Env): Promise<void> {
  const token = crypto.randomUUID();
  const data: MagicToken = { email, createdAt: Date.now() };

  await env.AUTH_KV.put(`magic:${token}`, JSON.stringify(data), {
    expirationTtl: MAGIC_LINK_TTL,
  });

  const baseUrl = env.MAGIC_LINK_BASE_URL || "https://daily.parachute.computer";
  const link = `${baseUrl}/auth/verify?token=${token}`;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: "Parachute Daily <daily@parachute.computer>",
      to: [email],
      subject: "Your sign-in link",
      html: [
        "<p>Hi! Click below to sign in to Parachute Daily:</p>",
        `<p><a href="${escapeHtml(link)}" style="display:inline-block;padding:12px 24px;background:#1a1a2e;color:#fff;border-radius:8px;text-decoration:none;font-weight:600;">Sign in</a></p>`,
        '<p style="color:#666;font-size:13px;">This link expires in 5 minutes. If you didn\'t request this, you can ignore it.</p>',
      ].join("\n"),
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Failed to send email: ${err}`);
  }
}

/**
 * Verify a magic link token. Returns the email if valid.
 * Deletes the token after use (one-time).
 */
export async function verifyMagicToken(token: string, env: Env): Promise<string | null> {
  const raw = await env.AUTH_KV.get(`magic:${token}`);
  if (!raw) return null;

  const data = JSON.parse(raw) as MagicToken;

  // Delete immediately — single use
  await env.AUTH_KV.delete(`magic:${token}`);

  return data.email;
}

/**
 * Create a session for an authenticated user. Returns the session token.
 */
export async function createSession(email: string, env: Env): Promise<string> {
  const userId = await hashUserId(email);
  const sessionToken = crypto.randomUUID();

  const session: AuthSession = { email, userId };

  await env.AUTH_KV.put(`session:${sessionToken}`, JSON.stringify(session), {
    expirationTtl: SESSION_TTL,
  });

  return sessionToken;
}

/**
 * Look up a session by token. Returns null if expired/invalid.
 */
export async function getSession(token: string, env: Env): Promise<AuthSession | null> {
  const raw = await env.AUTH_KV.get(`session:${token}`);
  if (!raw) return null;
  return JSON.parse(raw) as AuthSession;
}

/**
 * Destroy a session.
 */
export async function destroySession(token: string, env: Env): Promise<void> {
  await env.AUTH_KV.delete(`session:${token}`);
}

/**
 * Deterministic user ID from email — used as DO name.
 */
export async function hashUserId(email: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(email.toLowerCase().trim());
  const hash = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(hash);
  return Array.from(bytes.slice(0, 16))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

/** HTML-escape user-controlled values before interpolating into HTML. */
function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
