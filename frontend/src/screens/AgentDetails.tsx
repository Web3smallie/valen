import { useParams, Link } from 'react-router-dom'
import { ArrowLeft, ExternalLink } from 'lucide-react'
import { Card } from '@/components/ui/Card'
import { Badge } from '@/components/ui/Badge'
import { StatRow } from '@/components/ui/StatRow'
import { PageSpinner } from '@/components/ui/Spinner'
import { ErrorState } from '@/components/ui/ErrorState'
import { EmptyState } from '@/components/ui/EmptyState'
import { useApi } from '@/hooks/useApi'
import { api } from '@/lib/api'
import { shortAddr, fmtUsdc, loanStatusInfo } from '@/lib/format'

const ARC_EXPLORER = 'https://explorer.testnet.arc.io'
const TEST_WALLET = '0x786d491Fb520F3D9D9c7e62156C879fe52d6921E'

export function AgentDetails() {
  const { agentId } = useParams<{ agentId: string }>()
  const id = agentId ?? '1'

  const credit = useApi(() => api.credit(id), [id])
  const loans = useApi(() => api.agentLoans(id), [id])

  const isLoading = credit.isLoading || loans.isLoading
  const isError = credit.isError && loans.isError
  const errorMsg = credit.error ?? loans.error ?? undefined

  function refetch() { credit.refetch(); loans.refetch() }

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <Link to="/agents" className="flex items-center gap-1.5 text-xs text-[var(--muted)] hover:text-[var(--ink-2)] transition-colors">
          <ArrowLeft className="w-3.5 h-3.5" /> Agents
        </Link>
        <span className="text-[var(--subtle)]">/</span>
        <span className="text-sm font-medium text-[var(--ink)]">Agent #{id}</span>
      </div>

      {isLoading && <PageSpinner />}
      {isError && <ErrorState message={errorMsg} onRetry={refetch} />}

      {!isLoading && credit.data && (
        <div className="grid lg:grid-cols-2 gap-4">
          <Card>
            <h3 className="text-sm font-semibold text-[var(--ink)] mb-4">Credit Profile</h3>
            <div className="space-y-0">
              <StatRow label="Agent ID" value={<span className="mono">#{credit.data.agentId}</span>} />
              <StatRow label="Credit Limit" value={
                <span className="text-[var(--success)] font-semibold">{credit.data.limitFormatted}</span>
              } />
              <StatRow label="Total Borrowed" value={fmtUsdc(credit.data.record.totalBorrowed)} />
              <StatRow label="Total Repaid" value={fmtUsdc(credit.data.record.totalRepaid)} />
              <StatRow label="Active Loans" value={credit.data.record.activeLoans} />
              <StatRow label="Completed Loans" value={credit.data.record.completedLoans} />
              <StatRow label="Defaulted Loans" value={
                <span className={Number(credit.data.record.defaultedLoans) > 0 ? 'text-[var(--danger)]' : ''}>
                  {credit.data.record.defaultedLoans}
                </span>
              } />
            </div>
          </Card>

          <Card>
            <h3 className="text-sm font-semibold text-[var(--ink)] mb-4">Identity</h3>
            <div className="space-y-0">
              <StatRow label="Network" value="Arc Testnet" />
              <StatRow label="Registered Wallet" value={
                <a
                  href={`${ARC_EXPLORER}/address/${TEST_WALLET}`}
                  target="_blank"
                  rel="noreferrer"
                  className="flex items-center gap-1 text-[var(--accent)] hover:underline mono text-[10px]"
                >
                  {shortAddr(TEST_WALLET)}
                  <ExternalLink className="w-3 h-3" />
                </a>
              } />
              <StatRow label="Agent type" value="Autonomous / programmatic" />
              <StatRow label="Onboarding" value={<Badge variant="success">Registered</Badge>} />
              <StatRow label="Collateral" value="EURC (multi-asset)" />
            </div>
            <div className="mt-4 rounded-xl bg-[var(--surface-muted)] p-3">
              <p className="text-[11px] text-[var(--muted)] leading-relaxed">
                This agent interacts with Valen programmatically through its own signing wallet. It does not use a browser wallet or require manual approval for routine operations.
              </p>
            </div>
          </Card>
        </div>
      )}

      <div>
        <h3 className="text-sm font-semibold text-[var(--ink)] mb-3">Loan History</h3>
        {loans.isLoading && <PageSpinner />}
        {loans.isError && <ErrorState message={loans.error ?? undefined} onRetry={loans.refetch} />}
        {loans.data && loans.data.length === 0 && (
          <EmptyState title="No loans found" description="No LoanRequested events found for this agent." />
        )}
        {loans.data && loans.data.length > 0 && (
          <div className="space-y-2">
            {loans.data.map((loan) => {
              const { label, color } = loanStatusInfo(loan.status)
              return (
                <Link key={loan.loanId} to={`/loans/${loan.loanId}`}>
                  <Card className="hover:border-[var(--border-strong)] transition-colors">
                    <div className="flex items-center justify-between gap-4">
                      <div>
                        <p className="text-sm font-semibold text-[var(--ink)]">Loan #{loan.loanId}</p>
                        <p className="text-xs text-[var(--muted)]">Principal: {fmtUsdc(loan.principal)}</p>
                      </div>
                      <Badge variant={
                        loan.status === 5 ? 'success' :
                        loan.status === 4 ? 'warning' :
                        loan.status === 6 ? 'danger' : 'neutral'
                      }>
                        <span className={color}>{label}</span>
                      </Badge>
                    </div>
                  </Card>
                </Link>
              )
            })}
          </div>
        )}
      </div>
    </div>
  )
}
