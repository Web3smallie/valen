import { cn } from '@/lib/format'

type Variant = 'success' | 'danger' | 'warning' | 'neutral' | 'accent'

const variantClasses: Record<Variant, string> = {
  success: 'bg-[rgba(77,214,140,0.15)] text-[var(--success)]',
  danger: 'bg-[rgba(240,107,120,0.15)] text-[var(--danger)]',
  warning: 'bg-[rgba(245,166,35,0.15)] text-[var(--warning)]',
  neutral: 'bg-[var(--surface-strong)] text-[var(--muted)]',
  accent: 'bg-[var(--accent-dim)] text-[var(--accent)]',
}

export function Badge({ children, variant = 'neutral', className }: {
  children: React.ReactNode
  variant?: Variant
  className?: string
}) {
  return (
    <span className={cn(
      'inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-semibold',
      variantClasses[variant],
      className,
    )}>
      {children}
    </span>
  )
}
