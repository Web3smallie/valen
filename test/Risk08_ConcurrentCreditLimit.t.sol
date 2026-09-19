// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ── Minimal mock token ────────────────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function decimals() public pure override returns (uint8) { return 6; }
}

// ── Minimal stub vault (only markFunded / markMilestoneReleased needed) ───────

contract StubVault {
    LoanRegistry public reg;
    MockUSDC     public usdc;

    constructor(address _reg, address _usdc) {
        reg  = LoanRegistry(_reg);
        usdc = MockUSDC(_usdc);
    }

    /// simulate fundLoan: sets lender, transitions to Active
    function fundLoan(uint256 loanId, address lender) external {
        reg.markFunded(loanId, lender);
    }
}

// ── Minimal stub router ───────────────────────────────────────────────────────

contract StubRouter {
    LoanRegistry public reg;
    CreditRegistry public credit;

    constructor(address _reg, address _credit) {
        reg    = LoanRegistry(_reg);
        credit = CreditRegistry(_credit);
    }

    function repay(uint256 loanId, address borrower, uint256 principal) external {
        credit.recordRepayment(borrower, principal, false);
        reg.markRepaid(loanId);
    }

    function totalRecovered(uint256) external pure returns (uint256) { return 0; }
}

// ── Test harness ──────────────────────────────────────────────────────────────

contract Risk08_ConcurrentCreditLimit is Test {
    // parameters matching Deploy.s.sol
    uint256 constant INITIAL_LIMIT   = 5_000e6;   //  5,000 USDC
    uint256 constant APPROVAL_THRESH = 25_000e6;  // 25,000 USDC
    uint256 constant MIN_DURATION    = 7  days;
    uint256 constant MAX_DURATION    = 365 days;
    uint256 constant GRACE           = 3  days;
    uint256 constant COLLATERAL_APPROVAL_THRESH = 50_000e6;

    MockUSDC        usdc;
    LoanRegistry    registry;
    CreditRegistry  creditReg;
    RecipientRegistry recipientReg;
    CollateralVault collVault;
    StubVault       vault;
    StubRouter      router;

    address owner    = address(this);
    address borrower = address(0xB0B0);
    address lender   = address(0xBEEF);
    address recipient;

    // ── setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        usdc = new MockUSDC();

        // CreditRegistry
        CreditRegistry creditImpl = new CreditRegistry();
        bytes memory creditInit = abi.encodeCall(
            CreditRegistry.initialize,
            (owner, INITIAL_LIMIT, 1000, 500, 50_000e6, 2000, APPROVAL_THRESH)
        );
        creditReg = CreditRegistry(address(new ERC1967Proxy(address(creditImpl), creditInit)));

        // RecipientRegistry
        RecipientRegistry recipientImpl = new RecipientRegistry();
        bytes memory recipientInit = abi.encodeCall(RecipientRegistry.initialize, (owner));
        recipientReg = RecipientRegistry(address(new ERC1967Proxy(address(recipientImpl), recipientInit)));
        recipient = address(0xCAFE);
        recipientReg.approveRecipient(recipient, bytes32("dev"), "test");

        // LoanRegistry
        LoanRegistry regImpl = new LoanRegistry();
        bytes memory regInit = abi.encodeCall(
            LoanRegistry.initialize,
            (owner, address(creditReg), MIN_DURATION, MAX_DURATION, GRACE, COLLATERAL_APPROVAL_THRESH)
        );
        registry = LoanRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        registry.setRecipientRegistry(address(recipientReg));

        // StubVault + StubRouter
        vault  = new StubVault(address(registry), address(usdc));
        router = new StubRouter(address(registry), address(creditReg));

        registry.setContracts(address(vault), address(router));

        // CollateralVault (needed for collateral tests)
        CollateralVault cvImpl = new CollateralVault();
        bytes memory cvInit = abi.encodeCall(
            CollateralVault.initialize,
            (owner, address(usdc), address(registry), 6600) // 66% max LTV
        );
        collVault = CollateralVault(address(new ERC1967Proxy(address(cvImpl), cvInit)));
        registry.setCollateralVault(address(collVault));

        // Authorize registry and router to call CreditRegistry
        creditReg.setAuthorizedCaller(address(registry), true);
        creditReg.setAuthorizedCaller(address(router), true);

        // Fund borrower and lender for collateral tests
        usdc.mint(borrower, 1_000_000e6);
        usdc.mint(lender,   1_000_000e6);

        vm.prank(borrower);
        usdc.approve(address(collVault), type(uint256).max);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _proposal(uint256 principal) internal view returns (ILoanRegistry.LoanProposal memory) {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = principal;
        string[] memory descs = new string[](1);
        descs[0] = "m0";
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: bytes32("dev"), cap: principal});
        return ILoanRegistry.LoanProposal({
            creditWallet:       address(0xDEAD),
            principal:          principal,
            totalRepaymentDue:  principal * 115 / 100,
            repaymentRateBps:   1000,
            duration:           30 days,
            purpose:            "test",
            budget:             budget,
            permittedRecipients: recipients,
            milestoneAmounts:   amounts,
            milestoneDescriptions: descs,
            collateralAmount:   0,
            underwriter:        address(0),
            underwriterAmount:  0
        });
    }

    function _collateralProposal(uint256 principal, uint256 collateral)
        internal view returns (ILoanRegistry.LoanProposal memory p)
    {
        p = _proposal(principal);
        p.collateralAmount = collateral;
    }

    /// @dev Deposit collateral into the vault as the borrower before requesting
    ///      a collateral-backed loan. CollateralVault uses a deposit-then-reserve
    ///      two-step model; the raw USDC balance is NOT used directly.
    function _depositCollateral(uint256 amount) internal {
        vm.prank(borrower);
        collVault.depositCollateral(amount);
    }

    function _fund(uint256 loanId) internal {
        vault.fundLoan(loanId, lender);
    }

    // ── Test 01: concurrent loans exceeding limit → second reverts ────────────

    function test_01_ConcurrentLoansExceedLimit_Reverts() public {
        uint256 half = INITIAL_LIMIT / 2 + 1e6; // each individually under limit

        vm.prank(borrower);
        registry.requestLoan(_proposal(half)); // outstandingPrincipal = half

        // second loan would push total over 5_000e6
        vm.expectRevert(LoanRegistry.ExceedsCreditLimit.selector);
        vm.prank(borrower);
        registry.requestLoan(_proposal(half));
    }

    // ── Test 02: concurrent loans within combined limit succeed ───────────────

    function test_02_ConcurrentLoansWithinLimit_Succeed() public {
        uint256 each = INITIAL_LIMIT / 3; // 1_666e6 each — three fit in 5_000e6

        vm.prank(borrower);
        uint256 id0 = registry.requestLoan(_proposal(each));
        vm.prank(borrower);
        uint256 id1 = registry.requestLoan(_proposal(each));
        vm.prank(borrower);
        uint256 id2 = registry.requestLoan(_proposal(each));

        assertEq(registry.outstandingPrincipal(borrower), each * 3);
        assertEq(uint8(registry.getLoan(id0).status), uint8(ILoanRegistry.LoanStatus.Requested));
        assertEq(uint8(registry.getLoan(id1).status), uint8(ILoanRegistry.LoanStatus.Requested));
        assertEq(uint8(registry.getLoan(id2).status), uint8(ILoanRegistry.LoanStatus.Requested));
    }

    // ── Test 03: repayment restores available credit ──────────────────────────

    function test_03_RepaymentRestoresCredit() public {
        uint256 p = INITIAL_LIMIT; // borrow the full limit

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(p));
        assertEq(registry.outstandingPrincipal(borrower), p);

        // fund → active
        _fund(loanId);

        // any further request should fail (no credit left)
        vm.expectRevert(LoanRegistry.ExceedsCreditLimit.selector);
        vm.prank(borrower);
        registry.requestLoan(_proposal(1e6));

        // repay
        router.repay(loanId, borrower, p);
        assertEq(registry.outstandingPrincipal(borrower), 0);

        // now a new loan is possible (limit also grew via recordRepayment)
        vm.prank(borrower);
        uint256 id2 = registry.requestLoan(_proposal(p));
        assertGt(id2, loanId);
    }

    // ── Test 04: default restores outstanding principal ───────────────────────

    function test_04_DefaultRestoresOutstandingPrincipal() public {
        uint256 p = INITIAL_LIMIT;

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(p));
        _fund(loanId);

        assertEq(registry.outstandingPrincipal(borrower), p);

        // warp past expiry + grace
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        registry.markDefault(loanId); // owner call (no keeper set)
        assertEq(registry.outstandingPrincipal(borrower), 0);
    }

    // ── Test 05: collateral-backed loan increments outstandingPrincipal ────────

    function test_05_CollateralLoan_IncrementsOutstanding() public {
        uint256 principal  = 10_000e6;
        uint256 collateral = principal * 10000 / 6600 + 1; // just above requiredCollateral

        // Borrower must deposit collateral into the vault first (two-step model)
        _depositCollateral(collateral);

        vm.prank(borrower);
        registry.requestLoan(_collateralProposal(principal, collateral));

        // outstandingPrincipal recorded even though credit-limit check was skipped
        assertEq(registry.outstandingPrincipal(borrower), principal);
    }

    // ── Test 06: collateral-backed loan NOT blocked by exhausted credit limit ──

    function test_06_CollateralLoan_NotBlockedByCreditLimit() public {
        // First exhaust the credit limit with an unsecured loan
        uint256 p = INITIAL_LIMIT;
        vm.prank(borrower);
        registry.requestLoan(_proposal(p));
        assertEq(registry.outstandingPrincipal(borrower), p);

        // Collateral-backed loan should still succeed despite exhausted limit
        uint256 bigPrincipal  = 20_000e6;
        uint256 collateral    = bigPrincipal * 10000 / 6600 + 1;
        _depositCollateral(collateral);

        vm.prank(borrower);
        uint256 cvId = registry.requestLoan(_collateralProposal(bigPrincipal, collateral));

        // bigPrincipal > collateralApprovalThreshold (50_000e6) is false (20_000 < 50_000)
        // so it lands as Requested, not PendingApproval
        assertEq(uint8(registry.getLoan(cvId).status), uint8(ILoanRegistry.LoanStatus.Requested));
        // outstandingPrincipal includes both
        assertEq(registry.outstandingPrincipal(borrower), p + bigPrincipal);
    }

    // ── Test 07: collateral default decrements outstandingPrincipal ───────────

    function test_07_CollateralDefault_DecrementsOutstanding() public {
        uint256 principal  = 10_000e6;
        uint256 collateral = principal * 10000 / 6600 + 1;
        _depositCollateral(collateral);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_collateralProposal(principal, collateral));

        // no approval needed since principal < collateralApprovalThreshold
        _fund(loanId);

        assertEq(registry.outstandingPrincipal(borrower), principal);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);
        registry.markDefault(loanId);

        assertEq(registry.outstandingPrincipal(borrower), 0);
    }

    // ── Test 08: double-termination cannot decrement twice ────────────────────

    function test_08_DoubleTermination_CannotDecrementTwice() public {
        uint256 p = INITIAL_LIMIT;

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(p));
        _fund(loanId);

        // repay via router
        router.repay(loanId, borrower, p);
        assertEq(registry.outstandingPrincipal(borrower), 0);

        // attempt to mark repaid again → should revert (status already Repaid)
        vm.expectRevert(LoanRegistry.LoanNotActive.selector);
        router.repay(loanId, borrower, p);

        // outstanding remains 0 — no double-decrement
        assertEq(registry.outstandingPrincipal(borrower), 0);
    }

    // ── Test 09: outstanding set correctly on 3 sequential requests ───────────

    function test_09_SequentialRequests_OutstandingAccumulates() public {
        uint256 each = 1_000e6;

        vm.prank(borrower);
        registry.requestLoan(_proposal(each));
        assertEq(registry.outstandingPrincipal(borrower), 1_000e6);

        vm.prank(borrower);
        registry.requestLoan(_proposal(each));
        assertEq(registry.outstandingPrincipal(borrower), 2_000e6);

        vm.prank(borrower);
        registry.requestLoan(_proposal(each));
        assertEq(registry.outstandingPrincipal(borrower), 3_000e6);
    }

    // ── Test 10: exact-limit request succeeds, one-over reverts ──────────────

    function test_10_ExactLimitSucceeds_OnceOverReverts() public {
        vm.prank(borrower);
        registry.requestLoan(_proposal(INITIAL_LIMIT)); // exactly at limit — should pass
        assertEq(registry.outstandingPrincipal(borrower), INITIAL_LIMIT);

        vm.expectRevert(LoanRegistry.ExceedsCreditLimit.selector);
        vm.prank(borrower);
        registry.requestLoan(_proposal(1e6)); // one micro-USDC over
    }
}
