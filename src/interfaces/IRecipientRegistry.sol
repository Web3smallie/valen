// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRecipientRegistry {
    function isApproved(address recipient) external view returns (bool);
}