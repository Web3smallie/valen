// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IReservePool {
    function recordContribution(uint256 loanId, uint256 amount) external;
    function payout(uint256 loanId, address lender, uint256 shortfall) external returns (uint256 paid);
}