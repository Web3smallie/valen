/**
 * Valen backend API client.
 * BASE defaults to the Vite dev-server proxy (/api → localhost:3000);
 * override with VITE_API_BASE (e.g. a deployed backend origin) — see .env.example.
 */

const BASE = import.meta.env.VITE_API_BASE ?? '/api'

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`)
  if (!res.ok) {
    let msg = `HTTP ${res.status}`
    try { msg = (await res.json()).error ?? msg } catch { /* noop */ }
    throw new Error(msg)
  }
  return res.json() as Promise<T>
}

// ── Response types ──────────────────────────────────────────────────────────

export interface HealthResponse {
  status: string
  service: string
  time: string
}

export interface AgentResponse {
  wallet: string
  agentId: string
  isRegistered: boolean
}

export interface IdentityResponse {
  agentId: string
  owner: string
  walletCount: string
  erc8004TokenId: string
}

export interface CreditResponse {
  agentId: string
  limit: string
  limitFormatted: string
  record: {
    totalBorrowed: string
    totalRepaid: string
    activeLoans: string
    completedLoans: string
    defaultedLoans: string
  }
}

export interface LoanSummary {
  loanId: string
  borrower: string
  agentId: string
  status: number
  statusName: string
  principal: string
  principalFormatted: string
}

export interface LoanDetail {
  loanId: string
  borrower: string
  lender: string
  creditWallet: string
  agentId: string
  principal: string
  principalFormatted: string
  totalRepaymentDue: string
  totalRepaymentDueFormatted: string
  repaymentRateBps: string
  status: number
  statusName: string
  /** True when the loan disburses in full at funding (V4+); absent/false = milestone-based. */
  directDisbursement?: boolean
  duration: string
  startTimestamp: string
  collateralAmount: string
  collateralAmountFormatted: string
  collateralAsset: string
}

export interface RepaymentResponse {
  loanId: string
  totalRecovered: string
  totalRecoveredFormatted: string
  isFullyRepaid: boolean
  totalRepaymentDue: string
  totalRepaymentDueFormatted: string
  outstanding: string
  outstandingFormatted: string
}

export interface CollateralResponse {
  loanId: string
  borrower: string
  asset: string
  amount: string
  amountFormatted: string
  resolved: boolean
}

export interface PoolResponse {
  idleLedger: string
  idleLedgerFormatted: string
  totalDeployed: string
  totalDeployedFormatted: string
  activeLoanCount: string
  reserveBalance: string
  reserveBalanceFormatted: string
}

export interface AssetsResponse {
  usdc: { address: string; decimals: number; price: string; enabled: boolean }
  eurc: { address: string; decimals: number; price: string; priceFormatted: string; enabled: boolean }
}

// ── API methods ─────────────────────────────────────────────────────────────

export const api = {
  health: () => get<HealthResponse>('/health'),
  agent: (wallet: string) => get<AgentResponse>(`/agents/${wallet}`),
  agentIdentity: (agentId: string) => get<IdentityResponse>(`/agents/${agentId}/identity`),
  credit: (agentId: string) => get<CreditResponse>(`/agents/${agentId}/credit`),
  agentLoans: (agentId: string) => get<LoanSummary[]>(`/agents/${agentId}/loans`),
  loans: () => get<LoanSummary[]>('/loans'),
  loan: (loanId: string) => get<LoanDetail>(`/loans/${loanId}`),
  loanRepayment: (loanId: string) => get<RepaymentResponse>(`/loans/${loanId}/repayment`),
  loanCollateral: (loanId: string) => get<CollateralResponse>(`/loans/${loanId}/collateral`),
  pool: () => get<PoolResponse>('/pool'),
  assets: () => get<AssetsResponse>('/assets'),
}
