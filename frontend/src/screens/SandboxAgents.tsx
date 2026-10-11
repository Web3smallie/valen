import { useState } from 'react'
import { Bot, ShoppingCart, FlaskConical, Package, Plane, Globe, ChevronRight, AlertTriangle, ExternalLink, CheckCircle, Clock } from 'lucide-react'
import { Card } from '@/components/ui/Card'
import { Badge } from '@/components/ui/Badge'
import { StatRow } from '@/components/ui/StatRow'
import { useApi } from '@/hooks/useApi'
import { api } from '@/lib/api'
import { shortAddr } from '@/lib/format'
import { useNavigate } from 'react-router-dom'

const DEPLOYED_AGENT_WALLET = '0x786d491Fb520F3D9D9c7e62156C879fe52d6921E'

interface SandboxAgent {
  id: string
  name: string
  category: string
  icon: React.ComponentType<{ className?: string }>
  wallet: string | null
  deployed: boolean
  description: string
  exampleTask: string
  taskSteps: string[]
}

const AGENTS: SandboxAgent[] = [
  {
    id: 'commerce',
    name: 'Commerce Agent',
    category: 'Commerce',
    icon: ShoppingCart,
    wallet: DEPLOYED_AGENT_WALLET,
    deployed: true,
    description: 'Manages autonomous purchasing flows — sources inventory, negotiates supplier contracts, and settles invoices programmatically.',
    exampleTask: 'Source and purchase 500 units of component XR-7',
    taskSteps: [
      'Identify approved suppliers via procurement oracle',
      'Request quote from 3 suppliers',
      'Select optimal bid by price + delivery time',
      'Request 10 USDC working-capital loan against EURC collateral',
      'Submit purchase order and escrow payment',
      'Confirm delivery and release final payment',
    ],
  },
  {
    id: 'research',
    name: 'Research Agent',
    category: 'Research / Data',
    icon: FlaskConical,
    wallet: null,
    deployed: false,
    description: 'Aggregates and validates external data sets, purchases API credits, and publishes verified research outputs on-chain.',
    exampleTask: 'Purchase and validate market data feed for Q4 2026',
    taskSteps: [
      'Query available data providers',
      'Request access credentials from chosen provider',
      'Credit-check against existing Valen history',
      'Pay data subscription fee via micro-loan',
      'Validate and attest data hash on-chain',
      'Publish attestation to ActivityAttester',
    ],
  },
  {
    id: 'procurement',
    name: 'Procurement Agent',
    category: 'Procurement',
    icon: Package,
    wallet: null,
    deployed: false,
    description: 'Runs recurring vendor management workflows — manages approved vendor lists, POs, and reconciliation.',
    exampleTask: 'Reconcile outstanding invoices with 4 vendors',
    taskSteps: [
      'Pull outstanding PO list from registry',
      'Verify delivery confirmations',
      'Calculate net settlement amount',
      'Batch-pay via single USDC transaction',
      'Update vendor credit scores on-chain',
    ],
  },
  {
    id: 'travel',
    name: 'Travel Agent',
    category: 'Travel & Logistics',
    icon: Plane,
    wallet: null,
    deployed: false,
    description: 'Coordinates transportation and accommodation bookings on behalf of principals, settling in USDC.',
    exampleTask: 'Book roundtrip transport and 3-night accommodation',
    taskSteps: [
      'Receive itinerary request from principal',
      'Query available transport options',
      'Select and reserve transport leg 1',
      'Reserve accommodation via booking oracle',
      'Settle total cost with approved USDC credit line',
    ],
  },
  {
    id: 'digital',
    name: 'Digital Services Agent',
    category: 'Digital Services',
    icon: Globe,
    wallet: null,
    deployed: false,
    description: 'Procures cloud compute, API subscriptions, and software licenses; manages renewal and spend tracking.',
    exampleTask: 'Renew compute quota and upgrade API tier',
    taskSteps: [
      'Audit current subscription usage',
      'Identify expiring or insufficient services',
      'Request upgrade quotes from providers',
      'Pay renewals via Valen credit line',
      'Log spend event to ActivityAttester',
    ],
  },
]

function TaskSimulation({ agent }: { agent: SandboxAgent }) {
  const [running, setRunning] = useState(false)
  const [step, setStep] = useState(-1)
  const [done, setDone] = useState(false)

  async function runTask() {
    if (!agent.deployed) return
    setRunning(true)
    setDone(false)
    setStep(-1)
    for (let i = 0; i < agent.taskSteps.length; i++) {
      setStep(i)
      await new Promise((r) => setTimeout(r, 900))
    }
    setRunning(false)
    setDone(true)
  }

  return (
    <div className="mt-4">
      <div className="flex items-start gap-2 rounded-xl bg-[rgba(245,166,35,0.08)] border border-[rgba(245,166,35,0.2)] p-3 mb-3">
        <AlertTriangle className="w-4 h-4 text-[var(--warning)] shrink-0 mt-0.5" />
        <p className="text-[11px] text-[var(--warning)] leading-relaxed">
          Task simulation is <strong>illustrative only</strong>. Steps shown here do not submit transactions or change on-chain state.
        </p>
      </div>

      {!running && !done && (
        <button
          onClick={runTask}
          disabled={!agent.deployed}
          className="w-full py-2.5 rounded-xl text-sm font-medium bg-[var(--accent)] text-white hover:bg-[var(--accent-hover)] transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
        >
          {agent.deployed ? `Simulate: ${agent.exampleTask}` : 'Simulation not available (agent not deployed)'}
        </button>
      )}

      {(running || done) && (
        <div className="space-y-1.5 mt-3">
          {agent.taskSteps.map((s, i) => {
            const isDone = done || i < step
            const isCurrent = running && i === step
            return (
              <div key={i} className="flex items-center gap-2.5 text-xs">
                {isDone ? (
                  <CheckCircle className="w-3.5 h-3.5 text-[var(--success)] shrink-0" />
                ) : isCurrent ? (
                  <Clock className="w-3.5 h-3.5 text-[var(--warning)] shrink-0 animate-pulse" />
                ) : (
                  <div className="w-3.5 h-3.5 rounded-full border border-[var(--border)] shrink-0" />
                )}
                <span className={isDone ? 'text-[var(--ink-2)]' : isCurrent ? 'text-[var(--warning)]' : 'text-[var(--subtle)]'}>
                  {s}
                </span>
              </div>
            )
          })}
          {done && (
            <div className="flex items-center justify-between mt-2">
              <p className="text-xs text-[var(--success)] flex items-center gap-1.5">
                <CheckCircle className="w-3.5 h-3.5" /> Simulation complete — no on-chain state was modified.
              </p>
              <button onClick={() => { setDone(false); setStep(-1) }}
                className="text-[10px] text-[var(--muted)] hover:text-[var(--ink-2)]">
                Reset
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function AgentCard({ agent, onSelect, selected }: {
  agent: SandboxAgent
  onSelect: (a: SandboxAgent) => void
  selected: boolean
}) {
  const Icon = agent.icon
  return (
    <button
      onClick={() => onSelect(agent)}
      className={`w-full text-left rounded-2xl border p-4 transition-all ${
        selected
          ? 'bg-[var(--accent-dim)] border-[var(--accent)]'
          : 'bg-[var(--surface)] border-[var(--border)] hover:border-[var(--border-strong)]'
      }`}
    >
      <div className="flex items-start gap-3">
        <div className={`w-9 h-9 rounded-xl flex items-center justify-center shrink-0 ${
          agent.deployed ? 'bg-[var(--accent)]' : 'bg-[var(--surface-strong)]'
        }`}>
          <Icon className={`w-5 h-5 ${agent.deployed ? 'text-white' : 'text-[var(--muted)]'}`} />
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-0.5">
            <p className="text-sm font-semibold text-[var(--ink)] truncate">{agent.name}</p>
            {agent.deployed && <Badge variant="success">Live</Badge>}
          </div>
          <p className="text-[11px] text-[var(--muted)]">{agent.category}</p>
        </div>
        <ChevronRight className={`w-4 h-4 shrink-0 transition-transform ${selected ? 'rotate-90 text-[var(--accent)]' : 'text-[var(--subtle)]'}`} />
      </div>
      {selected && (
        <p className="text-xs text-[var(--muted)] mt-3 leading-relaxed">{agent.description}</p>
      )}
    </button>
  )
}

function AgentDetail({ agent }: { agent: SandboxAgent }) {
  const navigate = useNavigate()
  const credit = useApi(
    () => agent.deployed && agent.wallet
      ? api.credit('1')
      : Promise.reject(new Error('not deployed')),
    [agent.id],
  )

  return (
    <Card className="h-full">
      <div className="flex items-center justify-between mb-5">
        <div>
          <h2 className="text-base font-semibold text-[var(--ink)]">{agent.name}</h2>
          <p className="text-xs text-[var(--muted)]">{agent.category}</p>
        </div>
        {agent.deployed && (
          <button
            onClick={() => navigate('/agents/1')}
            className="flex items-center gap-1 text-xs text-[var(--accent)] hover:underline"
          >
            Full details <ExternalLink className="w-3 h-3" />
          </button>
        )}
      </div>

      <div className="space-y-0 mb-4">
        <StatRow label="Wallet" value={
          agent.wallet
            ? <span className="mono text-[10px]">{shortAddr(agent.wallet)}</span>
            : <Badge variant="neutral">not deployed</Badge>
        } />
        <StatRow label="Identity" value={
          agent.deployed
            ? <Badge variant="success">Registered Agent #1</Badge>
            : <Badge variant="neutral">illustrative</Badge>
        } />
        <StatRow label="Credit limit" value={
          !agent.deployed ? '—' :
          credit.isLoading ? '…' :
          credit.data ? credit.data.limitFormatted :
          <span className="text-[var(--muted)] text-[11px]">{credit.error ?? 'unavailable'}</span>
        } />
      </div>

      <TaskSimulation agent={agent} />
    </Card>
  )
}

export function SandboxAgents() {
  const [selected, setSelected] = useState<SandboxAgent>(AGENTS[0])

  return (
    <div className="space-y-5">
      <div>
        <h1 className="display text-2xl font-semibold text-[var(--ink)]">Sandbox Agents</h1>
        <p className="text-sm text-[var(--muted)] mt-0.5">
          Five representative agent archetypes. The Commerce Agent is deployed on Arc Testnet; others are illustrative.
        </p>
      </div>

      {/* Programmatic note */}
      <div className="flex items-start gap-2 rounded-xl bg-[var(--surface-muted)] border border-[var(--border)] p-3">
        <Bot className="w-4 h-4 text-[var(--accent)] shrink-0 mt-0.5" />
        <p className="text-[11px] text-[var(--muted)] leading-relaxed">
          Autonomous agents interact with Valen through their own runtimes and signing wallets — not through a browser. Human wallet connection here is for lenders only. Agent identity and credit are established programmatically.
        </p>
      </div>

      <div className="grid lg:grid-cols-[280px_1fr] gap-4">
        <div className="space-y-2">
          {AGENTS.map((a) => (
            <AgentCard key={a.id} agent={a} onSelect={setSelected} selected={selected.id === a.id} />
          ))}
        </div>
        <AgentDetail agent={selected} />
      </div>
    </div>
  )
}
