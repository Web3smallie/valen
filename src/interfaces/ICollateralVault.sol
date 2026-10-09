// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICollateralVault {
    /// @notice Reserve collateral for a specific loan.
    /// @param loanId      The loan being collateralised.
    /// @param borrower    Address whose available balance to deduct.
    /// @param asset       ERC-20 collateral token address (USDC or EURC).
    /// @param amount      Raw token amount to lock (in the token's own decimals).
    /// @param principal   USDC principal (6 dec) — used for LTV validation.
    function reserveCollateral(
        uint256 loanId,
        address borrower,
        address asset,
        uint256 amount,
        uint256 principal
    ) external;

    function release(uint256 loanId) external;
    function seize(uint256 loanId) external;

    /// @notice Returns the primary token address (used for USDC-collateral defaulting).
    function usdc() external view returns (address);
}
