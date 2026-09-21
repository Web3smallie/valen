# Valen Protocol — Security Audit
**Repository:** Web3smallie/valen · commit fd088d9 · branch master  
**Audit date:** September 18, 2026  
**Scope:** All contracts in `src/`, interfaces in `src/interfaces/`, deploy script `script/Deploy.s.sol`, and all tests in `test/`.  
**Build:** clean (`forge build` — Compiler run successful, 5 lint warnings only)  
**Tests:** 54 pass, 1 fail (`LiquidityPool.t.sol setUp()` MemoryOOG — infrastructure constraint, not a logic failure; see RISK-11)

---

## Findings

---

### RISK-01 · Critical · Fund Lock After Default

**Contract / Function:** `LoanVault.settleExpiredLoan()` (line 140–152)  
**Also involves:** `LoanRegistry.markDefault()` (line 261–292)

**Root cause:**  
`settleExpiredLoan` contains a hard guard `if (loan.status != ILoanRegistry.LoanStatus.Active) revert LoanNotActive()`. `markDefault` transitions status to `Defaulted` before anyone can call `settleExpiredLoan`. After that transition the guard permanently prevents the call, and no other code path empties `lockedAmount[loanId]`.

**Failure scenario:**  
1. Pool funds a 4-milestone loan. Milestones 0 and 1 are released. Milestones 2 and 3 remain locked: `lockedAmount[loanId] = 50 000 USDC`.  
2. Loan expires + grace period elapses. Anyone calls `markDefault`. Status becomes `Defaulted`.  
3. Nobody can call `settleExpiredLoan` — reverts with `LoanNotActive`.  
4. Nobody can call `releaseMilestone` — also guards on `Active`.  
5. `lockedAmount[loanId]` = 50 000 USDC. No code path can ever move it. Funds are permanently stuck in the shared `LoanVault`.

**Applies to both funding paths:** direct P2P lender and pool (`loan.lender = LiquidityPool`). For the pool case `LiquidityPool.reconcileLoan` never credits the vault balance back — it only queries RevenueRouter, CollateralVault, UnderwriterPool, and ReservePool.

**Impact:** Permanent loss of up to 100% of the unreleased principal for every defaulted loan that still has locked milestones. No administrative escape valve exists. Severity: Critical.

**Minimal fix:**  
In `settleExpiredLoan`, replace the single-status check:
```solidity
// current — blocks after default
if (loan.status != ILoanRegistry.LoanStatus.Active) revert LoanNotActive();

// fix — allow settlement of expired+defaulted loans
if (
    loan.status != ILoanRegistry.LoanStatus.Active &&
    loan.status != ILoanRegistry.LoanStatus.Defaulted
) revert LoanNotActive();
```
No other contracts need to change for the fund-recovery path. For LiquidityPool accounting accuracy (so the pool's NAV correctly reflects the recovery), `reconcileLoan` should also be extended to query `lockedAmount` on the vault — but that is an accounting enhancement, not a prerequisite for unlocking funds.

---

### RISK-02 · High · LiquidityPool Does Not Account for Recovered Vault Funds

**Contract / Function:** `LiquidityPool.reconcileLoan()` (lines 196–251)

**Root cause:**  
`reconcileLoan` credits recovery from four sources: `RevenueRouter.totalRecovered`, `CollateralVault.reservations`, `UnderwriterPool.reservations`, and `ReservePool.loanPayout`. It never queries `LoanVault.lockedAmount`. Even after RISK-01 is fixed (so the vault balance can be physically recovered via `settleExpiredLoan`), the USDC lands in `loan.lender`'s address. For a direct lender that is fine. For a pool-funded loan `loan.lender == address(pool)`, so the USDC arrives in the pool contract — but `idleLedger` is never incremented, so it sits as an untracked, unaccountable inflow.

**Failure scenario:**  
A pool-funded 100 000 USDC loan defaults with 60 000 still in vault. After the RISK-01 fix, `settleExpiredLoan` sends 60 000 USDC to the pool's address. `totalDeployed` has already been partially or fully written off in `reconcileLoan`. The 60 000 USDC is in the pool's token balance but not in `idleLedger` or `totalDeployed`. Share price is permanently understated; lenders who withdraw after reconciliation receive less than they should. Later depositors receive inflated share counts at the wrong price because `totalAssets()` never includes those 60 000 USDC.

**Impact:** Permanent share-price understatement and loss of yield for existing LP holders. Severity: High.

**Minimal fix:**  
After the RISK-01 fix, extend `reconcileLoan` to check `LoanVault.lockedAmount(loanId)` when `status == Defaulted` and credit any non-zero value into `delta` (guarded by a separate `vaultRecoveryCounted[loanId]` boolean, matching the existing `defaultRecoveryCounted` pattern).

---

### RISK-03 · High · `settleExpiredLoan` Sends Vault Funds to `loan.lender` Without Notifying LiquidityPool

**Contract / Function:** `LoanVault.settleExpiredLoan()` (line 151)

**Root cause:**  
`usdc.safeTransfer(loan.lender, remaining)` — if `loan.lender == address(liquidityPool)` (pool-funded loan), USDC arrives in the pool contract as a raw token transfer. The pool has no `receive()` hook, no callback, and no record-keeping triggered by an incoming transfer. `idleLedger` does not change. This is a consequence of the same gap as RISK-02 and exists independently of RISK-01.

**Failure scenario:**  
Any expired pool-funded loan where milestones were partially released would, if `settleExpiredLoan` were callable, silently inflate `usdc.balanceOf(pool)` without updating `idleLedger`. This discrepancy persists until a reconcile explicitly accounts for it (which the current code never does).

**Impact:** Same share-price distortion as RISK-02. High, because it affects the correctness of every pool-funded loan that expires with unreleased milestones.

**Minimal fix:**  
Coordinate with the RISK-02 fix: after `settleExpiredLoan` sends funds to `loan.lender`, if `loan.lender == liquidityPool`, call a new pool callback (e.g. `LiquidityPool.notifyVaultRecovery(loanId, remaining)`) to credit `idleLedger`. Alternatively, implement the `reconcileLoan` query approach from RISK-02 and call `reconcileLoan(loanId)` at the end of `settleExpiredLoan`.

---

### RISK-04 · High · Permissionless `markDefault` Enables Griefing / Premature Default

**Contract / Function:** `LoanRegistry.markDefault()` (line 261)

**Root cause:**  
`markDefault` has no `onlyOwner` or access-control modifier. Any EOA can call it as soon as `block.timestamp > loan.expiresAt + defaultGracePeriod`. There is no protocol role required.

**Failure scenario:**  
A borrower and lender informally agree to a short extension. The borrower has already arranged a payment. A griefing bot (or a competing protocol participant) calls `markDefault` the moment the grace period ends, before the payment arrives. The loan is permanently `Defaulted`, collateral or underwriter stake is seized, and `creditRegistry.recordDefault` permanently cuts the borrower's credit limit (potentially to zero for severe cases). The borrower's payment, if it subsequently arrives through `RevenueRouter.repayLoan`, is accepted (the router checks for `Active | Defaulted | Repaid`) but does not reverse the collateral seizure or the credit-score damage.

**Impact:** Irreversible collateral seizure and credit damage triggered by any caller without protocol consent. Severity: High.

**Minimal fix:**  
Add `onlyOwner` (or a dedicated `LIQUIDATOR_ROLE` via AccessControl) to `markDefault`, matching the pattern used by `approveLoan`.

---

### RISK-05 · High · Permissionless `fundLoan` / `fundFromPool` — Anyone Can Fund Any Eligible Loan

**Contract / Function:** `LoanVault.fundLoan()` (line 80), `LoanVault.fundFromPool()` (line 98)

**Root cause:**  
Both functions are `external` with no access control. Any address can call `fundLoan` to become the lender of a `Requested` or `Approved` loan. For `fundFromPool`, any address can trigger pool-funded disbursement to any eligible loan.

**Failure scenarios:**  
- **Griefing via `fundLoan`:** Attacker funds a loan using their own USDC, becoming `loan.lender`. They can then refuse to call `releaseMilestone` (only the lender or pool owner can attest) — the borrower can never receive funds. The USDC is stuck until the loan expires, at which point the attacker recovers it via `settleExpiredLoan`. Net effect: DoS on the loan, temporary capital lockup for the attacker.
- **Frontrun a lender:** A legitimate lender prepares a transaction to fund loan #42. An attacker frontruns with their own USDC, stealing the lender position and the future revenue stream from that borrower.
- **Pool drain:** Any caller can call `fundFromPool` on any eligible loan and drain the pool into the vault. No whitelist of eligible callers exists.

**Impact:** DoS on borrower access to funds; lender position theft; uncontrolled pool outflows. Severity: High.

**Minimal fix:**  
Add `onlyOwner` or a `FUNDER_ROLE` modifier to both functions, or restrict `fundLoan` to `loan.borrower` and `fundFromPool` to a trusted keeper / the owner.

---

### RISK-06 · High · Pool Owner Single Key Can Release All Pool-Funded Milestones

**Contract / Function:** `LoanVault.releaseMilestone()` (lines 128–147), specifically lines 132–134

**Root cause:**  
```solidity
bool isPoolLoan = liquidityPool != address(0) && loan.lender == liquidityPool;
bool callerIsPoolOwner = isPoolLoan && msg.sender == OwnableUpgradeable(liquidityPool).owner();
if (msg.sender != loan.lender && !callerIsPoolOwner) revert NotLender();
```
The `LiquidityPool` owner (currently `DEPLOYER`) can call `releaseMilestone` for every pool-funded loan simultaneously. A single compromised key can drain the entire vault balance for all active pool-funded loans in one block.

**Design intent (confirmed by analysis):**  
This is intentional. The Valen milestone model is a **lender-attestation model**: the operator reviews off-chain deliverables (API metrics, agent output, revenue signals) and unilaterally triggers release on-chain. The borrower has no required on-chain role in milestone release. Requiring borrower co-signature would introduce new fund-lock failure modes (unresponsive borrower agent permanently blocks LP capital) and contradicts the A2A autonomous lending architecture.

**Classification: Operational/key-management risk. Not a code vulnerability.**  
The authorization logic is correct and intentional. The risk is concentration of privileged authority in a single hot key — a key-management concern, not a logic gap. Changing the Solidity would not meaningfully address the stated threat (Option A and keeper-mapping approaches do not survive a compromised owner key; they only change the shape of the storage read while the same key controls both the setting and the using of the authorization).

**Status: Mitigated operationally / accepted as a trust-model risk. No Solidity remediation.**

**Operational mitigations (recommended, not enforced by contracts):**

1. **Before the protocol handles significant LP capital**, transfer ownership of `LoanVault` and `LiquidityPool` to a hardware-wallet-backed multisig (e.g. a Gnosis Safe with a 3-of-5 or 2-of-3 threshold). This single operational change eliminates the single-key drain risk across all privileged functions simultaneously — not just milestone release, but also UUPS upgrades, loan approval, keeper management, and pool wiring.

2. **Consider separating milestone attestation from upgrade/admin authority** in a future operational hardening pass. A dedicated warm attestation key (controlled by the Safe) used only for day-to-day `releaseMilestone` calls reduces the exposure surface of routine operations without requiring multi-sig ceremony for every milestone. This key has no UUPS power and no setter access — its blast radius is limited to milestone release only.

3. This is an operational recommendation. The contracts do not enforce multisig or any separation of duties. Enforcement is the responsibility of the protocol operator.

---

### RISK-07 · High · `LiquidityPool.reconcileLoan` Uses Hardcoded Storage Slot in Test; `_bumpPoolNAV` Slot May Drift Across Upgrades

**Contract / Function:** `test/LiquidityPool.t.sol:_bumpPoolNAV()` (line 541)

**Root cause:**  
```solidity
vm.store(address(pool), bytes32(uint256(1)), bytes32(pool.idleLedger() + amount));
```
The test directly writes storage slot 1, assuming that is `idleLedger`. In an upgradeable contract (UUPS), the Initializable and OwnableUpgradeable base contracts consume storage slots before the child's own variables. If the storage layout shifts across an upgrade, this slot assumption silently corrupts unrelated state. This is a test reliability issue, but it also reveals that there is no storage layout snapshot test to prevent upgrade regressions.

**Impact:** Tests that pass today may silently corrupt state after an upgrade, giving a false green signal that masks a real regression. Severity: High (in the context of test integrity for an upgradeable system).

**Minimal fix:**  
Add `/// @custom:storage-location erc7201:...` annotations and a Foundry storage layout snapshot check (using `forge inspect LiquidityPool storageLayout` in CI). Replace the raw `vm.store` in the test with a direct USDC mint + `reconcileLoan` or another white-box path.

---

### RISK-08 · Medium · Concurrent Active Loans Consume the Same Credit Limit — No Per-Loan Deduction

**Contract / Function:** `LoanRegistry._validateProposal()` (lines 170–175), `CreditRegistry.getLimit()`

**Root cause:**  
The credit limit check at proposal time reads the borrower's current limit once: `effectiveLimit = creditRegistry.getLimit(msg.sender)`. It does not subtract the principal of any currently-active loans. A borrower with a 10 000 USDC limit and one active 9 000 USDC loan can immediately request a second 10 000 USDC loan (10 000 <= 10 000 limit) and receive it if it self-approves.

**Failure scenario:**  
Borrower's limit = 10 000 USDC. Loan A is Active for 9 000 USDC. Borrower requests Loan B for 10 000 USDC. `_validateProposal` checks `10 000 <= getLimit(borrower) = 10 000`. No active-loan deduction occurs. Loan B funds. Total outstanding exposure = 19 000 USDC against a 10 000 USDC limit.

**Impact:** Significant over-lending; credit limit becomes meaningless for borrowers who take out multiple concurrent loans. Severity: Medium.

**Minimal fix:**  
Add a `mapping(address => uint256) public outstandingPrincipal` in `LoanRegistry`, incremented on `markFunded` and decremented on `markRepaid` / `markDefault`. Subtract `outstandingPrincipal[msg.sender]` from `effectiveLimit` in `_validateProposal`.

---

### RISK-09 · Medium · `reservePool.payout` Is Called with `shortfall = loan.totalRepaymentDue - totalRecovered` But ReservePool Tracks Per-Loan Payout, Creating Double-Payout Risk if `markDefault` Is Called Twice

**Contract / Function:** `LoanRegistry.markDefault()` (lines 280–288)

**Root cause:**  
`markDefault` guards that `loan.status == Active`. A single call is therefore only possible once per loan — the guard prevents re-entry. However, the `recovered` variable is fetched at the moment `markDefault` is called:
```solidity
uint256 recovered = IRevenueRouter(router).totalRecovered(loanId);
uint256 shortfall = loan.totalRepaymentDue - recovered;
```
If a large payment arrives via `payRevenue` in the same block as `markDefault` (possible because the router accepts Defaulted-status loans), and a second `markDefault` call is attempted in the same block, Solidity's status check would revert the second call. So the direct double-payout is blocked. However, the `shortfall` passed to `reservePool.payout` may overstate the real shortfall if some revenue arrived between blocks but `totalRecovered` wasn't yet updated in the mempool ordering. This is an ordering risk, not a reentrancy risk.

**Impact:** ReservePool may pay a larger-than-necessary shortfall to the lender; pool balance drains faster than required. Severity: Medium.

**Minimal fix:**  
Cap the shortfall at `loan.totalRepaymentDue - router.totalRecovered(loanId)` and verify the calculation reflects the most current `totalRecovered` at default time. Document this is safe because `markDefault` is a single-status guard.

---

### RISK-10 · Medium · `LiquidityPool.deposit` Uses Pre-Reconciliation Share Price, Creating Front-Running / Share Dilution

**Contract / Function:** `LiquidityPool.deposit()` (lines 139–152)

**Root cause:**  
`deposit` calls `_reconcileAll()` before computing shares, which is correct. However `_reconcileAll` iterates `activeLoanIds`, which can be unbounded. At scale (many active loans), the gas cost of `_reconcileAll` inside a `deposit` could exceed the block gas limit, making `deposit` permanently uncallable.

**Additionally:** A depositor who calls `deposit` before `_reconcileAll` is invoked (in a block where reconciliation has not yet happened) does not pay the true post-reconciliation price. If a large reconcilable profit exists (e.g. a full loan repayment that has not been reconciled), the depositor captures part of the upside that should belong to existing LPs.

**Impact:** DoS risk at scale; minor value extraction for new depositors if reconciliation is delayed. Severity: Medium.

**Minimal fix:**  
Cap `activeLoanIds` length in `_reconcileAll` (e.g. reconcile only the first N or require explicit per-loan reconciliation before deposits). Alternatively, use a lazy reconciliation pattern that only reconciles the loan being deposited into.

---

### RISK-11 · Medium · `LiquidityPool.t.sol setUp()` Fails with MemoryOOG in CI — No Integration Test Coverage for the Most Critical Contract

**Contract / Function:** `test/LiquidityPool.t.sol` (entire test suite)

**Root cause:**  
The test's `setUp` deploys 8 UUPS proxies plus the OZ upgrades plugin's validation pipeline (`npm exec @openzeppelin/upgrades-core`) for each, exhausting EVM memory in the default Foundry test environment. The entire LiquidityPool test suite — 17 tests, the most comprehensive coverage of any contract — cannot run in CI.

**Impact:** Zero executed coverage for `LiquidityPool.reconcileLoan`, `fundLoan`, `deposit`, `withdraw`, and the default reconciliation paths. Any regression in these functions would not be caught by the test suite. Severity: Medium (test infrastructure), but produces an indirect Critical exposure because the most fund-critical code is untested in CI.

**Minimal fix:**  
Split the UUPS proxy deployment out of `setUp` into a `vm.createSelectFork` helper with increased memory limit (`--memory-limit` flag), or reduce the number of per-test proxy deployments by sharing a single fixture across the suite using a custom base contract pattern.

---

### RISK-12 · Medium · `LoanVault.setLiquidityPool` Is One-Way and Irrecoverable — A Misconfigured Address Cannot Be Changed

**Contract / Function:** `LoanVault.setLiquidityPool()` (lines 71–76)

**Root cause:**  
```solidity
function setLiquidityPool(address _liquidityPool) external onlyOwner {
    if (liquidityPool != address(0)) revert LiquidityPoolAlreadySet();
    ...
}
```
Once set, `liquidityPool` can never be changed. If the wrong address is deployed (e.g. a staging pool proxy on mainnet), the only recovery path is upgrading `LoanVault` itself and overwriting the storage slot.

**Impact:** Any bug in LiquidityPool that requires a redeployment also requires a LoanVault upgrade to point to the new pool, which is a heavy operational action. For misconfigurations at deploy time, funds may flow to the wrong pool permanently. Severity: Medium.

**Minimal fix:**  
Either remove the `AlreadySet` guard and replace it with a `onlyOwner` + event pattern (allowing owner to update), or document that address changes require a UUPS upgrade and add a corresponding Foundry upgrade safety test.

---

### RISK-13 · Medium · `LoanRegistry.setContracts` Is One-Way — Vault and Router Can Never Be Rotated

**Contract / Function:** `LoanRegistry.setContracts()` (lines 119–126)

**Root cause:**  
```solidity
if (vault != address(0) || router != address(0)) revert ContractsAlreadySet();
```
Same pattern as RISK-12. `vault` and `router` are permanently set on first call. Unlike `setLiquidityPool` and the other setters that protect individual addresses with their own `AlreadySet` checks, this function bundles `vault` and `router` together — if either is wrong, both must be fixed via an upgrade.

**Impact:** A compromised or buggy `LoanVault` or `RevenueRouter` cannot be replaced without a full `LoanRegistry` upgrade, which touches all loan state. Severity: Medium.

**Minimal fix:**  
Add a separate upgrade path or replace the setter with a TimelockController-gated update function.

---

### RISK-14 · Accepted design / documented

**Contract / Function:** `UnderwriterPool.commitToAgent()` / `UnderwriterPool.withdrawStake()`

**Original finding:**
An underwriter can withdraw deposited stake after calling `commitToAgent` but before the borrower's `requestLoan` executes, causing `reserveStake` to revert with `InsufficientStakeBalance`.

**Corrected characterisation:**
The original finding incorrectly stated that a failed `requestLoan` leaves the borrower's proposal "permanently stuck." This is not the case. `reserveStake` is called atomically within `requestLoan` in the same transaction. If `reserveStake` reverts, the entire `requestLoan` transaction reverts: no loan ID is assigned, no `outstandingPrincipal` is incremented, and no on-chain state is created. The borrower simply retries.

**Actual race:**
An underwriter monitoring the mempool can submit a higher-gas `withdrawStake` that executes before the borrower's `requestLoan`. This causes `requestLoan` to revert. No funds are lost and no on-chain loan state is corrupted. The window is negligible on Arc Testnet due to sub-second finality.

**Why `totalCommitted` was rejected:**
`commitToAgent` is intentionally designed as a revocable underwriting ceiling -- a statement of current willingness -- not a capital lock. The NatSpec explicitly uses the word "willing." An underwriter may commit to multiple borrowers whose aggregate commitments exceed their deposited stake, because only one loan per underwriter per loan ID can ever be reserved at a time. Locking `stakeBalance >= sum(all commitments)` would impose a 100% reserve requirement against all outstanding credit ceilings simultaneously, which changes the fundamental economic model from "attestation ceiling" to "reserved capital." This was rejected as an incorrect behavioural change. Furthermore, the legitimate revocation path (`commitToAgent(borrower, 0)` followed by `withdrawStake`) produces the identical UX outcome and is not affected by any `totalCommitted` constraint.

**Disposition:** Accepted design. The `commitToAgent` NatSpec has been updated to document the revocable-ceiling semantics explicitly. No Solidity or storage changes required.

---

### RISK-15 · Low · `LoanRegistry._validateProposal` Does Not Cross-Validate `budget` Categories Against `permittedRecipients`

**Contract / Function:** `LoanRegistry._validateProposal()` (lines 156–188)

**Root cause:**  
`budget[i].categoryId` is stored and `permittedRecipients[i]` are validated against `RecipientRegistry.isApproved`, but there is no check that each recipient's `RecipientRegistry.recipients[addr].categoryId` matches any entry in the loan's budget. A borrower can propose budget category "COMPUTE" but list a recipient approved under category "LEGAL", and the validation passes.

**Impact:** Weak budget controls; loan funds could be routed to recipients outside the declared budget category. Severity: Low (informational).

**Minimal fix:**  
In `_validateProposal`, check that `RecipientRegistry.recipients[recipient].categoryId` matches at least one `budget[i].categoryId` for each permitted recipient.

---

### RISK-16 · Low · `RevenueRouter.totalRecovered` Can Exceed `loan.totalRepaymentDue` if `repaymentShare` Calculation Overflows at Boundary

**Contract / Function:** `RevenueRouter._applyPayment()` (line 143–148)

**Root cause:**  
When `repaidHandled[loanId]` is false, `repaymentShare` is capped to `remainingDebt`. However the subsequent line `totalRecovered[loanId] += repaymentShare` is always fine in this path because `repaymentShare <= remainingDebt`. The issue is that `repaidHandled` is set `true` when `totalRecovered >= totalRepaymentDue` — so exact equality terminates cleanly. The slight risk is if `repaymentRateBps = 10000` (100%), `amount` is very large, and `repaymentShare > remainingDebt` — but the code caps it. No overflow is possible in practice.

**Impact:** Negligible; the cap is in place. Severity: Low / informational.

---

### RISK-17 · Low · Deploy Script Does Not Call `LoanVault.setLiquidityPool`

**Contract / Function:** `script/Deploy.s.sol` (entire `run()`)

**Root cause:**  
The deploy script wires all eight contracts together — including `loanRegistry.setContracts`, `setCollateralVault`, `setUnderwriterPool`, `setRecipientRegistry`, `setReservePool`, `creditRegistry.setAuthorizedCaller(×2)`, `reservePool.setAuthorizedContributor`, and `router.setReservePool`. It does **not** call `vault.setLiquidityPool(address(pool))`. No `LiquidityPool` is deployed at all in the script.

**Failure scenario:**  
After running the deploy script: `LoanVault.liquidityPool == address(0)`. Any call to `fundFromPool` reverts with `LiquidityPoolNotSet`. The pooled lending path is completely non-functional after deployment.

**Impact:** The LiquidityPool funding path is dead on arrival post-deploy. This is a deployment wiring gap, not a code logic error, but it is a guaranteed production failure. Severity: Low (easy to fix), but with High operational consequence if undetected.

**Minimal fix:**  
Add to the deploy script: deploy a `LiquidityPool` proxy, then call `vault.setLiquidityPool(liqPoolProxy)`.

---

### RISK-18 · Low · `CreditRegistry.setParameters` Is Unrestricted for All Parameters Including Retroactive Penalty Reduction

**Contract / Function:** `CreditRegistry.setParameters()` (lines 79–94)

**Root cause:**  
The owner can set `defaultPenaltyBps = 10000` (no penalty on default) or `initialLimit = type(uint256).max` (infinite credit for all new borrowers) at any time with no timelock. Changes apply immediately to the next `recordDefault` or `getLimit` call.

**Impact:** Protocol governance / centralization risk. Owner can extend unlimited credit or remove all default consequences at will. Severity: Low for a testnet deployment, but needs a Timelock on mainnet. Severity: Low.

**Minimal fix:**  
Wrap `setParameters` behind a `TimelockController` on mainnet deployment.

---

### RISK-19 · Low · No Event Emitted When `LoanVault.lockedAmount` Is Updated by `fundLoan` / `fundFromPool`

**Contract / Function:** `LoanVault.fundLoan()` (line 86), `fundFromPool()` (line 106)

**Root cause:**  
`lockedAmount[loanId] = loan.principal` is set silently. `LoanFundedInVault` is emitted, but it does not include the new `lockedAmount` value.

**Impact:** Off-chain indexers cannot track vault balance changes without reading contract state directly. Severity: Low / informational.

---

## Prioritized Finding List

| # | Severity | Title |
|---|----------|-------|
| RISK-01 | **Critical** | Vault funds permanently stuck after `markDefault` (no exit path for `lockedAmount`) |
| RISK-02 | **High** | LiquidityPool never credits recovered vault funds into `idleLedger` |
| RISK-03 | **High** | `settleExpiredLoan` sends USDC to pool address with no pool notification |
| RISK-04 | **High** | Permissionless `markDefault` — any caller can default any expired loan |
| RISK-05 | **High** | Permissionless `fundLoan`/`fundFromPool` — anyone can become lender or drain pool |
| RISK-06 | **High** | Pool owner single key can release all pool-funded milestones — *accepted as operational/trust-model risk; no Solidity change* |
| RISK-07 | **High** | Test uses hardcoded storage slot — upgrade regressions will be missed |
| RISK-08 | **Medium** | Concurrent loans consume same credit limit — no outstanding-principal deduction |
| RISK-09 | **Medium** | `markDefault` shortfall calculation has ordering risk against concurrent `payRevenue` |
| RISK-10 | **Medium** | Unbounded `_reconcileAll` loop risks DoS on `deposit`/`withdraw` at scale |
| RISK-11 | **Medium** | LiquidityPool test suite fails with MemoryOOG — zero CI coverage on most critical contract |
| RISK-12 | **Medium** | `setLiquidityPool` is one-way and irrecoverable without a contract upgrade |
| RISK-13 | **Medium** | `setContracts` is one-way — vault and router can never be rotated without upgrade |
| RISK-14 | **Accepted design** | Commitment is a revocable ceiling; `requestLoan` is atomic and reverts cleanly if stake is unavailable; `totalCommitted` guard rejected as incorrect economic model change |
| RISK-15 | **Low** | Budget categories not cross-validated against recipient registry categories |
| RISK-16 | **Low** | `totalRecovered` overflow at boundary — analysis shows cap is in place (informational) |
| RISK-17 | **Low** | Deploy script omits `LiquidityPool` deployment and `vault.setLiquidityPool` wiring |
| RISK-18 | **Low** | `CreditRegistry.setParameters` unrestricted — no timelock for governance params |
| RISK-19 | **Low** | No event for `lockedAmount` updates — off-chain indexing gap |
