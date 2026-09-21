// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";
import {ICreditRegistry} from "./interfaces/ICreditRegistry.sol";
import {IRevenueRouter} from "./interfaces/IRevenueRouter.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {IUnderwriterPool} from "./interfaces/IUnderwriterPool.sol";
import {IRecipientRegistry} from "./interfaces/IRecipientRegistry.sol";
import {IReservePool} from "./interfaces/IReservePool.sol";

contract LoanRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILoanRegistry {
    struct Loan {
        address borrower;
        address lender;
        address creditWallet;
        uint256 principal;
        uint256 totalRepaymentDue;
        uint16 repaymentRateBps;
        LoanStatus status;
        uint256 createdAt;
        uint256 expiresAt;
        uint256 collateralAmount;
        uint256 underwriterAmount;
        string purpose;
        BudgetCategory[] budget;
        address[] permittedRecipients;
        Milestone[] milestones;
    }

    address public vault;
    address public router;
    ICreditRegistry public creditRegistry;
    ICollateralVault public collateralVault;
    IUnderwriterPool public underwriterPool;
    IRecipientRegistry public recipientRegistry;
    IReservePool public reservePool;

    uint256 public nextLoanId;
    mapping(uint256 => Loan) private _loans;

    uint256 public minDuration;
    uint256 public maxDuration;
    uint256 public defaultGracePeriod;
    uint256 public collateralApprovalThreshold;
    /// @notice Addresses permitted to call markDefault() on behalf of
    ///         the protocol (e.g. an automated keeper bot). Managed by
    ///         the owner via setKeeper(). Kept as a mapping so multiple
    ///         keepers can be authorised and individually revoked without
    ///         a redeployment (RISK-04 fix).
    mapping(address => bool) public keepers;
    /// @notice Tracks total principal currently outstanding (requested,
    ///         approved, or active) for each borrower so concurrent loans
    ///         cannot collectively exceed the credit limit (RISK-08 fix).
    mapping(address => uint256) public outstandingPrincipal;

    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 principal, ILoanRegistry.LoanStatus initialStatus);
    event LoanApproved(uint256 indexed loanId, address indexed approver);
    event LoanFunded(uint256 indexed loanId, address indexed lender);
    event MilestoneReleased(uint256 indexed loanId, uint256 milestoneIndex, uint256 amount);
    event LoanStatusChanged(uint256 indexed loanId, ILoanRegistry.LoanStatus status);
    event LoanDefaulted(uint256 indexed loanId, bool severe);
    event VaultSet(address indexed vault);
    event RouterSet(address indexed router);
    event CreditRegistrySet(address indexed creditRegistry);
    event CollateralVaultSet(address indexed collateralVault);
    event UnderwriterPoolSet(address indexed underwriterPool);
    event RecipientRegistrySet(address indexed recipientRegistry);
    event ReservePoolSet(address indexed reservePool);
    event KeeperSet(address indexed keeper, bool allowed);

    error NotVault();
    error NotRouter();
    error ContractsAlreadySet();
    error CollateralVaultAlreadySet();
    error UnderwriterPoolAlreadySet();
    error RecipientRegistryAlreadySet();
    error ReservePoolAlreadySet();
    error LoansAlreadyExist();
    error ZeroAddress();
    error LengthMismatch();
    error NoMilestones();
    error MilestoneSumMismatch();
    error BudgetSumMismatch();
    error NoPermittedRecipients();
    error UnapprovedRecipient();
    error DurationOutOfRange();
    error ExceedsCreditLimit();
    error LoanNotRequestable();
    error LoanNotPendingApproval();
    error MilestoneAlreadyReleased();
    error LoanNotActive();
    error LoanNotDefaultable();
    error DefaultGraceNotElapsed();
    error NotAuthorized();

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    function _onlyVault() internal view {
        if (msg.sender != vault) revert NotVault();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address _creditRegistry,
        uint256 _minDuration,
        uint256 _maxDuration,
        uint256 _defaultGracePeriod,
        uint256 _collateralApprovalThreshold
    ) external initializer {
        if (_creditRegistry == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        creditRegistry = ICreditRegistry(_creditRegistry);
        minDuration = _minDuration;
        maxDuration = _maxDuration;
        defaultGracePeriod = _defaultGracePeriod;
        collateralApprovalThreshold = _collateralApprovalThreshold;
        emit CreditRegistrySet(_creditRegistry);
    }

    function setContracts(address _vault, address _router) external onlyOwner {
        if (_vault == address(0) || _router == address(0)) revert ZeroAddress();
        vault = _vault;
        router = _router;
        emit VaultSet(_vault);
        emit RouterSet(_router);
    }

    function setCollateralVault(address _collateralVault) external onlyOwner {
        if (nextLoanId > 0) revert LoansAlreadyExist();
        if (_collateralVault == address(0)) revert ZeroAddress();
        collateralVault = ICollateralVault(_collateralVault);
        emit CollateralVaultSet(_collateralVault);
    }

    function setUnderwriterPool(address _underwriterPool) external onlyOwner {
        if (nextLoanId > 0) revert LoansAlreadyExist();
        if (_underwriterPool == address(0)) revert ZeroAddress();
        underwriterPool = IUnderwriterPool(_underwriterPool);
        emit UnderwriterPoolSet(_underwriterPool);
    }

    function setRecipientRegistry(address _recipientRegistry) external onlyOwner {
        if (_recipientRegistry == address(0)) revert ZeroAddress();
        recipientRegistry = IRecipientRegistry(_recipientRegistry);
        emit RecipientRegistrySet(_recipientRegistry);
    }

    function setReservePool(address _reservePool) external onlyOwner {
        if (nextLoanId > 0) revert LoansAlreadyExist();
        if (_reservePool == address(0)) revert ZeroAddress();
        reservePool = IReservePool(_reservePool);
        emit ReservePoolSet(_reservePool);
    }

    /// @notice Add or remove an address from the keeper set.
    ///         Keepers are the only non-owner addresses permitted to
    ///         call markDefault(). Intended for automated keeper bots
    ///         that monitor loan expiry and trigger defaults; they have
    ///         no other elevated privileges anywhere in the protocol
    ///         (RISK-04 fix).
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function _validateProposal(LoanProposal calldata proposal) internal view returns (bool needsApproval) {
        if (proposal.creditWallet == address(0)) revert ZeroAddress();
        if (proposal.duration < minDuration || proposal.duration > maxDuration) revert DurationOutOfRange();
        if (proposal.permittedRecipients.length == 0) revert NoPermittedRecipients();
        if (proposal.milestoneAmounts.length != proposal.milestoneDescriptions.length) revert LengthMismatch();
        if (proposal.milestoneAmounts.length == 0) revert NoMilestones();

        for (uint256 i = 0; i < proposal.permittedRecipients.length; i++) {
            if (!recipientRegistry.isApproved(proposal.permittedRecipients[i])) revert UnapprovedRecipient();
        }

        if (proposal.collateralAmount > 0) {
            needsApproval = proposal.principal > collateralApprovalThreshold;
        } else {
            uint256 effectiveLimit = creditRegistry.getLimit(msg.sender);
            if (proposal.underwriterAmount > 0) {
                effectiveLimit += proposal.underwriterAmount;
            }
            // RISK-08: compare against available credit (ceiling minus
            // already-outstanding principal) to prevent concurrent loans
            // from collectively exceeding the credit limit.
            uint256 usedCredit = outstandingPrincipal[msg.sender];
            uint256 available = usedCredit >= effectiveLimit ? 0 : effectiveLimit - usedCredit;
            if (proposal.principal > available) revert ExceedsCreditLimit();
            needsApproval = creditRegistry.requiresApproval(proposal.principal);
        }

        uint256 budgetSum = 0;
        for (uint256 i = 0; i < proposal.budget.length; i++) {
            budgetSum += proposal.budget[i].cap;
        }
        if (budgetSum != proposal.principal) revert BudgetSumMismatch();

        uint256 milestoneSum = 0;
        for (uint256 i = 0; i < proposal.milestoneAmounts.length; i++) {
            milestoneSum += proposal.milestoneAmounts[i];
        }
        if (milestoneSum != proposal.principal) revert MilestoneSumMismatch();
    }

    function _storeLoan(LoanProposal calldata proposal, bool needsApproval) internal returns (uint256 loanId) {
        loanId = nextLoanId++;
        Loan storage loan = _loans[loanId];
        loan.borrower = msg.sender;
        loan.creditWallet = proposal.creditWallet;
        loan.principal = proposal.principal;
        loan.repaymentRateBps = proposal.repaymentRateBps;
        loan.totalRepaymentDue = proposal.totalRepaymentDue;
        loan.createdAt = block.timestamp;
        loan.expiresAt = block.timestamp + proposal.duration;
        loan.collateralAmount = proposal.collateralAmount;
        loan.underwriterAmount = proposal.underwriterAmount;
        loan.purpose = proposal.purpose;

        for (uint256 i = 0; i < proposal.budget.length; i++) {
            loan.budget.push(proposal.budget[i]);
        }
        for (uint256 i = 0; i < proposal.permittedRecipients.length; i++) {
            loan.permittedRecipients.push(proposal.permittedRecipients[i]);
        }
        for (uint256 i = 0; i < proposal.milestoneAmounts.length; i++) {
            loan.milestones.push(Milestone({
                amount: proposal.milestoneAmounts[i],
                released: false,
                description: proposal.milestoneDescriptions[i]
            }));
        }

        loan.status = needsApproval ? LoanStatus.PendingApproval : LoanStatus.Requested;
    }

    function requestLoan(LoanProposal calldata proposal) external returns (uint256 loanId) {
        bool needsApproval = _validateProposal(proposal);
        loanId = _storeLoan(proposal, needsApproval);

        // RISK-08: record principal as outstanding from the moment a loan
        // is requested so subsequent concurrent requests are checked against
        // the reduced available credit.
        outstandingPrincipal[msg.sender] += proposal.principal;

        if (proposal.collateralAmount > 0) {
            collateralVault.reserveCollateral(loanId, msg.sender, proposal.collateralAmount, proposal.principal);
        } else if (proposal.underwriterAmount > 0) {
            underwriterPool.reserveStake(loanId, proposal.underwriter, msg.sender, proposal.underwriterAmount);
        }

        emit LoanRequested(loanId, msg.sender, proposal.principal, _loans[loanId].status);
    }

    function approveLoan(uint256 loanId) external onlyOwner {
        Loan storage loan = _loans[loanId];
        if (loan.status != LoanStatus.PendingApproval) revert LoanNotPendingApproval();
        loan.status = LoanStatus.Approved;
        emit LoanApproved(loanId, msg.sender);
        emit LoanStatusChanged(loanId, LoanStatus.Approved);
    }

    function markFunded(uint256 loanId, address lender) external onlyVault {
        Loan storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Requested && loan.status != LoanStatus.Approved) {
            revert LoanNotRequestable();
        }
        loan.lender = lender;
        loan.status = LoanStatus.Active;
        emit LoanFunded(loanId, lender);
        emit LoanStatusChanged(loanId, LoanStatus.Active);
    }

    function markMilestoneReleased(uint256 loanId, uint256 milestoneIndex) external onlyVault {
        Loan storage loan = _loans[loanId];
        if (loan.milestones[milestoneIndex].released) revert MilestoneAlreadyReleased();
        loan.milestones[milestoneIndex].released = true;
        emit MilestoneReleased(loanId, milestoneIndex, loan.milestones[milestoneIndex].amount);
    }

    function markDefault(uint256 loanId) external {
        // RISK-04 fix: restrict to owner or an authorised keeper bot.
        // Prevents any EOA from front-running a loan into default and
        // triggering irreversible collateral seizure / credit destruction
        // before a pending repayment can land.
        if (msg.sender != owner() && !keepers[msg.sender]) revert NotAuthorized();
        Loan storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active) revert LoanNotDefaultable();
        if (block.timestamp <= loan.expiresAt + defaultGracePeriod) revert DefaultGraceNotElapsed();

        loan.status = LoanStatus.Defaulted;

        // RISK-08: release the outstanding-principal reservation on default.
        outstandingPrincipal[loan.borrower] -= loan.principal;

        if (loan.collateralAmount > 0) {
            collateralVault.seize(loanId);
            creditRegistry.recordDefault(loan.borrower, false);
            emit LoanDefaulted(loanId, false);
        } else if (loan.underwriterAmount > 0) {
            underwriterPool.seize(loanId);
            creditRegistry.recordDefault(loan.borrower, false);
            emit LoanDefaulted(loanId, false);
        } else {
            uint256 recovered = IRevenueRouter(router).totalRecovered(loanId);
            bool severe = recovered == 0;
            creditRegistry.recordDefault(loan.borrower, severe);

            if (address(reservePool) != address(0)) {
                uint256 shortfall = loan.totalRepaymentDue - recovered;
                if (shortfall > 0) {
                    reservePool.payout(loanId, loan.lender, shortfall);
                }
            }

            emit LoanDefaulted(loanId, severe);
        }

        emit LoanStatusChanged(loanId, LoanStatus.Defaulted);
    }

    function markRepaid(uint256 loanId) external {
        if (msg.sender != router) revert NotRouter();
        Loan storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active && loan.status != LoanStatus.Defaulted) revert LoanNotActive();
        bool wasActive = loan.status == LoanStatus.Active;
        loan.status = LoanStatus.Repaid;

        // RISK-08: release the outstanding-principal reservation when the
        // loan is repaid. Only decrement when transitioning from Active —
        // the Defaulted path already decremented in markDefault(), so a
        // second decrement here would underflow (RISK-09 fix).
        if (wasActive) {
            outstandingPrincipal[loan.borrower] -= loan.principal;
        }

        if (loan.collateralAmount > 0) {
            collateralVault.release(loanId);
        } else if (loan.underwriterAmount > 0) {
            underwriterPool.release(loanId);
        }

        emit LoanStatusChanged(loanId, LoanStatus.Repaid);
    }

    function getLoan(uint256 loanId) external view returns (LoanView memory) {
        Loan storage loan = _loans[loanId];
        return LoanView({
            borrower: loan.borrower,
            lender: loan.lender,
            creditWallet: loan.creditWallet,
            principal: loan.principal,
            totalRepaymentDue: loan.totalRepaymentDue,
            repaymentRateBps: loan.repaymentRateBps,
            status: loan.status,
            createdAt: loan.createdAt,
            expiresAt: loan.expiresAt
        });
    }

    function getMilestones(uint256 loanId) external view returns (Milestone[] memory) {
        return _loans[loanId].milestones;
    }

    function getBudget(uint256 loanId) external view returns (BudgetCategory[] memory) {
        return _loans[loanId].budget;
    }

    function getPermittedRecipients(uint256 loanId) external view returns (address[] memory) {
        return _loans[loanId].permittedRecipients;
    }

    function getCollateralAmount(uint256 loanId) external view returns (uint256) {
        return _loans[loanId].collateralAmount;
    }

    function getUnderwriterAmount(uint256 loanId) external view returns (uint256) {
        return _loans[loanId].underwriterAmount;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}