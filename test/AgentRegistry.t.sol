// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";

contract AgentRegistryTest is Test {

    AgentRegistry registry;

    address owner    = address(this);
    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);
    address carol    = address(0xCA401);
    address dave     = address(0xDA4E);
    address stranger = address(0x9999);

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        registry = AgentRegistry(
            _proxy(
                address(new AgentRegistry()),
                abi.encodeCall(AgentRegistry.initialize, (owner))
            )
        );
    }

    // -------------------------------------------------------------------------
    // registerAgent
    // -------------------------------------------------------------------------

    function test_registerAgent_succeeds() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        assertEq(agentId, 1, "first agentId should be 1");
        assertEq(registry.agentOwner(agentId), alice);
        assertTrue(registry.isAuthorizedWallet(agentId, alice));
        assertEq(registry.walletToAgent(alice), agentId);
        assertEq(registry.walletCount(agentId), 1);
    }

    function test_registerAgent_incrementsNextAgentId() public {
        vm.prank(alice);
        uint256 id1 = registry.registerAgent(0);
        vm.prank(bob);
        uint256 id2 = registry.registerAgent(0);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(registry.nextAgentId(), 3);
    }

    function test_registerAgent_storesErc8004Ref() public {
        uint256 extTokenId = 42;
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(extTokenId);

        assertEq(registry.erc8004Ref(agentId), extTokenId);
    }

    function test_registerAgent_zeroErc8004RefNotStored() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);
        assertEq(registry.erc8004Ref(agentId), 0);
    }

    function test_registerAgent_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit AgentRegistry.AgentRegistered(1, alice, 99);
        registry.registerAgent(99);
    }

    function test_registerAgent_duplicateWalletReverts() public {
        vm.prank(alice);
        registry.registerAgent(0);

        // alice is already registered — second call must revert
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.WalletAlreadyRegistered.selector);
        registry.registerAgent(0);
    }

    // -------------------------------------------------------------------------
    // addWallet
    // -------------------------------------------------------------------------

    function test_addWallet_succeeds() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        registry.addWallet(agentId, bob);

        assertTrue(registry.isAuthorizedWallet(agentId, bob));
        assertEq(registry.walletToAgent(bob), agentId);
        assertEq(registry.walletCount(agentId), 2);
    }

    function test_addWallet_emitsEvent() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.WalletAdded(agentId, bob);
        registry.addWallet(agentId, bob);
    }

    function test_addWallet_nonOwnerReverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(stranger);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        registry.addWallet(agentId, bob);
    }

    function test_addWallet_zeroAddressReverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        vm.expectRevert(AgentRegistry.ZeroAddress.selector);
        registry.addWallet(agentId, address(0));
    }

    function test_addWallet_alreadyRegisteredToSameAgentReverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);
        // alice is already authorized for agentId — adding again should revert
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.WalletAlreadyRegistered.selector);
        registry.addWallet(agentId, alice);
    }

    function test_addWallet_alreadyRegisteredToOtherAgentReverts() public {
        vm.prank(alice);
        uint256 agentId1 = registry.registerAgent(0);
        vm.prank(bob);
        uint256 agentId2 = registry.registerAgent(0);
        assertGt(agentId2, agentId1); // suppress unused-variable warning; agentId2 is bob's agent

        // Try to add bob (already registered under agentId2) to agentId1
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.WalletAlreadyRegistered.selector);
        registry.addWallet(agentId1, bob);
    }

    function test_addWallet_nonExistentAgentReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.AgentDoesNotExist.selector);
        registry.addWallet(999, bob);
    }

    // -------------------------------------------------------------------------
    // removeWallet
    // -------------------------------------------------------------------------

    function test_removeWallet_succeeds() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);
        vm.prank(alice);
        registry.addWallet(agentId, bob);

        vm.prank(alice);
        registry.removeWallet(agentId, bob);

        assertFalse(registry.isAuthorizedWallet(agentId, bob));
        assertEq(registry.walletToAgent(bob), 0);
        assertEq(registry.walletCount(agentId), 1);
    }

    function test_removeWallet_emitsEvent() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);
        vm.prank(alice);
        registry.addWallet(agentId, bob);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit AgentRegistry.WalletRemoved(agentId, bob);
        registry.removeWallet(agentId, bob);
    }

    function test_removeWallet_nonOwnerReverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);
        vm.prank(alice);
        registry.addWallet(agentId, bob);

        vm.prank(stranger);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        registry.removeWallet(agentId, bob);
    }

    function test_removeWallet_notAuthorizedReverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        vm.expectRevert(AgentRegistry.WalletNotAuthorized.selector);
        registry.removeWallet(agentId, carol); // carol was never added
    }

    function test_removeLastWalletReverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        // alice is the only wallet — removing her should revert
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.CannotRemoveLastWallet.selector);
        registry.removeWallet(agentId, alice);
    }

    function test_removeWallet_zeroAddressReverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        vm.expectRevert(AgentRegistry.ZeroAddress.selector);
        registry.removeWallet(agentId, address(0));
    }

    // -------------------------------------------------------------------------
    // Wallet rotation
    // -------------------------------------------------------------------------

    function test_walletRotation_addThenRemove() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        // Add bob
        vm.prank(alice);
        registry.addWallet(agentId, bob);
        assertTrue(registry.isAuthorizedWallet(agentId, bob));

        // Remove alice (bob still authorized — count = 1)
        vm.prank(alice);
        registry.removeWallet(agentId, alice);

        assertFalse(registry.isAuthorizedWallet(agentId, alice));
        assertEq(registry.walletToAgent(alice), 0);
        assertTrue(registry.isAuthorizedWallet(agentId, bob));
        assertEq(registry.walletToAgent(bob), agentId);
        assertEq(registry.walletCount(agentId), 1);
    }

    function test_walletRotation_removedWalletCanBeReRegistered() public {
        // After removal, the wallet's slot in walletToAgent is cleared,
        // so it can be added to a different agent.
        vm.prank(alice);
        uint256 agentId1 = registry.registerAgent(0);
        vm.prank(alice);
        registry.addWallet(agentId1, bob);
        vm.prank(alice);
        registry.removeWallet(agentId1, bob);

        // bob is now free — register it under a new agent
        vm.prank(bob);
        uint256 agentId2 = registry.registerAgent(0);
        assertTrue(registry.isAuthorizedWallet(agentId2, bob));
        assertEq(registry.walletToAgent(bob), agentId2);
    }

    // -------------------------------------------------------------------------
    // isAuthorizedWallet / getAgentId
    // -------------------------------------------------------------------------

    function test_isAuthorizedWallet_falseForUnknown() public view {
        assertFalse(registry.isAuthorizedWallet(1, stranger));
    }

    function test_getAgentId_returnsZeroForUnknown() public view {
        assertEq(registry.getAgentId(stranger), 0);
    }

    function test_getAgentId_returnsCorrectId() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);
        assertEq(registry.getAgentId(alice), agentId);
    }

    // -------------------------------------------------------------------------
    // transferAgentOwnership
    // -------------------------------------------------------------------------

    function test_transferAgentOwnership_succeeds() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        registry.transferAgentOwnership(agentId, bob);

        assertEq(registry.agentOwner(agentId), bob);
    }

    function test_transferAgentOwnership_emitsEvent() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        vm.expectEmit(true, true, true, false);
        emit AgentRegistry.AgentOwnershipTransferred(agentId, alice, bob);
        registry.transferAgentOwnership(agentId, bob);
    }

    function test_transferAgentOwnership_newOwnerCanAddWallet() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        registry.transferAgentOwnership(agentId, bob);

        // bob is now owner; alice no longer is
        vm.prank(bob);
        registry.addWallet(agentId, carol);
        assertTrue(registry.isAuthorizedWallet(agentId, carol));
    }

    function test_transferAgentOwnership_oldOwnerCanNoLongerMutate() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        registry.transferAgentOwnership(agentId, bob);

        vm.prank(alice);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        registry.addWallet(agentId, carol);
    }

    function test_transferAgentOwnership_doesNotAffectWalletAuth() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        registry.transferAgentOwnership(agentId, bob);

        // alice's wallet authorization is unchanged by the ownership transfer
        assertTrue(registry.isAuthorizedWallet(agentId, alice));
        assertEq(registry.walletToAgent(alice), agentId);
    }

    function test_transferAgentOwnership_nonOwnerReverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(stranger);
        vm.expectRevert(AgentRegistry.NotAgentOwner.selector);
        registry.transferAgentOwnership(agentId, stranger);
    }

    function test_transferAgentOwnership_zeroAddressReverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(0);

        vm.prank(alice);
        vm.expectRevert(AgentRegistry.ZeroAddress.selector);
        registry.transferAgentOwnership(agentId, address(0));
    }

    function test_transferAgentOwnership_nonExistentAgentReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.AgentDoesNotExist.selector);
        registry.transferAgentOwnership(999, bob);
    }

    // -------------------------------------------------------------------------
    // erc8004Ref — informational only
    // -------------------------------------------------------------------------

    function test_erc8004Ref_storedCorrectly() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(777);
        assertEq(registry.erc8004Ref(agentId), 777);
    }

    function test_erc8004Ref_doesNotConferAuthorization() public {
        // ERC-8004 ref is purely informational — it does not authorize any wallet
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(42);

        // An address that holds ERC-8004 token 42 externally has no implicit
        // authorization in Valen's AgentRegistry.
        address erc8004Holder = address(0x8004);
        assertFalse(registry.isAuthorizedWallet(agentId, erc8004Holder));
        assertEq(registry.walletToAgent(erc8004Holder), 0);
    }

    // -------------------------------------------------------------------------
    // UUPS upgrade guard
    // -------------------------------------------------------------------------

    function test_upgradeOnlyOwner() public {
        AgentRegistry newImpl = new AgentRegistry();
        // Non-owner cannot upgrade
        vm.prank(stranger);
        vm.expectRevert();
        registry.upgradeToAndCall(address(newImpl), "");
    }

    // -------------------------------------------------------------------------
    // initialize guard
    // -------------------------------------------------------------------------

    function test_cannotInitializeTwice() public {
        vm.expectRevert();
        registry.initialize(owner);
    }
}
