// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";
import {IRevenueRouter} from "./interfaces/IRevenueRouter.sol";

interface ICollateralVaultView {
    function reservations(uint256 loanId) external view returns (address borrower, uint256 amount, bool resolved);
}

interface IUnderwriterPoolView {
    function reservations(uint256 loanId) external view returns (address underwriter, uint256 amount, bool resolved);
}

interface IReservePoolView {
    function loanPayout(uint256 loanId) external view returns (uint256);
}

interface ILoanVaultView {
    /// @notice Amount settled from vault for a Defaulted loan (RISK-01 fix).
    ///         Set in LoanVault.settleExpiredLoan() and readable even after
    ///         lockedAmount[loanId] has been cleared.
    function settledDefaultAmount(uint256 loanId) external view returns (uint256);
}

/// @title LiquidityPool
/// @notice Shared, share-accounted USDC liquidity for automatically- and
///         manually-approved Valen loans. idleLedger + totalDeployed =
///         totalAssets (NAV). Recovery from RevenueRouter, CollateralVault,
///         UnderwriterPool, and ReservePool all arrive as plain USDC
///         transfers to this contract (since loan.lender = pool address);
///         reconcileLoan() pulls the latest recovered figures from each
///         source and recognizes them into idleLedger, so uncredited
///         inflows never distort share price until explicitly reconciled.
contract LiquidityPool is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    ILoanRegistry public loanRegistry;
    IRevenueRouter public revenueRouter;
    ICollateralVaultView public collateralVault;
    IUnderwriterPoolView public underwriterPool;
    IReservePoolView public reservePool;
    address public loanVault;

    uint256 public idleLedger;
    uint256 public totalDeployed;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    mapping(uint256 => uint256) public principalAdvanced;
    mapping(uint256 => uint256) public principalReturned;
    mapping(uint256 => uint256) public lastRouterRecorded;
    mapping(uint256 => bool) public defaultRecoveryCounted;
    mapping(uint256 => bool) public finalized;

    uint256[] public activeLoanIds;
    mapping(uint256 => uint256) private _activeLoanIndexPlusOne;

    bool public initializedLiquidity;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;
    /// @notice One-time guard that records when settledDefaultAmount[loanId]
    ///         has been credited into idleLedger. Independent of
    ///         defaultRecoveryCounted so that vault settlement is recognised
    ///         whether settleExpiredLoan() is called before OR after the first
    ///         reconcileLoan() (RISK-03 fix). Appended at end of storage to
    ///         preserve all existing slot positions.
    mapping(uint256 => bool) public vaultSettlementCounted;

    event LiquidityInitialized(uint256 amount, uint256 shares);
    event Deposited(address indexed lender, uint256 amount, uint256 shares);
    event Withdrawn(address indexed lender, uint256 shares, uint256 amount);
    event LoanFundedFromPool(uint256 indexed loanId, uint256 amount);
    event LoanReconciled(uint256 indexed loanId, uint256 delta, uint256 principalPortion, uint256 profitPortion);
    event LoanWrittenOff(uint256 indexed loanId, uint256 lossAmount);
    event LoanFinalized(uint256 indexed loanId);

    error ZeroAddress();
    error ZeroAmount();
    error ReentrantCall();
    error AlreadyInitialized();
    error NotInitialized();
    error NotLoanVault();
    error InsufficientLiquidity();
    error InsufficientShares();
    error AlreadyFunded();
    error NoSharesOutstanding();

    modifier onlyLoanVault() {
        if (msg.sender != loanVault) revert NotLoanVault();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address _usdc,
        address _loanRegistry,
        address _revenueRouter,
        address _collateralVault,
        address _underwriterPool,
        address _reservePool,
        address _loanVault
    ) external initializer {
        if (
            _usdc == address(0) || _loanRegistry == address(0) || _revenueRouter == address(0) ||
            _collateralVault == address(0) || _underwriterPool == address(0) ||
            _reservePool == address(0) || _loanVault == address(0)
        ) revert ZeroAddress();
        __Ownable_init(initialOwner);
        usdc = IERC20(_usdc);
        loanRegistry = ILoanRegistry(_loanRegistry);
        revenueRouter = IRevenueRouter(_revenueRouter);
        collateralVault = ICollateralVaultView(_collateralVault);
        underwriterPool = IUnderwriterPoolView(_underwriterPool);
        reservePool = IReservePoolView(_reservePool);
        loanVault = _loanVault;
        _reentrancyStatus = _NOT_ENTERED;
    }

    /// @notice Owner-only first deposit — closes the front-running window
    ///         a public first depositor would otherwise create.
    function initializeLiquidity(uint256 amount) external onlyOwner nonReentrant {
        if (initializedLiquidity) revert AlreadyInitialized();
        if (amount == 0) revert ZeroAmount();
        initializedLiquidity = true;
        idleLedger = amount;
        totalShares = amount;
        sharesOf[msg.sender] = amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityInitialized(amount, amount);
    }

    function deposit(uint256 amount) external nonReentrant {
        if (!initializedLiquidity) revert NotInitialized();
        if (amount == 0) revert ZeroAmount();
        _reconcileAll();

        uint256 assetsBefore = idleLedger + totalDeployed;
        uint256 sharesMinted = (amount * totalShares) / assetsBefore;

        idleLedger += amount;
        totalShares += sharesMinted;
        sharesOf[msg.sender] += sharesMinted;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, sharesMinted);
    }

    function withdraw(uint256 sharesToBurn) external nonReentrant {
        if (sharesToBurn == 0) revert ZeroAmount();
        if (sharesOf[msg.sender] < sharesToBurn) revert InsufficientShares();
        _reconcileAll();

        if (totalShares == 0) revert NoSharesOutstanding();
        uint256 assetsBefore = idleLedger + totalDeployed;
        uint256 amountOut = (sharesToBurn * assetsBefore) / totalShares;
        if (amountOut > idleLedger) revert InsufficientLiquidity();

        sharesOf[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        idleLedger -= amountOut;

        usdc.safeTransfer(msg.sender, amountOut);
        emit Withdrawn(msg.sender, sharesToBurn, amountOut);
    }

    /// @notice Called only by LoanVault, which has already independently
    ///         verified loan eligibility against LoanRegistry directly.
    function fundLoan(uint256 loanId, uint256 amount) external onlyLoanVault nonReentrant {
        if (principalAdvanced[loanId] != 0) revert AlreadyFunded();
        if (amount > idleLedger) revert InsufficientLiquidity();

        idleLedger -= amount;
        totalDeployed += amount;
        principalAdvanced[loanId] = amount;
        _trackActiveLoan(loanId);

        usdc.safeTransfer(loanVault, amount);
        emit LoanFundedFromPool(loanId, amount);
    }

    function canFund(uint256 amount) external view returns (bool) {
        return amount <= idleLedger;
    }

    /// @notice Permissionless. Pulls the latest RevenueRouter recovery
    ///         (and, once Defaulted, the one-time collateral/underwriter/
    ///         reserve recovery) and updates pool accounting. Idempotent —
    ///         a no-op once nothing new has arrived for this loan.
    function reconcileLoan(uint256 loanId) public {
        if (principalAdvanced[loanId] == 0) return;
        if (finalized[loanId]) return;

        uint256 routerTotal = revenueRouter.totalRecovered(loanId);
        uint256 delta = routerTotal - lastRouterRecorded[loanId];
        lastRouterRecorded[loanId] = routerTotal;

        ILoanRegistry.LoanView memory loan = loanRegistry.getLoan(loanId);

        if (loan.status == ILoanRegistry.LoanStatus.Defaulted && !defaultRecoveryCounted[loanId]) {
            defaultRecoveryCounted[loanId] = true;
            if (loanRegistry.getCollateralAmount(loanId) > 0) {
                (, uint256 amt, bool resolved) = collateralVault.reservations(loanId);
                if (resolved) delta += amt;
            } else if (loanRegistry.getUnderwriterAmount(loanId) > 0) {
                (, uint256 amt, bool resolved) = underwriterPool.reservations(loanId);
                if (resolved) delta += amt;
            } else {
                delta += reservePool.loanPayout(loanId);
            }
        }

        // RISK-03 fix: account for vault settlement independently of the
        // collateral/underwriter/reserve block above. settleExpiredLoan() may
        // be called either before or after the first reconcileLoan(). Using a
        // separate vaultSettlementCounted guard ensures the amount is credited
        // exactly once regardless of call order, and cannot be double-counted
        // with the one-time defaultRecoveryCounted block.
        if (
            loan.status == ILoanRegistry.LoanStatus.Defaulted &&
            !vaultSettlementCounted[loanId]
        ) {
            uint256 vaultSettled = ILoanVaultView(loanVault).settledDefaultAmount(loanId);
            if (vaultSettled > 0) {
                vaultSettlementCounted[loanId] = true;
                delta += vaultSettled;
            }
        }

        if (delta > 0) {
            uint256 principalRemaining = principalAdvanced[loanId] - principalReturned[loanId];
            uint256 principalPortion = delta > principalRemaining ? principalRemaining : delta;
            uint256 profitPortion = delta - principalPortion;

            principalReturned[loanId] += principalPortion;
            totalDeployed -= principalPortion;
            idleLedger += delta;

            emit LoanReconciled(loanId, delta, principalPortion, profitPortion);
        }

        // Realize the loss exactly once, the moment Defaulted status is
        // observed and one-time recovery sources are spent. Any later
        // RevenueRouter recovery (post-default garnishment) becomes pure
        // profit from here on, since principalReturned is now forced to
        // principalAdvanced — this is what prevents post-default payments
        // from creating any accounting inconsistency.
        if (loan.status == ILoanRegistry.LoanStatus.Defaulted && defaultRecoveryCounted[loanId]) {
            uint256 remaining = principalAdvanced[loanId] - principalReturned[loanId];
            if (remaining > 0) {
                totalDeployed -= remaining;
                principalReturned[loanId] = principalAdvanced[loanId];
                emit LoanWrittenOff(loanId, remaining);
            }
        }

        if (revenueRouter.isFullyRepaid(loanId)) {
            finalized[loanId] = true;
            _untrackActiveLoan(loanId);
            emit LoanFinalized(loanId);
        }
    }

    function _reconcileAll() internal {
        uint256[] memory ids = activeLoanIds;
        for (uint256 i = 0; i < ids.length; i++) {
            reconcileLoan(ids[i]);
        }
    }

    function _trackActiveLoan(uint256 loanId) internal {
        if (_activeLoanIndexPlusOne[loanId] != 0) return;
        activeLoanIds.push(loanId);
        _activeLoanIndexPlusOne[loanId] = activeLoanIds.length;
    }

    function _untrackActiveLoan(uint256 loanId) internal {
        uint256 idxPlusOne = _activeLoanIndexPlusOne[loanId];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = activeLoanIds.length - 1;
        uint256 lastLoanId = activeLoanIds[lastIdx];
        activeLoanIds[idx] = lastLoanId;
        _activeLoanIndexPlusOne[lastLoanId] = idx + 1;
        activeLoanIds.pop();
        delete _activeLoanIndexPlusOne[loanId];
    }

    function totalAssets() external view returns (uint256) {
        return idleLedger + totalDeployed;
    }

    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return 0;
        return ((idleLedger + totalDeployed) * 1e18) / totalShares;
    }

    function activeLoanCount() external view returns (uint256) {
        return activeLoanIds.length;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}