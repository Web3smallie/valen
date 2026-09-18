// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";

/// @title CollateralVault
/// @notice Path A: same-asset USDC collateral. No oracle needed — USDC
///         collateral is worth exactly its face value. Borrower deposits,
///         LoanRegistry reserves against a specific loan at request time,
///         released back on full repayment or seized to the lender on default.
contract CollateralVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    struct Reservation {
        address borrower;
        uint256 amount;
        bool resolved;
    }

    IERC20 public usdc;
    ILoanRegistry public registry;
    uint16 public maxLTVBps; // e.g. 6600 = 66% -> principal <= collateral * 0.66

    mapping(address => uint256) public availableBalance;
    mapping(uint256 => Reservation) public reservations;

    event Deposited(address indexed borrower, uint256 amount);
    event Withdrawn(address indexed borrower, uint256 amount);
    event Reserved(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event Released(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event Seized(uint256 indexed loanId, address indexed lender, uint256 amount);
    event MaxLTVSet(uint16 maxLTVBps);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientAvailableBalance();
    error NotRegistry();
    error AlreadyReserved();
    error NoReservation();
    error AlreadyResolved();
    error InsufficientCollateralForLTV();

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) revert NotRegistry();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _usdc, address _registry, uint16 _maxLTVBps)
        external
        initializer
    {
        if (_usdc == address(0) || _registry == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        usdc = IERC20(_usdc);
        registry = ILoanRegistry(_registry);
        maxLTVBps = _maxLTVBps;
    }

    function setMaxLTV(uint16 _maxLTVBps) external onlyOwner {
        maxLTVBps = _maxLTVBps;
        emit MaxLTVSet(_maxLTVBps);
    }

    /// @notice Collateral required for a given principal at the current LTV.
    function requiredCollateral(uint256 principal) public view returns (uint256) {
        return (principal * 10000) / maxLTVBps;
    }

    function depositCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        availableBalance[msg.sender] += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (availableBalance[msg.sender] < amount) revert InsufficientAvailableBalance();
        availableBalance[msg.sender] -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Called by LoanRegistry at request time to lock collateral
    ///         against a specific loan.
    function reserveCollateral(uint256 loanId, address borrower, uint256 amount, uint256 principal)
        external
        onlyRegistry
    {
        if (reservations[loanId].amount != 0) revert AlreadyReserved();
        if (availableBalance[borrower] < amount) revert InsufficientAvailableBalance();
        if (amount < requiredCollateral(principal)) revert InsufficientCollateralForLTV();

        availableBalance[borrower] -= amount;
        reservations[loanId] = Reservation({borrower: borrower, amount: amount, resolved: false});
        emit Reserved(loanId, borrower, amount);
    }

    /// @notice Called by LoanRegistry on full repayment.
    function release(uint256 loanId) external onlyRegistry {
        Reservation storage r = reservations[loanId];
        if (r.amount == 0) revert NoReservation();
        if (r.resolved) revert AlreadyResolved();
        r.resolved = true;

        usdc.safeTransfer(r.borrower, r.amount);
        emit Released(loanId, r.borrower, r.amount);
    }

    /// @notice Called by LoanRegistry on default — seizes collateral to the lender.
    function seize(uint256 loanId) external onlyRegistry {
        Reservation storage r = reservations[loanId];
        if (r.amount == 0) revert NoReservation();
        if (r.resolved) revert AlreadyResolved();
        r.resolved = true;

        address lender = registry.getLoan(loanId).lender;
        usdc.safeTransfer(lender, r.amount);
        emit Seized(loanId, lender, r.amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}