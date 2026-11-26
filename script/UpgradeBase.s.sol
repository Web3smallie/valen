// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IOwnableLike {
    function owner() external view returns (address);
}

interface IUUPSVersion {
    function UPGRADE_INTERFACE_VERSION() external view returns (string memory);
}

/// @notice Shared helpers for the Valen in-place UUPS upgrade scripts.
///
/// SAFETY MODEL
///   - No private key, keystore password or .env value is read by these scripts.
///     The broadcaster is supplied on the command line (--account <keystore>).
///   - Every script is a no-op unless the proxy is at the exact baseline
///     implementation recorded below (verified on Arc Testnet, chain 5042002).
///   - Every script requires the broadcaster to be the proxy owner.
///   - Post-upgrade assertions revert the script run if anything unexpected
///     changed (implementation slot, owner, wiring, per-loan state snapshot).
///
/// BUILD RECIPE: always select the named profile in foundry.toml (solc 0.8.36,
/// optimizer ON runs=200, evm cancun). The default profile (optimizer OFF) makes
/// LoanRegistry 24,619 bytes, which exceeds the 24,576-byte limit Arc enforces.
///   FOUNDRY_PROFILE=upgrade forge script ...
abstract contract UpgradeBase is Script {
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;

    /// @dev Owner of all 11 proxies (EOA), read on-chain on 2026-11-26.
    address internal constant EXPECTED_OWNER = 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144;

    /// @dev ERC-1967 implementation slot.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Upper bound for loop-based per-loan snapshots (current nextLoanId is 1).
    uint256 internal constant MAX_SNAPSHOT_LOANS = 200;

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    /// @dev Pre-upgrade gate: right chain, right owner, proxy at the expected baseline.
    function _requireBaseline(address proxy, address expectedOldImpl, string memory name) internal view {
        require(block.chainid == ARC_TESTNET_CHAIN_ID, "ABORT: not Arc Testnet (chain 5042002)");
        require(IOwnableLike(proxy).owner() == EXPECTED_OWNER, string.concat("ABORT: ", name, " owner is not the expected EOA"));
        address cur = _implOf(proxy);
        require(
            cur == expectedOldImpl,
            string.concat("ABORT: ", name, " proxy is not at the expected baseline impl; found ", vm.toString(cur))
        );
        require(expectedOldImpl.code.length > 0, string.concat("ABORT: ", name, " baseline impl has no code"));
        console.log(string.concat("[OK] ", name, " baseline impl confirmed: "), cur);
    }

    /// @dev Call inside vm.startBroadcast(): the broadcaster must be the owner.
    function _requireBroadcasterIsOwner() internal {
        (, address caller,) = vm.readCallers();
        require(caller == EXPECTED_OWNER, string.concat("ABORT: broadcaster ", vm.toString(caller), " is not the proxy owner"));
    }

    /// @dev Plain UUPS upgrade with empty init calldata (no reinitializer exists in any version).
    function _upgrade(address proxy, address newImpl) internal {
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
    }

    /// @dev Post-upgrade invariants common to every contract.
    function _requirePost(address proxy, address newImpl, string memory name) internal view {
        require(newImpl.code.length > 0, string.concat("ABORT: ", name, " new impl has no code"));
        // Foundry's local EVM does not enforce EIP-170 but Arc does: catch a wrong build profile here.
        require(
            newImpl.code.length <= 24576,
            string.concat("ABORT: ", name, " new impl exceeds the 24,576-byte limit; build with FOUNDRY_PROFILE=upgrade")
        );
        require(_implOf(proxy) == newImpl, string.concat("ABORT: ", name, " implementation slot != new impl"));
        require(IOwnableLike(proxy).owner() == EXPECTED_OWNER, string.concat("ABORT: ", name, " owner changed"));
        require(
            keccak256(bytes(IUUPSVersion(proxy).UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")),
            string.concat("ABORT: ", name, " UPGRADE_INTERFACE_VERSION != 5.0.0")
        );
        // The bare implementation must have initializers disabled (owner stays zero).
        require(IOwnableLike(newImpl).owner() == address(0), string.concat("ABORT: ", name, " new impl is initializable"));
        console.log(string.concat("[OK] ", name, " post-upgrade impl slot + owner verified: "), newImpl);
    }
}
