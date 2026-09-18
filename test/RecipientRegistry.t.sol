// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";

contract RecipientRegistryTest is Test {
    RecipientRegistry registry;

    address owner = address(this);
    address nonOwner = address(0xBAD);
    address recipient = address(0xD00D);

    function setUp() public {
        address proxy = Upgrades.deployUUPSProxy(
            "RecipientRegistry.sol",
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        );
        registry = RecipientRegistry(proxy);
    }

    function test_ApproveRecipient() public {
        registry.approveRecipient(recipient, keccak256("COMPUTE"), "AWS Compute");
        assertTrue(registry.isApproved(recipient));
    }

    function test_UnapprovedRecipientReturnsFalse() public view {
        assertFalse(registry.isApproved(recipient));
    }

    function test_RevertsOnZeroAddressApproval() public {
        vm.expectRevert(RecipientRegistry.ZeroAddress.selector);
        registry.approveRecipient(address(0), keccak256("COMPUTE"), "Invalid");
    }

    function test_RevertsOnDoubleApproval() public {
        registry.approveRecipient(recipient, keccak256("COMPUTE"), "AWS Compute");
        vm.expectRevert(RecipientRegistry.AlreadyApproved.selector);
        registry.approveRecipient(recipient, keccak256("COMPUTE"), "AWS Compute");
    }

    function test_RevokeRecipient() public {
        registry.approveRecipient(recipient, keccak256("COMPUTE"), "AWS Compute");
        registry.revokeRecipient(recipient);
        assertFalse(registry.isApproved(recipient));
    }

    function test_RevertsOnRevokingUnapproved() public {
        vm.expectRevert(RecipientRegistry.NotApproved.selector);
        registry.revokeRecipient(recipient);
    }

    function test_OnlyOwnerCanApprove() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.approveRecipient(recipient, keccak256("COMPUTE"), "AWS Compute");
    }

    function test_OnlyOwnerCanRevoke() public {
        registry.approveRecipient(recipient, keccak256("COMPUTE"), "AWS Compute");
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.revokeRecipient(recipient);
    }
}