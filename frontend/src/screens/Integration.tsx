import { Code2, Terminal, CheckCircle, ExternalLink } from 'lucide-react'
import { Card } from '@/components/ui/Card'

function CodeBlock({ code, lang = 'bash' }: { code: string; lang?: string }) {
  return (
    <div className="rounded-xl bg-[#0a1220] border border-[var(--border)] overflow-hidden mt-2">
      <div className="flex items-center gap-2 px-3 py-2 border-b border-[var(--border)]">
        <Terminal className="w-3.5 h-3.5 text-[var(--muted)]" />
        <span className="text-[10px] text-[var(--subtle)] font-mono">{lang}</span>
      </div>
      <pre className="text-[11px] text-[var(--ink-2)] font-mono leading-relaxed p-4 overflow-x-auto whitespace-pre">
        {code}
      </pre>
    </div>
  )
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <Card>
      <h3 className="text-sm font-semibold text-[var(--ink)] mb-3">{title}</h3>
      {children}
    </Card>
  )
}

const CONTRACTS = [
  { name: 'AgentRegistry', address: '0xeC74944752Fff0f53Af5b727F288f59435C0144e' },
  { name: 'CreditRegistry', address: '0x258B0678b30E2d32034389cfeCa7f58fE1CeB897' },
  { name: 'LoanRegistry (V3)', address: '0x253B68c7a2D646561387Dc0958A6C176a30a6f8d' },
  { name: 'LoanVault', address: '0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19' },
  { name: 'CollateralVault', address: '0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f' },
  { name: 'LiquidityPool', address: '0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061' },
  { name: 'RevenueRouter', address: '0xE0B9b39E72f73f2d85D77a1e24a2f319246de822' },
  { name: 'RecipientRegistry', address: '0xf8E069B659CEAf9c68318041D727b5c482Ac6374' },
  { name: 'ActivityAttester', address: '0x2660044E4A7316B65263ea1B23b80aAf09841196' },
  { name: 'USDC (Arc native)', address: '0x3600000000000000000000000000000000000000' },
  { name: 'EURC (testnet)', address: '0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a' },
]

export function Integration() {
  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <div className="w-8 h-8 rounded-xl bg-[var(--accent)] flex items-center justify-center">
          <Code2 className="w-4 h-4 text-white" />
        </div>
        <div>
          <h1 className="display text-2xl font-semibold text-[var(--ink)]">Agent Integration</h1>
          <p className="text-sm text-[var(--muted)] mt-0.5">Connect your autonomous agent to Valen programmatically</p>
        </div>
      </div>

      {/* Key principle */}
      <Card accent>
        <div className="flex items-start gap-3">
          <CheckCircle className="w-5 h-5 text-[var(--accent)] shrink-0 mt-0.5" />
          <div>
            <p className="text-sm font-semibold text-[var(--ink)] mb-1">Agents connect through their own runtimes</p>
            <p className="text-xs text-[var(--muted)] leading-relaxed">
              Valen is credit infrastructure for autonomous AI agents. Agents never open a browser, click "Connect Wallet", or delegate their signing keys to this frontend. Your agent holds its own private key, calls contracts directly via viem or cast, and uses the backend API for read-only state. Human lenders use the frontend; agents use the protocol directly.
            </p>
          </div>
        </div>
      </Card>

      <Section title="Step 1 — Install dependencies">
        <p className="text-xs text-[var(--muted)] mb-2">Your agent needs viem and the Valen ABIs.</p>
        <CodeBlock lang="bash" code={`npm install viem
# Copy ABIs from backend/src/abis/ into your agent project`} />
      </Section>

      <Section title="Step 2 — Configure the chain and signer">
        <CodeBlock lang="typescript" code={`import { createWalletClient, createPublicClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

const arcTestnet = {
  id: 5003012,
  name: 'Arc Testnet',
  rpcUrls: { default: { http: ['https://rpc.testnet.arc.io'] } },
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
}

const account = privateKeyToAccount(process.env.AGENT_PRIVATE_KEY)

const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http() })
const publicClient = createPublicClient({ chain: arcTestnet, transport: http() })`} />
      </Section>

      <Section title="Step 3 — Register as an agent (one-time)">
        <p className="text-xs text-[var(--muted)] mb-1">Call <code className="mono text-[10px] bg-[var(--surface-strong)] px-1 rounded">registerAgent(0)</code> on AgentRegistry. Pass 0 for the ERC-8004 token ID unless you have a registered identity NFT.</p>
        <CodeBlock lang="typescript" code={`const AGENT_REGISTRY = '0xeC74944752Fff0f53Af5b727F288f59435C0144e'

const txHash = await walletClient.writeContract({
  address: AGENT_REGISTRY,
  abi: AgentRegistryAbi,
  functionName: 'registerAgent',
  args: [0n], // ERC-8004 token ID — pass 0 if none
})

// Wait for confirmation
await publicClient.waitForTransactionReceipt({ hash: txHash })`} />
      </Section>

      <Section title="Step 4 — Deposit collateral">
        <p className="text-xs text-[var(--muted)] mb-1">Approve and deposit EURC (or USDC) into the CollateralVault.</p>
        <CodeBlock lang="typescript" code={`const COLLATERAL_VAULT = '0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f'
const EURC = '0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a'
const AMOUNT = 14_029_180n  // 14.02918 EURC (6 decimals)

// 1. Approve CollateralVault to spend EURC
await walletClient.writeContract({
  address: EURC,
  abi: ERC20Abi,
  functionName: 'approve',
  args: [COLLATERAL_VAULT, AMOUNT],
})

// 2. Deposit
await walletClient.writeContract({
  address: COLLATERAL_VAULT,
  abi: CollateralVaultAbi,
  functionName: 'depositCollateral',
  args: [EURC, AMOUNT],
})`} />
      </Section>

      <Section title="Step 5 — Request a loan (V3 ABI — currently deployed)">
        <p className="text-xs text-[var(--muted)] mb-1">
          The currently deployed LoanRegistry is <strong>V3</strong> (15-field LoanProposal). Do not include <code className="mono text-[10px] bg-[var(--surface-strong)] px-1 rounded">directDisbursement</code> — that field requires the not-yet-deployed V4 upgrade.
        </p>
        <CodeBlock lang="typescript" code={`const LOAN_REGISTRY = '0x253B68c7a2D646561387Dc0958A6C176a30a6f8d'

await walletClient.writeContract({
  address: LOAN_REGISTRY,
  abi: LoanRegistryAbi, // V3 — 15 fields
  functionName: 'requestLoan',
  args: [{
    agentId: 1n,
    creditWallet: account.address,
    principal: 10_000_000n,            // 10 USDC
    repaymentRateBps: 1000,            // 10%
    totalRepaymentDue: 11_000_000n,    // 11 USDC
    duration: 86400n,                  // 1 day
    purpose: 'working capital',
    budget: [{ categoryId: '0x0000…', amount: 10_000_000n }],
    permittedRecipients: [account.address],
    milestoneAmounts: [10_000_000n],
    milestoneDescriptions: ['full disbursement'],
    collateralAmount: 14_029_180n,     // requiredCollateral(10e6, EURC)
    collateralAsset: EURC,
    underwriter: '0x0000…0000',
    underwriterAmount: 0n,
  }],
})`} />
      </Section>

      <Section title="Step 6 — Repay the loan">
        <CodeBlock lang="typescript" code={`const REVENUE_ROUTER = '0xE0B9b39E72f73f2d85D77a1e24a2f319246de822'
const USDC = '0x3600000000000000000000000000000000000000'
const REPAYMENT = 11_000_000n  // full repayment

// 1. Approve RevenueRouter to spend USDC
await walletClient.writeContract({
  address: USDC, abi: ERC20Abi,
  functionName: 'approve',
  args: [REVENUE_ROUTER, REPAYMENT],
})

// 2. Repay
await walletClient.writeContract({
  address: REVENUE_ROUTER, abi: RevenueRouterAbi,
  functionName: 'repayLoan',
  args: [0n, REPAYMENT],  // loanId=0, amount=11 USDC
})`} />
      </Section>

      <Section title="Backend API — read-only state">
        <p className="text-xs text-[var(--muted)] mb-2">
          Use the Valen backend to read contract state without a direct RPC connection. Default port 3000.
        </p>
        <CodeBlock lang="bash" code={`# Pool liquidity
curl http://localhost:3000/pool

# Agent state
curl http://localhost:3000/agents/0x786d...921E

# Credit limit for agent #1
curl http://localhost:3000/agents/1/credit

# Loan details
curl http://localhost:3000/loans/0

# Required collateral for 10 USDC in EURC
curl 'http://localhost:3000/collateral/required?principal=10000000&asset=0x89B5…'`} />
      </Section>

      {/* Contract table */}
      <Card>
        <h3 className="text-sm font-semibold text-[var(--ink)] mb-4">Deployed Contract Addresses — Arc Testnet</h3>
        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-[var(--border)]">
                <th className="text-left text-[var(--muted)] font-medium pb-2 pr-4">Contract</th>
                <th className="text-left text-[var(--muted)] font-medium pb-2">Address</th>
              </tr>
            </thead>
            <tbody>
              {CONTRACTS.map(({ name, address }) => (
                <tr key={address} className="border-b border-[var(--border)] last:border-0">
                  <td className="py-2 pr-4 text-[var(--ink-2)] font-medium">{name}</td>
                  <td className="py-2">
                    <a
                      href={`https://explorer.testnet.arc.io/address/${address}`}
                      target="_blank"
                      rel="noreferrer"
                      className="mono text-[var(--accent)] hover:underline flex items-center gap-1"
                    >
                      {address}
                      <ExternalLink className="w-3 h-3 shrink-0" />
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  )
}
