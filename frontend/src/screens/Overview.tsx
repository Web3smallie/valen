import { Activity, TrendingUp, Users, CreditCard, RefreshCw } from 'lucide-react'
import { Card, CardLabel, CardValue } from '@/components/ui/Card'
import { Badge } from '@/components/ui/Badge'
import { PageSpinner } from '@/components/ui/Spinner'
import { ErrorState } from '@/components/ui/ErrorState'
import { StatRow } from '@/components/ui/StatRow'
import { useApi } from '@/hooks/useApi'
import { api } from '@/lib/api'
import { fmtUsdc } from '@/lib/format'
import type { PoolResponse, AssetsResponse } from '@/lib/api'

function PoolStats({ pool }: { pool: PoolResponse }) {
  const total = BigInt(pool.idleLedger) + BigInt(pool.totalDeployed)
  const utilisation = total > 0n
    ? Number(BigInt(pool.totalDeployed) * 10000n / total) / 100
    : 0

  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
      <Card>
        <CardLabel>Idle Liquidity</CardLabel>
        <CardValue>{fmtUsdc(pool.idleLedger)}</CardValue>
        <p className="text-[11px] text-[var(--muted)] mt-1">USDC available</p>
      </Card>
      <Card>
        <CardLabel>Deployed Capital</CardLabel>
        <CardValue className="text-[var(--warning)]">{fmtUsdc(pool.totalDeployed)}</CardValue>
        <p className="text-[11px] text-[var(--muted)] mt-1">in active loans</p>
      </Card>
      <Card>
        <CardLabel>Active Loans</CardLabel>
        <CardValue>{pool.activeLoanCount}</CardValue>
        <p className="text-[11px] text-[var(--muted)] mt-1">outstanding</p>
      </Card>
      <Card>
        <CardLabel>Pool Utilisation</CardLabel>
        <CardValue className={utilisation > 80 ? 'text-[var(--danger)]' : 'text-[var(--success)]'}>
          {Math.round(utilisation)}%
        </CardValue>
        <div className="mt-2 h-1 rounded-full bg-[var(--border)] overflow-hidden">
          <div
            className="h-full rounded-full bg-[var(--accent)] transition-all"
            style={{ width: `${Math.min(utilisation, 100)}%` }}
          />
        </div>
      </Card>
    </div>
  )
}

function AssetConfig({ assets }: { assets: AssetsResponse }) {
  const rows = [
    { key: 'usdc', label: 'USDC', ...assets.usdc },
    { key: 'eurc', label: 'EURC', ...assets.eurc },
  ]
  return (
    <Card>
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-[var(--ink)]">Accepted Collateral</h3>
        <Badge variant="success">Live</Badge>
      </div>
      <div className="space-y-0">
        {rows.map((a) => (
          <StatRow
            key={a.key}
            label={a.label}
            value={
              <span className="flex items-center gap-2">
                {'priceFormatted' in a
                  ? <span className="mono">{(a as typeof assets.eurc).priceFormatted}/token</span>
                  : <span className="mono">$1.00/token</span>
                }
                {a.enabled
                  ? <Badge variant="success">enabled</Badge>
                  : <Badge variant="neutral">disabled</Badge>
                }
              </span>
            }
          />
        ))}
      </div>
    </Card>
  )
}

export function Overview() {
  const pool = useApi(() => api.pool())
  const assets = useApi(() => api.assets())

  const isLoading = pool.isLoading || assets.isLoading
  const isError = pool.isError || assets.isError
  const errorMsg = pool.error ?? assets.error ?? undefined

  function refetch() { pool.refetch(); assets.refetch() }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="display text-2xl font-semibold text-[var(--ink)]">Protocol Overview</h1>
          <p className="text-sm text-[var(--muted)] mt-0.5">Live state from Arc Testnet</p>
        </div>
        <button
          onClick={refetch}
          className="flex items-center gap-1.5 text-xs text-[var(--muted)] hover:text-[var(--ink-2)] transition-colors"
        >
          <RefreshCw className="w-3.5 h-3.5" />
          Refresh
        </button>
      </div>

      {isLoading && <PageSpinner />}
      {isError && <ErrorState message={errorMsg} onRetry={refetch} />}

      {!isLoading && !isError && pool.data && (
        <>
          <PoolStats pool={pool.data} />

          <div className="grid lg:grid-cols-2 gap-4">
            {assets.data && <AssetConfig assets={assets.data} />}

            <Card>
              <div className="flex items-center gap-2 mb-4">
                <Activity className="w-4 h-4 text-[var(--accent)]" />
                <h3 className="text-sm font-semibold text-[var(--ink)]">Protocol Stats</h3>
              </div>
              <div className="space-y-0">
                <StatRow label="Network" value="Arc Testnet" />
                <StatRow label="USDC Contract" value={<span className="mono text-[10px]">0x3600…0000</span>} />
                <StatRow label="EURC Contract" value={<span className="mono text-[10px]">0x89B5…72a</span>} />
                <StatRow label="LoanRegistry (V3)" value={<span className="mono text-[10px]">0x253B…6f8d</span>} />
                <StatRow label="CollateralVault" value={<span className="mono text-[10px]">0xC499…dA2f</span>} />
              </div>
            </Card>
          </div>

          <Card>
            <div className="flex items-center gap-2 mb-1">
              <TrendingUp className="w-4 h-4 text-[var(--accent)]" />
              <h3 className="text-sm font-semibold text-[var(--ink)]">How Valen Works</h3>
            </div>
            <p className="text-xs text-[var(--muted)] mb-4">
              Valen provides programmable credit infrastructure for autonomous AI agents on Arc.
            </p>
            <div className="grid sm:grid-cols-3 gap-3">
              {[
                { icon: Users, title: 'Agents register', desc: 'Autonomous agents establish persistent on-chain identities and build verifiable credit histories.' },
                { icon: CreditCard, title: 'Agents borrow', desc: 'Against approved collateral or verified activity, agents access USDC credit through their own signing wallets.' },
                { icon: TrendingUp, title: 'Lenders earn', desc: 'Human lenders deposit USDC into the pool and earn yield as agents borrow and repay.' },
              ].map(({ icon: Icon, title, desc }) => (
                <div key={title} className="rounded-xl bg-[var(--surface-muted)] p-4">
                  <Icon className="w-5 h-5 text-[var(--accent)] mb-2" />
                  <p className="text-xs font-semibold text-[var(--ink-2)] mb-1">{title}</p>
                  <p className="text-[11px] text-[var(--muted)] leading-relaxed">{desc}</p>
                </div>
              ))}
            </div>
          </Card>
        </>
      )}
    </div>
  )
}
