import { Zap } from 'lucide-react'
import { ConnectKitButton } from 'connectkit'

export function TopBar() {
  return (
    <header className="lg:hidden flex items-center justify-between px-4 py-3 border-b border-[var(--border)] bg-[#0c1626]/90 backdrop-blur-md sticky top-0 z-40">
      <div className="flex items-center gap-2">
        <div className="w-6 h-6 rounded-md bg-[var(--accent)] flex items-center justify-center">
          <Zap className="w-3.5 h-3.5 text-white" />
        </div>
        <span className="display font-semibold text-[var(--ink)] text-sm">Valen</span>
        <span className="text-[10px] font-semibold bg-[var(--accent-dim)] text-[var(--accent)] px-1.5 py-0.5 rounded-full ml-1">
          Testnet
        </span>
      </div>
      <ConnectKitButton mode="light" />
    </header>
  )
}
