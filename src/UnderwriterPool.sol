// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";
import {IUnderwriterPool} from "./interfaces/IUnderwriterPool.sol";

/// @title UnderwriterPool
/// @notice Delegated underwriter staking for large unsecured (Path B) loans.
///         An underwriter deposits USDC, commits a ceiling to a specific
///         borrower they've vetted (underwriter picks the agent, not the
///         reverse), and that commitment extends the borrower's effective
///         limit beyond their own CreditRegistry history. Dedicated stake
///         per loan — no shared-pool cross-loan exposure.
contract UnderwriterPool is Initializable, OwnableUpgradeable, UUPSUpgradeable, IUnderwriterPool {
    using SafeERC20 for IERC20;

    struct Reservation {
        address underwriter;
        uint256 amount;
        bool resolved;
    }

    IERC20 public usdc;
    ILoanRegistry public registry;

    mapping(address => uint256) public stakeBalance; // deposited, unreserved
    mapping(address => mapping(address => uint256)) public commitments; // underwriter => borrower => ceiling
    mapping(uint256 => Reservation) public reservations; // loanId => reservation

    event StakeDeposited(address indexed underwriter, uint256 amount);
    event StakeWithdrawn(address indexed underwriter, uint256 amount);
    event CommitmentSet(address indexed underwriter, address indexed borrower, uint256 amount);
    event Reserved(uint256 indexed loanId, address indexed underwriter, address indexed borrower, uint256 amount);
    event Released(uint256 indexed loanId, address indexed underwriter, uint256 amount);
    event Seized(uint256 indexed loanId, address indexed underwriter, address indexed lender, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStakeBalance();
    error InsufficientCommitment();
    error NotRegistry();
    error AlreadyReserved();
    error NoReservation();
    error AlreadyResolved();

    modifier onlyRegistry() {
        _onlyRegistry();
        _;
    }

    function _onlyRegistry() internal view {
        if (msg.sender != address(registry)) revert NotRegistry();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _usdc, address _registry) external initializer {
        if (_usdc == address(0) || _registry == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        usdc = IERC20(_usdc);
        registry = ILoanRegistry(_registry);
    }

    function depositStake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        stakeBalance[msg.sender] += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit StakeDeposited(msg.sender, amount);
    }

    function withdrawStake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (stakeBalance[msg.sender] < amount) revert InsufficientStakeBalance();
        stakeBalance[msg.sender] -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit StakeWithdrawn(msg.sender, amount);
    }

    /// @notice Underwriter sets (or updates) the ceiling they're willing to
    ///         back a specific borrower for. Underwriter-initiated, by design.
    /// @dev    This commitment is a revocable ceiling. It does NOT lock or
    ///         reserve any USDC. Actual stake is reserved atomically when a
    ///         qualifying loan request executes via `reserveStake`. If the
    ///         underwriter withdraws stake or revokes this commitment before
    ///         `requestLoan` executes, that call will revert with
    ///         `InsufficientStakeBalance` -- no loan state is created and no
    ///         funds are lost. The borrower may retry with a different
    ///         underwriter or wait for the underwriter to re-deposit.
    function commitToAgent(address borrower, uint256 amount) external {
        if (borrower == address(0)) revert ZeroAddress();
        commitments[msg.sender][borrower] = amount;
        emit CommitmentSet(msg.sender, borrower, amount);
    }

    function committedTo(address underwriter, address borrower) external view returns (uint256) {
        return commitments[underwriter][borrower];
    }

    /// @notice Called by LoanRegistry at request time. Requires the
    ///         underwriter to have already committed enough to this borrower
    ///         and to have enough deposited, unreserved stake.
    function reserveStake(uint256 loanId, address underwriter, address borrower, uint256 amount)
        external
        onlyRegistry
    {
        if (reservations[loanId].amount != 0) revert AlreadyReserved();
        if (commitments[underwriter][borrower] < amount) revert InsufficientCommitment();
        if (stakeBalance[underwriter] < amount) revert InsufficientStakeBalance();

        stakeBalance[underwriter] -= amount;
        reservations[loanId] = Reservation({underwriter: underwriter, amount: amount, resolved: false});
        emit Reserved(loanId, underwriter, borrower, amount);
    }

    /// @notice Called by LoanRegistry on full repayment — returns stake to the underwriter.
    function release(uint256 loanId) external onlyRegistry {
        Reservation storage r = reservations[loanId];
        if (r.amount == 0) revert NoReservation();
        if (r.resolved) revert AlreadyResolved();
        r.resolved = true;

        stakeBalance[r.underwriter] += r.amount;
        emit Released(loanId, r.underwriter, r.amount);
    }

    /// @notice Called by LoanRegistry on default — slashes stake to the lender.
    function seize(uint256 loanId) external onlyRegistry {
        Reservation storage r = reservations[loanId];
        if (r.amount == 0) revert NoReservation();
        if (r.resolved) revert AlreadyResolved();
        r.resolved = true;

        address lender = registry.getLoan(loanId).lender;
        usdc.safeTransfer(lender, r.amount);
        emit Seized(loanId, r.underwriter, lender, r.amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}