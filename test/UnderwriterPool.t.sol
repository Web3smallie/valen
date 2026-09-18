// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC3 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UnderwriterPoolTest is Test {
    LoanRegistry registry;
    CreditRegistry creditRegistry;
    RevenueRouter router;
    UnderwriterPool pool;
    RecipientRegistry recipientRegistry;
    MockUSDC3 usdc;

    address owner = address(this);
    address loanVault = address(0xBEEF);
    address borrower = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address lender = address(0x1E4DE4);
    address underwriter = address(0x11DE12);

    uint256 principal = 30_000e6;
    uint256 constant DEFAULT_GRACE_PERIOD = 3 days;
    uint256 constant COLLATERAL_APPROVAL_THRESHOLD = 10_000e6;
    uint256 constant STAKE_AMOUNT = 30_000e6;

    function setUp() public {
        usdc = new MockUSDC3();

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

        address poolProxy = Upgrades.deployUUPSProxy(
            "UnderwriterPool.sol",
            abi.encodeCall(UnderwriterPool.initialize, (owner, address(usdc), address(registry)))
        );
        pool = UnderwriterPool(poolProxy);

        address recipientRegistryProxy = Upgrades.deployUUPSProxy(
            "RecipientRegistry.sol",
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        );
        recipientRegistry = RecipientRegistry(recipientRegistryProxy);

        registry.setContracts(loanVault, address(router));
        registry.setUnderwriterPool(address(pool));
        registry.setRecipientRegistry(address(recipientRegistry));
        creditRegistry.setAuthorizedCaller(address(router), true);
        creditRegistry.setAuthorizedCaller(address(registry), true);

        recipientRegistry.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Test Provider");

        usdc.mint(underwriter, 100_000e6);
        vm.prank(underwriter);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _buildProposal(address _underwriter, uint256 underwriterAmount)
        internal
        view
        returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});

        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);

        uint256[] memory milestoneAmounts = new uint256[](1);
        milestoneAmounts[0] = principal;
        string[] memory milestoneDescs = new string[](1);
        milestoneDescs[0] = "Full release";

        return ILoanRegistry.LoanProposal({
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 1500,
            totalRepaymentDue: 34_500e6,
            duration: 30 days,
            purpose: "Underwriter-backed loan",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: milestoneAmounts,
            milestoneDescriptions: milestoneDescs,
            collateralAmount: 0,
            underwriter: _underwriter,
            underwriterAmount: underwriterAmount
        });
    }

    function test_UnderwriterCommitmentExtendsEffectiveLimit() public {
        assertEq(creditRegistry.getLimit(borrower), 5e6);

        vm.prank(underwriter);
        pool.depositStake(STAKE_AMOUNT);
        vm.prank(underwriter);
        pool.commitToAgent(borrower, STAKE_AMOUNT);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(underwriter, STAKE_AMOUNT));

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.PendingApproval));
    }

    function test_RevertsIfExceedsLimitAndCommitment() public {
        vm.prank(underwriter);
        pool.depositStake(STAKE_AMOUNT);
        vm.prank(underwriter);
        pool.commitToAgent(borrower, 1_000e6);

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.ExceedsCreditLimit.selector);
        registry.requestLoan(_buildProposal(underwriter, 1_000e6));
    }

    function test_RevertsIfInsufficientDepositedStake() public {
        vm.prank(underwriter);
        pool.commitToAgent(borrower, STAKE_AMOUNT);

        vm.prank(borrower);
        vm.expectRevert(UnderwriterPool.InsufficientStakeBalance.selector);
        registry.requestLoan(_buildProposal(underwriter, STAKE_AMOUNT));
    }

    function test_RepaymentReleasesStakeToUnderwriter() public {
        vm.prank(underwriter);
        pool.depositStake(STAKE_AMOUNT);
        vm.prank(underwriter);
        pool.commitToAgent(borrower, STAKE_AMOUNT);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(underwriter, STAKE_AMOUNT));

        registry.approveLoan(loanId);
        vm.prank(loanVault);
        registry.markFunded(loanId, lender);

        address client = address(0xC1E4);
        usdc.mint(client, 300_000e6);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(client);
        router.payRevenue(loanId, 250_000e6);

        assertEq(pool.stakeBalance(underwriter), STAKE_AMOUNT);
    }

    function test_DefaultSlashesStakeToLender() public {
        vm.prank(underwriter);
        pool.depositStake(STAKE_AMOUNT);
        vm.prank(underwriter);
        pool.commitToAgent(borrower, STAKE_AMOUNT);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(underwriter, STAKE_AMOUNT));

        registry.approveLoan(loanId);
        vm.prank(loanVault);
        registry.markFunded(loanId, lender);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);

        uint256 lenderBalanceBefore = usdc.balanceOf(lender);
        registry.markDefault(loanId);
        uint256 lenderBalanceAfter = usdc.balanceOf(lender);

        assertEq(lenderBalanceAfter - lenderBalanceBefore, STAKE_AMOUNT);
        assertEq(pool.stakeBalance(underwriter), 0);
    }

    function test_OnlyRegistryCanReserveStake() public {
        vm.expectRevert(UnderwriterPool.NotRegistry.selector);
        pool.reserveStake(999, underwriter, borrower, 100e6);
    }

    function test_RevertsOnOverWithdraw() public {
        vm.prank(underwriter);
        pool.depositStake(1_000e6);

        vm.prank(underwriter);
        vm.expectRevert(UnderwriterPool.InsufficientStakeBalance.selector);
        pool.withdrawStake(2_000e6);
    }
}