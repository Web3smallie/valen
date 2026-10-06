// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";
import {ICreditRegistry} from "./interfaces/ICreditRegistry.sol";
import {IRevenueRouter} from "./interfaces/IRevenueRouter.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {IReservePool} from "./interfaces/IReservePool.sol";

contract RevenueRouter is Initializable, OwnableUpgradeable, UUPSUpgradeable, IRevenueRouter {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Storage (slots 0–9 documented in storage-snapshots/RevenueRouter.json)
    // -------------------------------------------------------------------------

    ILoanRegistry   public registry;          // slot 0
    ICreditRegistry public creditRegistry;    // slot 1
    IReservePool    public reservePool;        // slot 2
    IERC20          public usdc;               // slot 3

    uint256 private constant BPS_DENOMINATOR = 10000;
    uint16  public reserveBps;                 // slot 4 (packed)

    mapping(uint256 => uint256) public totalRecovered;   // slot 5
    mapping(uint256 => bool)    public repaidHandled;    // slot 6

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _reentrancyStatus;                   // slot 6 (packed after repaidHandled mapping? no — mappings occupy a full slot)

    /// @notice For each defaulted loan, tracks how much of the reserve
    ///         payout has been clawed back via post-default garnishments
    ///         (RISK-09 fix). Appended at slot 7, after _reentrancyStatus.
    mapping(uint256 => uint256) public reserveRepaid;    // slot 7

    /// @notice AgentRegistry for wallet-to-agent authorization checks.
    ///         Stored at slot 8, appended after reserveRepaid (slot 7).
    ///         Packed with _agentRegistrySet (bool, 1 byte) in the same slot.
    IAgentRegistry public agentRegistry;                 // slot 8 (20 bytes)

    /// @notice One-way lock: true once setAgentRegistry has been called.
    bool private _agentRegistrySet;                      // slot 8 (packed, byte 20)

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RevenueReceived(uint256 indexed loanId, address indexed payer, uint256 amount);
    event SelfRepayment(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event RepaymentRecovered(uint256 indexed loanId, uint256 repaymentShare, uint256 creditWalletShare);
    event ReserveContribution(uint256 indexed loanId, uint256 amount);
    event LoanFullyRepaid(uint256 indexed loanId, uint256 totalRecoveredAmount, bool early, bool viaDefaultGarnishment);
    event ReservePoolSet(address indexed reservePool);
    event ReserveBpsSet(uint16 reserveBps);
    event AgentRegistrySet(address indexed agentRegistry);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error ReentrantCall();
    error ZeroAmount();
    error LoanNotReceivingRevenue();
    error PayerNotAllowed();
    error ReservePoolAlreadySet();
    error AgentRegistryAlreadySet();
    error CallerNotAgentWallet();
    error LoansAlreadyExist();

    // -------------------------------------------------------------------------
    // Reentrancy
    // -------------------------------------------------------------------------

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

    function initialize(address initialOwner, address _registry, address _creditRegistry, address _usdc)
        external
        initializer
    {
        if (_registry == address(0) || _creditRegistry == address(0) || _usdc == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        registry       = ILoanRegistry(_registry);
        creditRegistry = ICreditRegistry(_creditRegistry);
        usdc           = IERC20(_usdc);
        _reentrancyStatus = _NOT_ENTERED;
    }

    // -------------------------------------------------------------------------
    // Setters
    // -------------------------------------------------------------------------

    function setReservePool(address _reservePool, uint16 _reserveBps) external onlyOwner {
        if (registry.nextLoanId() > 0) revert LoansAlreadyExist();
        if (_reservePool == address(0)) revert ZeroAddress();
        reservePool = IReservePool(_reservePool);
        reserveBps  = _reserveBps;
        emit ReservePoolSet(_reservePool);
        emit ReserveBpsSet(_reserveBps);
    }

    /// @notice One-time setter: wire the AgentRegistry. Cannot be changed after first call.
    function setAgentRegistry(address _agentRegistry) external onlyOwner {
        if (_agentRegistrySet) revert AgentRegistryAlreadySet();
        if (_agentRegistry == address(0)) revert ZeroAddress();
        _agentRegistrySet = true;
        agentRegistry     = IAgentRegistry(_agentRegistry);
        emit AgentRegistrySet(_agentRegistry);
    }

    function setReserveBps(uint16 _reserveBps) external onlyOwner {
        reserveBps = _reserveBps;
        emit ReserveBpsSet(_reserveBps);
    }

    // -------------------------------------------------------------------------
    // Revenue receipt (third-party payer)
    // -------------------------------------------------------------------------

    function payRevenue(uint256 loanId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        _checkLoanReceivable(loan);

        // Reject any caller who is an authorized wallet of the agent:
        // agent wallets must use repayLoan(), which records a SelfRepayment event
        // and routes through the no-split path. This prevents the agent from
        // disguising self-repayment as third-party revenue to game the split.
        if (agentRegistry.isAuthorizedWallet(loan.agentId, msg.sender)) revert PayerNotAllowed();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit RevenueReceived(loanId, msg.sender, amount);

        _applyPayment(loanId, loan, amount, true);
    }

    // -------------------------------------------------------------------------
    // Self-repayment (agent wallet)
    // -------------------------------------------------------------------------

    function repayLoan(uint256 loanId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        _checkLoanReceivable(loan);

        // Only an AgentRegistry-authorized wallet for this agent may self-repay.
        if (!agentRegistry.isAuthorizedWallet(loan.agentId, msg.sender)) revert CallerNotAgentWallet();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit SelfRepayment(loanId, msg.sender, amount);

        _applyPayment(loanId, loan, amount, false);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _checkLoanReceivable(ILoanRegistry.LoanView memory loan) internal pure {
        if (
            loan.status != ILoanRegistry.LoanStatus.Active &&
            loan.status != ILoanRegistry.LoanStatus.Defaulted &&
            loan.status != ILoanRegistry.LoanStatus.Repaid
        ) {
            revert LoanNotReceivingRevenue();
        }
    }

    function _applyPayment(
        uint256 loanId,
        ILoanRegistry.LoanView memory loan,
        uint256 amount,
        bool splitEnabled
    ) internal {
        bool isDefaulted = loan.status == ILoanRegistry.LoanStatus.Defaulted;

        if (repaidHandled[loanId]) {
            usdc.safeTransfer(loan.creditWallet, amount);
            return;
        }

        uint256 remainingDebt = loan.totalRepaymentDue - totalRecovered[loanId];
        uint256 repaymentShare;
        if (!splitEnabled || isDefaulted) {
            repaymentShare = amount > remainingDebt ? remainingDebt : amount;
        } else {
            repaymentShare = (amount * loan.repaymentRateBps) / BPS_DENOMINATOR;
            if (repaymentShare > remainingDebt) {
                repaymentShare = remainingDebt;
            }
        }
        uint256 creditWalletShare = amount - repaymentShare;

        totalRecovered[loanId] += repaymentShare;
        emit RepaymentRecovered(loanId, repaymentShare, creditWalletShare);

        // Reserve skim only on normal (non-default) repayment share.
        // Debt is still reduced by the full repaymentShare regardless of
        // where that money ends up — the reserve cut comes out of the
        // lender's take, functioning as an insurance premium.
        uint256 lenderShare = repaymentShare;
        if (!isDefaulted && address(reservePool) != address(0) && reserveBps > 0 && repaymentShare > 0) {
            uint256 reserveCut = (repaymentShare * reserveBps) / BPS_DENOMINATOR;
            if (reserveCut > 0) {
                lenderShare = repaymentShare - reserveCut;
                usdc.safeTransfer(address(reservePool), reserveCut);
                reservePool.recordContribution(loanId, reserveCut);
                emit ReserveContribution(loanId, reserveCut);
            }
        }

        // RISK-09 fix: for defaulted loans that received a reserve payout,
        // redirect post-default garnishments back to the reserve (up to the
        // outstanding payout balance) before crediting the lender. This
        // prevents the lender from receiving both the reserve payout and
        // the subsequent garnishment, and keeps pool accounting correct
        // because only funds physically reaching the pool are credited via
        // poolRecovered() rather than totalRecovered().
        if (isDefaulted && address(reservePool) != address(0) && lenderShare > 0) {
            uint256 paid = reservePool.loanPayout(loanId);
            if (paid > 0) {
                uint256 remaining = paid - reserveRepaid[loanId];
                if (remaining > 0) {
                    uint256 toReserve = lenderShare > remaining ? remaining : lenderShare;
                    reserveRepaid[loanId] += toReserve;
                    usdc.safeTransfer(address(reservePool), toReserve);
                    lenderShare -= toReserve;
                }
            }
        }

        bool justCompleted = totalRecovered[loanId] >= loan.totalRepaymentDue;
        if (justCompleted) {
            repaidHandled[loanId] = true;
        }

        if (lenderShare > 0) {
            usdc.safeTransfer(loan.lender, lenderShare);
        }
        if (creditWalletShare > 0) {
            usdc.safeTransfer(loan.creditWallet, creditWalletShare);
        }

        if (justCompleted) {
            registry.markRepaid(loanId);
            if (isDefaulted) {
                emit LoanFullyRepaid(loanId, totalRecovered[loanId], false, true);
            } else {
                bool early = block.timestamp < loan.expiresAt;
                // Step 5: repayment credit goes to loan.agentId — not loan.borrower.
                creditRegistry.recordRepayment(loan.agentId, loan.totalRepaymentDue, early);
                emit LoanFullyRepaid(loanId, totalRecovered[loanId], early, false);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function isFullyRepaid(uint256 loanId) external view returns (bool) {
        return repaidHandled[loanId];
    }

    /// @notice Returns the portion of totalRecovered that physically
    ///         reached the lender/pool — i.e., excluding any amount
    ///         redirected to the ReservePool as garnishment claw-back
    ///         (RISK-09 fix). LiquidityPool.reconcileLoan uses this
    ///         instead of totalRecovered to avoid crediting funds that
    ///         never arrived at the pool.
    function poolRecovered(uint256 loanId) external view returns (uint256) {
        uint256 rec = totalRecovered[loanId];
        uint256 rep = reserveRepaid[loanId];
        return rec > rep ? rec - rep : 0;
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
