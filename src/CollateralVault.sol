// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable}      from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable}    from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20}             from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}          from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanRegistry}      from "./interfaces/ILoanRegistry.sol";

/// @title CollateralVault
/// @notice Multi-asset collateral vault. USDC is the unit of account for LTV
///         calculations; each approved collateral asset has an admin-set USD
///         price (18-decimal, per 1 whole token) and its own decimals recorded
///         so that LTV checks are always done in a common denomination.
///
///         V1 approved assets: USDC (6 dec, price = 1e18) and
///                             EURC (6 dec, price set by owner ~1.08e18).
///
///         Borrowers deposit a specific asset, which is tracked per
///         (borrower, asset). On default, the seized asset is transferred
///         to the lender in its original token.
contract CollateralVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct AssetConfig {
        bool    approved;
        uint8   decimals;    // native decimals of this token
        uint256 usdPriceE18; // USD value of 1 whole token, scaled by 1e18
                             // e.g. USDC: 1e18, EURC: 1.08e18 -> 1_080_000_000_000_000_000
    }

    struct Reservation {
        address borrower;
        address asset;    // collateral token address
        uint256 amount;   // raw token units (in asset's own decimals)
        bool    resolved;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    // Legacy single-asset slot — preserved for UUPS storage layout compatibility.
    // Holds the primary USDC address after initialize(); also used as the
    // canonical USDC reference for the default asset config.
    IERC20 public usdc;
    ILoanRegistry public registry;
    uint16 public maxLTVBps; // global LTV cap e.g. 6600 = 66%

    // Per-borrower, per-asset available balances.
    // availableBalance[borrower][asset] = raw token units
    mapping(address => mapping(address => uint256)) public availableBalance;

    mapping(uint256 => Reservation) public reservations;

    // Approved collateral assets and their price/decimal configs.
    mapping(address => AssetConfig) public assetConfigs;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Deposited(address indexed borrower, address indexed asset, uint256 amount);
    event Withdrawn(address indexed borrower, address indexed asset, uint256 amount);
    event Reserved(uint256 indexed loanId, address indexed borrower, address indexed asset, uint256 amount);
    event Released(uint256 indexed loanId, address indexed borrower, address indexed asset, uint256 amount);
    event Seized(uint256 indexed loanId, address indexed lender, address indexed asset, uint256 amount);
    event MaxLTVSet(uint16 maxLTVBps);
    event AssetConfigSet(address indexed asset, bool approved, uint8 decimals, uint256 usdPriceE18);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error UnapprovedAsset();
    error InsufficientAvailableBalance();
    error NotRegistry();
    error AlreadyReserved();
    error NoReservation();
    error AlreadyResolved();
    error InsufficientCollateralForLTV();
    error ZeroPrice();
    error PriceOutOfBounds();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) revert NotRegistry();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor / initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the vault.
    /// @param initialOwner  Contract owner.
    /// @param _usdc         Arc USDC address (approved automatically at price 1e18, 6 dec).
    /// @param _registry     LoanRegistry address.
    /// @param _maxLTVBps    Global LTV ceiling in basis points (e.g. 6600 = 66%).
    function initialize(address initialOwner, address _usdc, address _registry, uint16 _maxLTVBps)
        external
        initializer
    {
        if (_usdc == address(0) || _registry == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        usdc     = IERC20(_usdc);
        registry = ILoanRegistry(_registry);
        maxLTVBps = _maxLTVBps;

        // Approve USDC as collateral at 1:1 USD parity, 6 decimals.
        assetConfigs[_usdc] = AssetConfig({approved: true, decimals: 6, usdPriceE18: 1e18});
        emit AssetConfigSet(_usdc, true, 6, 1e18);
    }

    // -------------------------------------------------------------------------
    // Owner setters
    // -------------------------------------------------------------------------

    function setMaxLTV(uint16 _maxLTVBps) external onlyOwner {
        maxLTVBps = _maxLTVBps;
        emit MaxLTVSet(_maxLTVBps);
    }

    /// @notice Add or update a collateral asset.
    /// @param asset        ERC-20 token address.
    /// @param approved     Whether deposits are accepted for this asset.
    /// @param decimals     Token's native decimals (must match the real contract).
    /// @param usdPriceE18  USD value of 1 whole token scaled by 1e18.
    ///                     Example: EURC at 1.08 USD => 1_080_000_000_000_000_000.
    function setAssetConfig(address asset, bool approved, uint8 decimals, uint256 usdPriceE18)
        external
        onlyOwner
    {
        if (asset == address(0)) revert ZeroAddress();
        if (approved && usdPriceE18 == 0) revert ZeroPrice();
        // Sanity bounds: price must be between $0.50 and $100 per whole token.
        // Prevents misconfiguration that would make LTV trivially bypassable
        // (price too high → near-zero collateral required) or permanently brick
        // deposits (price too low → astronomically large collateral required).
        if (approved && (usdPriceE18 < 0.5e18 || usdPriceE18 > 100e18)) revert PriceOutOfBounds();
        assetConfigs[asset] = AssetConfig({approved: approved, decimals: decimals, usdPriceE18: usdPriceE18});
        emit AssetConfigSet(asset, approved, decimals, usdPriceE18);
    }

    // -------------------------------------------------------------------------
    // LTV helpers
    // -------------------------------------------------------------------------

    /// @notice Required collateral in USDC-equivalent units (6 dec) for a given
    ///         principal (also 6 dec). Pure USDC-denominated view.
    function requiredCollateralUsdc(uint256 principal) public view returns (uint256) {
        return (principal * 10000) / maxLTVBps;
    }

    /// @notice Required raw token units of `asset` to back `principal` USDC.
    ///         Accounts for asset price and decimal offset.
    function requiredCollateral(uint256 principal, address asset) public view returns (uint256) {
        AssetConfig storage cfg = assetConfigs[asset];
        if (!cfg.approved) revert UnapprovedAsset();
        // required_usdc_units  = (principal * 10000) / maxLTVBps          [6 dec]
        // required_asset_units = required_usdc_units * 10^assetDecimals
        //                        * 1e18 / (usdPriceE18 * 10^6)
        //                      = required_usdc_units * 10^assetDecimals
        //                        / (usdPriceE18 / 1e12)
        // For USDC  (6 dec, price=1e18): simplifies to (principal * 10000) / maxLTVBps  [correct]
        // For EURC  (6 dec, price=1.08e18): slightly less EURC needed than USDC
        uint256 requiredUsdc6 = requiredCollateralUsdc(principal);
        // Scale: requiredUsdc6 is in 1e-6 USD units.
        // asset is in 10^(-assetDecimals) token units.
        // required_asset = requiredUsdc6 * 1e18 * 10^assetDecimals / (usdPriceE18 * 1e6)
        return (requiredUsdc6 * 1e18 * (10 ** uint256(cfg.decimals))) / (cfg.usdPriceE18 * 1e6);
    }

    /// @notice Convenience: requiredCollateral for USDC collateral (backwards compat).
    function requiredCollateral(uint256 principal) public view returns (uint256) {
        return requiredCollateral(principal, address(usdc));
    }

    // -------------------------------------------------------------------------
    // Deposit / withdraw
    // -------------------------------------------------------------------------

    /// @notice Deposit `asset` as collateral. Asset must be approved.
    function depositCollateral(address asset, uint256 amount) external {
        if (!assetConfigs[asset].approved) revert UnapprovedAsset();
        if (amount == 0) revert ZeroAmount();
        availableBalance[msg.sender][asset] += amount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, asset, amount);
    }

    /// @notice Backwards-compatible: deposit USDC collateral.
    function depositCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        availableBalance[msg.sender][address(usdc)] += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, address(usdc), amount);
    }

    /// @notice Withdraw previously deposited collateral that is not reserved.
    function withdrawCollateral(address asset, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (availableBalance[msg.sender][asset] < amount) revert InsufficientAvailableBalance();
        availableBalance[msg.sender][asset] -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, asset, amount);
    }

    /// @notice Backwards-compatible: withdraw USDC collateral.
    function withdrawCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (availableBalance[msg.sender][address(usdc)] < amount) revert InsufficientAvailableBalance();
        availableBalance[msg.sender][address(usdc)] -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, address(usdc), amount);
    }

    // -------------------------------------------------------------------------
    // Registry-only operations
    // -------------------------------------------------------------------------

    /// @notice Called by LoanRegistry at request time.
    ///         Locks `amount` of `asset` from `borrower` against `loanId`.
    function reserveCollateral(
        uint256 loanId,
        address borrower,
        address asset,
        uint256 amount,
        uint256 principal
    ) external onlyRegistry {
        if (!assetConfigs[asset].approved) revert UnapprovedAsset();
        if (reservations[loanId].amount != 0) revert AlreadyReserved();
        if (availableBalance[borrower][asset] < amount) revert InsufficientAvailableBalance();
        if (amount < requiredCollateral(principal, asset)) revert InsufficientCollateralForLTV();

        availableBalance[borrower][asset] -= amount;
        reservations[loanId] = Reservation({borrower: borrower, asset: asset, amount: amount, resolved: false});
        emit Reserved(loanId, borrower, asset, amount);
    }

    /// @notice Called by LoanRegistry on full repayment — returns collateral to borrower.
    function release(uint256 loanId) external onlyRegistry {
        Reservation storage r = reservations[loanId];
        if (r.amount == 0) revert NoReservation();
        if (r.resolved) revert AlreadyResolved();
        r.resolved = true;

        IERC20(r.asset).safeTransfer(r.borrower, r.amount);
        emit Released(loanId, r.borrower, r.asset, r.amount);
    }

    /// @notice Called by LoanRegistry on default — seizes collateral to the lender.
    ///         Collateral is transferred in its original token (USDC or EURC).
    function seize(uint256 loanId) external onlyRegistry {
        Reservation storage r = reservations[loanId];
        if (r.amount == 0) revert NoReservation();
        if (r.resolved) revert AlreadyResolved();
        r.resolved = true;

        address lender = registry.getLoan(loanId).lender;
        IERC20(r.asset).safeTransfer(lender, r.amount);
        emit Seized(loanId, lender, r.asset, r.amount);
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
