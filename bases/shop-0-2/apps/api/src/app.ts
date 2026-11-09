import Fastify, { type FastifyInstance } from "fastify";

/** Будує застосунок без запуску сервера — так його тестують через app.inject (§7). */
export function buildApp(): FastifyInstance {
  const app = Fastify({ logger: false });
  app.get("/api/health", async () => ({ status: "ok" }));
  return app;
}
