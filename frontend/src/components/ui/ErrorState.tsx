import { AlertCircle } from 'lucide-react'

export function ErrorState({ message, onRetry }: { message?: string; onRetry?: () => void }) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-16 text-center">
      <div className="w-10 h-10 rounded-full bg-[rgba(240,107,120,0.15)] flex items-center justify-center">
        <AlertCircle className="w-5 h-5 text-[var(--danger)]" />
      </div>
      <p className="text-[var(--muted)] text-sm max-w-xs">
        {message ?? 'Something went wrong. The backend may be offline or the RPC endpoint is rate-limited.'}
      </p>
      {onRetry && (
        <button
          onClick={onRetry}
          className="text-xs text-[var(--accent)] hover:underline mt-1"
        >
          Retry
        </button>
      )}
    </div>
  )
}
