// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}          from "forge-std/Test.sol";
import {ERC1967Proxy}  from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentRegistry}     from "../src/AgentRegistry.sol";
import {LoanRegistry}      from "../src/LoanRegistry.sol";
import {CreditRegistry}    from "../src/CreditRegistry.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ILoanRegistry}     from "../src/interfaces/ILoanRegistry.sol";
import {ERC20}             from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------------------
// Minimal stubs
// ---------------------------------------------------------------------------

contract MockUSDC_LR is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// A minimal vault stub: only markFunded and markMilestoneReleased calls.
contract StubVault_LR {
    LoanRegistry public reg;
    constructor(address _reg) { reg = LoanRegistry(_reg); }
    function fund(uint256 loanId, address lender) external { reg.markFunded(loanId, lender); }
    function releaseMilestone(uint256 loanId, uint256 idx) external { reg.markMilestoneReleased(loanId, idx); }
}

// A minimal router stub: only markRepaid.
contract StubRouter_LR {
    LoanRegistry public reg;
    constructor(address _reg) { reg = LoanRegistry(_reg); }
    function repay(uint256 loanId) external { reg.markRepaid(loanId); }
    function totalRecovered(uint256) external pure returns (uint256) { return 0; }
}

// ---------------------------------------------------------------------------
// Test contract
// ---------------------------------------------------------------------------

contract LoanRegistryTest is Test {

    // ── Protocol actors ──────────────────────────────────────────────────────
    address owner      = address(this);
    address borrower   = address(0xB0);
    address creditWallet = address(0xC0FFEE);
    address lender     = address(0x1E);
    address stranger   = address(0xDEAD);

    // ── Deployed instances ───────────────────────────────────────────────────
    AgentRegistry      agentReg;
    LoanRegistry       registry;
    CreditRegistry     creditReg;
    RecipientRegistry  recipientReg;
    StubVault_LR       vault;
    StubRouter_LR      router;

    uint256 agentId;

    // ── Proposal constants ───────────────────────────────────────────────────
    uint256 constant PRINCIPAL    = 1_000e6;
    uint256 constant TOTAL_DUE    = 1_150e6;
    uint16  constant RATE_BPS     = 1500;
    uint256 constant MIN_DUR      = 1 days;
    uint256 constant MAX_DUR      = 365 days;
    uint256 constant GRACE        = 3 days;
    uint256 constant COLL_THRESH  = 10_000e6;
    uint256 constant INITIAL_LIMIT = 5_000e6;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        // AgentRegistry
        agentReg = AgentRegistry(address(new ERC1967Proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        )));
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        // CreditRegistry — initialLimit=5_000e6 so borrower has room
        creditReg = CreditRegistry(address(new ERC1967Proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize,
                (owner, 5e6, 2500, 1000, 2000e6, 2000, 25_000e6, 500, 50e6, 50_000e6))
        )));

        // LoanRegistry
        registry = LoanRegistry(address(new ERC1967Proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), MIN_DUR, MAX_DUR, GRACE, COLL_THRESH))
        )));

        // RecipientRegistry
        recipientReg = RecipientRegistry(address(new ERC1967Proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        )));
        recipientReg.approveRecipient(creditWallet, keccak256("SVC"), "Credit Wallet");

        // Stubs
        vault  = new StubVault_LR(address(registry));
        router = new StubRouter_LR(address(registry));

        // Wire
        registry.setContracts(address(vault), address(router));
        registry.setRecipientRegistry(address(recipientReg));
        registry.setAgentRegistry(address(agentReg));

        // Authorize registry to call CreditRegistry
        creditReg.setAuthorizedCaller(address(registry), true);
        creditReg.setAuthorizedCaller(address(router), true);

        // Seed credit so borrower has INITIAL_LIMIT available
        vm.prank(address(router));
        creditReg.recordRepayment(agentId, 5_000e6, false);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _proposal(uint256 principal, uint256 totalDue) internal view returns (ILoanRegistry.LoanProposal memory) {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("SVC"), cap: principal});

        address[] memory recipients = new address[](1);
        recipients[0] = creditWallet;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = principal;
        string[] memory descs = new string[](1);
        descs[0] = "Milestone 1";

        return ILoanRegistry.LoanProposal({
            agentId:              agentId,
            creditWallet:         creditWallet,
            principal:            principal,
            repaymentRateBps:     RATE_BPS,
            totalRepaymentDue:    totalDue,
            duration:             30 days,
            purpose:              "Test loan",
            budget:               budget,
            permittedRecipients:  recipients,
            milestoneAmounts:     amounts,
            milestoneDescriptions: descs,
            collateralAmount:     0,
            collateralAsset:       address(0),
            underwriter:          address(0),
            underwriterAmount:    0
        });
    }

    function _defaultProposal() internal view returns (ILoanRegistry.LoanProposal memory) {
        return _proposal(PRINCIPAL, TOTAL_DUE);
    }

    function _requestAndFund() internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = registry.requestLoan(_defaultProposal());
        vault.fund(loanId, lender);
    }

    // ── setAgentRegistry tests ────────────────────────────────────────────────

    function test_SetAgentRegistry_StoredCorrectly() public view {
        assertEq(address(registry.agentRegistry()), address(agentReg));
    }

    function test_SetAgentRegistry_RevertsOnSecondCall() public {
        vm.expectRevert(LoanRegistry.AgentRegistryAlreadySet.selector);
        registry.setAgentRegistry(address(agentReg));
    }

    function test_SetAgentRegistry_RevertsOnZeroAddress() public {
        // Deploy a fresh registry that hasn't had setAgentRegistry called yet
        LoanRegistry fresh = LoanRegistry(address(new ERC1967Proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), MIN_DUR, MAX_DUR, GRACE, COLL_THRESH))
        )));
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        fresh.setAgentRegistry(address(0));
    }

    function test_SetAgentRegistry_OnlyOwner() public {
        LoanRegistry fresh = LoanRegistry(address(new ERC1967Proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), MIN_DUR, MAX_DUR, GRACE, COLL_THRESH))
        )));
        vm.prank(stranger);
        vm.expectRevert();   // OwnableUnauthorizedAccount
        fresh.setAgentRegistry(address(agentReg));
    }

    // ── requestLoan: happy path ───────────────────────────────────────────────

    function test_RequestLoan_Succeeds_And_StoresLoan() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_defaultProposal());

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(loan.agentId,           agentId);
        assertEq(loan.borrower,          borrower);
        assertEq(loan.creditWallet,      creditWallet);
        assertEq(loan.principal,         PRINCIPAL);
        assertEq(loan.totalRepaymentDue, TOTAL_DUE);
        assertEq(uint8(loan.status),     uint8(ILoanRegistry.LoanStatus.Requested));
    }

    function test_RequestLoan_IncrementsOutstandingPrincipal() public {
        vm.prank(borrower);
        registry.requestLoan(_defaultProposal());
        assertEq(registry.outstandingPrincipal(agentId), PRINCIPAL);
    }

    function test_RequestLoan_IncrementsNextLoanId() public {
        assertEq(registry.nextLoanId(), 0);
        vm.prank(borrower);
        registry.requestLoan(_defaultProposal());
        assertEq(registry.nextLoanId(), 1);
    }

    function test_RequestLoan_EmitsLoanRequested() public {
        vm.prank(borrower);
        vm.expectEmit(true, true, false, true);
        emit LoanRegistry.LoanRequested(0, borrower, PRINCIPAL, ILoanRegistry.LoanStatus.Requested);
        registry.requestLoan(_defaultProposal());
    }

    // ── requestLoan: CallerNotAgentWallet ─────────────────────────────────────

    function test_RequestLoan_RevertsWhen_CallerNotAgentWallet() public {
        // stranger is not registered as a wallet for agentId
        vm.prank(stranger);
        vm.expectRevert(LoanRegistry.CallerNotAgentWallet.selector);
        registry.requestLoan(_defaultProposal());
    }

    function test_RequestLoan_RevertsWhen_WrongAgentId() public {
        // borrower is authorized for agentId but not for agentId+1
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.agentId = agentId + 1; // non-existent agent
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.CallerNotAgentWallet.selector);
        registry.requestLoan(p);
    }

    // ── requestLoan: CreditWalletNotAgentWallet ───────────────────────────────

    function test_RequestLoan_RevertsWhen_CreditWalletNotAgentWallet() public {
        address unregisteredCW = address(0xBAD);
        // Approve it in RecipientRegistry but NOT in AgentRegistry
        recipientReg.approveRecipient(unregisteredCW, keccak256("SVC"), "Bad CW");

        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.creditWallet = unregisteredCW;
        // Also update permittedRecipients and budget to stay consistent
        address[] memory r = new address[](1);
        r[0] = unregisteredCW;
        p.permittedRecipients = r;

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.CreditWalletNotAgentWallet.selector);
        registry.requestLoan(p);
    }

    // ── requestLoan: UnapprovedRecipient ──────────────────────────────────────

    function test_RequestLoan_RevertsWhen_CreditWalletNotApproved() public {
        address unapproved = address(0xBAD2);
        // Register in AgentRegistry but NOT in RecipientRegistry
        vm.prank(borrower);
        agentReg.addWallet(agentId, unapproved);

        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.creditWallet = unapproved;
        address[] memory r = new address[](1);
        r[0] = unapproved;
        p.permittedRecipients = r;

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.UnapprovedRecipient.selector);
        registry.requestLoan(p);
    }

    // ── requestLoan: CreditWalletNotInRecipients ──────────────────────────────

    function test_RequestLoan_RevertsWhen_CreditWalletNotInPermittedRecipients() public {
        // creditWallet is approved in both registries but excluded from permittedRecipients
        address otherRecipient = address(0xAA);
        recipientReg.approveRecipient(otherRecipient, keccak256("SVC"), "Other");
        vm.prank(borrower);
        agentReg.addWallet(agentId, otherRecipient);

        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        // permittedRecipients contains otherRecipient only — creditWallet is absent
        address[] memory r = new address[](1);
        r[0] = otherRecipient;
        p.permittedRecipients = r;
        p.creditWallet = creditWallet; // creditWallet authorized in both, but not in permittedRecipients

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.CreditWalletNotInRecipients.selector);
        registry.requestLoan(p);
    }

    // ── requestLoan: DurationOutOfRange ───────────────────────────────────────

    function test_RequestLoan_RevertsWhen_DurationTooShort() public {
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.duration = MIN_DUR - 1;
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.DurationOutOfRange.selector);
        registry.requestLoan(p);
    }

    function test_RequestLoan_RevertsWhen_DurationTooLong() public {
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.duration = MAX_DUR + 1;
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.DurationOutOfRange.selector);
        registry.requestLoan(p);
    }

    // ── requestLoan: NoMilestones / LengthMismatch ────────────────────────────

    function test_RequestLoan_RevertsWhen_NoMilestones() public {
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.milestoneAmounts = new uint256[](0);
        p.milestoneDescriptions = new string[](0);
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.NoMilestones.selector);
        registry.requestLoan(p);
    }

    function test_RequestLoan_RevertsWhen_MilestoneLengthMismatch() public {
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        string[] memory descs = new string[](2);
        descs[0] = "A";
        descs[1] = "B";
        p.milestoneDescriptions = descs;
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.LengthMismatch.selector);
        registry.requestLoan(p);
    }

    // ── requestLoan: ExceedsCreditLimit ───────────────────────────────────────

    function test_RequestLoan_RevertsWhen_ExceedsCreditLimit() public {
        // After the setUp seed, getLimit(agentId) is ~5_000e6.
        // Request just above that.
        uint256 tooMuch = 10_000e6;
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.principal = tooMuch;
        p.totalRepaymentDue = tooMuch * 115 / 100;
        p.budget[0].cap = tooMuch;
        p.milestoneAmounts[0] = tooMuch;

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.ExceedsCreditLimit.selector);
        registry.requestLoan(p);
    }

    // ── requestLoan: BudgetSumMismatch ────────────────────────────────────────

    function test_RequestLoan_RevertsWhen_BudgetSumMismatch() public {
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.budget[0].cap = p.principal + 1; // sum != principal
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.BudgetSumMismatch.selector);
        registry.requestLoan(p);
    }

    // ── requestLoan: MilestoneSumMismatch ─────────────────────────────────────

    function test_RequestLoan_RevertsWhen_MilestoneSumMismatch() public {
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.milestoneAmounts[0] = p.principal + 1;
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.MilestoneSumMismatch.selector);
        registry.requestLoan(p);
    }

    // ── markFunded ────────────────────────────────────────────────────────────

    function test_MarkFunded_TransitionsToActive() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_defaultProposal());
        vault.fund(loanId, lender);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Active));
        assertEq(loan.lender, lender);
    }

    function test_MarkFunded_RevertsWhen_NotVault() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_defaultProposal());
        vm.prank(stranger);
        vm.expectRevert(LoanRegistry.NotVault.selector);
        registry.markFunded(loanId, lender);
    }

    function test_MarkFunded_RevertsWhen_LoanNotRequestable() public {
        uint256 loanId = _requestAndFund();
        // Already Active — funding again must revert
        vm.expectRevert(LoanRegistry.LoanNotRequestable.selector);
        vault.fund(loanId, lender);
    }

    // ── markRepaid ────────────────────────────────────────────────────────────

    function test_MarkRepaid_TransitionsToRepaid_And_ReleasesOutstanding() public {
        uint256 loanId = _requestAndFund();
        assertEq(registry.outstandingPrincipal(agentId), PRINCIPAL);

        router.repay(loanId);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Repaid));
        assertEq(registry.outstandingPrincipal(agentId), 0);
    }

    function test_MarkRepaid_RevertsWhen_NotRouter() public {
        uint256 loanId = _requestAndFund();
        vm.prank(stranger);
        vm.expectRevert(LoanRegistry.NotRouter.selector);
        registry.markRepaid(loanId);
    }

    function test_MarkRepaid_RevertsWhen_LoanNotActive() public {
        uint256 loanId = _requestAndFund();
        router.repay(loanId);
        // Already Repaid — second repay must revert
        vm.expectRevert(LoanRegistry.LoanNotActive.selector);
        router.repay(loanId);
    }

    // ── markDefault ───────────────────────────────────────────────────────────

    function test_MarkDefault_TransitionsToDefaulted_And_ReleasesOutstanding() public {
        uint256 loanId = _requestAndFund();
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        registry.markDefault(loanId);

        loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Defaulted));
        assertEq(registry.outstandingPrincipal(agentId), 0);
    }

    function test_MarkDefault_RevertsWhen_GraceNotElapsed() public {
        uint256 loanId = _requestAndFund();
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE - 1); // one second too early

        vm.expectRevert(LoanRegistry.DefaultGraceNotElapsed.selector);
        registry.markDefault(loanId);
    }

    function test_MarkDefault_RevertsWhen_NotAuthorized() public {
        uint256 loanId = _requestAndFund();
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        vm.prank(stranger);
        vm.expectRevert(LoanRegistry.NotAuthorized.selector);
        registry.markDefault(loanId);
    }

    function test_MarkDefault_RevertsWhen_LoanNotActive() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_defaultProposal());
        // Loan is Requested, not Active
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        vm.expectRevert(LoanRegistry.LoanNotDefaultable.selector);
        registry.markDefault(loanId);
    }

    function test_MarkDefault_ByKeeper_Succeeds() public {
        address keeper = address(0x4EE9);
        registry.setKeeper(keeper, true);

        uint256 loanId = _requestAndFund();
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        vm.prank(keeper);
        registry.markDefault(loanId);

        loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Defaulted));
    }

    function test_RevokedKeeper_CannotDefault() public {
        address keeper = address(0x4EE9);
        registry.setKeeper(keeper, true);
        registry.setKeeper(keeper, false);

        uint256 loanId = _requestAndFund();
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        vm.prank(keeper);
        vm.expectRevert(LoanRegistry.NotAuthorized.selector);
        registry.markDefault(loanId);
    }

    // ── outstandingPrincipal: multi-loan accumulation ─────────────────────────

    function test_OutstandingPrincipal_AccumulatesAcrossLoans() public {
        // Seed extra credit so two loans fit
        vm.prank(address(router));
        creditReg.recordRepayment(agentId, 5_000e6, false);

        uint256 p1 = 500e6;
        uint256 p2 = 700e6;

        ILoanRegistry.LoanProposal memory prop1 = _proposal(p1, p1 * 115 / 100);
        prop1.budget[0].cap = p1;
        prop1.milestoneAmounts[0] = p1;

        ILoanRegistry.LoanProposal memory prop2 = _proposal(p2, p2 * 115 / 100);
        prop2.budget[0].cap = p2;
        prop2.milestoneAmounts[0] = p2;

        vm.prank(borrower);
        registry.requestLoan(prop1);
        assertEq(registry.outstandingPrincipal(agentId), p1);

        vm.prank(borrower);
        registry.requestLoan(prop2);
        assertEq(registry.outstandingPrincipal(agentId), p1 + p2);
    }

    function test_OutstandingPrincipal_DoubleRepay_CannotDecrement_Twice() public {
        uint256 loanId = _requestAndFund();
        router.repay(loanId);
        assertEq(registry.outstandingPrincipal(agentId), 0);

        // Second repay must revert before any decrement
        vm.expectRevert(LoanRegistry.LoanNotActive.selector);
        router.repay(loanId);
        assertEq(registry.outstandingPrincipal(agentId), 0);
    }

    // ── agentId stored in loan ────────────────────────────────────────────────

    function test_LoanView_ContainsCorrectAgentId() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_defaultProposal());
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(loan.agentId, agentId);
    }

    // ── PendingApproval threshold ─────────────────────────────────────────────

    function test_RequestLoan_AboveApprovalThreshold_SetsStatusPendingApproval() public {
        // CreditRegistry requiresApproval fires at principal > 25_000e6.
        // Collateral-backed loan of exactly COLL_THRESH passes threshold logic for approval.
        // Use collateral-backed path: principal > collateralApprovalThreshold → PendingApproval.
        uint256 bigPrincipal = COLL_THRESH + 1;

        // Can't test collateral-backed without CollateralVault wired.
        // Test the unsecured approval path: requiresApproval = principal > 25_000e6.
        // Each recordRepayment call adds min(5_000e6 * 25%, 2_000e6) = 1_250e6 credit.
        // setUp seeds 1 repayment. Seed 21 more to reach ~27_505e6 limit (> 26_000e6).
        for (uint256 i = 0; i < 21; i++) {
            vm.prank(address(router));
            creditReg.recordRepayment(agentId, 5_000e6, false);
        }

        uint256 overApproval = 26_000e6;
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.principal = overApproval;
        p.totalRepaymentDue = overApproval * 115 / 100;
        p.budget[0].cap = overApproval;
        p.milestoneAmounts[0] = overApproval;

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(p);
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.PendingApproval));
    }

    function test_ApproveLoan_TransitionsToApproved() public {
        // Seed enough credit — same calculation as PendingApproval test above.
        for (uint256 i = 0; i < 21; i++) {
            vm.prank(address(router));
            creditReg.recordRepayment(agentId, 5_000e6, false);
        }

        uint256 overApproval = 26_000e6;
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.principal = overApproval;
        p.totalRepaymentDue = overApproval * 115 / 100;
        p.budget[0].cap = overApproval;
        p.milestoneAmounts[0] = overApproval;

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(p);

        registry.approveLoan(loanId);
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Approved));
    }

    function test_ApproveLoan_RevertsWhen_NotPendingApproval() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_defaultProposal());
        // Status is Requested, not PendingApproval
        vm.expectRevert(LoanRegistry.LoanNotPendingApproval.selector);
        registry.approveLoan(loanId);
    }

    // ── setContracts: one-time lock ───────────────────────────────────────────

    function test_SetContracts_RevertsOnSecondCall() public {
        vm.expectRevert(LoanRegistry.ContractsAlreadySet.selector);
        registry.setContracts(address(vault), address(router));
    }

    function test_SetContracts_RevertsOnSecondCallWithDifferentArgs() public {
        vm.expectRevert(LoanRegistry.ContractsAlreadySet.selector);
        registry.setContracts(address(0xBEEF), address(0xCAFE));
    }

    // ── setCollateralVault / setReservePool: LoansAlreadyExist ───────────────

    function test_SetCollateralVault_RevertsAfterFirstLoan() public {
        vm.prank(borrower);
        registry.requestLoan(_defaultProposal());
        vm.expectRevert(LoanRegistry.LoansAlreadyExist.selector);
        registry.setCollateralVault(address(0xABCD));
    }

    function test_SetReservePool_RevertsAfterFirstLoan() public {
        vm.prank(borrower);
        registry.requestLoan(_defaultProposal());
        vm.expectRevert(LoanRegistry.LoansAlreadyExist.selector);
        registry.setReservePool(address(0xABCD));
    }

    // ── Milestone released ────────────────────────────────────────────────────

    function test_MarkMilestoneReleased_Succeeds() public {
        uint256 loanId = _requestAndFund();
        vault.releaseMilestone(loanId, 0);
        ILoanRegistry.Milestone[] memory milestones = registry.getMilestones(loanId);
        assertTrue(milestones[0].released);
    }

    function test_MarkMilestoneReleased_RevertsWhen_AlreadyReleased() public {
        uint256 loanId = _requestAndFund();
        vault.releaseMilestone(loanId, 0);
        vm.expectRevert(LoanRegistry.MilestoneAlreadyReleased.selector);
        vault.releaseMilestone(loanId, 0);
    }

    // ── View functions ────────────────────────────────────────────────────────

    function test_GetBudget_ReturnsCorrectCategories() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_defaultProposal());
        ILoanRegistry.BudgetCategory[] memory budget = registry.getBudget(loanId);
        assertEq(budget.length, 1);
        assertEq(budget[0].cap, PRINCIPAL);
    }

    function test_GetPermittedRecipients_ReturnsCorrectList() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_defaultProposal());
        address[] memory r = registry.getPermittedRecipients(loanId);
        assertEq(r.length, 1);
        assertEq(r[0], creditWallet);
    }

    function test_GetMilestones_ReturnsCorrectMilestone() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_defaultProposal());
        ILoanRegistry.Milestone[] memory ms = registry.getMilestones(loanId);
        assertEq(ms.length, 1);
        assertEq(ms[0].amount, PRINCIPAL);
        assertFalse(ms[0].released);
    }

    // ── noPermittedRecipients ─────────────────────────────────────────────────

    function test_RequestLoan_RevertsWhen_NoPermittedRecipients() public {
        ILoanRegistry.LoanProposal memory p = _defaultProposal();
        p.permittedRecipients = new address[](0);
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.NoPermittedRecipients.selector);
        registry.requestLoan(p);
    }
}
