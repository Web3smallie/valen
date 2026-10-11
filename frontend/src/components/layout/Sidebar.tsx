import { NavLink } from 'react-router-dom'
import {
  LayoutDashboard,
  Bot,
  Wallet,
  ArrowLeftRight,
  Code2,
  Zap,
} from 'lucide-react'
import { ConnectKitButton } from 'connectkit'
import { cn } from '@/lib/format'

const NAV = [
  { to: '/', label: 'Overview', icon: LayoutDashboard, end: true },
  { to: '/agents', label: 'Sandbox Agents', icon: Bot },
  { to: '/pool', label: 'Lending Pool', icon: Wallet },
  { to: '/transactions', label: 'Transactions', icon: ArrowLeftRight },
  { to: '/integration', label: 'Integration', icon: Code2 },
]

function NavItem({ to, label, icon: Icon, end }: { to: string; label: string; icon: React.ComponentType<{ className?: string }>; end?: boolean }) {
  return (
    <NavLink
      to={to}
      end={end}
      className={({ isActive }) =>
        cn(
          'flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium transition-colors',
          isActive
            ? 'bg-[var(--accent-dim)] text-[var(--accent)]'
            : 'text-[var(--muted)] hover:text-[var(--ink-2)] hover:bg-[var(--surface-strong)]',
        )
      }
    >
      <Icon className="w-[18px] h-[18px] shrink-0" />
      {label}
    </NavLink>
  )
}

export function Sidebar() {
  return (
    <aside className="hidden lg:flex flex-col w-56 shrink-0 h-screen sticky top-0 px-3 pt-6 pb-4 border-r border-[var(--border)]">
      {/* Logo */}
      <div className="flex items-center gap-2 px-3 mb-8">
        <div className="w-7 h-7 rounded-lg bg-[var(--accent)] flex items-center justify-center">
          <Zap className="w-4 h-4 text-white" />
        </div>
        <span className="display font-semibold text-[var(--ink)] tracking-tight">Valen</span>
        <span className="ml-auto text-[10px] font-semibold bg-[var(--accent-dim)] text-[var(--accent)] px-1.5 py-0.5 rounded-full">
          Testnet
        </span>
      </div>

      {/* Nav */}
      <nav className="flex flex-col gap-0.5 flex-1">
        {NAV.map((item) => (
          <NavItem key={item.to} {...item} />
        ))}
      </nav>

      {/* Wallet */}
      <div className="mt-4">
        <ConnectKitButton.Custom>
          {({ isConnected, show, address, truncatedAddress }) => (
            <button
              onClick={show}
              className={cn(
                'w-full flex items-center gap-2.5 px-3 py-2.5 rounded-xl text-sm font-medium transition-colors border',
                isConnected
                  ? 'bg-[var(--surface-strong)] border-[var(--border)] text-[var(--ink-2)]'
                  : 'bg-[var(--accent)] border-transparent text-white hover:bg-[var(--accent-hover)]',
              )}
            >
              <Wallet className="w-4 h-4 shrink-0" />
              <span className="truncate mono text-xs">
                {isConnected ? truncatedAddress : 'Connect Wallet'}
              </span>
            </button>
          )}
        </ConnectKitButton.Custom>
      </div>

      <p className="mt-3 px-3 text-[10px] text-[var(--subtle)]">
        Human lenders only. Agents connect programmatically.
      </p>
    </aside>
  )
}
