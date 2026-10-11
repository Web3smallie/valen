import { cn } from '@/lib/format'

export function Spinner({ className }: { className?: string }) {
  return (
    <svg
      className={cn('animate-spin', className ?? 'h-5 w-5 text-[var(--accent)]')}
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
    >
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z" />
    </svg>
  )
}

export function PageSpinner() {
  return (
    <div className="flex items-center justify-center h-48">
      <Spinner className="h-8 w-8 text-[var(--accent)]" />
    </div>
  )
}
