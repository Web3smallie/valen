// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICreditRegistry {
    function getLimit(address agent) external view returns (uint256);
    function requiresApproval(uint256 amount) external view returns (bool);
    function recordRepayment(address agent, uint256 repaidAmount, bool early) external;
    function recordDefault(address agent, bool severe) external;
}