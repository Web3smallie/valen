// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {LoanRegistryModule} from "./UpgradeLoanRegistry.s.sol";
import {LoanVaultModule} from "./UpgradeLoanVault.s.sol";
import {LiquidityPoolModule} from "./UpgradeLiquidityPool.s.sol";
import {RevenueRouterModule} from "./UpgradeRevenueRouter.s.sol";

/// @notice Ordered upgrade of the four changed contracts in ONE broadcast session:
///           1. LoanRegistry   (must be first: LoanVault depends on it)
///           2. LoanVault
///           3. LiquidityPool
///           4. RevenueRouter
///         Eight transactions in total: four implementation deployments and four
///         upgradeToAndCall calls, interleaved in the order above.
///
/// All baseline checks for all four proxies run BEFORE vm.startBroadcast(), so a
/// wrong baseline aborts the whole run before any transaction exists.
///
/// NOT USED BY THE RUNBOOK. The approved runbook upgrades ONE contract per step
/// (UpgradeLoanRegistry, UpgradeLoanVault, UpgradeLiquidityPool, UpgradeRevenueRouter)
/// so the owner can verify state between steps. This script is kept only to
/// simulate the whole sequence in a single fork run. Do not broadcast it.
///
/// DRY RUN (no --broadcast; simulates the full sequence against live state):
///   FOUNDRY_PROFILE=upgrade forge script script/UpgradeAll.s.sol:UpgradeAll \
///     --fork-url https://rpc.testnet.arc.io --sender 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144
contract UpgradeAll is LoanRegistryModule, LoanVaultModule, LiquidityPoolModule, RevenueRouterModule {
    function run() external {
        // ---- 1. Preconditions for every proxy (no transactions yet) ----------
        _lrPre();
        _requireBaseline(LV_PROXY, LV_OLD_IMPL, "LoanVault");
        _lpPre();
        _rrPre();

        bytes32 lrPre = _lrSnap();
        bytes32 lvPre = _lvSnap();
        bytes32 lpPre = _lpSnap();
        bytes32 rrPre = _rrSnap();

        // ---- 2. Upgrades, in dependency order --------------------------------
        vm.startBroadcast();
        _requireBroadcasterIsOwner();

        address lrImpl = _lrUpgrade();
        _lvPre(); // ordering guard: registry must now expose getDirectDisbursement()
        address lvImpl = _lvUpgrade();
        address lpImpl = _lpUpgrade();
        address rrImpl = _rrUpgrade();

        vm.stopBroadcast();

        // ---- 3. Post-upgrade assertions --------------------------------------
        _lrPost(lrPre, lrImpl);
        _lvPost(lvPre, lvImpl);
        _lpPost(lpPre, lpImpl);
        _rrPost(rrPre, rrImpl);

        console.log("=== NEW IMPLEMENTATIONS (record these) ===");
        console.log("LoanRegistry   :", lrImpl);
        console.log("LoanVault      :", lvImpl);
        console.log("LiquidityPool  :", lpImpl);
        console.log("RevenueRouter  :", rrImpl);
    }
}
