// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiquidityPool {
    function fundLoan(uint256 loanId, uint256 amount) external;
}