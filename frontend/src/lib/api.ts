/** Valen backend API client — all reads go through /api proxy to localhost:3000 */

const BASE = '/api'

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`)
  if (!res.ok) {
    let msg = `HTTP ${res.status}`
    try { msg = (await res.json()).error ?? msg } catch { /* noop */ }
    throw new Error(msg)
  }
  return res.json() as Promise<T>
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
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

export interface WalletCollateralResponse {
  wallet: string
  usdc: { available: string; availableFormatted: string }
  eurc: { available: string; availableFormatted: string }
}

export interface RequiredCollateralResponse {
  principal: string
  asset: string
  required: string
  requiredFormatted: string
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

export interface RecipientResponse {
  wallet: string
  isApproved: boolean
  categoryId: string
  label: string
}

export interface ActivityResponse {
  activityHash: string
  attested: boolean
  attester: string
  timestamp: string
  data: string
}

export interface PrepareResponse {
  to: string
  data: string
  chainId: number
  functionName: string
  note: string
}

// ── API methods ─────────────────────────────────────────────────────────────

export const api = {
  health: () => get<HealthResponse>('/health'),
  agent: (wallet: string) => get<AgentResponse>(`/agents/${wallet}`),
  credit: (agentId: string) => get<CreditResponse>(`/agents/${agentId}/credit`),
  agentLoans: (agentId: string) => get<LoanSummary[]>(`/agents/${agentId}/loans`),
  loans: () => get<LoanSummary[]>('/loans'),
  loan: (loanId: string) => get<LoanDetail>(`/loans/${loanId}`),
  loanRepayment: (loanId: string) => get<RepaymentResponse>(`/loans/${loanId}/repayment`),
  loanCollateral: (loanId: string) => get<CollateralResponse>(`/loans/${loanId}/collateral`),
  walletCollateral: (wallet: string) => get<WalletCollateralResponse>(`/collateral/${wallet}`),
  requiredCollateral: (principal: string, asset: string) =>
    get<RequiredCollateralResponse>(`/collateral/required?principal=${principal}&asset=${asset}`),
  pool: () => get<PoolResponse>('/pool'),
  assets: () => get<AssetsResponse>('/assets'),
  recipient: (wallet: string) => get<RecipientResponse>(`/recipients/${wallet}`),
  activity: (hash: string) => get<ActivityResponse>(`/activity/${hash}`),
  prepareLoan: (proposal: unknown) => post<PrepareResponse>('/loans/prepare', proposal),
}
