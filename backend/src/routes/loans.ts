/**
 * GET /loans                      — all loans (paginated, via events)
 * GET /loans/:loanId              — full loan detail
 * GET /loans/:loanId/repayment    — repayment state
 * GET /loans/:loanId/collateral   — collateral reservation
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { LoanRegistryAbi }       from "../abis/LoanRegistry.js";
import { RevenueRouterAbi }      from "../abis/RevenueRouter.js";
import { CollateralVaultAbi }    from "../abis/CollateralVault.js";
import { LoanVaultAbi }          from "../abis/LoanVault.js";
import { readContract, getLogs } from "../lib/rpc.js";
import { validateUint, loanStatusName, formatUnits6 } from "../lib/format.js";

export async function loanRoutes(app: FastifyInstance) {

  // ── GET /loans ────────────────────────────────────────────────────────────
  app.get<{ Querystring: { page?: string; pageSize?: string } }>("/loans", async (req) => {
    const page     = Math.max(1, parseInt(req.query.page ?? "1", 10));
    const pageSize = Math.min(200, Math.max(1, parseInt(req.query.pageSize ?? "50", 10)));

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
      fromBlock: 0n,
      toBlock:   "latest",
    });

    type LoanReqLog = { args?: { loanId?: bigint; agentId?: bigint; borrower?: string } };
    const all   = logs.map((l) => {
      const args = (l as unknown as LoanReqLog).args ?? {};
      return {
        loanId:   args.loanId?.toString()  ?? "?",
        agentId:  args.agentId?.toString() ?? "?",
        borrower: args.borrower ?? "?",
      };
    });
    const total = all.length;
    const start = (page - 1) * pageSize;
    const items = all.slice(start, start + pageSize);

    return {
      total,
      page,
      pageSize,
      items,
      note: "Sourced from LoanRequested events. Use GET /loans/:loanId for full detail.",
    };
  });

  // ── GET /loans/:loanId ────────────────────────────────────────────────────
  app.get<{ Params: { loanId: string } }>("/loans/:loanId", async (req, reply) => {
    const loanId = validateUint(req.params.loanId, "loanId");

    const nextLoanId = await readContract({
      address: contracts.loanRegistry,
      abi:     LoanRegistryAbi,
      functionName: "nextLoanId",
    }) as bigint;

    if (loanId >= nextLoanId) {
      return reply.code(404).send({ error: `Loan ${loanId} does not exist` });
    }

    const [loan, milestones, budget, collateralAmount, collateralAsset] = await Promise.all([
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getLoan",           args: [loanId] }),
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getMilestones",     args: [loanId] }),
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getBudget",         args: [loanId] }),
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getCollateralAmount", args: [loanId] }) as Promise<bigint>,
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getCollateralAsset",  args: [loanId] }) as Promise<string>,
    ]);

    const l = loan as {
      agentId: bigint; borrower: string; lender: string; creditWallet: string;
      principal: bigint; totalRepaymentDue: bigint; repaymentRateBps: number;
      status: number; createdAt: bigint; expiresAt: bigint;
    };

    return {
      loanId: loanId.toString(),
      agentId: l.agentId.toString(),
      borrower:    l.borrower,
      lender:      l.lender,
      creditWallet:l.creditWallet,
      status: {
        code: l.status,
        name: loanStatusName(l.status),
      },
      principal: {
        raw:       l.principal.toString(),
        formatted: formatUnits6(l.principal),
      },
      totalRepaymentDue: {
        raw:       l.totalRepaymentDue.toString(),
        formatted: formatUnits6(l.totalRepaymentDue),
      },
      repaymentRateBps: l.repaymentRateBps,
      createdAt:  Number(l.createdAt),
      expiresAt:  Number(l.expiresAt),
      collateral: {
        asset:  collateralAsset,
        amount: { raw: collateralAmount.toString(), formatted: formatUnits6(collateralAmount) },
      },
      milestones: (milestones as Array<{ amount: bigint; released: boolean; description: string }>).map(
        (m, i) => ({ index: i, amount: { raw: m.amount.toString(), formatted: formatUnits6(m.amount) }, released: m.released, description: m.description })
      ),
      budget: (budget as Array<{ categoryId: string; cap: bigint }>).map(
        (b) => ({ categoryId: b.categoryId, cap: { raw: b.cap.toString(), formatted: formatUnits6(b.cap) } })
      ),
    };
  });

  // ── GET /loans/:loanId/repayment ──────────────────────────────────────────
  app.get<{ Params: { loanId: string } }>("/loans/:loanId/repayment", async (req, reply) => {
    const loanId = validateUint(req.params.loanId, "loanId");

    const nextLoanId = await readContract({
      address: contracts.loanRegistry,
      abi:     LoanRegistryAbi,
      functionName: "nextLoanId",
    }) as bigint;

    if (loanId >= nextLoanId) {
      return reply.code(404).send({ error: `Loan ${loanId} does not exist` });
    }

    const [recovered, isFullyRepaid, lockedAmount] = await Promise.all([
      readContract({ address: contracts.revenueRouter, abi: RevenueRouterAbi, functionName: "totalRecovered", args: [loanId] }) as Promise<bigint>,
      readContract({ address: contracts.revenueRouter, abi: RevenueRouterAbi, functionName: "isFullyRepaid",  args: [loanId] }) as Promise<boolean>,
      readContract({ address: contracts.loanVault,     abi: LoanVaultAbi,     functionName: "lockedAmount",   args: [loanId] }) as Promise<bigint>,
    ]);

    return {
      loanId: loanId.toString(),
      totalRecovered: { raw: recovered.toString(), formatted: formatUnits6(recovered) },
      isFullyRepaid,
      vaultLockedAmount: { raw: lockedAmount.toString(), formatted: formatUnits6(lockedAmount) },
    };
  });

  // ── GET /loans/:loanId/collateral ─────────────────────────────────────────
  app.get<{ Params: { loanId: string } }>("/loans/:loanId/collateral", async (req, reply) => {
    const loanId = validateUint(req.params.loanId, "loanId");

    const nextLoanId = await readContract({
      address: contracts.loanRegistry,
      abi:     LoanRegistryAbi,
      functionName: "nextLoanId",
    }) as bigint;

    if (loanId >= nextLoanId) {
      return reply.code(404).send({ error: `Loan ${loanId} does not exist` });
    }

    const reservation = await readContract({
      address: contracts.collateralVault,
      abi:     CollateralVaultAbi,
      functionName: "reservations",
      args: [loanId],
    }) as readonly [string, string, bigint, boolean];

    const [borrower, asset, amount, resolved] = reservation;

    return {
      loanId:   loanId.toString(),
      borrower,
      asset,
      amount: { raw: amount.toString(), formatted: formatUnits6(amount) },
      resolved,
    };
  });
}
