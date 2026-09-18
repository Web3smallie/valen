// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICollateralVault {
    function reserveCollateral(uint256 loanId, address borrower, uint256 amount, uint256 principal) external;
    function release(uint256 loanId) external;
    function seize(uint256 loanId) external;
}