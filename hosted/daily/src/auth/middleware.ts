import { createMiddleware } from "hono/factory";
import type { Env } from "../types";
import { getSession, extractToken } from "./session";

/**
 * Auth context added to Hono requests.
 */
export type AuthContext = {
  userId: string;
  email: string;
};

/**
 * Hono middleware that requires a valid session.
 * Extracts session token from Authorization header or cookie.
 * Sets `userId` and `email` on the context.
 */
export const requireAuth = createMiddleware<{
  Bindings: Env;
  Variables: AuthContext;
}>(async (c, next) => {
  const token = extractToken(c.req);
  if (!token) {
    return c.json({ error: "Authentication required" }, 401);
  }

  const session = await getSession(token, c.env);
  if (!session) {
    return c.json({ error: "Invalid or expired session" }, 401);
  }

  c.set("userId", session.userId);
  c.set("email", session.email);

  await next();
});
