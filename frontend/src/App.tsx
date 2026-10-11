import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { Sidebar } from '@/components/layout/Sidebar'
import { BottomNav } from '@/components/layout/BottomNav'
import { TopBar } from '@/components/layout/TopBar'
import { Overview } from '@/screens/Overview'
import { SandboxAgents } from '@/screens/SandboxAgents'
import { AgentDetails } from '@/screens/AgentDetails'
import { LendingPool } from '@/screens/LendingPool'
import { Transactions } from '@/screens/Transactions'
import { Integration } from '@/screens/Integration'

export default function App() {
  return (
    <BrowserRouter>
      <div className="flex min-h-screen bg-[var(--bg)]">
        <Sidebar />

        <div className="flex-1 flex flex-col min-w-0">
          <TopBar />

          <main className="flex-1 px-4 lg:px-8 py-6 pb-24 lg:pb-8 max-w-5xl w-full mx-auto">
            <Routes>
              <Route path="/" element={<Overview />} />
              <Route path="/agents" element={<SandboxAgents />} />
              <Route path="/agents/:agentId" element={<AgentDetails />} />
              <Route path="/pool" element={<LendingPool />} />
              <Route path="/transactions" element={<Transactions />} />
              <Route path="/loans/:loanId" element={<Transactions />} />
              <Route path="/integration" element={<Integration />} />
            </Routes>
          </main>
        </div>

        <BottomNav />
      </div>
    </BrowserRouter>
  )
}
