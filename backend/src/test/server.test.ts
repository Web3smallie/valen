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
// No env stubbing: contract addresses resolve from the real deployment
// manifest (deployments/arc-testnet.json), so these tests fail if the
// manifest rots. RPC itself stays mocked (see above).

import Fastify from "fastify";
import * as rpc from "../lib/rpc.js";
import { decodeFunctionData, type Abi } from "viem";
import { LoanRegistryAbi } from "../abis/LoanRegistry.js";

beforeEach(() => {
  vi.mocked(rpc.readContract).mockReset();
  vi.mocked(rpc.getLogs).mockReset();
});

// ── Build a minimal test app (no event listeners) ─────────────────────────────
async function buildApp(opts?: { prepareAbiVersion?: "V3" | "V4" }) {
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
  await app.register(prepareRoutes, { abiVersion: opts?.prepareAbiVersion });

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

describe("GET /agents/:agentId/identity", () => {
  const OWNER = "0x786d491fb520f3d9d9c7e62156c879fe52d6921e";

  it("returns 404 for a nonexistent agent", async () => {
    vi.mocked(rpc.readContract).mockResolvedValueOnce(
      "0x0000000000000000000000000000000000000000"
    ); // agentOwner = zero address
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/agents/999/identity" });
    expect(res.statusCode).toBe(404);
  });

  it("returns owner, wallet count, and ERC-8004 ref", async () => {
    vi.mocked(rpc.readContract)
      .mockResolvedValueOnce(OWNER) // agentOwner
      .mockResolvedValueOnce(2n)    // walletCount
      .mockResolvedValueOnce(0n);   // erc8004Ref
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/agents/1/identity" });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual({
      agentId: "1",
      owner: OWNER,
      walletCount: "2",
      erc8004TokenId: "0",
    });
  });
});

describe("GET /agents/:agentId/credit", () => {
  const OWNER = "0x786d491fb520f3d9d9c7e62156c879fe52d6921e";

  it("returns 404 for a nonexistent agent", async () => {
    vi.mocked(rpc.readContract).mockResolvedValueOnce(
      "0x0000000000000000000000000000000000000000"
    ); // agentOwner = zero address
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/agents/999/credit" });
    expect(res.statusCode).toBe(404);
  });

  it("keys CreditRegistry reads by agentId and derives totals from on-chain loans", async () => {
    vi.mocked(rpc.readContract)
      .mockResolvedValueOnce(OWNER)       // agentOwner
      .mockResolvedValueOnce(50_000_000n) // getLimit
      .mockResolvedValueOnce(              // credits: AgentCredit 6-tuple
        [10_000_000n, 3n, 1n, true, 5_000_000n, 7_000_000n] as const
      )
      .mockResolvedValueOnce({ agentId: 1n, borrower: OWNER, principal: 10_000_000n, status: 4 }) // getLoan(0)
      .mockResolvedValueOnce({ agentId: 2n, borrower: OWNER, principal: 99_000_000n, status: 4 }) // getLoan(1) — other agent
      .mockResolvedValueOnce({ agentId: 1n, borrower: OWNER, principal: 5_000_000n, status: 5 })  // getLoan(2) — repaid
      .mockResolvedValueOnce(4_000_000n)  // totalRecovered(0)
      .mockResolvedValueOnce(5_500_000n); // totalRecovered(2)
    vi.mocked(rpc.getLogs).mockResolvedValueOnce([
      { args: { loanId: 0n, borrower: OWNER } },
      { args: { loanId: 1n, borrower: OWNER } },
      { args: { loanId: 2n, borrower: OWNER } },
    ] as never);
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/agents/1/credit" });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body.agentId).toBe("1");
    expect(body.limit).toBe("50000000");
    expect(body.limitFormatted).toBe("50.000000");
    expect(body.record).toEqual({
      totalBorrowed: "15000000",  // 10M + 5M (agent 1 only)
      totalRepaid: "9500000",     // 4M + 5.5M
      activeLoans: "1",           // status 4 only; status 5 is terminal
      completedLoans: "3",        // loansRepaid from CreditRegistry
      defaultedLoans: "1",        // loansDefaulted from CreditRegistry
    });
    // CreditRegistry must be queried by agentId (uint256), never by address
    const calls = vi.mocked(rpc.readContract).mock.calls;
    expect(calls[1][0]).toMatchObject({ functionName: "getLimit", args: [1n] });
    expect(calls[2][0]).toMatchObject({ functionName: "credits", args: [1n] });
  });
});

describe("GET /agents/:agentId/loans", () => {
  const OWNER = "0x786d491fb520f3d9d9c7e62156c879fe52d6921e";

  it("filters by on-chain agentId", async () => {
    vi.mocked(rpc.getLogs).mockResolvedValueOnce([
      { args: { loanId: 0n } },
      { args: { loanId: 1n } },
    ] as never);
    vi.mocked(rpc.readContract)
      .mockResolvedValueOnce({ agentId: 1n, borrower: OWNER, principal: 10_000_000n, status: 4 })
      .mockResolvedValueOnce({ agentId: 2n, borrower: OWNER, principal: 1_000_000n, status: 4 });
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/agents/1/loans" });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body).toHaveLength(1);
    expect(body[0]).toMatchObject({
      loanId: "0",
      agentId: "1",
      status: 4,
      statusName: "Active",
      principal: "10000000",
      principalFormatted: "10.000000",
    });
  });

  it("paginates after filtering", async () => {
    vi.mocked(rpc.getLogs).mockResolvedValueOnce([
      { args: { loanId: 0n } },
      { args: { loanId: 1n } },
    ] as never);
    vi.mocked(rpc.readContract)
      .mockResolvedValueOnce({ agentId: 1n, borrower: OWNER, principal: 10_000_000n, status: 4 })
      .mockResolvedValueOnce({ agentId: 1n, borrower: OWNER, principal: 10_000_000n, status: 4 });
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/agents/1/loans?page=2&pageSize=1" });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body).toHaveLength(1);
    expect(body[0].loanId).toBe("1");
  });

  it("queries the canonical LoanRequested fragment", async () => {
    vi.mocked(rpc.getLogs).mockResolvedValueOnce([]);
    const app = await buildApp();
    await app.inject({ method: "GET", url: "/agents/1/loans" });
    const params = vi.mocked(rpc.getLogs).mock.calls[0][0] as unknown as {
      event: { name: string; inputs: Array<{ name: string; type: string; indexed: boolean }> };
    };
    expect(params.event.name).toBe("LoanRequested");
    expect(params.event.inputs).toEqual([
      { name: "loanId", type: "uint256", indexed: true },
      { name: "borrower", type: "address", indexed: true },
      { name: "principal", type: "uint256", indexed: false },
      { name: "initialStatus", type: "uint8", indexed: false },
    ]);
  });
});

describe("GET /loans", () => {
  const OWNER = "0x786d491fb520f3d9d9c7e62156c879fe52d6921e";

  it("returns summaries from events plus getLoan", async () => {
    vi.mocked(rpc.getLogs).mockResolvedValueOnce([{ args: { loanId: 0n } }] as never);
    vi.mocked(rpc.readContract).mockResolvedValueOnce(
      { agentId: 1n, borrower: OWNER, principal: 10_000_000n, status: 4 }
    );
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/loans" });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body).toHaveLength(1);
    expect(body[0]).toMatchObject({ loanId: "0", statusName: "Active" });
    const params = vi.mocked(rpc.getLogs).mock.calls[0][0] as { event: { name: string } };
    expect(params.event.name).toBe("LoanRequested");
  });

  it("falls back to default pagination on non-numeric params", async () => {
    vi.mocked(rpc.getLogs).mockResolvedValueOnce([
      { args: { loanId: 0n } },
      { args: { loanId: 1n } },
      { args: { loanId: 2n } },
    ] as never);
    vi.mocked(rpc.readContract)
      .mockResolvedValueOnce({ agentId: 1n, borrower: OWNER, principal: 1_000_000n, status: 4 })
      .mockResolvedValueOnce({ agentId: 1n, borrower: OWNER, principal: 1_000_000n, status: 4 })
      .mockResolvedValueOnce({ agentId: 1n, borrower: OWNER, principal: 1_000_000n, status: 4 });
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/loans?page=abc&pageSize=abc" });
    expect(res.statusCode).toBe(200);
    // default pageSize (20) returns everything; NaN would return nothing
    expect(JSON.parse(res.body)).toHaveLength(3);
  });
});

describe("POST /loans/prepare — input hardening", () => {
  const BASE = {
    agentId: "1",
    creditWallet: "0x786d491fb520f3d9d9c7e62156c879fe52d6921e",
    principal: "10000000",
    repaymentRateBps: 1000,
    totalRepaymentDue: "11000000",
    duration: "86400",
    purpose: "test loan",
    budget: [{ categoryId: "0x" + "00".repeat(32), cap: "10000000" }],
    permittedRecipients: ["0x786d491fb520f3d9d9c7e62156c879fe52d6921e"],
    milestoneAmounts: ["10000000"],
    milestoneDescriptions: ["full disbursement"],
    collateralAmount: "0",
    collateralAsset: "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a",
  };

  async function post(body: Record<string, unknown>): Promise<{ statusCode: number; details: string }> {
    const app = await buildApp();
    const res = await app.inject({
      method: "POST",
      url: "/loans/prepare",
      headers: { "content-type": "application/json" },
      payload: body,
    });
    const parsed = JSON.parse(res.body) as { details?: string[] };
    return { statusCode: res.statusCode, details: (parsed.details ?? []).join(" ") };
  }

  it("returns 400 (not 500) for non-integer agentId", async () => {
    const { statusCode, details } = await post({ ...BASE, agentId: "abc" });
    expect(statusCode).toBe(400);
    expect(details).toContain("agentId");
  });

  it("returns 400 for out-of-uint16 repaymentRateBps", async () => {
    const { statusCode, details } = await post({ ...BASE, repaymentRateBps: 70000 });
    expect(statusCode).toBe(400);
    expect(details).toContain("repaymentRateBps");
  });

  it("returns 400 for non-integer repaymentRateBps", async () => {
    const { statusCode, details } = await post({ ...BASE, repaymentRateBps: 10.5 });
    expect(statusCode).toBe(400);
    expect(details).toContain("repaymentRateBps");
  });

  it("returns 400 for non-bytes32 budget categoryId", async () => {
    const { statusCode, details } = await post({
      ...BASE,
      budget: [{ categoryId: "0x1234", cap: "10000000" }],
    });
    expect(statusCode).toBe(400);
    expect(details).toContain("categoryId");
  });

  it("returns 400 when creditWallet is missing from permittedRecipients", async () => {
    const { statusCode, details } = await post({
      ...BASE,
      permittedRecipients: ["0x1111111111111111111111111111111111111111"],
    });
    expect(statusCode).toBe(400);
    expect(details).toContain("permittedRecipients");
  });

  it("returns 400 (not 500) for invalid collateralAmount", async () => {
    const { statusCode, details } = await post({ ...BASE, collateralAmount: "abc" });
    expect(statusCode).toBe(400);
    expect(details).toContain("collateralAmount");
  });

  it("returns 400 (not 500) for invalid underwriterAmount", async () => {
    const { statusCode, details } = await post({ ...BASE, underwriterAmount: "1.5" });
    expect(statusCode).toBe(400);
    expect(details).toContain("underwriterAmount");
  });

  it("returns 400 for invalid underwriter address", async () => {
    const { statusCode, details } = await post({ ...BASE, underwriter: "0xbad" });
    expect(statusCode).toBe(400);
    expect(details).toContain("underwriter");
  });
});

describe("POST /loans/prepare — V4 mode (abiVersion route option)", () => {
  const BASE = {
    agentId: "1",
    creditWallet: "0x786d491fb520f3d9d9c7e62156c879fe52d6921e",
    principal: "10000000",
    repaymentRateBps: 1000,
    totalRepaymentDue: "11000000",
    duration: "86400",
    purpose: "test loan",
    budget: [{ categoryId: "0x" + "00".repeat(32), cap: "10000000" }],
    permittedRecipients: ["0x786d491fb520f3d9d9c7e62156c879fe52d6921e"],
    milestoneAmounts: ["10000000"],
    milestoneDescriptions: ["full disbursement"],
    collateralAmount: "0",
    collateralAsset: "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a",
  };

  async function postV4(body: Record<string, unknown>): Promise<{ statusCode: number; body: Record<string, unknown> }> {
    const app = await buildApp({ prepareAbiVersion: "V4" });
    const res = await app.inject({
      method: "POST",
      url: "/loans/prepare",
      headers: { "content-type": "application/json" },
      payload: body,
    });
    return { statusCode: res.statusCode, body: JSON.parse(res.body) as Record<string, unknown> };
  }

  it("accepts directDisbursement:true and encodes the V4 16-field proposal", async () => {
    const { statusCode, body } = await postV4({ ...BASE, directDisbursement: true });
    expect(statusCode).toBe(200);
    expect(body.abiVersion).toBe("V4");
    expect(body.directDisbursement).toBe(true);
    // The calldata must decode as V4 requestLoan with the flag set.
    const decoded = decodeFunctionData({
      abi: LoanRegistryAbi as unknown as Abi,
      data: body.calldata as `0x${string}`,
    });
    expect(decoded.functionName).toBe("requestLoan");
    const proposal = (decoded.args as Array<{ directDisbursement: boolean }>)[0];
    expect(proposal.directDisbursement).toBe(true);
  });

  it("defaults directDisbursement to false when omitted in V4 mode", async () => {
    const { statusCode, body } = await postV4({ ...BASE });
    expect(statusCode).toBe(200);
    expect(body.abiVersion).toBe("V4");
    expect(body.directDisbursement).toBe(false);
  });

  it("returns 400 for non-boolean directDisbursement in V4 mode", async () => {
    const { statusCode, body } = await postV4({ ...BASE, directDisbursement: "yes" });
    expect(statusCode).toBe(400);
    const details = ((body.details ?? []) as string[]).join(" ");
    expect(details).toContain("directDisbursement");
  });

  it("stays on V3 behavior by default (rejects the field)", async () => {
    // No option: the manifest (V3) decides.
    const app = await buildApp();
    const res = await app.inject({
      method: "POST",
      url: "/loans/prepare",
      headers: { "content-type": "application/json" },
      payload: { ...BASE, directDisbursement: false },
    });
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body).error).toMatch(/directDisbursement/);
  });
});

describe("GET /loans/:loanId — directDisbursement flag", () => {
  const VIEW = {
    agentId: 1n,
    borrower: "0x1111111111111111111111111111111111111111",
    lender: "0x2222222222222222222222222222222222222222",
    creditWallet: "0x786d491fb520f3d9d9c7e62156c879fe52d6921e",
    principal: 10_000_000n,
    totalRepaymentDue: 11_000_000n,
    repaymentRateBps: 1000,
    status: 4,
    createdAt: 1000n,
    expiresAt: 87400n,
  };

  function mockDetail(flag: unknown, flagRejects = false) {
    const q = vi.mocked(rpc.readContract)
      .mockResolvedValueOnce(1n)                                    // nextLoanId
      .mockResolvedValueOnce(VIEW)                                  // getLoan
      .mockResolvedValueOnce([])                                    // getMilestones
      .mockResolvedValueOnce([])                                    // getBudget
      .mockResolvedValueOnce(0n)                                    // getCollateralAmount
      .mockResolvedValueOnce("0x0000000000000000000000000000000000000000"); // getCollateralAsset
    if (flagRejects) q.mockRejectedValueOnce(new Error("execution reverted"));
    else q.mockResolvedValueOnce(flag);
  }

  it("exposes directDisbursement:true from the V4 getter", async () => {
    mockDetail(true);
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/loans/0" });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body.directDisbursement).toBe(true);
    expect(body.principal).toBe("10000000");
    expect(body.statusName).toBe("Active");
  });

  it("defaults to false when the getter is missing (V3 deployed)", async () => {
    mockDetail(undefined, true);
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/loans/0" });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).directDisbursement).toBe(false);
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
