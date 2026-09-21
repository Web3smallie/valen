// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILoanRegistry {
    enum LoanStatus {
        Requested,
        PendingApproval,
        Approved,
        Funded,
        Active,
        Repaid,
        Defaulted,
        Expired,
        Cancelled
    }

    struct Milestone {
        uint256 amount;
        bool released;
        string description;
    }

    struct BudgetCategory {
        bytes32 categoryId;
        uint256 cap;
    }

    struct LoanView {
        address borrower;
        address lender;
        address creditWallet;
        uint256 principal;
        uint256 totalRepaymentDue;
        uint16 repaymentRateBps;
        LoanStatus status;
        uint256 createdAt;
        uint256 expiresAt;
    }

       struct LoanProposal {
        address creditWallet;
        uint256 principal;
        uint16 repaymentRateBps;
        uint256 totalRepaymentDue;
        uint256 duration;
        string purpose;
        BudgetCategory[] budget;
        address[] permittedRecipients;
        uint256[] milestoneAmounts;
        string[] milestoneDescriptions;
        uint256 collateralAmount; // Path A: >0 = collateral-backed
        address underwriter;      // Path B: address(0) = no underwriter
        uint256 underwriterAmount; // Path B: >0 = underwriter-backed amount
    }

    function getCollateralAmount(uint256 loanId) external view returns (uint256);
    function getUnderwriterAmount(uint256 loanId) external view returns (uint256);
    function getLoan(uint256 loanId) external view returns (LoanView memory);
    function getMilestones(uint256 loanId) external view returns (Milestone[] memory);
    function getBudget(uint256 loanId) external view returns (BudgetCategory[] memory);
    function getPermittedRecipients(uint256 loanId) external view returns (address[] memory);
    function markFunded(uint256 loanId, address lender) external;
    function markMilestoneReleased(uint256 loanId, uint256 milestoneIndex) external;
    function markRepaid(uint256 loanId) external;
    function nextLoanId() external view returns (uint256);
}
