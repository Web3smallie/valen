import { cn } from '@/lib/format'

interface CardProps {
  children: React.ReactNode
  className?: string
  glass?: boolean
  accent?: boolean
}

export function Card({ children, className, glass = true, accent = false }: CardProps) {
  return (
    <div
      className={cn(
        'rounded-2xl border p-5',
        glass
          ? 'bg-[var(--surface)] backdrop-blur-sm border-[var(--border)]'
          : 'bg-[var(--surface-muted)] border-[var(--border)]',
        accent && 'border-[var(--accent)] border-opacity-40',
        className,
      )}
    >
      {children}
    </div>
  )
}

export function CardLabel({ children }: { children: React.ReactNode }) {
  return (
    <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--muted)] mb-1">
      {children}
    </p>
  )
}

export function CardValue({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <p className={cn('display text-2xl font-semibold tabular-nums text-[var(--ink)]', className)}>
      {children}
    </p>
  )
}
