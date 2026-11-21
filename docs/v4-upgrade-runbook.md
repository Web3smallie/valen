# V4 Upgrade Runbook — Direct Disbursement (`directDisbursement` flag)

Scope: activating the V4 `LoanRegistry` + `LoanVault` implementations on a
network where V3 is currently deployed behind UUPS proxies. No deployment is
authorized by this document — it is the procedure to follow when (and if)
the upgrade is explicitly approved.

## 1. Upgrade ordering (REQUIRED)

Upgrade the **LoanRegistry implementation FIRST**, then the **LoanVault
implementation**. Never the reverse.

- The V4 vault calls `registry.getDirectDisbursement()`, which exists only on
  the V4 registry. A V4 vault pointed at a V3 registry reverts on **every**
  `fundLoan`, `fundFromPool`, and `releaseMilestone` call (funding freeze).
- A V3 vault pointed at a V4 registry degrades gracefully: direct loans are
  simply handled as milestone loans (funds lock, milestones release). Safe
  intermediate state while the second upgrade lands.

Rollback order is the reverse: downgrade the **vault first**, then the
registry, for the same reason.

Suggested verification between the two steps:

1. After the registry upgrade, call `getDirectDisbursement(<existingLoanId>)`
   on a pre-upgrade loan — expect `false`.
2. Release (or simulate) one milestone on a pre-upgrade milestone loan —
   expect normal behavior.
3. After the vault upgrade, fund a small direct loan end-to-end on testnet
   before resuming normal operations.

## 2. Selector and compatibility consequences

- `requestLoan` takes a 16-field tuple in V4 (was 15). Its selector changes,
  so V3-encoded calldata **reverts** post-upgrade (neither contract has a
  fallback). All writers must switch at activation time (see §3).
- `getDirectDisbursement(uint256)` is new. All other read signatures,
  `getLoan`/`LoanView`, and all events are unchanged — pre-upgrade indexers
  and the backend's read paths keep working.
- Storage: the flag is appended last in the `Loan` struct (new slot, zero
  default). No existing storage is reinterpreted. Covered by
  `test_Q_UUPSUpgrade_PreservesLoansAndFlag` (proxy mechanics + default).

## 3. Activation checklist (all steps manual, all reversible pre-activation)

1. Deploy the V4 `LoanRegistry` and `LoanVault` implementations (no proxy
   changes yet). Record both implementation addresses.
2. Upgrade proxies in §1 order via the authorized owner/safe.
3. Run the §1 verification queries.
4. Backend: record both new implementation addresses and set `abiVersion`
   to `"V4"` in `deployments/arc-testnet.json`, then restart the API. Until
   then the backend keeps encoding V3 and rejecting `directDisbursement`,
   which is the correct pre-upgrade behavior. Startup validation verifies
   the upgrade is active and refuses to boot on any mismatch.
5. Keeper: before calling `fundFromPool` on any loan, read
   `getDirectDisbursement(loanId)` (or `GET /loans/:loanId`, which exposes
   the flag). Do not deploy pooled capital to a direct loan without explicit,
   recorded authorization — direct loans disburse in full immediately and
   cannot be halted mid-course via milestone attestation.
6. Announce to integrators that `requestLoan` calldata must use the 16-field
   V4 tuple from the activation block onward.

## 4. Policy notes (accepted behavior — change only via governance)

- `directDisbursement` is borrower-proposed and is NOT restricted to
  collateralized loans: underwriter-backed and unsecured (credit-limit)
  direct loans are allowed and pinned by tests M and N. P2P lenders consent
  implicitly by funding a loan whose flag is on-chain readable.
- Milestone arrays remain mandatory at request time even for direct loans
  (currently dead data for them). Relaxing that is a validation change for
  a future upgrade, not a silent patch.
