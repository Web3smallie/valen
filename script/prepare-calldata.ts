/**
 * Generates requestLoan calldata by calling the backend's REAL route,
 * POST /loans/prepare, in-process (Fastify `inject`: no network listener,
 * no signing, no broadcasting, no private key, no RPC call because
 * collateralAmount is "0").
 *
 * It encodes the SAME inputs for each ABI version so the post-upgrade fork
 * checks can prove: V3 calldata worked before the upgrade and fails after it,
 * V4 calldata fails before the upgrade and works after it.
 *
 * Run from a directory where the backend's dependencies are installed
 * (fastify, viem, dotenv), e.g. a scratch copy of the repo:
 *   bun run script/prepare-calldata.ts > /tmp/prepare-calldata.json
 *
 * Output (JSON): { inputs, v3, v4_false, v4_true } where each of the last three
 * is { status, body } exactly as the route returned it.
 */
import Fastify from "fastify";
import { prepareRoutes } from "../backend/src/routes/prepare.js";

// Agent 1 is the agent that already has a repaid loan on Arc Testnet. Its
// wallet is an approved recipient, and its credit limit (8.85 USDC at the time
// of writing) is above this 5 USDC principal, so the loan is unsecured
// (collateralAmount "0"). No on-chain value is assumed by this file; the
// fork checks read the real state.
const WALLET = "0x786d491Fb520F3D9D9c7e62156C879fe52d6921E";
const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

export const INPUTS = {
  agentId: "1",
  creditWallet: WALLET,
  principal: "5000000",
  repaymentRateBps: 1000,
  totalRepaymentDue: "5500000",
  duration: "86400",
  purpose: "post-upgrade fork check",
  budget: [{ categoryId: "0x" + "00".repeat(32), cap: "5000000" }],
  permittedRecipients: [WALLET],
  milestoneAmounts: ["5000000"],
  milestoneDescriptions: ["full disbursement"],
  collateralAmount: "0",
  collateralAsset: EURC,
};

async function call(abiVersion: "V3" | "V4", body: Record<string, unknown>) {
  const app = Fastify({ logger: false });
  await app.register(prepareRoutes, { abiVersion });
  const res = await app.inject({
    method: "POST",
    url: "/loans/prepare",
    headers: { "content-type": "application/json" },
    payload: body,
  });
  await app.close();
  return { status: res.statusCode, body: JSON.parse(res.body) as Record<string, unknown> };
}

const out = {
  route: "POST /loans/prepare",
  inputs: INPUTS,
  v3: await call("V3", { ...INPUTS }),
  v4_false: await call("V4", { ...INPUTS }), // directDisbursement omitted -> false
  v4_true: await call("V4", { ...INPUTS, directDisbursement: true }),
};
console.log(JSON.stringify(out, null, 2));
