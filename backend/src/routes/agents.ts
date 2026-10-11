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
import { LoanRegistryAbi }       from "../abis/LoanRegistry.js";
import { readContract, getLogs } from "../lib/rpc.js";
import {
  validateAddress, validateUint, formatUnits6, loanStatusName,
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

    const [limit, credits] = await Promise.all([
      readContract({
        address: contracts.creditRegistry,
        abi:     CreditRegistryAbi,
        functionName: "getLimit",
        args: [owner as `0x${string}`],
      }) as Promise<bigint>,
      readContract({
        address: contracts.creditRegistry,
        abi:     CreditRegistryAbi,
        functionName: "credits",
        args: [owner as `0x${string}`],
      }) as Promise<readonly [bigint, bigint, bigint, bigint]>,
    ]);

    // credits returns (totalBorrowed, totalRepaid, loanCount, defaultCount)
    const [totalBorrowed, totalRepaid, loanCount, defaultCount] = credits;

    return {
      agentId:        agentId.toString(),
      limit:          limit.toString(),
      limitFormatted: formatUnits6(limit),
      record: {
        totalBorrowed:  totalBorrowed.toString(),
        totalRepaid:    totalRepaid.toString(),
        activeLoans:    "0",           // not tracked separately in CreditRegistry V1
        completedLoans: loanCount.toString(),
        defaultedLoans: defaultCount.toString(),
      },
    };
  });

  // ── GET /agents/:agentId/loans ────────────────────────────────────────────
  // Returns LoanSummary[] by fetching LoanRequested events then getLoan for each.
  app.get<{ Params: { agentId: string }; Querystring: { page?: string; pageSize?: string } }>(
    "/agents/:agentId/loans",
    async (req, reply) => {
      const agentId  = validateUint(req.params.agentId, "agentId");
      const page     = Math.max(1, parseInt(req.query.page ?? "1", 10));
      const pageSize = Math.min(50, Math.max(1, parseInt(req.query.pageSize ?? "20", 10)));

      const logs = await getLogs({
        address: contracts.loanRegistry,
        event: {
          type: "event",
          name: "LoanRequested",
          inputs: [
            { name: "loanId",   type: "uint256", indexed: true  },
            { name: "agentId",  type: "uint256", indexed: true  },
            { name: "borrower", type: "address", indexed: false },
          ],
        },
        args: { agentId },
        fromBlock: 0n,
        toBlock:   "latest",
      });

      type LoanReqLog = { args?: { loanId?: bigint; agentId?: bigint; borrower?: string } };
      const allLoanIds = logs.map((l) => (l as unknown as LoanReqLog).args?.loanId ?? 0n)
                             .filter((id) => id > 0n || id === 0n);

      const total = allLoanIds.length;
      const start = (page - 1) * pageSize;
      const slice = allLoanIds.slice(start, start + pageSize);

      // Fetch full loan details for this page
      const summaries = await Promise.all(
        slice.map(async (loanId) => {
          const loan = await readContract({
            address: contracts.loanRegistry,
            abi:     LoanRegistryAbi,
            functionName: "getLoan",
            args: [loanId],
          }) as {
            agentId: bigint; borrower: string; lender: string; creditWallet: string;
            principal: bigint; totalRepaymentDue: bigint; repaymentRateBps: number;
            status: number; createdAt: bigint; expiresAt: bigint;
          };

          return {
            loanId:           loanId.toString(),
            borrower:         loan.borrower,
            agentId:          loan.agentId.toString(),
            status:           loan.status,
            statusName:       loanStatusName(loan.status),
            principal:        loan.principal.toString(),
            principalFormatted: formatUnits6(loan.principal),
          };
        })
      );

      return summaries;
    }
  );
}
