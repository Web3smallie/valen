import { cn } from '@/lib/format'

export function EmptyState({
  icon: Icon,
  title,
  description,
  className,
}: {
  icon?: React.ComponentType<{ className?: string }>
  title: string
  description?: string
  className?: string
}) {
  return (
    <div className={cn('flex flex-col items-center justify-center gap-3 py-16 text-center', className)}>
      {Icon && (
        <div className="w-10 h-10 rounded-full bg-[var(--surface-strong)] flex items-center justify-center">
          <Icon className="w-5 h-5 text-[var(--muted)]" />
        </div>
      )}
      <p className="text-[var(--ink-2)] text-sm font-medium">{title}</p>
      {description && <p className="text-[var(--muted)] text-xs max-w-xs">{description}</p>}
    </div>
  )
}
