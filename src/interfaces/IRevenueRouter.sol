// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRevenueRouter {
    function totalRecovered(uint256 loanId) external view returns (uint256);
    function isFullyRepaid(uint256 loanId) external view returns (bool);
}