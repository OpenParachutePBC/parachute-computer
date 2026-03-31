import { Hono } from "hono";
import type { SqliteStore } from "@parachute/core";
import { thingRoutes, type ThingCreatedHook } from "./routes/things.js";
import { tagRoutes } from "./routes/tags.js";
import { edgeRoutes } from "./routes/edges.js";
import { toolRoutes } from "./routes/tools.js";
import { searchRoutes } from "./routes/search.js";
import { storageRoutes } from "./routes/storage.js";
import { registerRoutes } from "./routes/register.js";

export function createRoutes(
  store: SqliteStore,
  assetsDir: string,
  onThingCreated?: ThingCreatedHook,
): Hono {
  const app = new Hono();

  app.route("/things", thingRoutes(store, onThingCreated));
  app.route("/tags", tagRoutes(store));
  app.route("/edges", edgeRoutes(store));
  app.route("/tools", toolRoutes(store));
  app.route("/search", searchRoutes(store));
  app.route("/storage", storageRoutes(assetsDir));
  app.route("/register", registerRoutes(store));

  return app;
}
