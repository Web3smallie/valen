// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RevenueRouterTest is Test {
    LoanRegistry registry;
    CreditRegistry creditRegistry;
    RevenueRouter router;
    RecipientRegistry recipientRegistry;
    MockUSDC usdc;

    address owner = address(this);
    address vault = address(0xBEEF);
    address borrower = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address lender = address(0x1E4DE4);
    address client = address(0xC1E4);

    uint256 loanId;
    uint256 principal = 1_000e6;
    uint256 totalRepaymentDue = 1_150e6;
    uint16 repaymentRateBps = 1500;

    uint256 constant INITIAL_LIMIT = 5e6;
    uint16 constant GROWTH_BPS = 2500;
    uint16 constant EARLY_BONUS_BPS = 1000;
    uint256 constant MAX_STEP_INCREASE = 2000e6;
    uint16 constant DEFAULT_PENALTY_BPS = 2000;
    uint256 constant APPROVAL_THRESHOLD = 25_000e6;
    uint256 constant DEFAULT_GRACE_PERIOD = 3 days;
    uint256 constant COLLATERAL_APPROVAL_THRESHOLD = 10_000e6;

    function setUp() public {
        usdc = new MockUSDC();

        address creditRegistryProxy = Upgrades.deployUUPSProxy(
            "CreditRegistry.sol",
            abi.encodeCall(
                CreditRegistry.initialize,
                (owner, INITIAL_LIMIT, GROWTH_BPS, EARLY_BONUS_BPS, MAX_STEP_INCREASE, DEFAULT_PENALTY_BPS, APPROVAL_THRESHOLD)
            )
        );
        creditRegistry = CreditRegistry(creditRegistryProxy);

        address registryProxy = Upgrades.deployUUPSProxy(
            "LoanRegistry.sol",
            abi.encodeCall(
                LoanRegistry.initialize,
                (owner, address(creditRegistry), 1 days, 365 days, DEFAULT_GRACE_PERIOD, COLLATERAL_APPROVAL_THRESHOLD)
            )
        );
        registry = LoanRegistry(registryProxy);

        address routerProxy = Upgrades.deployUUPSProxy(
            "RevenueRouter.sol",
            abi.encodeCall(RevenueRouter.initialize, (owner, address(registry), address(creditRegistry), address(usdc)))
        );
        router = RevenueRouter(routerProxy);

        address recipientRegistryProxy = Upgrades.deployUUPSProxy(
            "RecipientRegistry.sol",
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        );
        recipientRegistry = RecipientRegistry(recipientRegistryProxy);

        registry.setContracts(vault, address(router));
        registry.setRecipientRegistry(address(recipientRegistry));
        creditRegistry.setAuthorizedCaller(address(router), true);
        creditRegistry.setAuthorizedCaller(address(registry), true);

        recipientRegistry.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Test Provider");

        vm.prank(address(router));
        creditRegistry.recordRepayment(borrower, 5_000e6, false);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});

        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);

        uint256[] memory milestoneAmounts = new uint256[](1);
        milestoneAmounts[0] = principal;
        string[] memory milestoneDescs = new string[](1);
        milestoneDescs[0] = "Full release";

        ILoanRegistry.LoanProposal memory proposal = ILoanRegistry.LoanProposal({
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: repaymentRateBps,
            totalRepaymentDue: totalRepaymentDue,
            duration: 30 days,
            purpose: "Test loan",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: milestoneAmounts,
            milestoneDescriptions: milestoneDescs,
            collateralAmount: 0,
            underwriter: address(0),
            underwriterAmount: 0
        });

        vm.prank(borrower);
        loanId = registry.requestLoan(proposal);

        vm.prank(vault);
        registry.markFunded(loanId, lender);

        usdc.mint(client, 60_000e6);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
    }

    function test_RevertsWhenCreditWalletIsPayer() public {
        usdc.mint(creditWallet, 100e6);
        vm.prank(creditWallet);
        usdc.approve(address(router), 100e6);

        vm.prank(creditWallet);
        vm.expectRevert(RevenueRouter.PayerNotAllowed.selector);
        router.payRevenue(loanId, 100e6);
    }

    function test_RevertsWhenBorrowerIsPayer() public {
        usdc.mint(borrower, 100e6);
        vm.prank(borrower);
        usdc.approve(address(router), 100e6);

        vm.prank(borrower);
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

    function test_EarlyRepaymentGrantsBonus() public {
        uint256 beforeLimit = creditRegistry.getLimit(borrower);

        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);

        uint256 afterLimit = creditRegistry.getLimit(borrower);
        assertGt(afterLimit, beforeLimit);
        assertEq(afterLimit - beforeLimit, (totalRepaymentDue * 3500) / 10000);
    }

    function test_RepaymentExactlyAtExpiryIsNotEarly() public {
        ILoanRegistry.LoanView memory loanBefore = registry.getLoan(loanId);
        vm.warp(loanBefore.expiresAt);

        uint256 beforeLimit = creditRegistry.getLimit(borrower);
        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);
        uint256 afterLimit = creditRegistry.getLimit(borrower);

        assertEq(afterLimit - beforeLimit, (totalRepaymentDue * 2500) / 10000);
    }

    function test_RepaymentAfterExpiryStillRepaysNoBonus() public {
        ILoanRegistry.LoanView memory loanBefore = registry.getLoan(loanId);
        vm.warp(loanBefore.expiresAt + 1);

        uint256 beforeLimit = creditRegistry.getLimit(borrower);
        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);
        uint256 afterLimit = creditRegistry.getLimit(borrower);

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

        uint256 loansRepaidAfterFirst = _loansRepaidCount(borrower);

        vm.prank(client);
        router.payRevenue(loanId, 500e6);

        uint256 loansRepaidAfterSecond = _loansRepaidCount(borrower);
        assertEq(loansRepaidAfterFirst, loansRepaidAfterSecond);
    }

    function _loansRepaidCount(address agent) internal view returns (uint256 count) {
        (, count, , ) = creditRegistry.credits(agent);
    }

    function test_UnauthorizedCallerCannotRecordRepayment() public {
        vm.prank(client);
        vm.expectRevert(CreditRegistry.NotAuthorized.selector);
        creditRegistry.recordRepayment(borrower, 100e6, false);
    }

    function test_UnauthorizedCallerCannotMarkRepaid() public {
        vm.prank(client);
        vm.expectRevert(LoanRegistry.NotRouter.selector);
        registry.markRepaid(loanId);
    }

    function test_DefaultOnUnsecuredLoanCutsCredit() public {
        ILoanRegistry.LoanView memory loanBefore = registry.getLoan(loanId);
        vm.warp(loanBefore.expiresAt + DEFAULT_GRACE_PERIOD + 1);

        registry.markDefault(loanId);

        ILoanRegistry.LoanView memory loanAfter = registry.getLoan(loanId);
        assertEq(uint8(loanAfter.status), uint8(ILoanRegistry.LoanStatus.Defaulted));
        assertEq(creditRegistry.getLimit(borrower), 0);
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

    function test_HumanCanSelfRepay() public {
        usdc.mint(borrower, 10_000e6);
        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(borrower);
        router.repayLoan(loanId, 8_000e6);

        assertTrue(router.isFullyRepaid(loanId));
    }

    function test_SelfRepaySends100PercentToLender() public {
        usdc.mint(borrower, 10_000e6);
        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);

        uint256 lenderBalanceBefore = usdc.balanceOf(lender);
        uint256 creditWalletBalanceBefore = usdc.balanceOf(creditWallet);

        vm.prank(borrower);
        router.repayLoan(loanId, 500e6);

        uint256 lenderBalanceAfter = usdc.balanceOf(lender);
        uint256 creditWalletBalanceAfter = usdc.balanceOf(creditWallet);

        assertEq(lenderBalanceAfter - lenderBalanceBefore, 500e6);
        assertEq(creditWalletBalanceAfter, creditWalletBalanceBefore);
    }

    function test_RevertsIfNonBorrowerCallsRepayLoan() public {
        usdc.mint(client, 1_000e6);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(client);
        vm.expectRevert(RevenueRouter.OnlyBorrowerCanSelfRepay.selector);
        router.repayLoan(loanId, 100e6);
    }

    function test_SelfRepayGrantsCreditGrowthOnFullRepayment() public {
        usdc.mint(borrower, 10_000e6);
        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);

        uint256 beforeLimit = creditRegistry.getLimit(borrower);

        vm.prank(borrower);
        router.repayLoan(loanId, 8_000e6);

        uint256 afterLimit = creditRegistry.getLimit(borrower);
        assertGt(afterLimit, beforeLimit);
    }
}