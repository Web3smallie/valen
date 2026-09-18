// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IRecipientRegistry} from "./interfaces/IRecipientRegistry.sol";

/// @title RecipientRegistry
/// @notice Admin-maintained allowlist of addresses eligible to receive
///         loan proceeds. Closes the gap where a borrower could self-declare
///         their own alt wallet (or a fake "provider") as an approved
///         recipient in their own proposal — recipients must now already
///         exist in this registry before a proposal referencing them can
///         even be submitted.
contract RecipientRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable, IRecipientRegistry {
    struct RecipientInfo {
        bool approved;
        bytes32 categoryId; // informational only, not cross-checked against budget yet
        string label;       // human-readable name for dashboards, e.g. "AWS Compute"
    }

    mapping(address => RecipientInfo) public recipients;

    event RecipientApproved(address indexed recipient, bytes32 categoryId, string label);
    event RecipientRevoked(address indexed recipient);

    error ZeroAddress();
    error AlreadyApproved();
    error NotApproved();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    function approveRecipient(address recipient, bytes32 categoryId, string calldata label) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipients[recipient].approved) revert AlreadyApproved();
        recipients[recipient] = RecipientInfo({approved: true, categoryId: categoryId, label: label});
        emit RecipientApproved(recipient, categoryId, label);
    }

    function revokeRecipient(address recipient) external onlyOwner {
        if (!recipients[recipient].approved) revert NotApproved();
        recipients[recipient].approved = false;
        emit RecipientRevoked(recipient);
    }

    function isApproved(address recipient) external view returns (bool) {
        return recipients[recipient].approved;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}