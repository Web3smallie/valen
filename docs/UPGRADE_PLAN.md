# Valen V4 upgrade plan: LoanRegistry, LoanVault, LiquidityPool, RevenueRouter

Status: **PREPARED, NOT EXECUTED.** No transaction was sent, nothing was signed, no key was read.
Base: `master` @ `9098748fabe8e1c0c633f4f9a0fe5db48cf85704`. Work branch: `upgrade-v4` (local only, not pushed).
Network: Arc Testnet (chain 5042002), RPC `https://rpc.testnet.arc.io` (log ranges limited to 9,999 blocks).
Owner of all 11 proxies (EOA, verified on-chain 2026-11-26): `0xB0E8Ba6aFe21371AD4001e611224FC200FD10144`.

## 1. Summary

- All 11 deployed implementations are reproduced byte-for-byte by commit `abd4225` (solc 0.8.36). Seven are already equal to `HEAD`; **four are behind HEAD**: LoanRegistry, LoanVault, LiquidityPool, RevenueRouter.
- Decision for all four: **A, upgrade in place** (same proxy addresses). Storage layout is append-only compatible; no reinitializer is needed.
- **Build profile:** the four new implementations MUST be built with `FOUNDRY_PROFILE=upgrade` (solc 0.8.36, optimizer ON runs=200, EVM cancun). With the default profile (optimizer off) LoanRegistry is 24,619 bytes and cannot be deployed: Arc enforces the 24,576-byte EIP-170 limit (verified with `eth_estimateGas`: 24,576 B accepted, 24,577 B reverts `CreateContractSizeLimit`).
- Runbook: **one step per contract**, order **LoanRegistry, LoanVault, LiquidityPool, RevenueRouter**, with read-only checks after each step (section 12).
- Post-upgrade fork checks (reconcile, backend calldata, old selector, nonexistent ids) all pass in simulation (section 9).
- One pre-existing accounting finding is NOT fixed by this upgrade and affects `reconcileLoan(0)` (section 10).

## 2. Environment

| Item | Value |
|---|---|
| forge | 1.7.1-stable |
| solc for the upgrade | 0.8.36 (the version in the deployed metadata) |
| Profile `upgrade` (foundry.toml) | `solc_version="0.8.36"`, `optimizer=true`, `optimizer_runs=200`, `via_ir=false`, `evm_version="cancun"`, `out="out/upgrade"`, `cache_path="cache/upgrade"` |
| Default profile | no solc pin, optimizer off (runs 200), `via_ir` false, `ffi=true`. Unchanged. |
| EVM target | bytecode is identical for cancun, prague and osaka (checked); no CLZ/TLOAD/TSTORE; PUSH0 and MCOPY are already used by the deployed code |
| Scripts use | no private key, no `.env`, no ffi, no `vm.envUint` |

## 3. Baseline: which commit produced each deployed implementation

Method: deployed runtime code (`eth_getCode`) vs `forge build` output of each of the 15 commits that changed `src/` (built against the current `lib/`; lib tree hash checked identical only for abd4225, 337cca7, cbe7791 and HEAD), solc 0.8.36, optimizer off. Metadata hash stripped, immutable ranges zeroed on both sides. `HEAD` `src/` is identical to `cbe7791`.

| Contract | Proxy | Deployed implementation | Exact baseline commit(s) | At HEAD? |
|---|---|---|---|---|
| AgentRegistry | 0xeC74944752Fff0f53Af5b727F288f59435C0144e | 0x797e0fcc4d05e2c606cc66c484418b602951cced | 61db75a to HEAD | yes |
| CreditRegistry | 0x258B0678b30E2d32034389cfeCa7f58fE1CeB897 | 0xf400dadaf8b01d16f5da65a2769a6b6e60dee1cd | 61db75a to HEAD | yes |
| **LoanRegistry** | 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d | 0xd47496361e5c485611718bd06065971691d2ba07 | abd4225 only | **no** |
| **RevenueRouter** | 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822 | 0x394d9f57f00f27b19b1549e23021efed9cd7be38 | 61db75a, abd4225, 337cca7 | **no** |
| **LoanVault** | 0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19 | 0xa698d80e5caf0b4b5033cd8091f1a37f98534537 | 61db75a, abd4225 | **no** |
| CollateralVault | 0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f | 0x9c1b6819b32615ca4d28d41be2a10303425b9ba5 | abd4225, 337cca7, HEAD | yes |
| UnderwriterPool | 0x23307d061dad8335995080518B73A839Ffe69E7A | 0x49b018d11b869d7964c2c560c5dd233e64f2aa32 | 61db75a to HEAD | yes |
| RecipientRegistry | 0xf8E069B659CEAf9c68318041D727b5c482Ac6374 | 0xe10598c039dd26609e0758bf737a68c9fae15f54 | all 15 (only a line-ending change) | yes |
| ReservePool | 0xe741d95aa64F125f75cB14E90d4b1cF96618f0fD | 0x9d488e961bdcb2fb00bfb7984605d3c00dae7dd7 | all 15 | yes |
| **LiquidityPool** | 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 | 0x828525794b195329e8f1ae501a61d7590df542c1 | abd4225, 337cca7 | **no** |
| ActivityAttester | 0x2660044E4A7316B65263ea1B23b80aAf09841196 | 0x6e119483041ff34b72db722b1c6cd2324b036dd4 | 61db75a to HEAD | yes |

Note: with forge's default solc (0.8.28) `LoanRegistry` and `RecipientRegistry` appear to match nothing. That was a compiler-version artefact; 0.8.32 or later (the deployed metadata says 0.8.36) reproduces all 11.

## 4. What changes (baseline to HEAD, `src/` only)

| Contract (baseline) | Functions / selectors | Events / errors | Modifiers, auth, initializers |
|---|---|---|---|
| LoanRegistry (abd4225) | `requestLoan`: **0xb5fd236d removed, 0x1e0af345 added** (`LoanProposal` gains a final `bool directDisbursement`); `+getDirectDisbursement(uint256)` 0x8e1fac83. No function removed. | `+error LoanDoesNotExist`, `+error ZeroPrincipal` | none changed |
| LoanVault (abd4225) | no signature change; behaviour: direct-disbursement path in `fundLoan`/`fundFromPool`, `releaseMilestone` rejects direct loans, existence guards | `+event DirectDisbursementSent(uint256,address,uint256)`, `+error DirectLoanCannotReleaseMilestone`, `+error LoanDoesNotExist` | none changed |
| LiquidityPool (337cca7) | no signature change; behaviour: `fundLoan` existence + zero-amount guard, `reconcileLoan` untracks phantom loans | `+error LoanDoesNotExist` | none changed |
| RevenueRouter (337cca7) | no signature change; behaviour: existence guard in `payRevenue`, `repayLoan` | `+error LoanDoesNotExist` | none changed |

(ABI comparison of the compiled artifacts, baseline vs HEAD; modifiers compared from the source diff.)

`_authorizeUpgrade` is `onlyOwner` and the constructor calls `_disableInitializers()` in all 11 contracts. No `reinitializer` exists in baseline or HEAD: every upgrade is `upgradeToAndCall(newImpl, 0x)`.

## 5. Tests (valen-master, default profile, solc 0.8.36)

| Run | Result |
|---|---|
| `forge test` run 1 and run 2 | 465 passed, 0 failed, 0 skipped (24 suites); identical per-test results (no flakiness) |
| `PhantomLoan.t.sol` | 11 of 11 pass |
| `DirectDisbursement.t.sol` | 18 of 18 pass (includes `test_Q_UUPSUpgrade_PreservesLoansAndFlag`) |
| Same suite with the optimizer ON (runs 200) | 465 passed, 0 failed |
| Fuzz / invariant tests | none exist in the repo |

## 6. Storage layout (`forge inspect <C> storage-layout --json`, baseline vs HEAD)

10 of 11 contracts are identical. **LoanRegistry**: one member appended at the end of the `Loan` struct inside the `_loans` mapping (`directDisbursement`, member slot 16, after `milestones` at 15). No variable moved, was removed, reordered or retyped. Existing loans read `false` (slot is empty; the scripts assert it for every existing loan before upgrading). Verified two ways (artifact `storageLayout` and `forge inspect`), also for the three other changed contracts (identical).

State semantics: existing loan 0 reads `directDisbursement == false`; `requestLoan` now rejects zero principal; calls with an unknown loan id revert `LoanDoesNotExist` (previously they read an empty "Requested" loan); the old `requestLoan` selector disappears.

## 7. Decision per contract

| Contract | Decision | Why |
|---|---|---|
| LoanRegistry | **A. Upgrade in place** | append-only layout, no initializer, loan history and all 11 wiring links preserved |
| LoanVault | **A** | identical layout; must follow LoanRegistry (it calls `getDirectDisbursement`) |
| LiquidityPool | **A** | identical layout |
| RevenueRouter | **A** | identical layout |

B (fresh redeploy) is not needed. It would orphan loan 0 history, change every proxy address referenced by `agent-card/`, `deployments/arc-testnet.json` and the backend, and break the CIS-8 binding scope. Not recommended.

## 8. Build record, per contract (profile `upgrade`)

Reproducibility: `FOUNDRY_PROFILE=upgrade forge build` reproduces exactly the bytecode tested (compared with separate builds for cancun/prague/osaka; artifacts record solc 0.8.36+commit.8a079791, evm cancun, optimizer 200 runs, viaIR none).

| Contract | Runtime B | Initcode B | EIP-170 headroom | `eth_estimateGas` (creation, read-only) | Dry-run gas (deploy + upgrade) | Runtime keccak (artifact, metadata stripped) |
|---|---|---|---|---|---|---|
| LoanRegistry | 13,852 | 14,101 | 10,724 | 3,099,981 | 4,050,009 | 0x84cdad447c41f563691eb68042223e6e7f552bd20ae5c6131e111d6093c8ffc7 |
| LoanVault | 7,878 | 8,127 | 16,698 | 1,798,113 | about 2,370,799 (derived, see note) | 0xc58dce13d9c65b38e80b5ff136206d454494f5234fad0d3f33232013a3ebc0cf |
| LiquidityPool | 9,858 | 10,107 | 14,718 | 2,229,755 | 2,927,606 | 0x0cf29f4113b5b8dc58cc44630612ffd46cffb0145c0521a5be9b410edab9dca4 |
| RevenueRouter | 7,729 | 7,978 | 16,847 | 1,765,691 | 2,329,057 | 0x724b8a8209303c9842fb38a4e11b6f3170e2bbe3c2c9c4bedb88bafe5b64c527 |

Note: LoanVault cannot be dry-run alone before LoanRegistry is upgraded (its ordering guard aborts, by design). Its gas is `UpgradeAll` total (11,677,471) minus the other three. Full sequence: 11,677,471 gas, about 0.24 USDC at the 20.8 gwei quoted on 2026-11-26 (price varies). Owner native balance at the time: 17.50 USDC.

## 9. Scripts and fork dry runs (no `--broadcast`)

Files (all new): `UpgradeBase.s.sol` (shared checks), `UpgradeLoanRegistry.s.sol`, `UpgradeLoanVault.s.sol`, `UpgradeLiquidityPool.s.sol`, `UpgradeRevenueRouter.s.sol` (each: pre-checks, deploy only the new implementation, `upgradeToAndCall`, post-checks, plus read-only `snapshot()` and `verifyPostUpgrade(address)`), `UpgradeAll.s.sol` (simulation of the whole sequence, NOT used by the runbook), `PostUpgradeForkChecks.s.sol` (fork-only, no broadcast cheatcode), `prepare-calldata.ts`, `verify-implementation.py`.

Every script refuses to run unless: chain is 5042002, `owner()` is the expected EOA, the proxy is at the exact baseline implementation, the broadcaster is the owner, and (LoanVault only) the registry already exposes `getDirectDisbursement`. After upgrading it asserts: implementation slot equals the new address, new code is within 24,576 bytes, `owner()` unchanged, `UPGRADE_INTERFACE_VERSION == "5.0.0"`, the bare implementation has initializers disabled, and the state snapshot hash equals the pre-upgrade hash.

| Dry run (fork, profile upgrade) | Result |
|---|---|
| UpgradeLoanRegistry | ran successfully, 4,050,009 gas |
| UpgradeLoanVault (before LoanRegistry is upgraded) | aborted by design: "LoanRegistry is not upgraded yet. Upgrade LoanRegistry BEFORE LoanVault." |
| UpgradeLiquidityPool | ran successfully, 2,927,606 gas |
| UpgradeRevenueRouter | ran successfully, 2,329,057 gas |
| UpgradeAll (ordered, all four) | ran successfully, 11,677,471 gas, all post-checks OK |
| `verifyPostUpgrade(oldImpl)` on the un-upgraded registry | fails, as it must |
| `snapshot()` x4 (read-only, `--rpc-url`) | work; hashes in section 12 |

### Post-upgrade fork checks (`PostUpgradeForkChecks`, simulates all four upgrades, then checks)

Result: **0 failed expectations**. Phase 1 records the current code; `[old]` lines are the pre-upgrade contrast, not failures.

a) **`LiquidityPool.reconcileLoan(0)`** still works on the upgraded pool and gives the identical outcome and accounting as before the upgrade (finalized true, activeLoanCount 0, idleLedger 21,000,000, totalDeployed 0). See finding F1.

b) **Backend `POST /loans/prepare`** (the real route, run in-process by `script/prepare-calldata.ts`, `abiVersion: "V4"`), inputs: agentId 1, creditWallet 0x786d491Fb520F3D9D9c7e62156C879fe52d6921E, principal 5000000, repaymentRateBps 1000, totalRepaymentDue 5500000, duration 86400, purpose "post-upgrade fork check", one budget category `0x00..00` cap 5000000, permittedRecipients [the same wallet], one milestone of 5000000 ("full disbursement"), collateralAmount 0, collateralAsset EURC `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a`. Selector 0x1e0af345, sent as that wallet to the upgraded LoanRegistry: accepted, returned loanId 1 (= previous `nextLoanId`), `getDirectDisbursement(1) == false` (and `true` when the request sets `directDisbursement: true`), `nextLoanId` advanced by 1.

c) **Old selector 0xb5fd236d**: the V3 calldata produced by the same route is rejected after the upgrade (empty revert, no fallback); a bare 0xb5fd236d call is rejected. Before the upgrade the V3 calldata succeeded and the V4 calldata failed.

d) **Nonexistent loan id** (tested with `nextLoanId` and `uint256.max`): all 12 guarded functions revert `LoanDoesNotExist`: LoanRegistry `approveLoan`, `markFunded`, `markMilestoneReleased`, `markDefault`, `markRepaid`; LoanVault `fundLoan`, `fundFromPool`, `releaseMilestone`, `settleExpiredLoan`; LiquidityPool `fundLoan`; RevenueRouter `payRevenue`, `repayLoan`. Before the upgrade 0 of 12 do. Existing loan 0 is still readable and not rejected.

Limits of this evidence: it runs in Foundry's local EVM on a fork of live state (gas metering paused in the check script because four contract creations exceed the simulator's script gas ceiling; real gas is the per-script figures above). It proves logic against real state, not execution on Arc.

## 10. Findings that need your attention (not caused by, and not fixed by, this upgrade)

**F1. `reconcileLoan(0)` overstates the pool by 220,000 USDC units (0.22 USDC).** Live values (block 74,170,566): pool USDC balance 20,780,000; `idleLedger` 10,000,000; `totalDeployed` 10,000,000; `finalized(0)` false; `activeLoanCount` 1; RevenueRouter `reserveBps` 200, `totalRecovered(0)` 11,000,000, `poolRecovered(0)` 11,000,000, `reserveRepaid(0)` 0; ReservePool balance 220,000. After `reconcileLoan(0)` the pool would book `totalAssets` 21,000,000 against 20,780,000 held. The numbers are consistent with the 2% reserve skim (220,000) having gone to the ReservePool while `poolRecovered` counted the full 11,000,000. `reconcileLoan` is permissionless and does this today, before and after the upgrade. HEAD's RevenueRouter does not change it. I did not diagnose the root cause further.

**F2. CI will not pass as the repo stands** (`forge fmt --check`), unrelated to this upgrade.

## 11. Consumers to update (nothing below was changed)

After the LoanRegistry upgrade the requestLoan selector changes, so every writer must switch to the V4 encoding. The backend refuses to start if the manifest and the chain disagree (`ConfigError`, process exit), so the manifest flip belongs in the same maintenance window.

| File | What is tied to the old ABI / old implementations |
|---|---|
| `deployments/arc-testnet.json` | `abiVersion: "V3"` (line 4); `implementation` for loanRegistry (line 19), loanVault (24), revenueRouter (34), liquidityPool (44) hold the OLD addresses |
| `backend/src/config/validate.ts` (lines 248 to 277) | fatal startup check: manifest V3 while the chain exposes `getDirectDisbursement` is an error |
| `backend/src/routes/prepare.ts` | encodes V3 (15-field, 0xb5fd236d) unless the manifest says V4; rejects `directDisbursement` under V3 |
| `backend/src/abis/LoanRegistryDeployed.ts` | the V3 ABI; obsolete after the upgrade (keep until rollback window closes) |
| `backend/src/routes/loans.ts` (lines 67 to 106) | probes `getDirectDisbursement` with a V3 fallback; works under both |
| `backend/src/testRequestLoan.ts` | already imports the V4 ABI: fails against the current chain, works after the upgrade (it is a script that can send a transaction if a key is configured; not run here) |
| `backend/src/test/manifest.test.ts` (CANONICAL_IMPL block, around lines 31 to 42; `abiVersion` V3 expectation) | pinned to the old implementations and V3; will fail once the manifest is updated |
| `backend/src/test/server.test.ts` (line 271) | expects `abiVersion` `"V3-deployed"` from the default manifest; will fail after the flip |
| `frontend/src/screens/Integration.tsx` (lines 130 to 137) | documents V3 / 15-field `requestLoan` |
| `frontend/src/lib/api.ts`, `frontend/src/screens/Transactions.tsx` | read `directDisbursement` from the API; no change needed, they tolerate its absence |
| `docs/v4-upgrade-runbook.md`, `docs/security-audit.md`, `docs/v1-readiness-audit.md`, `docs/pitch/companion.md` | describe V3 as the deployed state |
| `agent-card/` | contains proxy addresses only; unchanged by an in-place upgrade. Not touched. |

## 12. Runbook (owner runs these; I have not run any step below that sends a transaction)

Conventions: run from the repo root on branch `upgrade-v4`. `KEYSTORE` is the name of the owner's Foundry keystore (created with `cast wallet import`); I could not verify it exists. The scripts never read a key.

```bash
git checkout upgrade-v4
export FOUNDRY_PROFILE=upgrade
export RPC=https://rpc.testnet.arc.io
export OWNER=0xB0E8Ba6aFe21371AD4001e611224FC200FD10144
export KEYSTORE=<your-keystore-name>
export LR=0x253B68c7a2D646561387Dc0958A6C176a30a6f8d LV=0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19
export LP=0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061 RR=0xE0B9b39E72f73f2d85D77a1e24a2f319246de822
export SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
```

### Step 0. Preflight (read-only)

```bash
forge build                                          # expect: Compiler run successful
cast call $LR "owner()(address)" --rpc-url $RPC      # expect: 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144 (same for $LV $LP $RR)
cast storage $LR $SLOT --rpc-url $RPC                # expect: ...d47496361e5c485611718bd06065971691d2ba07
cast storage $LV $SLOT --rpc-url $RPC                # expect: ...a698d80e5caf0b4b5033cd8091f1a37f98534537
cast storage $LP $SLOT --rpc-url $RPC                # expect: ...828525794b195329e8f1ae501a61d7590df542c1
cast storage $RR $SLOT --rpc-url $RPC                # expect: ...394d9f57f00f27b19b1549e23021efed9cd7be38
cast balance $OWNER --rpc-url $RPC --ether           # expect: about 17.5 (needs more than ~1)
for t in UpgradeLoanRegistry UpgradeLoanVault UpgradeLiquidityPool UpgradeRevenueRouter; do
  forge script script/$t.s.sol:$t --sig "snapshot()" --rpc-url $RPC | grep -A1 "snapshot hash"
done
```

Record the four hashes. Values on 2026-11-26 (block about 74,170,000; re-run, they change if any state changes):

| Contract | Snapshot hash before |
|---|---|
| LoanRegistry | 0xd42c32ea27eb71bb9fbb15a3b7f2f61c29c7c2d6a2c8ba008bbe89df315c8f59 (nextLoanId 1) |
| LoanVault | 0x936dbc8ade23fcbea662f96e348b77fbbd6c26dc8c9296bc0a5e674d581d8037 |
| LiquidityPool | 0x51257e212afe0df35e16c85cbc7fdb59cb689611a6df5eca44709043728b38ed |
| RevenueRouter | 0xe6329b2aeb4237303a24bc063db2cec52a50aac116918886791244233e21c953 |

Fork dry run of the whole path (no broadcast). Generate the calldata with the backend deps installed in a scratch copy, then:

```bash
bun run script/prepare-calldata.ts > /tmp/prepare-calldata.json    # run where fastify/viem/dotenv are installed
V3=$(jq -r .v3.body.calldata /tmp/prepare-calldata.json); V4F=$(jq -r .v4_false.body.calldata /tmp/prepare-calldata.json); V4T=$(jq -r .v4_true.body.calldata /tmp/prepare-calldata.json)
forge script script/PostUpgradeForkChecks.s.sol:PostUpgradeForkChecks --sig "run(bytes,bytes,bytes)" "$V3" "$V4F" "$V4T" \
  --fork-url $RPC --sender $OWNER
# expect last lines: "failed expectations: 0" and "ALL POST-UPGRADE FORK CHECKS PASSED (simulation only; nothing was broadcast)"
```

### Step 1. LoanRegistry (first, mandatory)

```bash
forge script script/UpgradeLoanRegistry.s.sol:UpgradeLoanRegistry --fork-url $RPC --sender $OWNER   # dry run first, no --broadcast
forge script script/UpgradeLoanRegistry.s.sol:UpgradeLoanRegistry --rpc-url $RPC --account $KEYSTORE --sender $OWNER --broadcast --slow
```
Expected output: `[OK] LoanRegistry baseline impl confirmed: 0xd474...ba07`, `[OK] LoanRegistry appended struct member slot is empty for all existing loans: 1`, 2 transactions (create + upgrade), `[OK] LoanRegistry post-upgrade impl slot + owner verified: <NEW_LR>`, `[OK] LoanRegistry snapshot (wiring, params, every loan) unchanged`, `LoanRegistry new implementation: <NEW_LR>`. Write down `<NEW_LR>` and both tx hashes.

Checks (read-only) and expected values:
```bash
cast receipt <txhash> status --rpc-url $RPC                 # 1 for both transactions
cast storage $LR $SLOT --rpc-url $RPC                       # ...<NEW_LR> (lowercase, left-padded)
cast call $LR "owner()(address)" --rpc-url $RPC             # 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144
forge script script/UpgradeLoanRegistry.s.sol:UpgradeLoanRegistry --sig "snapshot()" --rpc-url $RPC   # hash == the LoanRegistry hash recorded in Step 0
cast call $LR "getDirectDisbursement(uint256)(bool)" 0 --rpc-url $RPC   # false
cast call $LR "nextLoanId()(uint256)" --rpc-url $RPC        # 1
cast call $LR 0xb5fd236d --rpc-url $RPC                     # error: execution reverted (old selector gone)
python3 script/verify-implementation.py LoanRegistry --proxy $LR   # RESULT: MATCH
```
Stop if any value differs (see Rollback).

### Step 2. LoanVault (only after Step 1 passed)

```bash
forge script script/UpgradeLoanVault.s.sol:UpgradeLoanVault --rpc-url $RPC --account $KEYSTORE --sender $OWNER --broadcast --slow
```
Expected: `[OK] ordering guard`, 2 transactions, `[OK] LoanVault post-upgrade impl slot + owner verified: <NEW_LV>`, `[OK] LoanVault snapshot (wiring, lockedAmount, settledDefaultAmount per loan) unchanged`. If it prints `ABORT: LoanRegistry is not upgraded yet`, do Step 1 first.
Checks: `cast storage $LV $SLOT` = `<NEW_LV>`; `owner()` unchanged; `snapshot()` hash equals the LoanVault hash from Step 0; `python3 script/verify-implementation.py LoanVault --proxy $LV` = MATCH; `cast call $LV "registry()(address)"` = `$LR`.

### Step 3. LiquidityPool

```bash
forge script script/UpgradeLiquidityPool.s.sol:UpgradeLiquidityPool --rpc-url $RPC --account $KEYSTORE --sender $OWNER --broadcast --slow
```
Checks: `cast storage $LP $SLOT` = `<NEW_LP>`; `owner()` unchanged; `snapshot()` hash equals the Step 0 LiquidityPool hash; `verify-implementation.py LiquidityPool --proxy $LP` = MATCH; `activeLoanCount()` = 1, `idleLedger()` = 10000000, `totalDeployed()` = 10000000, `finalized(0)` = false (the upgrade does not reconcile loan 0). **Do not call `reconcileLoan(0)` until F1 is decided.**

### Step 4. RevenueRouter

```bash
forge script script/UpgradeRevenueRouter.s.sol:UpgradeRevenueRouter --rpc-url $RPC --account $KEYSTORE --sender $OWNER --broadcast --slow
```
Checks: `cast storage $RR $SLOT` = `<NEW_RR>`; `owner()` unchanged; `snapshot()` hash equals the Step 0 RevenueRouter hash; `verify-implementation.py RevenueRouter --proxy $RR` = MATCH; `reserveBps()` = 200; `poolRecovered(0)` = 11000000; `isFullyRepaid(0)` = true.

### Step 5. Off-chain cutover (separate approval, not done here)

In one window: set `abiVersion` to `"V4"` and the four `implementation` entries in `deployments/arc-testnet.json` to `<NEW_*>`; update the pinned values and the V3 expectations in `backend/src/test/manifest.test.ts` and `server.test.ts`; restart the backend (its startup check must pass); update `Integration.tsx` text and the docs listed in section 11. Expected: backend starts, `POST /loans/prepare` returns `abiVersion: "V4"` with selector 0x1e0af345.

## 13. Rollback plan

Old implementations stay on chain permanently, so rollback is one `upgradeToAndCall` per proxy to the old address. Targets:

| Proxy | Old implementation (rollback target) |
|---|---|
| LoanRegistry | 0xd47496361e5C485611718BD06065971691D2ba07 |
| LoanVault | 0xa698D80e5cAf0B4B5033Cd8091f1a37f98534537 |
| LiquidityPool | 0x828525794b195329e8F1aE501A61d7590df542c1 |
| RevenueRouter | 0x394D9f57F00f27B19b1549e23021Efed9CD7be38 |

Rules:
1. **Roll back in reverse order:** RevenueRouter, LiquidityPool, LoanVault, then LoanRegistry. Never leave a new LoanVault on an old LoanRegistry (every `fundLoan` would revert). RevenueRouter and LiquidityPool are independent of the others.
2. **Check first** that no loan uses the new feature: `for i in 0..nextLoanId-1: cast call $LR "getDirectDisbursement(uint256)(bool)" $i` must all be `false`. If any is `true`, do not roll back LoanRegistry or LoanVault without a separate plan (the old code does not know the flag).
3. Per contract (owner runs):
```bash
cast send $RR "upgradeToAndCall(address,bytes)" 0x394D9f57F00f27B19b1549e23021Efed9CD7be38 0x --rpc-url $RPC --account $KEYSTORE
# same shape for $LP, $LV, $LR with their old addresses
cast storage <proxy> $SLOT --rpc-url $RPC      # expect the old implementation address
cast call <proxy> "owner()(address)" --rpc-url $RPC
python3 script/verify-implementation.py <Contract> <oldImpl> --artifacts out    # only meaningful after `unset FOUNDRY_PROFILE; forge build`
```
4. The appended struct slot (slot 16 of each loan) stays in storage; the old code ignores it, so it is harmless. Loans created while V4 was live keep whatever value was written there.
5. Off-chain: revert the manifest to `abiVersion: "V3"` and the old implementation addresses in the same window, then restart the backend.
6. If a step fails before the `upgradeToAndCall` transaction is mined, nothing needs rolling back (a stray new implementation is inert; nobody points at it).

## 14. What I could not verify

- The owner's keystore name and that it signs for the owner address (no key was touched).
- Execution of the new code on Arc itself. The fork checks run in Foundry's local EVM against live state; Arc enforced rules were checked only for code size and creation gas (`eth_estimateGas`).
- The gas price at broadcast time (costs above use 20.8 gwei).
- Backend, frontend and CI behaviour after the cutover (none built or run here beyond the in-process `POST /loans/prepare` call).
- `eth_getProof` is not supported by the RPC, and only one RPC provider was used.
- `verifyPostUpgrade(address)` for LoanVault, LiquidityPool and RevenueRouter checks only the implementation slot, owner and version; their state is covered by the `snapshot()` hash equality.
- The provenance of `HEAD`'s `src/` (commit `cbe7791`, "Pending changes exported from your codespace"): I read the diffs but did not audit the changes beyond the checks above.
- Root cause of F1 beyond the arithmetic noted.
