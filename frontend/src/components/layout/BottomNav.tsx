import { NavLink } from 'react-router-dom'
import { LayoutDashboard, Bot, Wallet, ArrowLeftRight, Code2 } from 'lucide-react'
import { cn } from '@/lib/format'

const NAV = [
  { to: '/', label: 'Overview', icon: LayoutDashboard, end: true },
  { to: '/agents', label: 'Agents', icon: Bot },
  { to: '/pool', label: 'Pool', icon: Wallet },
  { to: '/transactions', label: 'Txns', icon: ArrowLeftRight },
  { to: '/integration', label: 'Dev', icon: Code2 },
]

export function BottomNav() {
  return (
    <nav className="lg:hidden fixed bottom-0 inset-x-0 z-50 bg-[#0c1626]/95 backdrop-blur-md border-t border-[var(--border)] flex">
      {NAV.map(({ to, label, icon: Icon, end }) => (
        <NavLink
          key={to}
          to={to}
          end={end}
          className={({ isActive }) =>
            cn(
              'flex-1 flex flex-col items-center justify-center gap-1 py-3 text-[10px] font-medium transition-colors',
              isActive ? 'text-[var(--accent)]' : 'text-[var(--subtle)] hover:text-[var(--muted)]',
            )
          }
        >
          <Icon className="w-5 h-5" />
          {label}
        </NavLink>
      ))}
    </nav>
  )
}
