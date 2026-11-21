/**
 * GET /agents/:wallet          — agent identity and wallet lookup
 * GET /agents/:agentId/credit  — credit limit and repayment history
 * GET /agents/:agentId/loans   — loan summaries for an agentId (via events + getLoan)
 *
 * Response shapes match frontend AgentResponse, CreditResponse, LoanSummary[].
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { AgentRegistryAbi }      from "../abis/AgentRegistry.js";
import { CreditRegistryAbi }     from "../abis/CreditRegistry.js";
import { readContract }          from "../lib/rpc.js";
import {
  fetchAllLoanIds, fetchLoanViews, fetchAgentLoanStats,
} from "../lib/loanEvents.js";
import {
  validateAddress, validateUint, formatUnits6, loanStatusName, parsePageParam,
} from "../lib/format.js";

export async function agentRoutes(app: FastifyInstance) {

  // ── GET /agents/:wallet ───────────────────────────────────────────────────
  app.get<{ Params: { wallet: string } }>("/agents/:wallet", async (req, reply) => {
    const wallet = validateAddress(req.params.wallet, "wallet");

    const agentId = await readContract({
      address: contracts.agentRegistry,
      abi:     AgentRegistryAbi,
      functionName: "walletToAgent",
      args: [wallet],
    }) as bigint;

    if (agentId === 0n) {
      return reply.code(404).send({ error: "Wallet is not registered as a Valen agent" });
    }

    return {
      wallet,
      agentId:      agentId.toString(),
      isRegistered: true,
    };
  });

  // ── GET /agents/:agentId/identity ─────────────────────────────────────────
  // Shape: IdentityResponse — { agentId, owner, walletCount, erc8004TokenId }
  app.get<{ Params: { agentId: string } }>("/agents/:agentId/identity", async (req, reply) => {
    const agentId = validateUint(req.params.agentId, "agentId");

    const owner = await readContract({
      address: contracts.agentRegistry,
      abi:     AgentRegistryAbi,
      functionName: "agentOwner",
      args: [agentId],
    }) as string;

    if (!owner || owner === "0x0000000000000000000000000000000000000000") {
      return reply.code(404).send({ error: `Agent ${agentId} does not exist` });
    }

    const [walletCount, erc8004Ref] = await Promise.all([
      readContract({ address: contracts.agentRegistry, abi: AgentRegistryAbi, functionName: "walletCount", args: [agentId] }) as Promise<bigint>,
      readContract({ address: contracts.agentRegistry, abi: AgentRegistryAbi, functionName: "erc8004Ref",  args: [agentId] }) as Promise<bigint>,
    ]);

    return {
      agentId:        agentId.toString(),
      owner,
      walletCount:    walletCount.toString(),
      erc8004TokenId: erc8004Ref.toString(),
    };
  });

  // ── GET /agents/:agentId/credit ───────────────────────────────────────────
  // Shape: CreditResponse — { agentId, limit, limitFormatted, record: { totalBorrowed, totalRepaid, activeLoans, completedLoans, defaultedLoans } }
  app.get<{ Params: { agentId: string } }>("/agents/:agentId/credit", async (req, reply) => {
    const agentId = validateUint(req.params.agentId, "agentId");

    const owner = await readContract({
      address: contracts.agentRegistry,
      abi:     AgentRegistryAbi,
      functionName: "agentOwner",
      args: [agentId],
    }) as string;

    if (!owner || owner === "0x0000000000000000000000000000000000000000") {
      return reply.code(404).send({ error: `Agent ${agentId} does not exist` });
    }

    // CreditRegistry is keyed by agentId (uint256), not by wallet address.
    const [limit, credits] = await Promise.all([
      readContract({
        address: contracts.creditRegistry,
        abi:     CreditRegistryAbi,
        functionName: "getLimit",
        args: [agentId],
      }) as Promise<bigint>,
      readContract({
        address: contracts.creditRegistry,
        abi:     CreditRegistryAbi,
        functionName: "credits",
        args: [agentId],
      }) as Promise<readonly [bigint, bigint, bigint, boolean, bigint, bigint]>,
    ]);

    // credits returns AgentCredit: (currentLimit, loansRepaid, loansDefaulted,
    // exists, activityLimit, activityAttested).
    const [, loansRepaid, loansDefaulted] = credits;

    // Amounts and open-loan counts are derived from the agent's on-chain loans
    // (CreditRegistry tracks counts, not amounts).
    const stats = await fetchAgentLoanStats(agentId);

    return {
      agentId:        agentId.toString(),
      limit:          limit.toString(),
      limitFormatted: formatUnits6(limit),
      record: {
        totalBorrowed:  stats.totalBorrowed.toString(),
        totalRepaid:    stats.totalRepaid.toString(),
        activeLoans:    stats.activeLoans.toString(),
        completedLoans: loansRepaid.toString(),
        defaultedLoans: loansDefaulted.toString(),
      },
    };
  });

  // ── GET /agents/:agentId/loans ────────────────────────────────────────────
  // Returns LoanSummary[]. LoanRequested carries no agentId, so every loan is
  // resolved via getLoan and filtered by its on-chain agentId, then paginated.
  app.get<{ Params: { agentId: string }; Querystring: { page?: string; pageSize?: string } }>(
    "/agents/:agentId/loans",
    async (req) => {
      const agentId  = validateUint(req.params.agentId, "agentId");
      const page     = parsePageParam(req.query.page, 1, Number.MAX_SAFE_INTEGER);
      const pageSize = parsePageParam(req.query.pageSize, 20, 50);

      const ids = await fetchAllLoanIds();
      const withViews = await fetchLoanViews(ids);
      const mine = withViews.filter(({ view }) => view.agentId === agentId);

      const start = (page - 1) * pageSize;
      const slice = mine.slice(start, start + pageSize);

      return slice.map(({ loanId, view }) => ({
        loanId:             loanId.toString(),
        borrower:           view.borrower,
        agentId:            view.agentId.toString(),
        status:             view.status,
        statusName:         loanStatusName(view.status),
        principal:          view.principal.toString(),
        principalFormatted: formatUnits6(view.principal),
      }));
    }
  );
}
