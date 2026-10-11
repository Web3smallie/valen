/**
 * Valen Backend — Fastify HTTP server
 *
 * Serves the Valen read-only API and loan preparation endpoints.
 * Does NOT import walletClient or hold any private keys.
 * Does NOT expose deployer-only operations (fund, release, attest) as routes.
 */
import Fastify from "fastify";
import { startLoanEventListeners } from "./listeners/loanEvents.js";
import { agentRoutes }     from "./routes/agents.js";
import { loanRoutes }      from "./routes/loans.js";
import { collateralRoutes }from "./routes/collateral.js";
import { poolRoutes }      from "./routes/pool.js";
import { assetRoutes }     from "./routes/assets.js";
import { recipientRoutes } from "./routes/recipients.js";
import { activityRoutes }  from "./routes/activity.js";
import { prepareRoutes }   from "./routes/prepare.js";
import { ValidationError } from "./lib/format.js";
import { RpcError }        from "./lib/rpc.js";

const PORT = parseInt(process.env.PORT ?? "3000", 10);
const HOST = process.env.HOST ?? "0.0.0.0";

const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? "info" } });

// ── Global error handler ──────────────────────────────────────────────────────
app.setErrorHandler((error: Error & { statusCode?: number }, _req, reply) => {
  if (error instanceof ValidationError || error.statusCode === 400) {
    return reply.code(400).send({ error: error.message });
  }
  if (error instanceof RpcError) {
    return reply.code(error.statusCode).send({ error: error.message });
  }
  app.log.error(error);
  return reply.code(500).send({ error: "Internal server error" });
});

// ── Health check ──────────────────────────────────────────────────────────────
app.get("/health", async () => ({
  status:  "ok",
  service: "valen-backend",
  time:    new Date().toISOString(),
}));

// ── API routes ────────────────────────────────────────────────────────────────
await app.register(agentRoutes);
await app.register(loanRoutes);
await app.register(collateralRoutes);
await app.register(poolRoutes);
await app.register(assetRoutes);
await app.register(recipientRoutes);
await app.register(activityRoutes);
await app.register(prepareRoutes);

// ── Start event listeners (read-only, console.log only for now) ───────────────
startLoanEventListeners();

// ── Graceful shutdown ─────────────────────────────────────────────────────────
const shutdown = async (signal: string) => {
  app.log.info(`Received ${signal}, shutting down…`);
  await app.close();
  process.exit(0);
};
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));

// ── Listen ────────────────────────────────────────────────────────────────────
await app.listen({ port: PORT, host: HOST });
