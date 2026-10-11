import { Wallet, Info, ExternalLink } from 'lucide-react'
import { Card, CardLabel, CardValue } from '@/components/ui/Card'
import { StatRow } from '@/components/ui/StatRow'
import { PageSpinner } from '@/components/ui/Spinner'
import { ErrorState } from '@/components/ui/ErrorState'
import { useApi } from '@/hooks/useApi'
import { api } from '@/lib/api'
import { fmtUsdc } from '@/lib/format'
import { useAccount } from 'wagmi'
import { ConnectKitButton } from 'connectkit'

const LOAN_VAULT = '0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19'
const LIQUIDITY_POOL = '0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061'
const ARC_EXPLORER = 'https://explorer.testnet.arc.io'

export function LendingPool() {
  const { isConnected } = useAccount()
  const pool = useApi(() => api.pool())

  return (
    <div className="space-y-6">
      <div>
        <h1 className="display text-2xl font-semibold text-[var(--ink)]">Lending Pool</h1>
        <p className="text-sm text-[var(--muted)] mt-0.5">Supply USDC to earn yield from agent borrowing activity</p>
      </div>

      {pool.isLoading && <PageSpinner />}
      {pool.isError && <ErrorState message={pool.error ?? undefined} onRetry={pool.refetch} />}

      {pool.data && (
        <>
          <div className="grid grid-cols-2 lg:grid-cols-3 gap-3">
            <Card>
              <CardLabel>Total Pool Liquidity</CardLabel>
              <CardValue>
                {fmtUsdc((BigInt(pool.data.idleLedger) + BigInt(pool.data.totalDeployed)).toString())}
              </CardValue>
            </Card>
            <Card>
              <CardLabel>Idle</CardLabel>
              <CardValue className="text-[var(--success)]">{fmtUsdc(pool.data.idleLedger)}</CardValue>
            </Card>
            <Card>
              <CardLabel>Deployed</CardLabel>
              <CardValue className="text-[var(--warning)]">{fmtUsdc(pool.data.totalDeployed)}</CardValue>
            </Card>
          </div>

          <div className="grid lg:grid-cols-2 gap-4">
            <Card>
              <h3 className="text-sm font-semibold text-[var(--ink)] mb-4">Pool Details</h3>
              <div className="space-y-0">
                <StatRow label="Active Loans" value={pool.data.activeLoanCount} />
                <StatRow label="LiquidityPool contract" value={
                  <a href={`${ARC_EXPLORER}/address/${LIQUIDITY_POOL}`} target="_blank" rel="noreferrer"
                     className="mono text-[10px] text-[var(--accent)] hover:underline flex items-center gap-1">
                    {LIQUIDITY_POOL.slice(0, 10)}… <ExternalLink className="w-3 h-3" />
                  </a>
                } />
                <StatRow label="LoanVault contract" value={
                  <a href={`${ARC_EXPLORER}/address/${LOAN_VAULT}`} target="_blank" rel="noreferrer"
                     className="mono text-[10px] text-[var(--accent)] hover:underline flex items-center gap-1">
                    {LOAN_VAULT.slice(0, 10)}… <ExternalLink className="w-3 h-3" />
                  </a>
                } />
                <StatRow label="Collateral assets" value="USDC, EURC" />
              </div>
            </Card>

            <Card>
              <div className="flex items-center gap-2 mb-4">
                <Wallet className="w-4 h-4 text-[var(--accent)]" />
                <h3 className="text-sm font-semibold text-[var(--ink)]">Lend USDC</h3>
              </div>

              {!isConnected ? (
                <div className="flex flex-col items-center gap-4 py-8">
                  <p className="text-sm text-[var(--muted)] text-center max-w-xs">
                    Connect your wallet to view your pool position and deposit USDC.
                  </p>
                  <ConnectKitButton />
                </div>
              ) : (
                <div>
                  <div className="rounded-xl bg-[rgba(245,166,35,0.08)] border border-[rgba(245,166,35,0.2)] p-3 mb-4">
                    <div className="flex items-start gap-2">
                      <Info className="w-4 h-4 text-[var(--warning)] shrink-0 mt-0.5" />
                      <p className="text-[11px] text-[var(--warning)] leading-relaxed">
                        Direct pool deposits via the frontend are not yet enabled. Lender interactions will be available in an upcoming release.
                      </p>
                    </div>
                  </div>
                  <div className="space-y-0">
                    <StatRow label="Your USDC balance" value="—" />
                    <StatRow label="Your pool shares" value="—" />
                    <StatRow label="Withdrawal available" value="—" />
                  </div>
                </div>
              )}
            </Card>
          </div>
        </>
      )}

      <Card>
        <div className="flex items-start gap-2 mb-3">
          <Info className="w-4 h-4 text-[var(--accent)] shrink-0 mt-0.5" />
          <h3 className="text-sm font-semibold text-[var(--ink)]">About the lending pool</h3>
        </div>
        <p className="text-xs text-[var(--muted)] leading-relaxed">
          The Valen LiquidityPool holds USDC supplied by human lenders. When a collateral-backed agent loan is approved, funds move from the pool to the LoanVault, then to the borrower's credit wallet. Repayments flow through the RevenueRouter, which splits principal recovery to the pool and retains a reserve share. The pool tracks idle vs deployed capital at all times.
        </p>
      </Card>
    </div>
  )
}
