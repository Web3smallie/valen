/** UI formatting helpers — safe BigInt paths, no floating-point conversion of on-chain amounts */

export function shortAddr(addr: string): string {
  if (!addr || addr.length < 10) return addr
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

/** Format a raw 6-decimal USDC/EURC amount string as "$X.XX" */
export function fmtUsdc(raw: string | bigint | undefined): string {
  if (raw === undefined || raw === null) return '—'
  const n = BigInt(raw)
  const whole = n / 1_000_000n
  const frac = n % 1_000_000n
  const fracStr = frac.toString().padStart(6, '0').slice(0, 2)
  return `$${whole.toLocaleString()}.${fracStr}`
}

export const LOAN_STATUSES: Record<number, { label: string; color: string }> = {
  0: { label: 'Requested', color: 'text-valen-warning' },
  1: { label: 'Approved', color: 'text-valen-ink-2' },
  2: { label: 'Pending Approval', color: 'text-valen-muted' },
  3: { label: 'Rejected', color: 'text-valen-danger' },
  4: { label: 'Active', color: 'text-valen-success' },
  5: { label: 'Repaid', color: 'text-valen-success' },
  6: { label: 'Defaulted', color: 'text-valen-danger' },
  7: { label: 'Cancelled', color: 'text-valen-muted' },
}

export function loanStatusInfo(status: number) {
  return LOAN_STATUSES[status] ?? { label: `Status ${status}`, color: 'text-valen-muted' }
}

export function timeAgo(isoOrTs: string | number): string {
  const ts = typeof isoOrTs === 'number' ? isoOrTs * 1000 : new Date(isoOrTs).getTime()
  const diff = Date.now() - ts
  if (diff < 60_000) return 'just now'
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`
  return `${Math.floor(diff / 86_400_000)}d ago`
}

export function cn(...classes: (string | undefined | false | null)[]): string {
  return classes.filter(Boolean).join(' ')
}
