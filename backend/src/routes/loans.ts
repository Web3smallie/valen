/**
 * GET /loans                      — all loans (paginated via events)
 * GET /loans/:loanId              — full loan detail
 * GET /loans/:loanId/repayment    — repayment state
 * GET /loans/:loanId/collateral   — collateral reservation
 *
 * All response shapes match frontend types in api.ts.
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { LoanRegistryAbi }       from "../abis/LoanRegistry.js";
import { RevenueRouterAbi }      from "../abis/RevenueRouter.js";
import { CollateralVaultAbi }    from "../abis/CollateralVault.js";
import { LoanVaultAbi }          from "../abis/LoanVault.js";
import { readContract } from "../lib/rpc.js";
import { fetchAllLoanIds, fetchLoanViews } from "../lib/loanEvents.js";
import { validateUint, loanStatusName, formatUnits6, parsePageParam } from "../lib/format.js";

export async function loanRoutes(app: FastifyInstance) {

  // ── GET /loans ────────────────────────────────────────────────────────────
  // Returns LoanSummary[] — fetches LoanRequested events then getLoan for each
  // item on the page.
  app.get<{ Querystring: { page?: string; pageSize?: string } }>("/loans", async (req) => {
    const page     = parsePageParam(req.query.page, 1, Number.MAX_SAFE_INTEGER);
    const pageSize = parsePageParam(req.query.pageSize, 20, 50);

    const allIds = await fetchAllLoanIds();
    const start  = (page - 1) * pageSize;
    const slice  = allIds.slice(start, start + pageSize);
    const withViews = await fetchLoanViews(slice);

    return withViews.map(({ loanId, view }) => ({
      loanId:             loanId.toString(),
      borrower:           view.borrower,
      agentId:            view.agentId.toString(),
      status:             view.status,
      statusName:         loanStatusName(view.status),
      principal:          view.principal.toString(),
      principalFormatted: formatUnits6(view.principal),
    }));
  });

  // ── GET /loans/:loanId ────────────────────────────────────────────────────
  // Returns LoanDetail — flat shape matching frontend type.
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
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getLoan",             args: [loanId] }),
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getMilestones",       args: [loanId] }),
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getBudget",           args: [loanId] }),
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getCollateralAmount", args: [loanId] }) as Promise<bigint>,
      readContract({ address: contracts.loanRegistry, abi: LoanRegistryAbi, functionName: "getCollateralAsset",  args: [loanId] }) as Promise<string>,
    ]);

    // getDirectDisbursement exists only on V4. The deployed V3 contract lacks
    // the getter, so a failed read means "milestone loan", not an error —
    // default to false instead of failing the whole response.
    let directDisbursement = false;
    try {
      directDisbursement = await readContract({
        address: contracts.loanRegistry,
        abi:     LoanRegistryAbi,
        functionName: "getDirectDisbursement",
        args: [loanId],
      }) as boolean;
    } catch {
      directDisbursement = false;
    }

    const l = loan as {
      agentId: bigint; borrower: string; lender: string; creditWallet: string;
      principal: bigint; totalRepaymentDue: bigint; repaymentRateBps: number;
      status: number; createdAt: bigint; expiresAt: bigint;
    };

    const duration = l.expiresAt > 0n && l.createdAt > 0n
      ? (l.expiresAt - l.createdAt).toString()
      : "0";

    return {
      // Flat fields matching frontend LoanDetail
      loanId:                      loanId.toString(),
      agentId:                     l.agentId.toString(),
      borrower:                    l.borrower,
      lender:                      l.lender,
      creditWallet:                l.creditWallet,
      principal:                   l.principal.toString(),
      principalFormatted:          formatUnits6(l.principal),
      totalRepaymentDue:           l.totalRepaymentDue.toString(),
      totalRepaymentDueFormatted:  formatUnits6(l.totalRepaymentDue),
      repaymentRateBps:            l.repaymentRateBps.toString(),
      status:                      l.status,
      statusName:                  loanStatusName(l.status),
      directDisbursement,
      duration,
      startTimestamp:              l.createdAt.toString(),
      collateralAmount:            collateralAmount.toString(),
      collateralAmountFormatted:   formatUnits6(collateralAmount),
      collateralAsset,
      // Nested extended data
      milestones: (milestones as Array<{ amount: bigint; released: boolean; description: string }>).map(
        (m, i) => ({
          index:       i,
          amount:      m.amount.toString(),
          amountFormatted: formatUnits6(m.amount),
          released:    m.released,
          description: m.description,
        })
      ),
      budget: (budget as Array<{ categoryId: string; cap: bigint }>).map(
        (b) => ({ categoryId: b.categoryId, cap: b.cap.toString(), capFormatted: formatUnits6(b.cap) })
      ),
    };
  });

  // ── GET /loans/:loanId/repayment ──────────────────────────────────────────
  // Returns RepaymentResponse — flat, matches frontend type.
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

    const [recovered, isFullyRepaid, loanRaw] = await Promise.all([
      readContract({ address: contracts.revenueRouter, abi: RevenueRouterAbi, functionName: "totalRecovered", args: [loanId] }) as Promise<bigint>,
      readContract({ address: contracts.revenueRouter, abi: RevenueRouterAbi, functionName: "isFullyRepaid",  args: [loanId] }) as Promise<boolean>,
      readContract({ address: contracts.loanRegistry,  abi: LoanRegistryAbi,  functionName: "getLoan",        args: [loanId] }),
    ]);

    const l = loanRaw as { totalRepaymentDue: bigint };
    const outstanding = l.totalRepaymentDue > recovered
      ? l.totalRepaymentDue - recovered
      : 0n;

    return {
      loanId:                      loanId.toString(),
      totalRecovered:              recovered.toString(),
      totalRecoveredFormatted:     formatUnits6(recovered),
      isFullyRepaid,
      totalRepaymentDue:           l.totalRepaymentDue.toString(),
      totalRepaymentDueFormatted:  formatUnits6(l.totalRepaymentDue),
      outstanding:                 outstanding.toString(),
      outstandingFormatted:        formatUnits6(outstanding),
    };
  });

  // ── GET /loans/:loanId/collateral ─────────────────────────────────────────
  // Returns CollateralResponse — flat, matches frontend type.
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
      loanId:          loanId.toString(),
      borrower,
      asset,
      amount:          amount.toString(),
      amountFormatted: formatUnits6(amount),
      resolved,
    };
  });
}
