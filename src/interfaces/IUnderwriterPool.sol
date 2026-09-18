// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUnderwriterPool {
    function reserveStake(uint256 loanId, address underwriter, address borrower, uint256 amount) external;
    function release(uint256 loanId) external;
    function seize(uint256 loanId) external;
    function committedTo(address underwriter, address borrower) external view returns (uint256);
}