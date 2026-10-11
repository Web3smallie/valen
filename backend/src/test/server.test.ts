/**
 * Server route unit tests — all RPC calls are mocked.
 * No network access, no private keys loaded.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";

// Mock the chain clients and rpc lib BEFORE importing routes
vi.mock("../chain/publicClient.js", () => ({
  publicClient: {
    readContract: vi.fn(),
    getLogs:      vi.fn(),
  },
}));
vi.mock("../lib/rpc.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../lib/rpc.js")>();
  return {
    ...actual,
    readContract: vi.fn(),
    getLogs:      vi.fn(),
  };
});
// Stub env vars so contracts.ts doesn't throw on missing env
vi.stubEnv("AGENT_REGISTRY_ADDRESS",    "0xeC74944752Fff0f53Af5b727F288f59435C0144e");
vi.stubEnv("LOAN_REGISTRY_ADDRESS",     "0x253B68c7a2D646561387Dc0958A6C176a30a6f8d");
vi.stubEnv("LOAN_VAULT_ADDRESS",        "0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19");
vi.stubEnv("CREDIT_REGISTRY_ADDRESS",   "0x258B0678b30E2d32034389cfeCa7f58fE1CeB897");
vi.stubEnv("REVENUE_ROUTER_ADDRESS",    "0xE0B9b39E72f73f2d85D77a1e24a2f319246de822");
vi.stubEnv("COLLATERAL_VAULT_ADDRESS",  "0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f");
vi.stubEnv("LIQUIDITY_POOL_ADDRESS",    "0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061");
vi.stubEnv("UNDERWRITER_POOL_ADDRESS",  "0x0000000000000000000000000000000000000001");
vi.stubEnv("RECIPIENT_REGISTRY_ADDRESS","0xf8E069B659CEAf9c68318041D727b5c482Ac6374");
vi.stubEnv("RESERVE_POOL_ADDRESS",      "0x0000000000000000000000000000000000000002");
vi.stubEnv("ACTIVITY_ATTESTER_ADDRESS", "0x2660044E4A7316B65263ea1B23b80aAf09841196");
vi.stubEnv("EURC_ADDRESS",              "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a");
vi.stubEnv("ARC_TESTNET_RPC_URL",       "https://rpc.testnet.arc.io");

import Fastify from "fastify";
import * as rpc from "../lib/rpc.js";

beforeEach(() => {
  vi.mocked(rpc.readContract).mockReset();
  vi.mocked(rpc.getLogs).mockReset();
});

// ── Build a minimal test app (no event listeners) ─────────────────────────────
async function buildApp() {
  const app = Fastify({ logger: false });

  app.setErrorHandler((error: Error & { statusCode?: number }, _req, reply) => {
    const code = error.statusCode ?? 500;
    return reply.code(code).send({ error: error.message });
  });

  app.get("/health", async () => ({ status: "ok" }));

  const { agentRoutes }      = await import("../routes/agents.js");
  const { loanRoutes }       = await import("../routes/loans.js");
  const { collateralRoutes } = await import("../routes/collateral.js");
  const { poolRoutes }       = await import("../routes/pool.js");
  const { assetRoutes }      = await import("../routes/assets.js");
  const { recipientRoutes }  = await import("../routes/recipients.js");
  const { activityRoutes }   = await import("../routes/activity.js");
  const { prepareRoutes }    = await import("../routes/prepare.js");

  await app.register(agentRoutes);
  await app.register(loanRoutes);
  await app.register(collateralRoutes);
  await app.register(poolRoutes);
  await app.register(assetRoutes);
  await app.register(recipientRoutes);
  await app.register(activityRoutes);
  await app.register(prepareRoutes);

  return app;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("GET /health", () => {
  it("returns 200 ok", async () => {
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/health" });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).status).toBe("ok");
  });
});

describe("GET /agents/:wallet", () => {
  it("returns 404 for unregistered wallet", async () => {
    vi.mocked(rpc.readContract).mockResolvedValueOnce(0n); // walletToAgent = 0
    const app = await buildApp();
    const res = await app.inject({
      method: "GET",
      url:    "/agents/0x786d491fb520f3d9d9c7e62156c879fe52d6921e",
    });
    expect(res.statusCode).toBe(404);
  });

  it("returns 400 for invalid address", async () => {
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/agents/notanaddress" });
    expect(res.statusCode).toBe(400);
  });

  it("returns agent data for registered wallet", async () => {
    vi.mocked(rpc.readContract)
      .mockResolvedValueOnce(1n)                              // walletToAgent
      .mockResolvedValueOnce("0x786d491fb520f3d9d9c7e62156c879fe52d6921e") // agentOwner
      .mockResolvedValueOnce(1n)                              // walletCount
      .mockResolvedValueOnce(0n);                             // erc8004Ref
    const app = await buildApp();
    const res = await app.inject({
      method: "GET",
      url:    "/agents/0x786d491fb520f3d9d9c7e62156c879fe52d6921e",
    });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body.agentId).toBe("1");
  });
});

describe("GET /loans/:loanId", () => {
  it("returns 404 for loanId >= nextLoanId", async () => {
    vi.mocked(rpc.readContract).mockResolvedValueOnce(0n); // nextLoanId = 0
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/loans/0" });
    expect(res.statusCode).toBe(404);
  });

  it("returns 400 for non-numeric loanId", async () => {
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/loans/abc" });
    expect(res.statusCode).toBe(400);
  });
});

describe("GET /collateral/required", () => {
  it("returns 400 when principal is missing", async () => {
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/collateral/required?asset=0x3600000000000000000000000000000000000000" });
    expect(res.statusCode).toBe(400);
  });

  it("returns 400 when asset is missing", async () => {
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/collateral/required?principal=10000000" });
    expect(res.statusCode).toBe(400);
  });

  it("returns required collateral for valid params", async () => {
    vi.mocked(rpc.readContract)
      .mockResolvedValueOnce(14_029_180n)                    // requiredCollateral
      .mockResolvedValueOnce([true, 6, 1_080_000_000_000_000_000n] as const); // assetConfigs
    const app = await buildApp();
    const res = await app.inject({
      method: "GET",
      url:    "/collateral/required?principal=10000000&asset=0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a",
    });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body.required.raw).toBe("14029180");
    expect(body.required.formatted).toBe("14.029180");
  });
});

describe("GET /pool", () => {
  it("returns pool state", async () => {
    vi.mocked(rpc.readContract)
      .mockResolvedValueOnce(20_000_000n)  // idleLedger
      .mockResolvedValueOnce(0n)           // totalDeployed
      .mockResolvedValueOnce(20_000_000n)  // totalAssets
      .mockResolvedValueOnce(1_000_000n)   // sharePrice
      .mockResolvedValueOnce(20_000_000n)  // totalShares
      .mockResolvedValueOnce(0n)           // activeLoanCount
      .mockResolvedValueOnce(10n)          // maxActiveLoans
      .mockResolvedValueOnce(true)         // initializedLiquidity
      .mockResolvedValueOnce(0n);          // totalContributed (reservePool)
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/pool" });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    // New flat shape: idleLedger is a string, not { raw, formatted }
    expect(body.idleLedger).toBe("20000000");
    expect(body.idleLedgerFormatted).toBe("20.000000");
    expect(body.totalDeployed).toBe("0");
    expect(body.activeLoanCount).toBe("0");
    expect(body.initializedLiquidity).toBe(true);
  });
});

describe("GET /recipients/:wallet", () => {
  it("returns approval status", async () => {
    vi.mocked(rpc.readContract).mockResolvedValueOnce(
      [true, "0x" + "00".repeat(32), "valen-test-agent"] as const
    );
    const app = await buildApp();
    const res = await app.inject({
      method: "GET",
      url:    "/recipients/0x786d491fb520f3d9d9c7e62156c879fe52d6921e",
    });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body.approved).toBe(true);
    expect(body.label).toBe("valen-test-agent");
  });
});

describe("GET /activity/:activityHash", () => {
  it("returns attested status", async () => {
    vi.mocked(rpc.readContract).mockResolvedValueOnce(false);
    const app = await buildApp();
    const hash = "0x" + "ab".repeat(32);
    const res  = await app.inject({ method: "GET", url: `/activity/${hash}` });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).attested).toBe(false);
  });

  it("returns 400 for invalid hash", async () => {
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/activity/0xbad" });
    expect(res.statusCode).toBe(400);
  });
});

describe("POST /loans/prepare — security boundaries", () => {
  it("returns 400 when body is empty", async () => {
    const app = await buildApp();
    const res = await app.inject({
      method:  "POST",
      url:     "/loans/prepare",
      headers: { "content-type": "application/json" },
      payload: {},
    });
    expect(res.statusCode).toBe(400);
  });

  it("returns 400 when directDisbursement is supplied (not in deployed V3 ABI)", async () => {
    const app = await buildApp();
    const res = await app.inject({
      method:  "POST",
      url:     "/loans/prepare",
      headers: { "content-type": "application/json" },
      payload: { directDisbursement: false },
    });
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body).error).toMatch(/directDisbursement/);
  });

  it("returns calldata without signing or broadcasting (V3 ABI, no directDisbursement)", async () => {
    // collateralAmount = 0 skips the on-chain requiredCollateral call
    const app = await buildApp();
    const validBody = {
      agentId:             "1",
      creditWallet:        "0x786d491fb520f3d9d9c7e62156c879fe52d6921e",
      principal:           "10000000",
      repaymentRateBps:    1000,
      totalRepaymentDue:   "11000000",
      duration:            "86400",
      purpose:             "test loan",
      budget:              [{ categoryId: "0x" + "00".repeat(32), cap: "10000000" }],
      permittedRecipients: ["0x786d491fb520f3d9d9c7e62156c879fe52d6921e"],
      milestoneAmounts:    ["10000000"],
      milestoneDescriptions: ["full disbursement"],
      collateralAmount:    "0",
      collateralAsset:     "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a",
      // directDisbursement intentionally omitted — not in deployed V3 ABI
    };
    const res = await app.inject({
      method:  "POST",
      url:     "/loans/prepare",
      headers: { "content-type": "application/json" },
      payload: validBody,
    });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    // to is returned as the checksummed address from env, not lowercased
    expect(body.to.toLowerCase()).toBe("0x253b68c7a2d646561387dc0958a6c176a30a6f8d");
    expect(body.calldata).toMatch(/^0x/);
    expect(body.value).toBe("0");
    expect(body.abiVersion).toBe("V3-deployed");
    // Must never include a signed transaction or private key
    const bodyStr = JSON.stringify(body);
    expect(bodyStr).not.toContain("privateKey");
    expect(bodyStr).not.toContain("signedTransaction");
    expect(bodyStr).not.toContain("rawTransaction");
  });
});

describe("Security: no deployer key loaded at startup", () => {
  it("index.ts does not import walletClient", () => {
    // Synchronous fs read — avoids vitest ESM polyfill issues with node:url
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const fs   = require("fs")   as typeof import("fs");
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const path = require("path") as typeof import("path");
    const indexPath = path.resolve(process.cwd(), "src/index.ts");
    const src = fs.readFileSync(indexPath, "utf8");
    // index.ts must never contain an import of the deployer wallet module.
    // (Comments mentioning "walletClient" are allowed — check for import statements only.)
    expect(src).not.toMatch(/^import[^'"]*['"].*walletClient/m);
    expect(src).not.toMatch(/process\.env\.DEPLOYER_PRIVATE_KEY/m);
  });
});
