// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {LoanRegistryModule} from "./UpgradeLoanRegistry.s.sol";
import {LoanVaultModule} from "./UpgradeLoanVault.s.sol";
import {LiquidityPoolModule} from "./UpgradeLiquidityPool.s.sol";
import {RevenueRouterModule} from "./UpgradeRevenueRouter.s.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";

interface IBalanceOf {
    function balanceOf(address) external view returns (uint256);
}

/// @notice FORK-ONLY verification of the upgraded protocol. It NEVER broadcasts:
///         there is no vm.startBroadcast/vm.broadcast anywhere in this file, so
///         even with --broadcast it would send nothing. All state changes happen
///         inside Foundry's local EVM copy of live Arc Testnet and are rolled
///         back with snapshots.
///
/// Phase 1  records how the CURRENT on-chain code behaves.
/// Phase 2  simulates the four upgrades (owner pranked) in the runbook order.
/// Phase 3  checks, against the upgraded code:
///   (a) LiquidityPool.reconcileLoan(0) still works and gives the same result
///   (b) calldata produced by the backend's POST /loans/prepare (V4) succeeds
///   (c) the old requestLoan selector 0xb5fd236d is rejected
///   (d) every function that now checks loan existence reverts LoanDoesNotExist
///
/// Calldata comes from script/prepare-calldata.ts (the real backend route).
///   FOUNDRY_PROFILE=upgrade forge script script/PostUpgradeForkChecks.s.sol:PostUpgradeForkChecks \
///     --sig "run(bytes,bytes,bytes)" <v3Calldata> <v4FalseCalldata> <v4TrueCalldata> \
///     --fork-url https://rpc.testnet.arc.io --sender 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144
contract PostUpgradeForkChecks is LoanRegistryModule, LoanVaultModule, LiquidityPoolModule, RevenueRouterModule {
    /// @dev Agent 1's wallet (approved recipient, the borrower of loan 0).
    address internal constant WALLET = 0x786d491Fb520F3D9D9c7e62156C879fe52d6921E;
    address internal constant ANYONE = address(0xBEEF);
    bytes4 internal constant OLD_REQUEST_LOAN = 0xb5fd236d;
    bytes4 internal constant LOAN_DOES_NOT_EXIST = bytes4(keccak256("LoanDoesNotExist()"));

    uint256 internal failures;

    // Cross-phase values live in storage (script contract only) to keep each function's stack small.
    bytes internal v3Data;
    bytes internal v4FalseData;
    bytes internal v4TrueData;
    bytes32 internal reconcilePre;
    bool internal v3Pre;
    bool internal v4Pre;
    uint256 internal goodPre;

    struct Pool {
        bool finalized0;
        uint256 active;
        uint256 idle;
        uint256 deployed;
        uint256 assets;
        uint256 balance;
    }

    struct DCall {
        string label;
        address caller;
        address target;
        bytes data;
    }

    // ───────────────────────── helpers ─────────────────────────

    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) {
            assembly {
                s := mload(add(ret, 32))
            }
        }
    }

    /// @dev Calls `target` as `caller`, then rolls the fork state back.
    function _probe(address caller, address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        uint256 s = vm.snapshotState();
        vm.prank(caller);
        (ok, ret) = target.call(data);
        vm.revertToState(s);
    }

    function _pool() internal view returns (Pool memory p) {
        LiquidityPool lp = LiquidityPool(LP_PROXY);
        p.finalized0 = lp.finalized(0);
        p.active = lp.activeLoanCount();
        p.idle = lp.idleLedger();
        p.deployed = lp.totalDeployed();
        p.assets = lp.totalAssets();
        p.balance = IBalanceOf(address(lp.usdc())).balanceOf(LP_PROXY);
    }

    /// @dev Runs reconcileLoan(0) as an arbitrary caller and returns a fingerprint of
    ///      (did it succeed, revert selector, resulting pool accounting). State is rolled back.
    function _reconcile(string memory tag) internal returns (bytes32 fp) {
        uint256 s = vm.snapshotState();
        Pool memory before_ = _pool();
        vm.prank(ANYONE);
        (bool ok, bytes memory ret) = LP_PROXY.call(abi.encodeWithSignature("reconcileLoan(uint256)", uint256(0)));
        Pool memory after_ = _pool();
        console.log(string.concat("  [", tag, "] reconcileLoan(0) success:"), ok);
        if (!ok) console.logBytes4(_sel(ret));
        console.log("    before: finalized(0) / activeLoanCount / idleLedger / totalDeployed:", before_.finalized0);
        console.log("            ", before_.active, before_.idle, before_.deployed);
        console.log("    after : finalized(0) / activeLoanCount / idleLedger / totalDeployed:", after_.finalized0);
        console.log("            ", after_.active, after_.idle, after_.deployed);
        console.log("    after : totalAssets / USDC balance of pool:", after_.assets, after_.balance);
        fp = keccak256(abi.encode(ok, _sel(ret), after_));
        vm.revertToState(s);
    }

    function _dCalls(uint256 id) internal pure returns (DCall[] memory c) {
        c = new DCall[](12);
        c[0] = DCall("LoanRegistry.approveLoan", EXPECTED_OWNER, LR_PROXY, abi.encodeWithSignature("approveLoan(uint256)", id));
        c[1] = DCall(
            "LoanRegistry.markFunded", LV_PROXY, LR_PROXY, abi.encodeWithSignature("markFunded(uint256,address)", id, LP_PROXY)
        );
        c[2] = DCall(
            "LoanRegistry.markMilestoneReleased",
            LV_PROXY,
            LR_PROXY,
            abi.encodeWithSignature("markMilestoneReleased(uint256,uint256)", id, uint256(0))
        );
        c[3] = DCall("LoanRegistry.markDefault", EXPECTED_OWNER, LR_PROXY, abi.encodeWithSignature("markDefault(uint256)", id));
        c[4] = DCall("LoanRegistry.markRepaid", RR_PROXY, LR_PROXY, abi.encodeWithSignature("markRepaid(uint256)", id));
        c[5] = DCall("LoanVault.fundLoan", ANYONE, LV_PROXY, abi.encodeWithSignature("fundLoan(uint256)", id));
        c[6] = DCall("LoanVault.fundFromPool", EXPECTED_OWNER, LV_PROXY, abi.encodeWithSignature("fundFromPool(uint256)", id));
        c[7] = DCall(
            "LoanVault.releaseMilestone",
            EXPECTED_OWNER,
            LV_PROXY,
            abi.encodeWithSignature("releaseMilestone(uint256,uint256)", id, uint256(0))
        );
        c[8] = DCall("LoanVault.settleExpiredLoan", ANYONE, LV_PROXY, abi.encodeWithSignature("settleExpiredLoan(uint256)", id));
        c[9] = DCall(
            "LiquidityPool.fundLoan", LV_PROXY, LP_PROXY, abi.encodeWithSignature("fundLoan(uint256,uint256)", id, uint256(1))
        );
        c[10] = DCall(
            "RevenueRouter.payRevenue", ANYONE, RR_PROXY, abi.encodeWithSignature("payRevenue(uint256,uint256)", id, uint256(1))
        );
        c[11] = DCall(
            "RevenueRouter.repayLoan", ANYONE, RR_PROXY, abi.encodeWithSignature("repayLoan(uint256,uint256)", id, uint256(1))
        );
    }

    /// @dev Runs the 12 guarded functions for `id`; returns how many reverted with LoanDoesNotExist.
    function _nonexistent(uint256 id, bool log, bool postUpgrade) internal returns (uint256 good) {
        DCall[] memory c = _dCalls(id);
        for (uint256 i = 0; i < c.length; i++) {
            (bool ok, bytes memory ret) = _probe(c[i].caller, c[i].target, c[i].data);
            bool hit = !ok && _sel(ret) == LOAN_DOES_NOT_EXIST;
            if (hit) good++;
            if (log) {
                string memory res = ok ? "did NOT revert" : (hit ? "reverts LoanDoesNotExist" : string.concat("reverts with ", vm.toString(_sel(ret))));
                console.log(string.concat(hit ? "  [OK]   " : (postUpgrade ? "  [FAIL] " : "  [old]  "), c[i].label, " id=", vm.toString(id), ": ", res));
            }
        }
    }

    function _expect(bool cond, string memory what) internal {
        if (cond) {
            console.log(string.concat("  [OK]   ", what));
        } else {
            console.log(string.concat("  [FAIL] ", what));
            failures++;
        }
    }

    // ───────────────────────── main ─────────────────────────

    function run(bytes calldata v3, bytes calldata v4False, bytes calldata v4True) external {
        require(block.chainid == ARC_TESTNET_CHAIN_ID, "ABORT: not Arc Testnet");
        require(bytes4(v3[:4]) == OLD_REQUEST_LOAN, "ABORT: v3 calldata must carry the old selector 0xb5fd236d");
        require(bytes4(v4False[:4]) != OLD_REQUEST_LOAN && bytes4(v4False[:4]) == bytes4(v4True[:4]), "ABORT: bad v4 calldata");
        // This is a logic check, not a gas measurement: four contract creations (~11M gas) on top of
        // the probes exceed the simulator's script gas ceiling. Real deployment gas is measured by the
        // per-contract dry runs (UpgradeLoanRegistry etc.).
        vm.pauseGasMetering();
        v3Data = v3;
        v4FalseData = v4False;
        v4TrueData = v4True;

        _phase1Before();
        _phase2Upgrade();
        _phase3a();
        _phase3b();
        _phase3c();
        _phase3d();

        console.log("=== RESULT ===");
        console.log("failed expectations:", failures);
        require(failures == 0, "ABORT: post-upgrade fork checks failed");
        console.log("ALL POST-UPGRADE FORK CHECKS PASSED (simulation only; nothing was broadcast)");
    }

    /// PHASE 1: behaviour of the CURRENT (pre-upgrade) on-chain code.
    function _phase1Before() internal {
        console.log("=== PHASE 1: current on-chain code (before any upgrade) ===");
        reconcilePre = _reconcile("pre ");
        (v3Pre,) = _probe(WALLET, LR_PROXY, v3Data);
        (v4Pre,) = _probe(WALLET, LR_PROXY, v4FalseData);
        console.log("  requestLoan with V3 (0xb5fd236d) calldata succeeds:", v3Pre);
        console.log("  requestLoan with V4 calldata succeeds             :", v4Pre);
        console.log("  nonexistent-id calls (id == nextLoanId) that revert LoanDoesNotExist, of 12:");
        goodPre = _nonexistent(_lrLoanCount(), true, false); // [old] = no guard yet (expected before the upgrade)
        console.log("    count:", goodPre);
    }

    /// PHASE 2: simulate the four upgrades in runbook order (owner pranked; nothing is broadcast).
    function _phase2Upgrade() internal {
        console.log("=== PHASE 2: simulated upgrades (owner pranked; nothing is broadcast) ===");
        _lrPre();
        _lpPre();
        _rrPre();
        _requireBaseline(LV_PROXY, LV_OLD_IMPL, "LoanVault");
        bytes32[4] memory pre = [_lrSnap(), _lvSnap(), _lpSnap(), _rrSnap()];

        address[4] memory impl;
        vm.startPrank(EXPECTED_OWNER);
        impl[0] = _lrUpgrade();
        _lvPre(); // ordering guard: LoanRegistry must already expose getDirectDisbursement
        impl[1] = _lvUpgrade();
        impl[2] = _lpUpgrade();
        impl[3] = _rrUpgrade();
        vm.stopPrank();

        _lrPost(pre[0], impl[0]);
        _lvPost(pre[1], impl[1]);
        _lpPost(pre[2], impl[2]);
        _rrPost(pre[3], impl[3]);
    }

    function _phase3a() internal {
        console.log("=== PHASE 3 (a): LiquidityPool.reconcileLoan(0) on the upgraded pool ===");
        bytes32 post = _reconcile("post");
        _expect(post == reconcilePre, "reconcileLoan(0): same outcome and same resulting accounting as before the upgrade");
    }

    function _phase3b() internal {
        console.log("=== PHASE 3 (b): backend POST /loans/prepare calldata against upgraded LoanRegistry ===");
        LoanRegistry r = LoanRegistry(LR_PROXY);
        uint256 expectedId = r.nextLoanId();
        uint256 s = vm.snapshotState();

        vm.prank(WALLET);
        (bool ok, bytes memory ret) = LR_PROXY.call(v4FalseData);
        _expect(ok, "V4 calldata (directDisbursement omitted -> false) accepted by requestLoan");
        if (ok) {
            uint256 id = abi.decode(ret, (uint256));
            _expect(id == expectedId, "returned loanId == previous nextLoanId");
            _expect(!r.getDirectDisbursement(id), "getDirectDisbursement(newId) == false");
            _expect(r.nextLoanId() == expectedId + 1, "nextLoanId advanced by 1");
        } else {
            console.logBytes4(_sel(ret));
        }
        vm.revertToState(s);

        vm.prank(WALLET);
        (ok, ret) = LR_PROXY.call(v4TrueData);
        _expect(ok, "V4 calldata (directDisbursement=true) accepted by requestLoan");
        if (ok) {
            _expect(r.getDirectDisbursement(abi.decode(ret, (uint256))), "getDirectDisbursement(newId) == true");
        } else {
            console.logBytes4(_sel(ret));
        }
        vm.revertToState(s);
    }

    function _phase3c() internal {
        console.log("=== PHASE 3 (c): old requestLoan selector 0xb5fd236d ===");
        (bool ok, bytes memory ret) = _probe(WALLET, LR_PROXY, v3Data);
        _expect(!ok, "V3 calldata from POST /loans/prepare is rejected after the upgrade");
        _expect(ret.length == 0, "rejection is an empty revert (selector no longer exists, no fallback)");
        (ok,) = _probe(WALLET, LR_PROXY, abi.encodeWithSelector(OLD_REQUEST_LOAN));
        _expect(!ok, "bare 0xb5fd236d call is rejected");
        console.log("  (before the upgrade the same V3 calldata succeeded:", v3Pre);
        console.log("   and the V4 calldata succeeded:", v4Pre);
    }

    function _phase3d() internal {
        console.log("=== PHASE 3 (d): nonexistent loan id -> LoanDoesNotExist ===");
        _expect(_nonexistent(_lrLoanCount(), true, true) == 12, "all 12 guarded functions revert LoanDoesNotExist for id == nextLoanId");
        _expect(_nonexistent(type(uint256).max, true, true) == 12, "all 12 guarded functions revert LoanDoesNotExist for id == uint256.max");
        console.log("  (before the upgrade, ids == nextLoanId reverting LoanDoesNotExist, of 12:", goodPre);

        // The guard must not reject real ids: loan 0 exists.
        (bool ok, bytes memory ret) = _probe(ANYONE, LR_PROXY, abi.encodeWithSignature("getLoan(uint256)", uint256(0)));
        _expect(ok && ret.length > 0, "getLoan(0) still readable");
        (, ret) = _probe(EXPECTED_OWNER, LR_PROXY, abi.encodeWithSignature("markDefault(uint256)", uint256(0)));
        _expect(_sel(ret) != LOAN_DOES_NOT_EXIST, "markDefault(0) is NOT rejected as nonexistent (loan 0 exists)");
    }
}
