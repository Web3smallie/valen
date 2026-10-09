// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract RevenueRouterTest is Test {
    function _opts() internal pure returns (Options memory o) { o.unsafeSkipAllChecks = true; }
    AgentRegistry  agentReg;
    LoanRegistry   registry;
    CreditRegistry creditRegistry;
    RevenueRouter  router;
    RecipientRegistry recipientRegistry;
    MockUSDC usdc;

    address owner        = address(this);
    address vault        = address(0xBEEF);
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address lender       = address(0x1E4DE4);
    address client       = address(0xC1E4);

    uint256 agentId;    // assigned in setUp after AgentRegistry.registerAgent
    uint256 loanId;
    uint256 principal           = 1_000e6;
    uint256 totalRepaymentDue   = 1_150e6;
    uint16  repaymentRateBps    = 1500;

    uint256 constant INITIAL_LIMIT       = 5e6;
    uint16  constant GROWTH_BPS          = 2500;
    uint16  constant EARLY_BONUS_BPS     = 1000;
    uint256 constant MAX_STEP_INCREASE   = 2000e6;
    uint16  constant DEFAULT_PENALTY_BPS = 2000;
    uint256 constant APPROVAL_THRESHOLD  = 25_000e6;
    uint256 constant DEFAULT_GRACE_PERIOD          = 3 days;
    uint256 constant COLLATERAL_APPROVAL_THRESHOLD  = 10_000e6;

    function setUp() public {
        usdc = new MockUSDC();

        // ── AgentRegistry ──────────────────────────────────────────────────────
        agentReg = AgentRegistry(address(new ERC1967Proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        )));

        // borrower is primary wallet; creditWallet is a second authorized wallet.
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        // ── CreditRegistry ─────────────────────────────────────────────────────
        address creditRegistryProxy = Upgrades.deployUUPSProxy(
            "CreditRegistry.sol",
            abi.encodeCall(CreditRegistry.initialize,
                (owner, INITIAL_LIMIT, GROWTH_BPS, EARLY_BONUS_BPS, MAX_STEP_INCREASE,
                 DEFAULT_PENALTY_BPS, APPROVAL_THRESHOLD, 500, 50e6, 50_000e6))
                    , _opts()
            );
        creditRegistry = CreditRegistry(creditRegistryProxy);

        // ── LoanRegistry ───────────────────────────────────────────────────────
        address registryProxy = Upgrades.deployUUPSProxy(
            "LoanRegistry.sol",
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditRegistry), 1 days, 365 days,
                 DEFAULT_GRACE_PERIOD, COLLATERAL_APPROVAL_THRESHOLD))
                    , _opts()
            );
        registry = LoanRegistry(registryProxy);

        // ── RevenueRouter ──────────────────────────────────────────────────────
        address routerProxy = Upgrades.deployUUPSProxy(
            "RevenueRouter.sol",
            abi.encodeCall(RevenueRouter.initialize,
                (owner, address(registry), address(creditRegistry), address(usdc)))
                    , _opts()
            );
        router = RevenueRouter(routerProxy);

        // ── RecipientRegistry ──────────────────────────────────────────────────
        address recipientRegistryProxy = Upgrades.deployUUPSProxy(
            "RecipientRegistry.sol",
            abi.encodeCall(RecipientRegistry.initialize, (owner))
                    , _opts()
            );
        recipientRegistry = RecipientRegistry(recipientRegistryProxy);

        // ── Wire ───────────────────────────────────────────────────────────────
        registry.setContracts(vault, address(router));
        registry.setRecipientRegistry(address(recipientRegistry));
        registry.setAgentRegistry(address(agentReg));
        // Step 5: wire AgentRegistry into RevenueRouter.
        router.setAgentRegistry(address(agentReg));
        creditRegistry.setAuthorizedCaller(address(router), true);
        creditRegistry.setAuthorizedCaller(address(registry), true);

        recipientRegistry.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Test Provider");
        recipientRegistry.approveRecipient(creditWallet,    keccak256("COMPUTE"), "CreditWallet");

        // Seed credit at agentId slot so requestLoan passes the credit-limit check.
        vm.prank(address(router));
        creditRegistry.recordRepayment(agentId, 5_000e6, false);

        // ── Create and fund the loan ────────────────────────────────────────────
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});

        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet;

        uint256[] memory milestoneAmounts = new uint256[](1);
        milestoneAmounts[0] = principal;
        string[] memory milestoneDescs = new string[](1);
        milestoneDescs[0] = "Full release";

        ILoanRegistry.LoanProposal memory proposal = ILoanRegistry.LoanProposal({
            agentId:               agentId,
            creditWallet:          creditWallet,
            principal:             principal,
            repaymentRateBps:      repaymentRateBps,
            totalRepaymentDue:     totalRepaymentDue,
            duration:              30 days,
            purpose:               "Test loan",
            budget:                budget,
            permittedRecipients:   recipients,
            milestoneAmounts:      milestoneAmounts,
            milestoneDescriptions: milestoneDescs,
            collateralAmount:      0,
            collateralAsset: address(0),
            underwriter:           address(0),
            underwriterAmount:     0
        });

        vm.prank(borrower);
        loanId = registry.requestLoan(proposal);

        vm.prank(vault);
        registry.markFunded(loanId, lender);

        usdc.mint(client, 60_000e6);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // payRevenue guards
    // ─────────────────────────────────────────────────────────────────────────

    /// creditWallet is an authorized wallet for the agent — must be rejected.
    function test_RevertsWhenCreditWalletIsPayer() public {
        usdc.mint(creditWallet, 100e6);
        vm.prank(creditWallet);
        usdc.approve(address(router), 100e6);
        vm.prank(creditWallet);
        vm.expectRevert(RevenueRouter.PayerNotAllowed.selector);
        router.payRevenue(loanId, 100e6);
    }

    /// borrower is the primary authorized wallet for the agent — must be rejected.
    function test_RevertsWhenBorrowerIsPayer() public {
        usdc.mint(borrower, 100e6);
        vm.prank(borrower);
        usdc.approve(address(router), 100e6);
        vm.prank(borrower);
        vm.expectRevert(RevenueRouter.PayerNotAllowed.selector);
        router.payRevenue(loanId, 100e6);
    }

    /// Any authorized wallet of the agent is rejected as a payer (Step 5 extension).
    function test_PayRevenueRejectsAuthorizedAgentWallet() public {
        // Rotate in a new wallet for the agent and confirm it is also rejected.
        address newWallet = address(0xFEED);
        vm.prank(borrower); // agent owner
        agentReg.addWallet(agentId, newWallet);

        usdc.mint(newWallet, 100e6);
        vm.prank(newWallet);
        usdc.approve(address(router), 100e6);
        vm.prank(newWallet);
        vm.expectRevert(RevenueRouter.PayerNotAllowed.selector);
        router.payRevenue(loanId, 100e6);
    }

    function test_AcceptsThirdPartyPayment() public {
        vm.prank(client);
        router.payRevenue(loanId, 100e6);
        assertEq(router.totalRecovered(loanId), 15e6);
    }

    function test_PartialRepaymentDoesNotCompleteLoan() public {
        vm.prank(client);
        router.payRevenue(loanId, 100e6);
        assertFalse(router.isFullyRepaid(loanId));
    }

    function test_FullRepaymentMarksLoanRepaid() public {
        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);
        assertTrue(router.isFullyRepaid(loanId));
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Repaid));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Credit identity: Step 5 — repayment must credit loan.agentId
    // ─────────────────────────────────────────────────────────────────────────

    /// Repayment credit growth lands in credits[agentId], not credits[uint160(borrower)].
    function test_RepaymentCreditsAgentIdNotBorrowerAddress() public {
        uint256 beforeAgentId = creditRegistry.getLimit(agentId);
        uint256 beforeBorrowerAddr = creditRegistry.getLimit(uint256(uint160(borrower)));

        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);

        uint256 afterAgentId      = creditRegistry.getLimit(agentId);
        uint256 afterBorrowerAddr = creditRegistry.getLimit(uint256(uint160(borrower)));

        // agentId slot must have grown.
        assertGt(afterAgentId, beforeAgentId);
        // borrower-address slot must NOT have grown (no bridge conversion).
        // Both before/after values equal INITIAL_LIMIT (no record at that slot).
        assertEq(afterBorrowerAddr, beforeBorrowerAddr);
        assertEq(afterBorrowerAddr, INITIAL_LIMIT);
    }

    function test_EarlyRepaymentGrantsBonus() public {
        // Step 5: credit lands at credits[agentId].
        uint256 beforeLimit = creditRegistry.getLimit(agentId);

        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);

        uint256 afterLimit = creditRegistry.getLimit(agentId);
        assertGt(afterLimit, beforeLimit);
        // growth = totalRepaymentDue * (GROWTH_BPS + EARLY_BONUS_BPS) / 10000
        assertEq(afterLimit - beforeLimit, (totalRepaymentDue * 3500) / 10000);
    }

    function test_RepaymentExactlyAtExpiryIsNotEarly() public {
        ILoanRegistry.LoanView memory loanBefore = registry.getLoan(loanId);
        vm.warp(loanBefore.expiresAt);

        uint256 beforeLimit = creditRegistry.getLimit(agentId);
        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);
        uint256 afterLimit = creditRegistry.getLimit(agentId);
        assertEq(afterLimit - beforeLimit, (totalRepaymentDue * 2500) / 10000);
    }

    function test_RepaymentAfterExpiryStillRepaysNoBonus() public {
        ILoanRegistry.LoanView memory loanBefore = registry.getLoan(loanId);
        vm.warp(loanBefore.expiresAt + 1);

        uint256 beforeLimit = creditRegistry.getLimit(agentId);
        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);
        uint256 afterLimit = creditRegistry.getLimit(agentId);
        assertTrue(router.isFullyRepaid(loanId));
        assertEq(afterLimit - beforeLimit, (totalRepaymentDue * 2500) / 10000);
    }

    function test_OverpaymentCapsAtTotalRepaymentDue() public {
        usdc.mint(client, 50_000e6);
        vm.prank(client);
        router.payRevenue(loanId, 50_000e6);
        assertEq(router.totalRecovered(loanId), totalRepaymentDue);
    }

    function test_PostRepaymentRevenueFullyForwarded() public {
        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);

        uint256 walletBalanceBefore = usdc.balanceOf(creditWallet);
        vm.prank(client);
        router.payRevenue(loanId, 500e6);
        uint256 walletBalanceAfter = usdc.balanceOf(creditWallet);
        assertEq(walletBalanceAfter - walletBalanceBefore, 500e6);
    }

    function test_RepaymentFinalizationHappensExactlyOnce() public {
        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);
        uint256 loansRepaidAfterFirst = _loansRepaidCount(agentId);

        vm.prank(client);
        router.payRevenue(loanId, 500e6);
        uint256 loansRepaidAfterSecond = _loansRepaidCount(agentId);
        assertEq(loansRepaidAfterFirst, loansRepaidAfterSecond);
    }

    /// @dev Step 5: reads loansRepaid from credits[agentId] (correct slot).
    function _loansRepaidCount(uint256 aid) internal view returns (uint256 count) {
        (, count,,,,) = creditRegistry.credits(aid);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Authorization
    // ─────────────────────────────────────────────────────────────────────────

    function test_UnauthorizedCallerCannotRecordRepayment() public {
        vm.prank(client);
        vm.expectRevert(CreditRegistry.NotAuthorized.selector);
        // Step 5: recordRepayment now takes uint256 agentId.
        creditRegistry.recordRepayment(agentId, 100e6, false);
    }

    function test_UnauthorizedCallerCannotMarkRepaid() public {
        vm.prank(client);
        vm.expectRevert(LoanRegistry.NotRouter.selector);
        registry.markRepaid(loanId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // repayLoan — AgentRegistry wallet authorization
    // ─────────────────────────────────────────────────────────────────────────

    /// The borrower (primary authorized wallet) can self-repay.
    function test_HumanCanSelfRepay() public {
        usdc.mint(borrower, 10_000e6);
        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(borrower);
        router.repayLoan(loanId, 8_000e6);
        assertTrue(router.isFullyRepaid(loanId));
    }

    /// A second authorized wallet (not the original borrower) can also repay
    /// because AgentRegistry.isAuthorizedWallet covers all wallets for the agent.
    function test_AuthorizedWalletCanSelfRepay() public {
        // creditWallet is already added as a second authorized wallet in setUp.
        usdc.mint(creditWallet, 10_000e6);
        vm.prank(creditWallet);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(creditWallet);
        // creditWallet is authorized → repayLoan must succeed.
        router.repayLoan(loanId, 8_000e6);
        assertTrue(router.isFullyRepaid(loanId));
    }

    /// Wallet rotation: remove old wallet, add new one — new wallet can repay,
    /// old wallet cannot.
    function test_WalletRotationAllowsNewWalletAndRevokesOld() public {
        address newWallet = address(0xFEED);
        // Remove creditWallet, add newWallet.
        vm.prank(borrower); // agent owner
        agentReg.removeWallet(agentId, creditWallet);
        vm.prank(borrower);
        agentReg.addWallet(agentId, newWallet);

        // newWallet can repay.
        usdc.mint(newWallet, 10_000e6);
        vm.prank(newWallet);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(newWallet);
        router.repayLoan(loanId, 8_000e6);
        assertTrue(router.isFullyRepaid(loanId));
    }

    function test_WalletRotationRevokesOldWallet() public {
        address newWallet = address(0xFEED);
        vm.prank(borrower);
        agentReg.removeWallet(agentId, creditWallet);
        vm.prank(borrower);
        agentReg.addWallet(agentId, newWallet);

        // creditWallet is no longer authorized — repayLoan must revert.
        usdc.mint(creditWallet, 10_000e6);
        vm.prank(creditWallet);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(creditWallet);
        vm.expectRevert(RevenueRouter.CallerNotAgentWallet.selector);
        router.repayLoan(loanId, 8_000e6);
    }

    /// A completely unrelated wallet is rejected.
    function test_RevertsIfNonAgentWalletCallsRepayLoan() public {
        usdc.mint(client, 1_000e6);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(client);
        vm.expectRevert(RevenueRouter.CallerNotAgentWallet.selector);
        router.repayLoan(loanId, 100e6);
    }

    /// loan.borrower is unchanged in storage after Step 5 migration.
    function test_LoanBorrowerFieldRemainsHistorical() public {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(loan.borrower, borrower);
    }

    function test_SelfRepaySends100PercentToLender() public {
        usdc.mint(borrower, 10_000e6);
        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);

        uint256 lenderBalanceBefore      = usdc.balanceOf(lender);
        uint256 creditWalletBalanceBefore = usdc.balanceOf(creditWallet);

        vm.prank(borrower);
        router.repayLoan(loanId, 500e6);

        assertEq(usdc.balanceOf(lender)      - lenderBalanceBefore,       500e6);
        assertEq(usdc.balanceOf(creditWallet), creditWalletBalanceBefore);
    }

    function test_SelfRepayGrantsCreditGrowthOnFullRepayment() public {
        usdc.mint(borrower, 10_000e6);
        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);

        uint256 beforeLimit = creditRegistry.getLimit(agentId);
        vm.prank(borrower);
        router.repayLoan(loanId, 8_000e6);
        uint256 afterLimit = creditRegistry.getLimit(agentId);
        assertGt(afterLimit, beforeLimit);
    }

    /// outstandingPrincipal[agentId] is zeroed after full repayment.
    function test_OutstandingPrincipalZeroedAfterRepayment() public {
        assertEq(registry.outstandingPrincipal(agentId), principal);

        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);

        assertEq(registry.outstandingPrincipal(agentId), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Default path
    // ─────────────────────────────────────────────────────────────────────────

    function test_DefaultOnUnsecuredLoanCutsCredit() public {
        ILoanRegistry.LoanView memory loanBefore = registry.getLoan(loanId);
        vm.warp(loanBefore.expiresAt + DEFAULT_GRACE_PERIOD + 1);

        registry.markDefault(loanId);

        ILoanRegistry.LoanView memory loanAfter = registry.getLoan(loanId);
        assertEq(uint8(loanAfter.status), uint8(ILoanRegistry.LoanStatus.Defaulted));
        // markDefault calls recordDefault(loan.agentId, severe) — writes to credits[agentId].
        assertEq(creditRegistry.getLimit(agentId), 0);
    }

    function test_DefaultRevertsBeforeGraceElapsed() public {
        ILoanRegistry.LoanView memory loanBefore = registry.getLoan(loanId);
        vm.warp(loanBefore.expiresAt + 1);
        vm.expectRevert(LoanRegistry.DefaultGraceNotElapsed.selector);
        registry.markDefault(loanId);
    }

    function test_PostDefaultGarnishmentTakes100Percent() public {
        ILoanRegistry.LoanView memory loanBefore = registry.getLoan(loanId);
        vm.warp(loanBefore.expiresAt + DEFAULT_GRACE_PERIOD + 1);
        registry.markDefault(loanId);

        uint256 creditWalletBalanceBefore = usdc.balanceOf(creditWallet);
        vm.prank(client);
        router.payRevenue(loanId, 100e6);
        uint256 creditWalletBalanceAfter = usdc.balanceOf(creditWallet);

        assertEq(creditWalletBalanceAfter, creditWalletBalanceBefore);
        assertEq(router.totalRecovered(loanId), 100e6);
    }
}
