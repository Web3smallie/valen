// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {UpgradeBase, IOwnableLike} from "./UpgradeBase.s.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";

/// @notice Module: in-place upgrade of the LoanVault proxy (abd4225 -> HEAD).
///
/// WHAT CHANGES (src diff abd4225..HEAD):
///   + direct-disbursement path in fundLoan/fundFromPool (full principal forwarded
///     to creditWallet; lockedAmount stays 0), event DirectDisbursementSent,
///   + releaseMilestone reverts DirectLoanCannotReleaseMilestone for direct loans,
///   + LoanDoesNotExist guards on fundLoan/fundFromPool/releaseMilestone/settleExpiredLoan.
///
/// ORDERING (docs/v4-upgrade-runbook.md section 1): the new vault calls
/// registry.getDirectDisbursement(), which exists only on the NEW LoanRegistry.
/// Upgrade LoanRegistry FIRST. This module refuses to run otherwise.
///
/// STORAGE: identical layout (6 variables). INITIALIZER: none required.
abstract contract LoanVaultModule is UpgradeBase {
    address internal constant LV_PROXY = 0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19;
    address internal constant LV_OLD_IMPL = 0xa698D80e5cAf0B4B5033Cd8091f1a37f98534537;
    address internal constant LV_REGISTRY = 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d;

    function _lvLoanCount() internal view returns (uint256 n) {
        n = LoanRegistry(LV_REGISTRY).nextLoanId();
        require(n <= MAX_SNAPSHOT_LOANS, "ABORT: too many loans for bounded snapshot");
    }

    function _lvSnap() internal view returns (bytes32) {
        LoanVault v = LoanVault(LV_PROXY);
        uint256 n = _lvLoanCount();
        bytes memory acc = abi.encode(n, v.registry(), v.usdc(), v.liquidityPool());
        for (uint256 i = 0; i < n; i++) {
            acc = abi.encode(acc, v.lockedAmount(i), v.settledDefaultAmount(i));
        }
        return keccak256(acc);
    }

    function _lvPre() internal view {
        _requireBaseline(LV_PROXY, LV_OLD_IMPL, "LoanVault");
        require(address(LoanVault(LV_PROXY).registry()) == LV_REGISTRY, "ABORT: vault registry is not the LoanRegistry proxy");
        // Ordering guard: the registry must already expose getDirectDisbursement().
        (bool ok, bytes memory data) = LV_REGISTRY.staticcall(abi.encodeWithSignature("getDirectDisbursement(uint256)", uint256(0)));
        require(ok && data.length == 32, "ABORT: LoanRegistry is not upgraded yet. Upgrade LoanRegistry BEFORE LoanVault.");
        console.log("[OK] ordering guard: LoanRegistry already exposes getDirectDisbursement()");
    }

    function _lvUpgrade() internal returns (address impl) {
        impl = address(new LoanVault());
        _upgrade(LV_PROXY, impl);
    }

    function _lvPost(bytes32 pre, address impl) internal view {
        _requirePost(LV_PROXY, impl, "LoanVault");
        require(_lvSnap() == pre, "ABORT: LoanVault state snapshot changed across upgrade");
        console.log("[OK] LoanVault snapshot (wiring, lockedAmount, settledDefaultAmount per loan) unchanged");
    }
}

/// @dev   FOUNDRY_SOLC_VERSION=0.8.36 forge script script/UpgradeLoanVault.s.sol:UpgradeLoanVault \
///          --fork-url https://rpc.testnet.arc.io --sender 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144
contract UpgradeLoanVault is LoanVaultModule {
    function run() external {
        _lvPre();
        bytes32 pre = _lvSnap();

        vm.startBroadcast();
        _requireBroadcasterIsOwner();
        address impl = _lvUpgrade();
        vm.stopBroadcast();

        _lvPost(pre, impl);
        console.log("LoanVault new implementation:", impl);
    }

    function verifyPostUpgrade(address newImpl) external view {
        _requirePost(LV_PROXY, newImpl, "LoanVault");
        console.log("[OK] LoanVault post-upgrade checks passed");
    }

    /// @notice Read-only state fingerprint. Run BEFORE and AFTER the upgrade step; hashes must match.
    ///         forge script ... --sig "snapshot()" --rpc-url https://rpc.testnet.arc.io
    function snapshot() external view {
        console.log("LoanVault implementation slot:", _implOf(LV_PROXY));
        console.log("LoanVault owner:", IOwnableLike(LV_PROXY).owner());
        console.log("LoanVault snapshot hash:");
        console.logBytes32(_lvSnap());
    }
}
