// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ReservePool} from "../src/ReservePool.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC4 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ReservePoolTest is Test {
    LoanRegistry registry;
    CreditRegistry creditRegistry;
    RevenueRouter router;
    RecipientRegistry recipientRegistry;
    ReservePool reserve;
    MockUSDC4 usdc;

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
    uint16 constant RESERVE_BPS = 200; // 2% of the repayment share
    uint256 constant DEFAULT_GRACE_PERIOD = 3 days;
    uint256 constant COLLATERAL_APPROVAL_THRESHOLD = 10_000e6;

    function setUp() public {
        usdc = new MockUSDC4();

        address creditRegistryProxy = Upgrades.deployUUPSProxy(
            "CreditRegistry.sol",
            abi.encodeCall(CreditRegistry.initialize, (owner, 5e6, 2500, 1000, 2000e6, 2000, 25_000e6))
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

        address reserveProxy = Upgrades.deployUUPSProxy(
            "ReservePool.sol",
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        );
        reserve = ReservePool(reserveProxy);

        registry.setContracts(vault, address(router));
        registry.setRecipientRegistry(address(recipientRegistry));
        registry.setReservePool(address(reserve));
        creditRegistry.setAuthorizedCaller(address(router), true);
        creditRegistry.setAuthorizedCaller(address(registry), true);
        vm.prank(address(router));
        creditRegistry.recordRepayment(borrower, 5_000e6, false);
        reserve.setAuthorizedContributor(address(router), true);
        router.setReservePool(address(reserve), RESERVE_BPS);

        recipientRegistry.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Test Provider");

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

        usdc.mint(client, 100_000e6);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
    }

    // 1. Normal repayment skims the configured % into the reserve
    function test_NormalRepaymentSkimsIntoReserve() public {
        vm.prank(client);
        router.payRevenue(loanId, 100e6); // repaymentShare = 15e6 at 15%

        uint256 expectedSkim = (15e6 * uint256(RESERVE_BPS)) / 10000; // 2% of 15e6
        assertEq(reserve.totalContributed(), expectedSkim);
        assertEq(usdc.balanceOf(address(reserve)), expectedSkim);
    }

    // 2. Skim reduces the lender's take but debt is still reduced by the full share
    function test_SkimReducesLenderShareNotDebtReduction() public {
        uint256 lenderBalanceBefore = usdc.balanceOf(lender);

        vm.prank(client);
        router.payRevenue(loanId, 100e6);

        uint256 repaymentShare = 15e6;
        uint256 skim = (repaymentShare * uint256(RESERVE_BPS)) / 10000;

        assertEq(usdc.balanceOf(lender) - lenderBalanceBefore, repaymentShare - skim);
        assertEq(router.totalRecovered(loanId), repaymentShare); // debt tracking unaffected by skim
    }

    // 3. No skim occurs during post-default garnishment
    function test_NoSkimDuringDefaultGarnishment() public {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);
        registry.markDefault(loanId);

        uint256 lenderBalanceBefore = usdc.balanceOf(lender);
        uint256 reserveContributedBefore = reserve.totalContributed();

        vm.prank(client);
        router.payRevenue(loanId, 100e6);

        assertEq(usdc.balanceOf(lender) - lenderBalanceBefore, 100e6); // full amount, no skim
        assertEq(reserve.totalContributed(), reserveContributedBefore); // unchanged
    }

    // 4. Reserve pays out shortfall on a pure-unsecured default, capped at what's available
    function test_ReservePaysOutShortfallOnDefault() public {
        // Fund the reserve first via normal repayments on other loans, simplified: mint directly
        usdc.mint(address(reserve), 5_000e6);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);

        uint256 lenderBalanceBefore = usdc.balanceOf(lender);
        registry.markDefault(loanId); // zero recovered so far, shortfall = full totalRepaymentDue
        uint256 lenderBalanceAfter = usdc.balanceOf(lender);

        assertEq(lenderBalanceAfter - lenderBalanceBefore, totalRepaymentDue); // reserve covers it, well within 5,000e6
    }

    // 5. Reserve payout is capped at available balance, never reverts
    function test_ReservePayoutCapsAtAvailableBalance() public {
        usdc.mint(address(reserve), 100e6); // much less than totalRepaymentDue

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);

        uint256 lenderBalanceBefore = usdc.balanceOf(lender);
        registry.markDefault(loanId); // must not revert despite insufficient reserve
        uint256 lenderBalanceAfter = usdc.balanceOf(lender);

        assertEq(lenderBalanceAfter - lenderBalanceBefore, 100e6); // only what was available
    }

    // 6. Only authorized contributors can record a contribution
    function test_OnlyAuthorizedContributorCanRecordContribution() public {
        vm.prank(client);
        vm.expectRevert(ReservePool.NotAuthorizedContributor.selector);
        reserve.recordContribution(loanId, 100e6);
    }

    // 7. Only LoanRegistry can trigger a payout
    function test_OnlyRegistryCanTriggerPayout() public {
        vm.expectRevert(ReservePool.NotRegistry.selector);
        reserve.payout(loanId, lender, 100e6);
    }
}