// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";
import {ILiquidityPool} from "./interfaces/ILiquidityPool.sol";

contract LoanVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    ILoanRegistry public registry;
    IERC20 public usdc;
    address public liquidityPool;

    mapping(uint256 => uint256) public lockedAmount;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    event LoanFundedInVault(uint256 indexed loanId, address indexed lender, uint256 amount);
    event MilestoneFundsReleased(uint256 indexed loanId, uint256 milestoneIndex, address indexed creditWallet, uint256 amount);
    event ExpiredLoanSettled(uint256 indexed loanId, address indexed lender, uint256 returnedAmount);
    event LiquidityPoolSet(address indexed liquidityPool);

    error ZeroAddress();
    error ReentrantCall();
    error LoanNotFundable();
    error LoanNotActive();
    error NotLender();
    error BadMilestoneIndex();
    error MilestoneAlreadyReleased();
    error InsufficientLockedFunds();
    error LoanNotExpired();
    error NothingToSettle();
    error LiquidityPoolAlreadySet();
    error LiquidityPoolNotSet();

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() internal {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
    }

    function _nonReentrantAfter() internal {
        _reentrancyStatus = _NOT_ENTERED;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _registry, address _usdc) external initializer {
        if (_registry == address(0) || _usdc == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        registry = ILoanRegistry(_registry);
        usdc = IERC20(_usdc);
        _reentrancyStatus = _NOT_ENTERED;
    }

    function setLiquidityPool(address _liquidityPool) external onlyOwner {
        if (liquidityPool != address(0)) revert LiquidityPoolAlreadySet();
        if (_liquidityPool == address(0)) revert ZeroAddress();
        liquidityPool = _liquidityPool;
        emit LiquidityPoolSet(_liquidityPool);
    }

    /// @notice Direct P2P funding path — unchanged. A specific caller
    ///         funds a specific loan with their own USDC.
    function fundLoan(uint256 loanId) external nonReentrant {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        if (loan.status != ILoanRegistry.LoanStatus.Requested && loan.status != ILoanRegistry.LoanStatus.Approved) {
            revert LoanNotFundable();
        }

        lockedAmount[loanId] = loan.principal;
        emit LoanFundedInVault(loanId, msg.sender, loan.principal);

        usdc.safeTransferFrom(msg.sender, address(this), loan.principal);
        registry.markFunded(loanId, msg.sender);
    }

    /// @notice Pooled funding path. Re-derives eligibility straight from
    ///         LoanRegistry — the exact same status check fundLoan() uses —
    ///         so a PendingApproval loan is exactly as unfundable here as
    ///         via the direct path. approveLoan() remains a real on-chain
    ///         gate, not a frontend convention.
    function fundFromPool(uint256 loanId) external nonReentrant {
        if (liquidityPool == address(0)) revert LiquidityPoolNotSet();

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        if (loan.status != ILoanRegistry.LoanStatus.Requested && loan.status != ILoanRegistry.LoanStatus.Approved) {
            revert LoanNotFundable();
        }

        lockedAmount[loanId] = loan.principal;
        emit LoanFundedInVault(loanId, liquidityPool, loan.principal);

        ILiquidityPool(liquidityPool).fundLoan(loanId, loan.principal);
        registry.markFunded(loanId, liquidityPool);
    }

    /// @notice Milestone attestation. For a P2P loan, only the actual
    ///         human/agent lender can attest. For a pool-funded loan
    ///         (loan.lender == liquidityPool), no EOA can ever literally
    ///         be that address — so the pool's own owner (the trusted
    ///         Valen backend) is permitted to attest on the pool's behalf.
    ///         This is the one authorization change pooled funding required.
    function releaseMilestone(uint256 loanId, uint256 milestoneIndex) external nonReentrant {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        if (loan.status != ILoanRegistry.LoanStatus.Active) revert LoanNotActive();

        bool isPoolLoan = liquidityPool != address(0) && loan.lender == liquidityPool;
        bool callerIsPoolOwner = isPoolLoan && msg.sender == OwnableUpgradeable(liquidityPool).owner();
        if (msg.sender != loan.lender && !callerIsPoolOwner) revert NotLender();

        ILoanRegistry.Milestone[] memory milestones = registry.getMilestones(loanId);
        if (milestoneIndex >= milestones.length) revert BadMilestoneIndex();
        ILoanRegistry.Milestone memory milestone = milestones[milestoneIndex];
        if (milestone.released) revert MilestoneAlreadyReleased();
        if (lockedAmount[loanId] < milestone.amount) revert InsufficientLockedFunds();

        lockedAmount[loanId] -= milestone.amount;
        emit MilestoneFundsReleased(loanId, milestoneIndex, loan.creditWallet, milestone.amount);

        registry.markMilestoneReleased(loanId, milestoneIndex);
        usdc.safeTransfer(loan.creditWallet, milestone.amount);
    }

    function settleExpiredLoan(uint256 loanId) external nonReentrant {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        if (block.timestamp < loan.expiresAt) revert LoanNotExpired();
        if (loan.status != ILoanRegistry.LoanStatus.Active) revert LoanNotActive();

        uint256 remaining = lockedAmount[loanId];
        if (remaining == 0) revert NothingToSettle();

        lockedAmount[loanId] = 0;
        emit ExpiredLoanSettled(loanId, loan.lender, remaining);

        usdc.safeTransfer(loan.lender, remaining);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}