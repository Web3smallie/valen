// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILoanRegistry {
    // -------------------------------------------------------------------------
    // Enumerations
    // -------------------------------------------------------------------------

    enum LoanStatus {
        Requested,       // 0 — accepted, awaiting funding
        PendingApproval, // 1 — above threshold; needs admin sign-off
        Approved,        // 2 — admin-approved, awaiting funding
        Funded,          // 3 — reserved; not emitted in V1
        Active,          // 4 — funded and running
        Repaid,          // 5 — fully repaid
        Defaulted,       // 6 — defaulted
        Expired,         // 7 — reserved; not emitted in V1
        Cancelled        // 8 — reserved; not emitted in V1
    }

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct Milestone {
        uint256 amount;
        bool released;
        string description;
    }

    struct BudgetCategory {
        bytes32 categoryId;
        uint256 cap;
    }

    /// @notice Read-only loan snapshot returned by getLoan().
    struct LoanView {
        uint256 agentId;       // Valen agentId — the persistent credit identity
        address borrower;      // msg.sender at requestLoan time; historical context only
        address lender;
        address creditWallet;
        uint256 principal;
        uint256 totalRepaymentDue;
        uint16  repaymentRateBps;
        LoanStatus status;
        uint256 createdAt;
        uint256 expiresAt;
    }

    /// @notice Proposal submitted by an agent to request a loan.
    /// @dev    agentId must be a registered Valen agentId.
    ///         msg.sender must be an AgentRegistry-authorized wallet for agentId.
    ///         creditWallet must also be an AgentRegistry-authorized wallet for agentId
    ///         AND must be RecipientRegistry-approved AND must appear in permittedRecipients.
    struct LoanProposal {
        uint256 agentId;           // Valen agentId of the borrowing agent
        address creditWallet;      // AgentRegistry-authorized + RecipientRegistry-approved spending wallet
        uint256 principal;
        uint16  repaymentRateBps;
        uint256 totalRepaymentDue;
        uint256 duration;
        string  purpose;
        BudgetCategory[]  budget;
        address[] permittedRecipients;
        uint256[] milestoneAmounts;
        string[]  milestoneDescriptions;
        uint256 collateralAmount;      // Path A: >0 = collateral-backed (raw token units)
        address collateralAsset;       // Path A: ERC-20 token used as collateral (address(0) = USDC default)
        address underwriter;           // Path B: address(0) = no underwriter
        uint256 underwriterAmount;     // Path B: >0 = underwriter-backed amount
        bool    directDisbursement;    // When true: full principal is sent to creditWallet at funding time,
                                       //            bypassing per-milestone release calls.
                                       // When false (default): funds are released per milestone as before.
                                       // Immutable after requestLoan; cannot be changed post-approval.
    }

    // -------------------------------------------------------------------------
    // View
    // -------------------------------------------------------------------------

    function getCollateralAmount(uint256 loanId) external view returns (uint256);
    function getCollateralAsset(uint256 loanId) external view returns (address);
    function getUnderwriterAmount(uint256 loanId) external view returns (uint256);
    function getDirectDisbursement(uint256 loanId) external view returns (bool);
    function getLoan(uint256 loanId) external view returns (LoanView memory);
    function getMilestones(uint256 loanId) external view returns (Milestone[] memory);
    function getBudget(uint256 loanId) external view returns (BudgetCategory[] memory);
    function getPermittedRecipients(uint256 loanId) external view returns (address[] memory);
    function nextLoanId() external view returns (uint256);

    // -------------------------------------------------------------------------
    // State-changing (called by vault / router)
    // -------------------------------------------------------------------------

    function markFunded(uint256 loanId, address lender) external;
    function markMilestoneReleased(uint256 loanId, uint256 milestoneIndex) external;
    function markRepaid(uint256 loanId) external;
}
