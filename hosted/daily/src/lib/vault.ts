import type { Env } from "../types";

/**
 * Get a stub to the user's DailyVault Durable Object.
 * Uses userId as the DO name — deterministic per user.
 */
export function getVault(env: Env, userId: string): DurableObjectStub {
  const id = env.DAILY_VAULT.idFromName(userId);
  return env.DAILY_VAULT.get(id);
}
