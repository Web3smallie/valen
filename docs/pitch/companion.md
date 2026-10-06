# Valen: Pitch Companion Document

**Deck file:** `docs/pitch/deck.html` (open in any browser; arrow keys or buttons to navigate)
**Prepared:** September 21, 2026
**Status:** Prototype / testnet stage

---

## 1. Slide-by-Slide Narrative

### Slide 1: Cover
Opens with the product name and the single defining thesis: programmable credit for autonomous AI agents. The five status tags at the bottom establish honesty upfront: Arc Testnet, USDC Native, EVM/Solidity 0.8.24, Prototype Stage, 9 Contracts · 132 Tests Passing. No implied production traction. The claim counts are verifiable directly from the repository.

### Slide 2: The Problem
Establishes two parallel realities: agents are increasingly economic actors (they execute tasks, transact, generate traceable on-chain revenue) while financial infrastructure was designed entirely around human borrowers. The contrast is factual and does not require specific agent-adoption metrics. The right column shows precisely what agents need that traditional lending cannot provide: programmable on-chain rules, financial identity tied to an agent address, revenue-linked repayment primitives, and a credit history that evolves with track record.

### Slide 3: The Solution
Introduces the Valen lifecycle: agent → credit request → underwriting → funding → economic task → revenue generated → revenue routed / debt serviced → on-chain credit history builds. The flow diagram step "Revenue routed → debt serviced" is intentionally precise: the RevenueRouter splits incoming USDC automatically once it is submitted, but submission is an action by the agent or its operator, not a background scheduler. The final step "On-chain credit history builds" makes explicit that each successful repayment contributes to the agent's verifiable on-chain record. Three bottom cards cover the three implemented funding paths: direct lending, pooled liquidity, and collateral/underwriting.

### Slide 4: Architecture
Shows all nine implemented contracts with one-sentence descriptions grounded in actual contract behavior. This is the technical-depth slide for reviewers who want to understand how the system works. Every contract listed exists in `src/`. CreditRegistry is described accurately: it tracks repayment history, defaults, and calculates evolving credit limits per agent address. Nothing is invented.

### Slide 5: Programmable Credit
Eight specific credit mechanisms, all grounded in the actual contract code:
- **Evolving credit limits:** CreditRegistry tracks each agent's repayment history, including successful and early repayments and defaults. Demonstrated repayment behavior can strengthen an agent's credit profile and increase its future credit limit.
- **Milestone-gated disbursement:** LoanVault locks proceeds and releases in defined stages.
- **Budget categories and recipient controls:** RecipientRegistry + RISK-15 fix (resolved).
- **Outstanding principal tracking:** LoanRegistry tracks concurrent debt across loans (RISK-08 fix).
- **Layered recovery on default:** defined on-chain sequence: vault recovery, collateral seizure, underwriter stake seizure, reserve pool payout.
- **Revenue-linked repayment:** RevenueRouter splits incoming USDC between debt service and agent operational share per loan terms.
- **Keeper-authorized defaults:** RISK-04 fix; markDefault requires an authorized keeper.
- **Lifecycle-gated configuration:** RISK-12/13 fixes; protocol contract addresses can only be reconfigured before any loans exist.

### Slide 6: Use Cases
Five illustrative agent personas showing how the protocol's mechanics map to real economic workflows. Prominently labeled as illustrative; no production agent traction is claimed. The integration model box correctly positions Valen as infrastructure, not an agent runtime: "Developer → their agent → Valen API/SDK → credit infrastructure."

### Slide 7: Why Valen
Six architectural differentiators, all grounded in implemented behavior. No superlatives. Key differentiator to emphasize: CreditRegistry builds a loan history per agent address. Credit limits grow with demonstrated repayment. The agent earns its own financial track record independent of its developer's identity. This is the core credit-flywheel narrative: borrow → repay → on-chain credit history builds → credit limit increases/evolves → borrow again.

### Slide 8: Product Today
The most important honesty slide. Five steps demonstrable on testnet today, side by side with a green "BUILT" card and an amber "ROADMAP" card. The BUILT card accurately describes the TypeScript/Viem backend as an event observer and integration scripts foundation, not a finished API or SDK. No blending of current and future.

### Slide 9: Technical Foundation
Stack breakdown across chain/settlement, smart contracts, and backend/integration. All technologies listed are present in the codebase. The backend event-observer card is accurate: "Backend observes all 10 loan lifecycle events from LoanRegistry and RevenueRouter. Provides the foundation for the agent-facing webhook and SDK notification layer — currently in development." The ABI card is accurate: "All 9 contract ABIs are present in the backend package alongside working recipient approval and loan submission scripts. The public developer SDK is roadmap."

### Slide 10: Security
The most credibility-sensitive slide. Shows all 19 audit findings by category with accurate counts: 14 resolved or accepted (RISK-01 through RISK-15, with RISK-06 and RISK-14 accepted), 4 low/informational open (RISK-16–19). RISK-15 is correctly shown in the green resolved row with its specific fix described. Explicitly states this is an internal review, not a third-party audit, and that independent audit is a prerequisite for mainnet.

### Slide 11: Roadmap
Three clean columns: Now (prototype), Next (developer platform), Future (agent credit markets). Every "Now" item is verified in the codebase. Every "Next" and "Future" item is not yet built. Security count in the Now column reads "14 resolved or accepted." No blending.

### Slide 12: Vision / Close
Closes with the big thesis: agents as independent economic entities with their own financial identity, on-chain credit history, and access to capital. The long-term vision is an open credit layer. No market-size claims. Five closing tags match the real project state.

---

## 2. Claims Grounded in Current Implementation

Every claim below is verifiable from the repository at the current commit.

| Claim | Source |
|---|---|
| 9 smart contracts implemented | `src/` directory: 9 .sol files |
| All contracts UUPS upgradeable | OwnableUpgradeable + UUPSUpgradeable in every contract |
| 132 tests passing | `forge test` result |
| Full loan lifecycle on-chain | LoanRegistry, LoanVault, RevenueRouter |
| Direct lending path | `LoanVault.fundLoan` |
| Pooled liquidity path | `LiquidityPool.fundLoan` + `LoanVault.fundFromPool` |
| Collateral-backed loans | `CollateralVault` + `collateralAmount` in LoanProposal |
| Underwriter-backed loans | `UnderwriterPool` + `underwriter` in LoanProposal |
| On-chain credit history per agent | `CreditRegistry.recordRepayment` / `recordDefault`: every repayment and default is recorded per agent address |
| Evolving credit limits | `CreditRegistry.getLimit`: computes from on-chain repayment history, early-repayment bonuses, default penalties |
| Outstanding principal tracking across concurrent loans | `LoanRegistry.outstandingPrincipal` mapping (RISK-08 fix) |
| Milestone-gated disbursement | `LoanVault.releaseMilestone` |
| Keeper-authorized defaults | `LoanRegistry.keepers` mapping + guard (RISK-04 fix) |
| Layered default recovery sequence | `markDefault` → vault recovery → collateral seizure → underwriter stake → reserve pool payout |
| Reserve pool shortfall coverage | `ReservePool.payout` called from `markDefault` |
| Revenue-linked repayment (split on submission) | `RevenueRouter.payRevenue` + `repayLoan`: splits incoming USDC automatically once submitted |
| Recipient allowlisting | `RecipientRegistry.isApproved` checked in `_validateProposal` |
| creditWallet registry and list check | `_validateProposal` RISK-15 fix in `LoanRegistry.sol`: resolved |
| Lifecycle-gated configuration | RISK-12 guards in LoanRegistry, LoanVault, RevenueRouter |
| TypeScript/Viem backend | `backend/src/`: Viem-based, Arc Testnet wired |
| Event listener (read-only observer) | `backend/src/listeners/loanEvents.ts`: observes 10 events, logs them; not a production webhook pipeline |
| Recipient approval script | `backend/src/approveTestRecipient.ts` |
| Loan submission script | `backend/src/testRequestLoan.ts` |
| 9 contract ABIs present in backend package | `backend/src/abis/`: all 9 contracts present; no public SDK yet |
| Foundry deploy script | `script/Deploy.s.sol`: deploys all contracts and wires them |
| USDC as native gas on Arc | Arc Testnet architecture; USDC address at system precompile |
| Internal security review 19 findings | `docs/security-audit.md` |
| 14 findings resolved or accepted | RISK-01–15 addressed: RISK-01–05, 07–13, 15 resolved in code; RISK-06 and RISK-14 accepted as documented |

---

## 3. Statements That Must Be Labeled Roadmap

The following are NOT implemented today and must be presented as roadmap:

| Statement | Status |
|---|---|
| Developer API / SDK | Not implemented. ABIs and transaction scripts exist. No public API surface or packaged SDK. |
| Frontend / dashboard | Not implemented. No frontend code exists in the repository. |
| Sandbox demonstration agents | Not implemented. No agent runtime code exists. |
| Independent third-party audit | Not done. Internal review only. |
| Mainnet deployment | Not done. Testnet only. |
| Agent-to-agent lending as LP | Not implemented. Conceptual future roadmap. |
| Cross-chain credit via CCTP | Not implemented. Conceptual future roadmap. |
| Secondary market for loan positions | Not implemented. Conceptual future roadmap. |
| Webhook / notification pipeline | Not implemented. Event observer foundation exists; delivery layer is roadmap. |

---

## 4. The Valen Credit-History Narrative

The core flywheel that distinguishes Valen from a simple lending protocol:

**Borrow → Execute economic task → Route revenue → Debt serviced → Repayment recorded on-chain → On-chain credit history builds → Credit limit increases/evolves → Borrow again**

Each successful loan repayment is recorded in `CreditRegistry` against the agent's address. `CreditRegistry.getLimit` computes the agent's current credit limit from this accumulated on-chain history, factoring in repayment track record, early-repayment bonuses, and default penalties. An agent that consistently repays on time builds a verifiable on-chain credit history that can support an increasing future credit limit. An agent that defaults sees its limit reduced.

**Important precision:** the contract computes an evolving credit limit from the agent's on-chain repayment record. It does not guarantee a fixed increase per repayment or a specific multiplier. The word "can" is correct: "Successful repayment strengthens the agent's on-chain credit history and can increase its future credit capacity."

---

## 5. The 30-Second Valen Pitch

> "AI agents are increasingly doing real economic work: they execute tasks, purchase services, and generate revenue. But financial infrastructure was built for human borrowers.
>
> Valen is programmable credit infrastructure for autonomous agents. An agent requests a loan governed by explicit on-chain rules, executes an economic task, routes its revenue through the protocol to service the debt, and builds an on-chain credit history with each successful repayment, a history that can support increasing credit capacity over time.
>
> We've built the core protocol: nine smart contracts, full loan lifecycle, direct lending, pooled liquidity, underwriter-backed loans, layered recovery mechanisms, and a TypeScript/Viem backend integration foundation, all on Arc Testnet. We're now building the developer SDK and the platform for agents to connect."

---

## 6. The 1-Minute Valen Pitch

> "The agent economy is forming. Autonomous AI agents are executing tasks, transacting on-chain, and generating real economic output. But they have no access to credit. Traditional lending assumes human identity, manual approval, and fixed repayment schedules. None of those apply to a machine borrower.
>
> Valen is programmable credit infrastructure for autonomous agents. Developers connect their agents to Valen's credit layer. The agent submits a loan proposal with a stated budget, permitted recipients, and milestone structure. If approved, funds are locked on-chain and released in stages as the agent completes work. Revenue from the agent's economic activity is routed through our RevenueRouter, which splits incoming USDC between debt service and the agent's operational share according to the loan terms. Each successful repayment is recorded on-chain against the agent's address, building a credit history that can support increasing future credit capacity.
>
> We support direct lending (a specific lender funds a specific agent), pooled liquidity, where LPs deposit USDC into a shared pool that funds multiple agents, and underwriter-backed loans, where third parties stake USDC to back specific agents. All three paths share the same loan lifecycle, credit history infrastructure, and layered default recovery: vault recovery, collateral seizure, underwriter stake seizure, and reserve pool payout.
>
> Today we have nine smart contracts fully implemented on Arc Testnet, 132 passing Foundry tests, a TypeScript/Viem event-observer backend, and an internal security review with 14 of 19 findings resolved or accepted. The protocol works end-to-end.
>
> What we're building next is the developer API and SDK, so any developer can connect their agent to Valen credit in hours, not weeks. The long-term vision is an open financial layer where autonomous agents are first-class economic participants with their own on-chain credit histories and access to capital."

---

## 7. Accelerator Application Description

**Company / project name:** Valen

**One-line description:**
Programmable credit infrastructure for autonomous AI agents: on-chain loans governed by explicit machine-readable rules, with revenue-linked repayment and an evolving on-chain credit history per agent.

**What is the product?**
Valen is nine smart contracts and a TypeScript/Viem developer backend that together provide a complete programmable credit layer for autonomous AI agents. Developers connect their agents to Valen via API/SDK (roadmap). An agent requests a loan with a defined budget and milestone structure. If approved, USDC is locked on-chain in LoanVault and released in milestone stages. Revenue from the agent's economic activity is routed through RevenueRouter, which automatically splits incoming USDC between debt service and the agent's operational share. Each successful repayment is recorded in CreditRegistry against the agent's address, building an on-chain credit history that can support increasing future credit limits. An agent that consistently repays builds financial capacity over time.

The protocol supports three lending paths: direct peer-to-agent lending (a specific lender funds a specific agent), pooled liquidity (LPs deposit into a shared pool that funds multiple agent loans), and underwriter-backed loans (third parties stake USDC to back specific agents). All three paths share the same loan lifecycle, on-chain credit tracking, and layered default recovery infrastructure.

**What stage are you at?**
Prototype / testnet. The full protocol is implemented and tested on Arc Testnet (Circle's EVM network where USDC is the native gas token). 132 Foundry tests pass. A TypeScript/Viem backend observes all 10 loan lifecycle events and includes working recipient approval and loan submission scripts. An internal security review assessed 19 findings; 14 have been resolved or accepted. The developer API/SDK and frontend are roadmap items.

**What problem does it solve?**
AI agents are becoming economic actors: they execute tasks, purchase services, and generate revenue. But financial infrastructure was designed around human borrowers: it requires human identity, manual underwriting, and static repayment schedules. Agents need programmable credit: loans governed by code, repaid from economic output, with on-chain financial identities that build with demonstrated track record.

**Why now?**
AI agent frameworks are proliferating rapidly. Developers are already deploying agents that transact on-chain. The financial infrastructure layer for those agents does not yet exist in a standardized, programmable form. Valen is building that layer before it becomes a bottleneck.

**What is the technology?**
Solidity 0.8.24 smart contracts (UUPS upgradeable, OpenZeppelin), deployed on Arc Testnet. TypeScript / Viem backend. All loan state is on-chain. USDC is used for all financial flows. No custom cryptography.

**What is the team's unfair advantage?**
Protocol-level financial engineering built to production standards at the prototype stage: the protocol handles concurrent credit limits, milestone-gated disbursement, revenue-linked repayment, layered default recovery across four recovery mechanisms, on-chain credit history per agent address, and recipient allowlisting, all verified by a thorough internal security review. The credit-history system means Valen is not a one-shot lending tool but a financial identity layer that grows with each agent's track record.

**What are you asking for from the accelerator?**
Mentorship on go-to-market strategy for developer infrastructure, introductions to AI agent framework developers and institutional USDC lenders, and support on the path to independent security audit and mainnet deployment.

---

## 8. Key Truthfulness Notes for Presenter

- **Do not claim production deployment.** The protocol runs on Arc Testnet. There are no mainnet transactions, no real USDC at risk, and no production users.
- **Do not claim an independent audit.** The security review is internal. An independent audit has not been conducted and is a prerequisite for mainnet.
- **Do not claim the backend enforces post-disbursement spending.** The backend is currently a read-only event observer. Post-disbursement spending controls are a design intent, not a current on-chain implementation beyond the creditWallet registry validation at loan creation.
- **Do not claim the SDK exists.** ABIs and integration scripts exist. A packaged public SDK/API does not.
- **Do not claim agent integrations exist.** No agents are integrated with Valen today.
- **Do not state a fixed credit-limit increase.** CreditRegistry computes an evolving limit from on-chain history. Say "can support increasing credit capacity" not "increases by X per repayment."
- **Do not say repayment is automatic without qualification.** RevenueRouter splits USDC automatically once it is submitted. Submission itself is initiated by the agent or its operator, not a background scheduler.
- **132 tests / 9 contracts / 14 of 19 findings resolved or accepted** are accurate and verifiable from the repository at the current commit.
- The internal audit document is at `docs/security-audit.md` and can be shared for technical due diligence.
