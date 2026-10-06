# Valen V1 Readiness Audit — Read-Only
**Date:** 2026-10-01  
**Baseline:** 197/197 tests green  
**Scope:** All `src/` contracts, interfaces, deploy script, backend, against the settled V1 architecture derived from the security audit findings.

---

## 1. What Already Exists (Implemented and Correct)

### Security Findings Resolved in Current Source

| Finding | Status in Code |
|---------|---------------|
| **RISK-01** Critical: Vault funds stuck after default | **Fixed.** `LoanVault.settleExpiredLoan()` accepts both `Active` and `Defaulted` status. `settledDefaultAmount[loanId]` is written and readable for post-default pool accounting. |
| **RISK-02** High: LiquidityPool never credits vault recovery | **Fixed.** `LiquidityPool.reconcileLoan()` queries `ILoanVaultView(loanVault).settledDefaultAmount(loanId)` and credits it into `idleLedger` via the `vaultSettlementCounted` guard. |
| **RISK-03** High: `settleExpiredLoan` sends USDC to pool without notification | **Fixed.** Same `vaultSettlementCounted` path in `reconcileLoan` handles this. `reconcileLoan` can be called after `settleExpiredLoan` in any order; the guard ensures exactly-once credit. |
| **RISK-04** High: Permissionless `markDefault` | **Fixed.** `markDefault` requires `msg.sender == owner() \|\| keepers[msg.sender]`. `setKeeper(address, bool)` exists with proper `ZeroAddress` guard and event. |
| **RISK-05** High: Permissionless `fundFromPool` | **Fixed.** `fundFromPool` carries `onlyOwner`. `fundLoan` (P2P path) remains unrestricted, consistent with the audit's stated design — any lender can fund a specific loan. |
| **RISK-06** High: Single key milestone release | **Accepted / documented.** No code change; accepted as operational trust-model risk. |
| **RISK-07** High: Hardcoded storage slot in test | **Fixed.** `LiquidityPool.t.sol` uses `ERC1967Proxy` direct deploy + USDC mint (`usdc.mint(address(pool), ...)`) instead of `vm.store(slot 1, ...)`. No raw storage writes remain. |
| **RISK-08** Medium: Concurrent loans bypass credit limit | **Fixed.** `outstandingPrincipal[borrower]` mapping exists in `LoanRegistry`. Incremented at `requestLoan`, decremented at `markDefault` and `markRepaid` (with correct Active-only guard to avoid double-decrement). `_validateProposal` subtracts `outstandingPrincipal[msg.sender]` from `effectiveLimit`. |
| **RISK-09** Medium: `markDefault` shortfall ordering risk | **Fixed.** `RevenueRouter` has `reserveRepaid[loanId]` tracking. `poolRecovered(loanId)` returns `totalRecovered - reserveRepaid`. `LiquidityPool.reconcileLoan()` uses `poolRecovered` not `totalRecovered`. Post-default garnishments are redirected to the reserve up to `loanPayout`. |
| **RISK-10** Medium: Unbounded `_reconcileAll` loop | **Fixed.** `maxActiveLoans = 150` cap enforced in `fundLoan`. `TooManyActiveLoans` error exists. `setMaxActiveLoans(uint256)` is owner-only adjustable. |
| **RISK-11** Medium: LiquidityPool test MemoryOOG | **Fixed.** All tests now use plain `ERC1967Proxy` pattern (no FFI upgrades harness). 197/197 pass. |
| **RISK-12** Medium: `setLiquidityPool` one-way irrecoverable | **Partially addressed.** The `LiquidityPoolAlreadySet` guard has been replaced — the new logic allows re-setting when `activeLoanCount() == 0`. The check is now `if (liquidityPool != address(0) && ILiquidityPool(liquidityPool).activeLoanCount() > 0) revert ActiveLoansExist()`. This is a meaningful improvement but introduces a new dependency: re-setting is blocked if any active loan exists, which could lock the address in edge cases. No test currently covers the re-set path. |
| **RISK-13** Medium: `setContracts` one-way | **Not addressed.** `setContracts` in `LoanRegistry` has been changed to a plain ownable setter (the `ContractsAlreadySet` guard was removed in the current code). The old `ContractsAlreadySet` error still exists in the error declaration list but is not used. This is an improvement — vault/router can now be rotated — but the error declaration is dead code. |
| **RISK-14** Accepted | No change needed. `commitToAgent` NatSpec updated with revocable-ceiling language. |
| **RISK-15** Low: Budget categories not cross-checked | **Implemented.** `_validateProposal` checks every `permittedRecipients[i]` is `recipientRegistry.isApproved()` AND that `creditWallet` is approved AND is present in `permittedRecipients`. The budget-category cross-check (matching `recipient.categoryId` to `budget[i].categoryId`) is **not yet implemented** — the `RecipientInfo.categoryId` field exists in `RecipientRegistry` but the cross-check in `_validateProposal` is absent. The current code does more than the audit's minimal fix (also validates creditWallet), but does not yet do the full category cross-check. |
| **RISK-16** Low: Informational | No change needed. |
| **RISK-17** Low: Deploy script omits LiquidityPool | **Not addressed.** `Deploy.s.sol` still deploys only 8 contracts (no `LiquidityPool`). `vault.setLiquidityPool(...)` is never called. Calling `fundFromPool` after this deployment will revert with `LiquidityPoolNotSet`. |
| **RISK-18** Low: `setParameters` unrestricted | No change. Accepted for testnet; timelock deferred to mainnet. |
| **RISK-19** Low: No event for `lockedAmount` updates | **Partially addressed.** `LoanFundedInVault` is emitted in both `fundLoan` and `fundFromPool`. The event does not include the new `lockedAmount` value explicitly, but the amount is in the event args. |

---

## 2. What Is Missing or Incomplete

### 2a. Deploy Script (`script/Deploy.s.sol`)

The single most actionable gap for V1 deployment:

- **`LiquidityPool` is not deployed.** The script deploys 8 of 9 contracts. There is no `LiquidityPool` instantiation anywhere in `run()`.
- **`vault.setLiquidityPool(...)` is never called.** `LoanVault.liquidityPool` will be `address(0)` after deployment. `fundFromPool` reverts with `LiquidityPoolNotSet`.
- **`LoanVault.setContracts` equivalent:** The RISK-12 new path (`setLiquidityPool` now updatable when `activeLoanCount == 0`) is not wired in the script because the pool isn't deployed.
- **`LoanRegistry.setKeeper(...)` not called.** No keeper bot address is registered at deploy time. `markDefault` will only be callable by the owner key post-deploy. This is acceptable for testnet but needs a keeper address before production.
- **`LiquidityPool.initializeLiquidity(...)` not called.** The pool starts with `initializedLiquidity = false`, so `deposit()` will revert with `NotInitialized` for all external users. An owner-seeded initial deposit transaction is required post-deploy.

### 2b. Solidity Gaps

- **RISK-15 category cross-check absent.** `RecipientRegistry.RecipientInfo.categoryId` is stored but `_validateProposal` never reads it. A recipient approved under `keccak256("LEGAL")` can appear in a loan proposal whose `budget` contains only `keccak256("COMPUTE")`. The field comment in `RecipientRegistry` explicitly marks it `// informational only, not cross-checked against budget yet`.
- **`ILoanRegistry` interface has stale status values.** The interface declares `Funded`, `Expired`, and `Cancelled` in the `LoanStatus` enum. None of these three values are used anywhere in `LoanRegistry.sol` or any other contract. The live code transitions only between `Requested → PendingApproval → Approved → Active → Repaid | Defaulted`. Having phantom enum values increases the chance of an off-chain indexer or future contract relying on a status that can never be emitted.
- **`ContractsAlreadySet` error is declared but unreachable.** It remains in `LoanRegistry`'s error declarations (line 77) but the `setContracts` function no longer uses it. Dead error declaration.
- **`setContracts` has no zero-address guard for the new repeatable-call path.** The current `setContracts` checks `_vault == address(0) || _router == address(0)` — this is present and correct. No functional gap, just confirming it.
- **`LoanVault.setLiquidityPool` re-set race.** If a pool migration is attempted while the `activeLoanCount` check passes (races with a concurrent `fundFromPool` call), the guard relies on reading `activeLoanCount()` at the moment of the call. No atomicity concern at the Solidity level (single-transaction), but worth documenting operationally.

### 2c. Interface Gaps

- **`ILoanRegistry` does not expose `markDefault`, `approveLoan`, `requestLoan`, `outstandingPrincipal`, or `keepers`.** These are present on `LoanRegistry` but absent from the interface. Backend code that imports `ILoanRegistry` cannot call them through the interface. Currently the backend uses raw ABIs rather than interface casting, so this is not blocking, but it means the interface is not a complete contract surface.
- **`IRevenueRouter` does not expose `payRevenue`, `repayLoan`, or `setReservePool`.** Same observation.
- **`ILiquidityPool` exposes only `fundLoan` and `activeLoanCount`.** `deposit`, `withdraw`, `reconcileLoan`, `initializeLiquidity`, and `sharePrice` are absent.

### 2d. Backend

- **`contracts.ts` references 8 addresses but no `LIQUIDITY_POOL_ADDRESS`.** When `LiquidityPool` is deployed, the backend config must be updated.
- **`loanEvents.ts` does not listen to `LiquidityPool` events** (`LoanFundedFromPool`, `LoanReconciled`, `LoanWrittenOff`, `LoanFinalized`, `Deposited`, `Withdrawn`). These are important for dashboard accounting.
- **No `markDefault` / keeper automation exists.** The backend has no scheduled or event-triggered call to `LoanRegistry.markDefault`. There is also no `fundFromPool` automation. The backend is currently event-logging only.
- **Backend has no `AgentRegistry` concept.** This appears to be a planned V1 component (mentioned in the audit as "A2A autonomous lending architecture") but no contract or backend file named `AgentRegistry` exists anywhere in the repository.

---

## 3. Conflicts With the V1 Architecture

### 3a. `ILoanRegistry.LoanStatus` phantom values conflict with indexer expectations

The interface declares `Funded`, `Expired`, and `Cancelled` statuses that the contract never emits. Any off-chain service consuming `LoanStatusChanged` events and switching on the full enum will have unreachable branches that look like dead code but are load-bearing documentation. If these statuses are genuinely deprecated, they should be removed from the interface. If they are planned for future states, the contract should document that.

### 3b. `setContracts` is now repeatable but `ContractsAlreadySet` still exists

The error is declared, never reverted, and may confuse a future developer into thinking the setter is still guarded. It should be removed or repurposed.

### 3c. Deploy script does not match the live contract surface

`Deploy.s.sol` is the authoritative deployment artifact. It is materially incomplete relative to the contracts that exist: `LiquidityPool` is fully implemented, tested (197 passing tests cover it), and required for pool-funded lending — but the deploy script has no knowledge of it. Any deployment from this script produces a broken protocol.

### 3d. `RevenueRouter.setReservePool` is callable only before any loans exist

```solidity
function setReservePool(...) external onlyOwner {
    if (registry.nextLoanId() > 0) revert LoansAlreadyExist();
```

This is intentional for V0 safety, but it means the reserve pool address and rate cannot be changed once any loan has been requested — not just funded, but requested. On a live testnet with any borrower activity, this is a permanent lock. The `setReserveBps(uint16)` function is a partial workaround (it can change the rate without the `nextLoanId` guard), but the pool address itself is frozen. This is a deployment-order constraint that is not documented in the script.

### 3e. `LoanVault.fundLoan` (P2P path) remains permissionless

The audit fix for RISK-05 only added `onlyOwner` to `fundFromPool`. `fundLoan` remains callable by any address. The audit's stated minimal fix says "restrict `fundLoan` to `loan.borrower`" or add a keeper role. That has not been implemented. Any EOA can still call `fundLoan`, become the lender, and then refuse to release milestones. This is the griefing/DoS path described in the RISK-05 finding.

---

## 4. Summary Table

| Category | Count |
|----------|-------|
| Audit findings fully resolved | 12 |
| Audit findings partially resolved | 3 (RISK-12, RISK-13, RISK-19) |
| Audit findings not addressed | 3 (RISK-17 deploy gap, RISK-15 category cross-check, RISK-05 P2P `fundLoan`) |
| Audit findings accepted / no-code | 3 (RISK-06, RISK-14, RISK-16, RISK-18) |
| New gaps introduced by fixes | 1 (`ContractsAlreadySet` dead error) |
| Deploy script gaps | 5 (no LiquidityPool, no `setLiquidityPool`, no keeper, no `initializeLiquidity`, ordering constraint on `setReservePool`) |
| Interface staleness issues | 3 (phantom enum values, incomplete surface on all three public interfaces) |
| Backend missing | 3 (no LP address config, no LP events, no keeper automation) |

---

## 5. Pre-Implementation Checklist for V1

Before any implementation work starts, the following decisions need to be made:

1. **Deploy script:** Add `LiquidityPool` deployment and wiring — this is the most blocking V1 gap.
2. **RISK-05 P2P path decision:** Restrict `fundLoan` to loan borrower, add a keeper role, or accept the griefing risk as a known limitation for testnet.
3. **RISK-15 category cross-check:** Decide whether to implement the full `budget.categoryId == recipient.categoryId` validation now, or document the current partial fix as the V1 baseline.
4. **Phantom enum values:** Remove `Funded`, `Expired`, `Cancelled` from `ILoanRegistry.LoanStatus`, or document them as reserved for future use.
5. **Dead error:** Remove `ContractsAlreadySet` from `LoanRegistry` or document why it is kept.
6. **Backend LiquidityPool wiring:** Add `LIQUIDITY_POOL_ADDRESS` env var and LP event listeners once the deploy script is updated.
