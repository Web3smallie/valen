// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {UpgradeBase, IOwnableLike} from "./UpgradeBase.s.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";

/// @notice Module: in-place upgrade of the RevenueRouter proxy (337cca7 -> HEAD).
///
/// WHAT CHANGES (src diff 337cca7..HEAD): payRevenue and repayLoan revert
/// LoanDoesNotExist for loanId >= registry.nextLoanId(). New error only; no new
/// storage, no new external function. STORAGE: identical (11 variables).
/// INITIALIZER: none (this repo's RevenueRouter has no reinitializer / migration state).
abstract contract RevenueRouterModule is UpgradeBase {
    address internal constant RR_PROXY = 0xE0B9b39E72f73f2d85D77a1e24a2f319246de822;
    address internal constant RR_OLD_IMPL = 0x394D9f57F00f27B19b1549e23021Efed9CD7be38;

    function _rrLoanCount() internal view returns (uint256 n) {
        n = LoanRegistry(address(RevenueRouter(RR_PROXY).registry())).nextLoanId();
        require(n <= MAX_SNAPSHOT_LOANS, "ABORT: too many loans for bounded snapshot");
    }

    function _rrSnap() internal view returns (bytes32) {
        RevenueRouter r = RevenueRouter(RR_PROXY);
        uint256 n = _rrLoanCount();
        bytes memory acc = abi.encode(n, r.registry(), r.agentRegistry(), r.creditRegistry());
        acc = abi.encode(acc, r.usdc(), r.reservePool(), r.reserveBps());
        for (uint256 i = 0; i < n; i++) {
            acc = abi.encode(acc, r.totalRecovered(i), r.repaidHandled(i), r.reserveRepaid(i));
            acc = abi.encode(acc, r.poolRecovered(i), r.isFullyRepaid(i));
        }
        return keccak256(acc);
    }

    function _rrPre() internal view {
        _requireBaseline(RR_PROXY, RR_OLD_IMPL, "RevenueRouter");
    }

    function _rrUpgrade() internal returns (address impl) {
        impl = address(new RevenueRouter());
        _upgrade(RR_PROXY, impl);
    }

    function _rrPost(bytes32 pre, address impl) internal view {
        _requirePost(RR_PROXY, impl, "RevenueRouter");
        require(_rrSnap() == pre, "ABORT: RevenueRouter state snapshot changed across upgrade");
        console.log("[OK] RevenueRouter snapshot (wiring, reserveBps, per-loan recovery state) unchanged");
    }
}

/// @dev   FOUNDRY_SOLC_VERSION=0.8.36 forge script script/UpgradeRevenueRouter.s.sol:UpgradeRevenueRouter \
///          --fork-url https://rpc.testnet.arc.io --sender 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144
contract UpgradeRevenueRouter is RevenueRouterModule {
    function run() external {
        _rrPre();
        bytes32 pre = _rrSnap();

        vm.startBroadcast();
        _requireBroadcasterIsOwner();
        address impl = _rrUpgrade();
        vm.stopBroadcast();

        _rrPost(pre, impl);
        console.log("RevenueRouter new implementation:", impl);
    }

    function verifyPostUpgrade(address newImpl) external view {
        _requirePost(RR_PROXY, newImpl, "RevenueRouter");
        console.log("[OK] RevenueRouter post-upgrade checks passed");
    }

    /// @notice Read-only state fingerprint. Run BEFORE and AFTER the upgrade step; hashes must match.
    ///         forge script ... --sig "snapshot()" --rpc-url https://rpc.testnet.arc.io
    function snapshot() external view {
        console.log("RevenueRouter implementation slot:", _implOf(RR_PROXY));
        console.log("RevenueRouter owner:", IOwnableLike(RR_PROXY).owner());
        console.log("RevenueRouter snapshot hash:");
        console.logBytes32(_rrSnap());
    }
}
