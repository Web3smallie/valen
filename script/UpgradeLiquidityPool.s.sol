// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {UpgradeBase, IOwnableLike} from "./UpgradeBase.s.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";

/// @notice Module: in-place upgrade of the LiquidityPool proxy (337cca7 -> HEAD).
///
/// WHAT CHANGES (src diff 337cca7..HEAD):
///   + fundLoan: reverts LoanDoesNotExist for unknown ids and ZeroAmount for 0,
///   + reconcileLoan: a tracked id with principalAdvanced == 0 is untracked
///     (self-heals legacy phantom slots) instead of returning silently,
///   + error LoanDoesNotExist.
///
/// NOT FIXED BY THIS UPGRADE: loan 0 is repaid but still un-reconciled on-chain
/// (finalized(0) == false, activeLoanCount == 1). reconcileLoan(0) is a separate,
/// permissionless call that is intentionally NOT part of this script.
///
/// STORAGE: identical layout (22 variables). INITIALIZER: none required.
abstract contract LiquidityPoolModule is UpgradeBase {
    address internal constant LP_PROXY = 0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061;
    address internal constant LP_OLD_IMPL = 0x828525794b195329e8F1aE501A61d7590df542c1;

    function _lpLoanCount() internal view returns (uint256 n) {
        n = LoanRegistry(address(LiquidityPool(LP_PROXY).loanRegistry())).nextLoanId();
        require(n <= MAX_SNAPSHOT_LOANS, "ABORT: too many loans for bounded snapshot");
    }

    function _lpSnap() internal view returns (bytes32) {
        LiquidityPool p = LiquidityPool(LP_PROXY);
        uint256 n = _lpLoanCount();
        bytes memory acc = abi.encode(n, p.loanRegistry(), p.loanVault(), p.usdc(), p.collateralVault());
        acc = abi.encode(acc, p.reservePool(), p.revenueRouter(), p.underwriterPool(), p.initializedLiquidity());
        acc = abi.encode(acc, p.maxActiveLoans(), p.activeLoanCount(), p.idleLedger(), p.totalDeployed());
        acc = abi.encode(acc, p.totalShares(), p.totalAssets(), p.sharePrice());
        uint256 active = p.activeLoanCount();
        for (uint256 j = 0; j < active; j++) {
            acc = abi.encode(acc, p.activeLoanIds(j));
        }
        for (uint256 i = 0; i < n; i++) {
            acc = abi.encode(acc, p.principalAdvanced(i), p.principalReturned(i), p.finalized(i));
            acc = abi.encode(acc, p.defaultRecoveryCounted(i), p.vaultSettlementCounted(i), p.lastRouterRecorded(i));
        }
        return keccak256(acc);
    }

    function _lpPre() internal view {
        _requireBaseline(LP_PROXY, LP_OLD_IMPL, "LiquidityPool");
    }

    function _lpUpgrade() internal returns (address impl) {
        impl = address(new LiquidityPool());
        _upgrade(LP_PROXY, impl);
    }

    function _lpPost(bytes32 pre, address impl) internal view {
        _requirePost(LP_PROXY, impl, "LiquidityPool");
        require(_lpSnap() == pre, "ABORT: LiquidityPool state snapshot changed across upgrade");
        console.log("[OK] LiquidityPool snapshot (wiring, ledgers, shares, per-loan accounting) unchanged");
    }
}

/// @dev   FOUNDRY_SOLC_VERSION=0.8.36 forge script script/UpgradeLiquidityPool.s.sol:UpgradeLiquidityPool \
///          --fork-url https://rpc.testnet.arc.io --sender 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144
contract UpgradeLiquidityPool is LiquidityPoolModule {
    function run() external {
        _lpPre();
        bytes32 pre = _lpSnap();

        vm.startBroadcast();
        _requireBroadcasterIsOwner();
        address impl = _lpUpgrade();
        vm.stopBroadcast();

        _lpPost(pre, impl);
        console.log("LiquidityPool new implementation:", impl);
    }

    function verifyPostUpgrade(address newImpl) external view {
        _requirePost(LP_PROXY, newImpl, "LiquidityPool");
        console.log("[OK] LiquidityPool post-upgrade checks passed");
    }

    /// @notice Read-only state fingerprint. Run BEFORE and AFTER the upgrade step; hashes must match.
    ///         forge script ... --sig "snapshot()" --rpc-url https://rpc.testnet.arc.io
    function snapshot() external view {
        console.log("LiquidityPool implementation slot:", _implOf(LP_PROXY));
        console.log("LiquidityPool owner:", IOwnableLike(LP_PROXY).owner());
        console.log("LiquidityPool snapshot hash:");
        console.logBytes32(_lpSnap());
    }
}
