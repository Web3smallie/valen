/**
 * Shared helpers for loan discovery via the LoanRequested event.
 *
 * The canonical event (LoanRegistry.sol — V3 and V4 alike) is:
 *   LoanRequested(uint256 indexed loanId, address indexed borrower,
 *                 uint256 principal, uint8 initialStatus)
 * It carries NO agentId: agent filtering is done off-chain by reading
 * getLoan(loanId).agentId. Keep LOAN_REQUESTED_EVENT in sync with the ABI —
 * src/test/abi.test.ts asserts its topic selector matches LoanRegistryAbi.
 */
import { contracts } from "../config/contracts.js";
import { LoanRegistryAbi } from "../abis/LoanRegistry.js";
import { RevenueRouterAbi } from "../abis/RevenueRouter.js";
import { readContract, getLogs } from "./rpc.js";

export const LOAN_REQUESTED_EVENT = {
  type: "event",
  name: "LoanRequested",
  inputs: [
    { name: "loanId",        type: "uint256", indexed: true  },
    { name: "borrower",      type: "address", indexed: true  },
    { name: "principal",     type: "uint256", indexed: false },
    { name: "initialStatus", type: "uint8",   indexed: false },
  ],
} as const;

/**
 * Upper bound on event logs scanned per request. History beyond the most
 * recent MAX_LOAN_SCAN loans is ignored so one request cannot trigger an
 * unbounded number of RPC calls.
 */
export const MAX_LOAN_SCAN = 1000;

/** Subset of ILoanRegistry.LoanView used by list/summary endpoints. */
export interface LoanViewLite {
  agentId: bigint;
  borrower: string;
  principal: bigint;
  status: number;
}

type LoanReqLog = { args?: { loanId?: bigint; borrower?: string } };

/** All loanIds from LoanRequested events: chronological, deduped, capped. */
export async function fetchAllLoanIds(): Promise<bigint[]> {
  const logs = await getLogs({
    address: contracts.loanRegistry,
    event: LOAN_REQUESTED_EVENT,
    fromBlock: 0n,
    toBlock: "latest",
  });
  const ids = (logs as unknown as LoanReqLog[])
    .map((l) => l.args?.loanId)
    .filter((id): id is bigint => id !== undefined);
  const deduped = [...new Set(ids)];
  return deduped.length > MAX_LOAN_SCAN ? deduped.slice(-MAX_LOAN_SCAN) : deduped;
}

/** getLoan for each id (parallel reads). */
export async function fetchLoanViews(
  loanIds: bigint[]
): Promise<Array<{ loanId: bigint; view: LoanViewLite }>> {
  const views = await Promise.all(
    loanIds.map((loanId) =>
      readContract({
        address: contracts.loanRegistry,
        abi: LoanRegistryAbi,
        functionName: "getLoan",
        args: [loanId],
      })
    )
  );
  return loanIds.map((loanId, i) => ({ loanId, view: views[i] as LoanViewLite }));
}

/** Statuses that close a loan; everything else counts as open/active. */
const TERMINAL_STATUSES = new Set([
  5, // Repaid
  6, // Defaulted
  8, // Cancelled
]);

export interface AgentLoanStats {
  loanIds: bigint[];
  totalBorrowed: bigint;
  totalRepaid: bigint;
  activeLoans: number;
}

/**
 * Aggregate one agent's loans: filter by on-chain getLoan agentId, sum
 * principals, sum RevenueRouter.totalRecovered, count non-terminal loans.
 */
export async function fetchAgentLoanStats(agentId: bigint): Promise<AgentLoanStats> {
  const ids = await fetchAllLoanIds();
  const withViews = await fetchLoanViews(ids);
  const mine = withViews.filter(({ view }) => view.agentId === agentId);

  const totalBorrowed = mine.reduce((acc, { view }) => acc + view.principal, 0n);
  const activeLoans = mine.filter(({ view }) => !TERMINAL_STATUSES.has(view.status)).length;

  let totalRepaid = 0n;
  if (mine.length > 0) {
    const recovered = await Promise.all(
      mine.map(({ loanId }) =>
        readContract({
          address: contracts.revenueRouter,
          abi: RevenueRouterAbi,
          functionName: "totalRecovered",
          args: [loanId],
        }) as Promise<bigint>
      )
    );
    totalRepaid = recovered.reduce((acc, r) => acc + r, 0n);
  }

  return { loanIds: mine.map(({ loanId }) => loanId), totalBorrowed, totalRepaid, activeLoans };
}
