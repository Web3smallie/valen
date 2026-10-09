// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable}      from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable}    from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ILoanRegistry}      from "./interfaces/ILoanRegistry.sol";
import {ICreditRegistry}    from "./interfaces/ICreditRegistry.sol";
import {IAgentRegistry}     from "./interfaces/IAgentRegistry.sol";
import {IRevenueRouter}     from "./interfaces/IRevenueRouter.sol";
import {ICollateralVault}   from "./interfaces/ICollateralVault.sol";
import {IUnderwriterPool}   from "./interfaces/IUnderwriterPool.sol";
import {IRecipientRegistry} from "./interfaces/IRecipientRegistry.sol";
import {IReservePool}       from "./interfaces/IReservePool.sol";


contract LoanRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILoanRegistry {

    // -------------------------------------------------------------------------
    // Internal Loan struct (storage)
    // -------------------------------------------------------------------------

    struct Loan {
        uint256 agentId;          // Valen agentId — persistent credit identity
        address borrower;         // msg.sender at requestLoan time; historical context
        address lender;
        address creditWallet;
        uint256 principal;
        uint256 totalRepaymentDue;
        uint16  repaymentRateBps;
        LoanStatus status;
        uint256 createdAt;
        uint256 expiresAt;
        uint256 collateralAmount;
        address collateralAsset;   // ERC-20 token used as collateral (USDC or EURC)
        uint256 underwriterAmount;
        string  purpose;
        BudgetCategory[] budget;
        address[] permittedRecipients;
        Milestone[] milestones;
    }

    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    address public vault;
    address public router;
    ICreditRegistry    public creditRegistry;
    IAgentRegistry     public agentRegistry;
    ICollateralVault   public collateralVault;
    IUnderwriterPool   public underwriterPool;
    IRecipientRegistry public recipientRegistry;
    IReservePool       public reservePool;

    uint256 public nextLoanId;
    mapping(uint256 => Loan) private _loans;

    uint256 public minDuration;
    uint256 public maxDuration;
    uint256 public defaultGracePeriod;
    uint256 public collateralApprovalThreshold;

    /// @notice Addresses permitted to call markDefault() (RISK-04).
    mapping(address => bool) public keepers;

    /// @notice Outstanding principal per agentId (RISK-08).
    ///         Replaces the former mapping(address => uint256) which used msg.sender.
    mapping(uint256 => uint256) public outstandingPrincipal;

    /// @notice True once setAgentRegistry has been called; prevents re-set.
    bool private _agentRegistrySet;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 principal, ILoanRegistry.LoanStatus initialStatus);
    event LoanApproved(uint256 indexed loanId, address indexed approver);
    event LoanFunded(uint256 indexed loanId, address indexed lender);
    event MilestoneReleased(uint256 indexed loanId, uint256 milestoneIndex, uint256 amount);
    event LoanStatusChanged(uint256 indexed loanId, ILoanRegistry.LoanStatus status);
    event LoanDefaulted(uint256 indexed loanId, bool severe);
    event VaultSet(address indexed vault);
    event RouterSet(address indexed router);
    event CreditRegistrySet(address indexed creditRegistry);
    event AgentRegistrySet(address indexed agentRegistry);
    event CollateralVaultSet(address indexed collateralVault);
    event UnderwriterPoolSet(address indexed underwriterPool);
    event RecipientRegistrySet(address indexed recipientRegistry);
    event ReservePoolSet(address indexed reservePool);
    event KeeperSet(address indexed keeper, bool allowed);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotVault();
    error NotRouter();
    error ContractsAlreadySet();
    error AgentRegistryAlreadySet();
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
    error CreditWalletNotInRecipients();
    error CreditWalletNotAgentWallet();
    error DurationOutOfRange();
    error ExceedsCreditLimit();
    error LoanNotRequestable();
    error LoanNotPendingApproval();
    error MilestoneAlreadyReleased();
    error LoanNotActive();
    error LoanNotDefaultable();
    error DefaultGraceNotElapsed();
    error NotAuthorized();
    error CallerNotAgentWallet();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    function _onlyVault() internal view {
        if (msg.sender != vault) revert NotVault();
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

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
        creditRegistry           = ICreditRegistry(_creditRegistry);
        minDuration              = _minDuration;
        maxDuration              = _maxDuration;
        defaultGracePeriod       = _defaultGracePeriod;
        collateralApprovalThreshold = _collateralApprovalThreshold;
        emit CreditRegistrySet(_creditRegistry);
    }

    // -------------------------------------------------------------------------
    // Setters
    // -------------------------------------------------------------------------

    function setContracts(address _vault, address _router) external onlyOwner {
        if (vault != address(0) || router != address(0)) revert ContractsAlreadySet();
        if (_vault == address(0) || _router == address(0)) revert ZeroAddress();
        vault  = _vault;
        router = _router;
        emit VaultSet(_vault);
        emit RouterSet(_router);
    }

    /// @notice Set the AgentRegistry. One-time; reverts if already set.
    function setAgentRegistry(address _agentRegistry) external onlyOwner {
        if (_agentRegistrySet) revert AgentRegistryAlreadySet();
        if (_agentRegistry == address(0)) revert ZeroAddress();
        agentRegistry    = IAgentRegistry(_agentRegistry);
        _agentRegistrySet = true;
        emit AgentRegistrySet(_agentRegistry);
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

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    // -------------------------------------------------------------------------
    // Proposal validation
    // -------------------------------------------------------------------------

    function _validateProposal(LoanProposal calldata proposal) internal view returns (bool needsApproval) {
        // 1. creditWallet zero-address guard (before any external calls).
        if (proposal.creditWallet == address(0)) revert ZeroAddress();

        // 2. msg.sender must be an AgentRegistry-authorized wallet for proposal.agentId.
        if (!agentRegistry.isAuthorizedWallet(proposal.agentId, msg.sender)) {
            revert CallerNotAgentWallet();
        }

        // 3. creditWallet must be an AgentRegistry-authorized wallet for proposal.agentId.
        if (!agentRegistry.isAuthorizedWallet(proposal.agentId, proposal.creditWallet)) {
            revert CreditWalletNotAgentWallet();
        }

        // 4. creditWallet must be RecipientRegistry-approved
        if (!recipientRegistry.isApproved(proposal.creditWallet)) revert UnapprovedRecipient();
        if (proposal.duration < minDuration || proposal.duration > maxDuration) revert DurationOutOfRange();
        if (proposal.permittedRecipients.length == 0) revert NoPermittedRecipients();
        if (proposal.milestoneAmounts.length != proposal.milestoneDescriptions.length) revert LengthMismatch();
        if (proposal.milestoneAmounts.length == 0) revert NoMilestones();

        // 5. All permittedRecipients must be RecipientRegistry-approved
        for (uint256 i = 0; i < proposal.permittedRecipients.length; i++) {
            if (!recipientRegistry.isApproved(proposal.permittedRecipients[i])) revert UnapprovedRecipient();
        }

        // 6. creditWallet must appear explicitly in permittedRecipients
        bool cwFound = false;
        for (uint256 i = 0; i < proposal.permittedRecipients.length; i++) {
            if (proposal.permittedRecipients[i] == proposal.creditWallet) {
                cwFound = true;
                break;
            }
        }
        if (!cwFound) revert CreditWalletNotInRecipients();

        // 7. Credit-limit / collateral checks
        if (proposal.collateralAmount > 0) {
            needsApproval = proposal.principal > collateralApprovalThreshold;
        } else {
            uint256 effectiveLimit = creditRegistry.getLimit(proposal.agentId);
            if (proposal.underwriterAmount > 0) {
                effectiveLimit += proposal.underwriterAmount;
            }
            uint256 usedCredit = outstandingPrincipal[proposal.agentId];
            uint256 available  = usedCredit >= effectiveLimit ? 0 : effectiveLimit - usedCredit;
            if (proposal.principal > available) revert ExceedsCreditLimit();
            needsApproval = creditRegistry.requiresApproval(proposal.principal);
        }

        // 8. Budget sum must equal principal
        uint256 budgetSum = 0;
        for (uint256 i = 0; i < proposal.budget.length; i++) {
            budgetSum += proposal.budget[i].cap;
        }
        if (budgetSum != proposal.principal) revert BudgetSumMismatch();

        // 9. Milestone sum must equal principal
        uint256 milestoneSum = 0;
        for (uint256 i = 0; i < proposal.milestoneAmounts.length; i++) {
            milestoneSum += proposal.milestoneAmounts[i];
        }
        if (milestoneSum != proposal.principal) revert MilestoneSumMismatch();
    }

    // -------------------------------------------------------------------------
    // Loan storage
    // -------------------------------------------------------------------------

    function _storeLoan(LoanProposal calldata proposal, bool needsApproval) internal returns (uint256 loanId) {
        loanId = nextLoanId++;
        Loan storage loan = _loans[loanId];
        loan.agentId          = proposal.agentId;
        loan.borrower         = msg.sender;
        loan.creditWallet     = proposal.creditWallet;
        loan.principal        = proposal.principal;
        loan.repaymentRateBps = proposal.repaymentRateBps;
        loan.totalRepaymentDue = proposal.totalRepaymentDue;
        loan.createdAt        = block.timestamp;
        loan.expiresAt        = block.timestamp + proposal.duration;
        loan.collateralAmount  = proposal.collateralAmount;
        loan.collateralAsset   = proposal.collateralAsset;
        loan.underwriterAmount = proposal.underwriterAmount;
        loan.purpose          = proposal.purpose;

        for (uint256 i = 0; i < proposal.budget.length; i++) {
            loan.budget.push(proposal.budget[i]);
        }
        for (uint256 i = 0; i < proposal.permittedRecipients.length; i++) {
            loan.permittedRecipients.push(proposal.permittedRecipients[i]);
        }
        for (uint256 i = 0; i < proposal.milestoneAmounts.length; i++) {
            loan.milestones.push(Milestone({
                amount:      proposal.milestoneAmounts[i],
                released:    false,
                description: proposal.milestoneDescriptions[i]
            }));
        }

        loan.status = needsApproval ? LoanStatus.PendingApproval : LoanStatus.Requested;
    }

    // -------------------------------------------------------------------------
    // requestLoan
    // -------------------------------------------------------------------------

    function requestLoan(LoanProposal calldata proposal) external returns (uint256 loanId) {
        bool needsApproval = _validateProposal(proposal);
        loanId = _storeLoan(proposal, needsApproval);

        // RISK-08: record principal as outstanding from request time, keyed by agentId.
        outstandingPrincipal[proposal.agentId] += proposal.principal;

        if (proposal.collateralAmount > 0) {
            // Resolve collateral asset: use proposal field if set, else fall back to
            // the vault's primary USDC address (backwards-compatible with existing tests
            // that omit collateralAsset).
            address asset = proposal.collateralAsset != address(0)
                ? proposal.collateralAsset
                : ICollateralVault(address(collateralVault)).usdc();
            // Persist the resolved asset on the stored loan.
            _loans[loanId].collateralAsset = asset;
            collateralVault.reserveCollateral(loanId, msg.sender, asset, proposal.collateralAmount, proposal.principal);
        } else if (proposal.underwriterAmount > 0) {
            underwriterPool.reserveStake(loanId, proposal.underwriter, msg.sender, proposal.underwriterAmount);
        }

        emit LoanRequested(loanId, msg.sender, proposal.principal, _loans[loanId].status);
    }

    // -------------------------------------------------------------------------
    // approveLoan
    // -------------------------------------------------------------------------

    function approveLoan(uint256 loanId) external onlyOwner {
        Loan storage loan = _loans[loanId];
        if (loan.status != LoanStatus.PendingApproval) revert LoanNotPendingApproval();
        loan.status = LoanStatus.Approved;
        emit LoanApproved(loanId, msg.sender);
        emit LoanStatusChanged(loanId, LoanStatus.Approved);
    }

    // -------------------------------------------------------------------------
    // markFunded
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // markMilestoneReleased
    // -------------------------------------------------------------------------

    function markMilestoneReleased(uint256 loanId, uint256 milestoneIndex) external onlyVault {
        Loan storage loan = _loans[loanId];
        if (loan.milestones[milestoneIndex].released) revert MilestoneAlreadyReleased();
        loan.milestones[milestoneIndex].released = true;
        emit MilestoneReleased(loanId, milestoneIndex, loan.milestones[milestoneIndex].amount);
    }

    // -------------------------------------------------------------------------
    // markDefault
    // -------------------------------------------------------------------------

    function markDefault(uint256 loanId) external {
        if (msg.sender != owner() && !keepers[msg.sender]) revert NotAuthorized();
        Loan storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active) revert LoanNotDefaultable();
        if (block.timestamp <= loan.expiresAt + defaultGracePeriod) revert DefaultGraceNotElapsed();

        loan.status = LoanStatus.Defaulted;

        // RISK-08: release outstanding principal reservation, keyed by agentId.
        outstandingPrincipal[loan.agentId] -= loan.principal;

        if (loan.collateralAmount > 0) {
            collateralVault.seize(loanId);
            creditRegistry.recordDefault(loan.agentId, false);
            emit LoanDefaulted(loanId, false);
        } else if (loan.underwriterAmount > 0) {
            underwriterPool.seize(loanId);
            creditRegistry.recordDefault(loan.agentId, false);
            emit LoanDefaulted(loanId, false);
        } else {
            uint256 recovered = IRevenueRouter(router).totalRecovered(loanId);
            bool severe = recovered == 0;
            creditRegistry.recordDefault(loan.agentId, severe);

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

    // -------------------------------------------------------------------------
    // markRepaid
    // -------------------------------------------------------------------------

    function markRepaid(uint256 loanId) external {
        if (msg.sender != router) revert NotRouter();
        Loan storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active && loan.status != LoanStatus.Defaulted) revert LoanNotActive();
        bool wasActive = loan.status == LoanStatus.Active;
        loan.status = LoanStatus.Repaid;

        // RISK-08: release outstanding principal only when transitioning from Active.
        // The Defaulted path already decremented in markDefault() (RISK-09 fix).
        if (wasActive) {
            outstandingPrincipal[loan.agentId] -= loan.principal;
        }

        if (loan.collateralAmount > 0) {
            collateralVault.release(loanId);
        } else if (loan.underwriterAmount > 0) {
            underwriterPool.release(loanId);
        }

        emit LoanStatusChanged(loanId, LoanStatus.Repaid);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getLoan(uint256 loanId) external view returns (LoanView memory) {
        Loan storage loan = _loans[loanId];
        return LoanView({
            agentId:          loan.agentId,
            borrower:         loan.borrower,
            lender:           loan.lender,
            creditWallet:     loan.creditWallet,
            principal:        loan.principal,
            totalRepaymentDue: loan.totalRepaymentDue,
            repaymentRateBps: loan.repaymentRateBps,
            status:           loan.status,
            createdAt:        loan.createdAt,
            expiresAt:        loan.expiresAt
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

    function getCollateralAsset(uint256 loanId) external view returns (address) {
        return _loans[loanId].collateralAsset;
    }

    function getUnderwriterAmount(uint256 loanId) external view returns (uint256) {
        return _loans[loanId].underwriterAmount;
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
