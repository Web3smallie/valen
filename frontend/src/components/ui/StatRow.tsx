import { cn } from '@/lib/format'

export function StatRow({
  label,
  value,
  mono = false,
  dim = false,
}: {
  label: string
  value: React.ReactNode
  mono?: boolean
  dim?: boolean
}) {
  return (
    <div className="flex items-center justify-between gap-4 py-2.5 border-b border-[var(--border)] last:border-0">
      <span className="text-xs text-[var(--muted)] shrink-0">{label}</span>
      <span className={cn(
        'text-xs font-medium text-right truncate',
        mono && 'mono',
        dim ? 'text-[var(--muted)]' : 'text-[var(--ink-2)]',
      )}>
        {value}
      </span>
    </div>
  )
}
