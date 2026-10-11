import { useParams, Link, useNavigate } from 'react-router-dom'
import { ArrowLeft, ExternalLink, RefreshCw } from 'lucide-react'
import { Card } from '@/components/ui/Card'
import { Badge } from '@/components/ui/Badge'
import { StatRow } from '@/components/ui/StatRow'
import { PageSpinner } from '@/components/ui/Spinner'
import { ErrorState } from '@/components/ui/ErrorState'
import { EmptyState } from '@/components/ui/EmptyState'
import { useApi } from '@/hooks/useApi'
import { api } from '@/lib/api'
import { fmtUsdc, loanStatusInfo, shortAddr } from '@/lib/format'
import type { LoanSummary } from '@/lib/api'

const ARC_EXPLORER = 'https://explorer.testnet.arc.io'

function LoanCard({ loan }: { loan: LoanSummary }) {
  const { label, color } = loanStatusInfo(loan.status)
  return (
    <Link to={`/loans/${loan.loanId}`}>
      <Card className="hover:border-[var(--border-strong)] transition-colors cursor-pointer">
        <div className="flex items-center justify-between gap-4">
          <div>
            <div className="flex items-center gap-2 mb-1">
              <span className="text-sm font-semibold text-[var(--ink)]">Loan #{loan.loanId}</span>
              <Badge variant={
                loan.status === 5 ? 'success' :
                loan.status === 4 ? 'warning' :
                loan.status === 6 ? 'danger' : 'neutral'
              }>
                <span className={color}>{label}</span>
              </Badge>
            </div>
            <p className="text-xs text-[var(--muted)] mono">{shortAddr(loan.borrower)}</p>
          </div>
          <div className="text-right">
            <p className="text-sm font-semibold text-[var(--ink)]">{loan.principalFormatted}</p>
            <p className="text-xs text-[var(--muted)]">Agent #{loan.agentId}</p>
          </div>
        </div>
      </Card>
    </Link>
  )
}

function LoanDetailView({ loanId }: { loanId: string }) {
  const navigate = useNavigate()
  const loan = useApi(() => api.loan(loanId), [loanId])
  const repayment = useApi(() => api.loanRepayment(loanId), [loanId])
  const collateral = useApi(() => api.loanCollateral(loanId), [loanId])

  if (loan.isLoading) return <PageSpinner />
  if (loan.isError) return <ErrorState message={loan.error ?? undefined} onRetry={loan.refetch} />
  if (!loan.data) return null

  const { label, color } = loanStatusInfo(loan.data.status)

  return (
    <div className="space-y-4">
      <button
        onClick={() => navigate('/transactions')}
        className="flex items-center gap-1.5 text-xs text-[var(--muted)] hover:text-[var(--ink-2)] transition-colors"
      >
        <ArrowLeft className="w-3.5 h-3.5" /> All Transactions
      </button>

      <div className="flex items-center justify-between">
        <h2 className="display text-xl font-semibold text-[var(--ink)]">Loan #{loanId}</h2>
        <Badge variant={
          loan.data.status === 5 ? 'success' :
          loan.data.status === 4 ? 'warning' :
          loan.data.status === 6 ? 'danger' : 'neutral'
        }>
          <span className={color}>{label}</span>
        </Badge>
      </div>

      <div className="grid lg:grid-cols-2 gap-4">
        <Card>
          <h3 className="text-sm font-semibold text-[var(--ink)] mb-4">Loan Terms</h3>
          <div className="space-y-0">
            <StatRow label="Principal" value={<span className="font-semibold">{loan.data.principalFormatted}</span>} />
            <StatRow label="Total Repayment Due" value={loan.data.totalRepaymentDueFormatted} />
            <StatRow label="Repayment Rate" value={`${Number(loan.data.repaymentRateBps) / 100}%`} />
            <StatRow label="Duration" value={`${Number(loan.data.duration) / 86400}d`} />
            <StatRow label="Borrower" value={
              <a href={`${ARC_EXPLORER}/address/${loan.data.borrower}`} target="_blank" rel="noreferrer"
                 className="flex items-center gap-1 text-[var(--accent)] hover:underline mono text-[10px]">
                {shortAddr(loan.data.borrower)} <ExternalLink className="w-3 h-3" />
              </a>
            } />
            <StatRow label="Credit Wallet" value={<span className="mono text-[10px]">{shortAddr(loan.data.creditWallet)}</span>} />
            <StatRow label="Lender" value={<span className="mono text-[10px]">{shortAddr(loan.data.lender)}</span>} />
            <StatRow label="Agent ID" value={`#${loan.data.agentId}`} />
          </div>
        </Card>

        <div className="space-y-4">
          {repayment.data && (
            <Card>
              <h3 className="text-sm font-semibold text-[var(--ink)] mb-4">Repayment</h3>
              <div className="space-y-0">
                <StatRow label="Recovered" value={
                  <span className="text-[var(--success)]">{repayment.data.totalRecoveredFormatted}</span>
                } />
                <StatRow label="Outstanding" value={repayment.data.outstandingFormatted} />
                <StatRow label="Fully Repaid" value={
                  repayment.data.isFullyRepaid
                    ? <Badge variant="success">Yes</Badge>
                    : <Badge variant="warning">No</Badge>
                } />
              </div>
            </Card>
          )}

          {collateral.data && (
            <Card>
              <h3 className="text-sm font-semibold text-[var(--ink)] mb-4">Collateral</h3>
              <div className="space-y-0">
                <StatRow label="Asset" value={
                  <span className="mono text-[10px]">{shortAddr(collateral.data.asset)}</span>
                } />
                <StatRow label="Reserved" value={fmtUsdc(collateral.data.amount)} />
                <StatRow label="Released" value={
                  collateral.data.resolved
                    ? <Badge variant="success">Yes — returned to borrower</Badge>
                    : <Badge variant="neutral">No — still locked</Badge>
                } />
              </div>
            </Card>
          )}
        </div>
      </div>
    </div>
  )
}

export function Transactions() {
  const { loanId } = useParams<{ loanId?: string }>()
  const loans = useApi(() => api.loans())

  if (loanId) return <LoanDetailView loanId={loanId} />

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="display text-2xl font-semibold text-[var(--ink)]">Transactions</h1>
          <p className="text-sm text-[var(--muted)] mt-0.5">All loans indexed from Arc Testnet events</p>
        </div>
        <button
          onClick={loans.refetch}
          className="flex items-center gap-1.5 text-xs text-[var(--muted)] hover:text-[var(--ink-2)] transition-colors"
        >
          <RefreshCw className="w-3.5 h-3.5" /> Refresh
        </button>
      </div>

      {loans.isLoading && <PageSpinner />}
      {loans.isError && <ErrorState message={loans.error ?? undefined} onRetry={loans.refetch} />}
      {loans.data && loans.data.length === 0 && (
        <EmptyState
          title="No transactions found"
          description="No LoanRequested events were found. Loans will appear here once agents start borrowing."
        />
      )}
      {loans.data && loans.data.length > 0 && (
        <div className="space-y-2">
          {loans.data.map((l) => <LoanCard key={l.loanId} loan={l} />)}
        </div>
      )}

      <Card className="mt-6">
        <p className="text-[11px] text-[var(--muted)] leading-relaxed">
          Transaction history is reconstructed from on-chain <code className="mono bg-[var(--surface-strong)] px-1 rounded text-[10px]">LoanRequested</code> events via <code className="mono bg-[var(--surface-strong)] px-1 rounded text-[10px]">eth_getLogs</code>. Pagination may be limited by the RPC endpoint's block-range cap.
        </p>
      </Card>
    </div>
  )
}
