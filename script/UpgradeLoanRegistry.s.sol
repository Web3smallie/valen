// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {UpgradeBase, IOwnableLike} from "./UpgradeBase.s.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";

/// @notice Module: in-place upgrade of the LoanRegistry proxy (abd4225 -> HEAD).
///
/// WHAT CHANGES (src diff abd4225..HEAD):
///   + Loan struct gains `bool directDisbursement` as its LAST member
///     (struct member slot 16; every existing loan reads false).
///   + requestLoan takes a 16-field LoanProposal -> NEW SELECTOR 0x1e0af345
///     (old selector 0xb5fd236d stops working; all writers must switch).
///   + getDirectDisbursement(uint256), errors LoanDoesNotExist, ZeroPrincipal.
///   + existence guard on approveLoan/markFunded/markMilestoneReleased/
///     markDefault/markRepaid; requestLoan rejects zero principal.
///
/// STORAGE: `forge inspect LoanRegistry storage-layout` is identical except one
/// appended member inside the `_loans` mapping value struct (no top-level slot moves).
/// INITIALIZER: none required (no reinitializer in baseline or HEAD).
abstract contract LoanRegistryModule is UpgradeBase {
    address internal constant LR_PROXY = 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d;
    address internal constant LR_OLD_IMPL = 0xd47496361e5C485611718BD06065971691D2ba07;

    /// @dev `_loans` mapping base slot (forge inspect, baseline and HEAD) and the
    ///      struct member index of the appended field.
    uint256 internal constant LR_LOANS_SLOT = 9;
    uint256 internal constant LR_NEW_MEMBER_INDEX = 16;

    function _lrLoanCount() internal view returns (uint256 n) {
        n = LoanRegistry(LR_PROXY).nextLoanId();
        require(n <= MAX_SNAPSHOT_LOANS, "ABORT: too many loans for bounded snapshot");
    }

    function _lrNewMemberSlot(uint256 loanId) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(loanId, LR_LOANS_SLOT))) + LR_NEW_MEMBER_INDEX);
    }

    /// @dev Hash of everything that exists in BOTH the old and new ABI.
    function _lrSnap() internal view returns (bytes32) {
        LoanRegistry r = LoanRegistry(LR_PROXY);
        uint256 n = _lrLoanCount();
        bytes memory acc = abi.encode(n, r.vault(), r.router(), r.creditRegistry(), r.agentRegistry());
        acc = abi.encode(acc, r.collateralVault(), r.underwriterPool(), r.recipientRegistry(), r.reservePool());
        acc = abi.encode(acc, r.minDuration(), r.maxDuration(), r.defaultGracePeriod(), r.collateralApprovalThreshold());
        for (uint256 i = 0; i < n; i++) {
            acc = abi.encode(acc, r.getLoan(i), r.getMilestones(i), r.getPermittedRecipients(i));
            acc = abi.encode(acc, r.getBudget(i), r.getCollateralAmount(i), r.getCollateralAsset(i));
            acc = abi.encode(acc, r.getUnderwriterAmount(i), r.outstandingPrincipal(r.getLoan(i).agentId));
        }
        return keccak256(acc);
    }

    function _lrPre() internal view {
        _requireBaseline(LR_PROXY, LR_OLD_IMPL, "LoanRegistry");
        uint256 n = _lrLoanCount();
        for (uint256 i = 0; i < n; i++) {
            require(vm.load(LR_PROXY, _lrNewMemberSlot(i)) == bytes32(0), "ABORT: appended struct slot already in use");
        }
        console.log("[OK] LoanRegistry appended struct member slot is empty for all existing loans:", n);
    }

    /// @dev Deploys the new implementation and swaps the proxy. Call inside a broadcast.
    function _lrUpgrade() internal returns (address impl) {
        impl = address(new LoanRegistry());
        _upgrade(LR_PROXY, impl);
    }

    function _lrPost(bytes32 pre, address impl) internal view {
        _requirePost(LR_PROXY, impl, "LoanRegistry");
        require(_lrSnap() == pre, "ABORT: LoanRegistry state snapshot changed across upgrade");
        _lrNewFeatureChecks();
        console.log("[OK] LoanRegistry snapshot (wiring, params, every loan) unchanged");
    }

    function _lrNewFeatureChecks() internal view {
        uint256 n = _lrLoanCount();
        for (uint256 i = 0; i < n; i++) {
            require(!LoanRegistry(LR_PROXY).getDirectDisbursement(i), "ABORT: pre-existing loan reads directDisbursement=true");
            require(vm.load(LR_PROXY, _lrNewMemberSlot(i)) == bytes32(0), "ABORT: appended struct slot changed");
        }
    }
}

/// @dev   FOUNDRY_SOLC_VERSION=0.8.36 forge script script/UpgradeLoanRegistry.s.sol:UpgradeLoanRegistry \
///          --fork-url https://rpc.testnet.arc.io --sender 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144        (dry run)
contract UpgradeLoanRegistry is LoanRegistryModule {
    function run() external {
        _lrPre();
        bytes32 pre = _lrSnap();

        vm.startBroadcast();
        _requireBroadcasterIsOwner();
        address impl = _lrUpgrade();
        vm.stopBroadcast();

        _lrPost(pre, impl);
        console.log("LoanRegistry new implementation:", impl);
    }

    /// @notice Read-only check to run AFTER a real broadcast:
    ///         forge script ... --sig "verifyPostUpgrade(address)" <newImpl> --rpc-url ...
    function verifyPostUpgrade(address newImpl) external view {
        _requirePost(LR_PROXY, newImpl, "LoanRegistry");
        _lrNewFeatureChecks();
        console.log("[OK] LoanRegistry post-upgrade checks passed");
    }

    /// @notice Read-only state fingerprint (wiring, parameters, every existing loan).
    ///         Run it BEFORE and AFTER the upgrade step: both hashes must be identical.
    ///         forge script ... --sig "snapshot()" --rpc-url https://rpc.testnet.arc.io
    function snapshot() external view {
        console.log("LoanRegistry implementation slot:", _implOf(LR_PROXY));
        console.log("LoanRegistry owner:", IOwnableLike(LR_PROXY).owner());
        console.log("LoanRegistry nextLoanId:", _lrLoanCount());
        console.log("LoanRegistry snapshot hash:");
        console.logBytes32(_lrSnap());
    }
}
