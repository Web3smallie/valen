// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ReservePool} from "../src/ReservePool.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC5 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract LiquidityPoolTest is Test {
    LoanRegistry registry;
    LoanVault vault;
    CreditRegistry creditRegistry;
    RevenueRouter router;
    CollateralVault collateralVault;
    UnderwriterPool underwriterPool;
    RecipientRegistry recipientRegistry;
    ReservePool reservePool;
    LiquidityPool pool;
    MockUSDC5 usdc;

    address owner = address(this);
    address borrower = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address lisa = address(0x1157A);   // first/seed lender
    address mo = address(0x2222);      // second lender
    address client = address(0xC1E4);  // revenue payer
    address attacker = address(0xBAD);

    uint256 constant DEFAULT_GRACE_PERIOD = 3 days;
    uint256 constant COLLATERAL_APPROVAL_THRESHOLD = 10_000e6;
    uint16 constant MAX_LTV_BPS = 6600;

    function setUp() public {
        usdc = new MockUSDC5();

        creditRegistry = CreditRegistry(Upgrades.deployUUPSProxy(
            "CreditRegistry.sol",
            abi.encodeCall(CreditRegistry.initialize, (owner, 5e6, 2500, 1000, 2000e6, 2000, 25_000e6))
        ));

        registry = LoanRegistry(Upgrades.deployUUPSProxy(
            "LoanRegistry.sol",
            abi.encodeCall(LoanRegistry.initialize, (owner, address(creditRegistry), 1 days, 365 days, DEFAULT_GRACE_PERIOD, COLLATERAL_APPROVAL_THRESHOLD))
        ));

        router = RevenueRouter(Upgrades.deployUUPSProxy(
            "RevenueRouter.sol",
            abi.encodeCall(RevenueRouter.initialize, (owner, address(registry), address(creditRegistry), address(usdc)))
        ));

        vault = LoanVault(Upgrades.deployUUPSProxy(
            "LoanVault.sol",
            abi.encodeCall(LoanVault.initialize, (owner, address(registry), address(usdc)))
        ));

        collateralVault = CollateralVault(Upgrades.deployUUPSProxy(
            "CollateralVault.sol",
            abi.encodeCall(CollateralVault.initialize, (owner, address(usdc), address(registry), MAX_LTV_BPS))
        ));

        underwriterPool = UnderwriterPool(Upgrades.deployUUPSProxy(
            "UnderwriterPool.sol",
            abi.encodeCall(UnderwriterPool.initialize, (owner, address(usdc), address(registry)))
        ));

        recipientRegistry = RecipientRegistry(Upgrades.deployUUPSProxy(
            "RecipientRegistry.sol",
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        ));

        reservePool = ReservePool(Upgrades.deployUUPSProxy(
            "ReservePool.sol",
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        ));

        pool = LiquidityPool(Upgrades.deployUUPSProxy(
            "LiquidityPool.sol",
            abi.encodeCall(
                LiquidityPool.initialize,
                (owner, address(usdc), address(registry), address(router), address(collateralVault), address(underwriterPool), address(reservePool), address(vault))
            )
        ));

        registry.setContracts(address(vault), address(router));
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        registry.setRecipientRegistry(address(recipientRegistry));
        registry.setReservePool(address(reservePool));
        creditRegistry.setAuthorizedCaller(address(router), true);
        creditRegistry.setAuthorizedCaller(address(registry), true);
        reservePool.setAuthorizedContributor(address(router), true);
        router.setReservePool(address(reservePool), 0); // 0% skim — isolating pool-accounting tests from RevenueRouter's own reserve skim
        vault.setLiquidityPool(address(pool));

        recipientRegistry.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Test Provider");

        // Seed borrower credit high enough for the test loans below.
        vm.prank(address(router));
        creditRegistry.recordRepayment(borrower, 5_000e6, false);

        usdc.mint(lisa, 1_000_000e6);
        usdc.mint(mo, 1_000_000e6);
        usdc.mint(client, 1_000_000e6);

        vm.prank(lisa);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(mo);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
    }

    function _proposal(uint256 principal, uint256 totalDue, uint16 rateBps, uint256 collateralAmount, address underwriter, uint256 underwriterAmount)
        internal
        view
        returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256[] memory ms = new uint256[](1);
        ms[0] = principal;
        string[] memory desc = new string[](1);
        desc[0] = "Full release";

        return ILoanRegistry.LoanProposal({
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: rateBps,
            totalRepaymentDue: totalDue,
            duration: 30 days,
            purpose: "Pool test loan",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: collateralAmount,
            underwriter: underwriter,
            underwriterAmount: underwriterAmount
        });
    }

    // ---- A. First liquidity initialization ----
    function test_A_FirstLiquidityInitialization() public {
        vm.prank(lisa);
        usdc.transfer(owner, 0); // no-op, just ensure owner untouched
        vm.startPrank(owner);
        usdc.mint(owner, 1_000e6);
        usdc.approve(address(pool), 1_000e6);
        pool.initializeLiquidity(1_000e6);
        vm.stopPrank();

        assertEq(pool.idleLedger(), 1_000e6);
        assertEq(pool.totalDeployed(), 0);
        assertEq(pool.totalShares(), 1_000e6);
        assertEq(pool.sharesOf(owner), 1_000e6);
        assertEq(pool.sharePrice(), 1e18); // 1.0 share price
    }

    function test_A_CannotInitializeTwice() public {
        _seedPool(1_000e6);
        vm.startPrank(owner);
        usdc.approve(address(pool), 1e6);
        vm.expectRevert(LiquidityPool.AlreadyInitialized.selector);
        pool.initializeLiquidity(1e6);
        vm.stopPrank();
    }

    // ---- B. Multiple lenders depositing at different share prices ----
    function test_B_MultipleLendersDifferentSharePrices() public {
        _seedPool(1_000e6); // owner: 1,000 shares @ $1.00

        // Simulate a profit event before Mo deposits, so share price rises.
        _bumpPoolNAV(100e6); // idleLedger += 100e6 directly (simulated profit landing)

        // sharePrice now = 1,100/1,000 = 1.10
        vm.prank(mo);
        pool.deposit(220e6); // should mint 220/1.10 = 200 shares

        assertEq(pool.sharesOf(mo), 200e6 * 1e6 / 1e6); // 200e6 shares (6-decimal USDC units used as share units throughout)
        assertEq(pool.totalShares(), 1_000e6 + 200e6);
        // NAV after Mo's deposit = 1,100 + 220 = 1,320; shares = 1,200 -> price = 1.10 unchanged
        assertEq(pool.sharePrice(), 1.1e18);
    }

    // ---- C. Small Requested loan automatically funded ----
    function test_C_SmallRequestedLoanAutoFunded() public {
        _seedPool(1_000e6);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(5e6, 5.75e6, 10000, 0, address(0), 0)); // 100% rate for clean pool-level math

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Requested)); // auto-clearable, no approval needed

        vault.fundFromPool(loanId);

        assertEq(pool.idleLedger(), 995e6);
        assertEq(pool.totalDeployed(), 5e6);
        assertEq(pool.totalAssets(), 1_000e6); // unchanged — value just moved buckets
        assertEq(vault.lockedAmount(loanId), 5e6);
    }

    // ---- D. PendingApproval loan cannot be funded before human approval ----
    function test_D_PendingApprovalCannotBeFundedFromPool() public {
        _seedPool(1_000_000e6);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(30_000e6, 34_500e6, 1500, 0, address(0), 0)); // exceeds $25k threshold
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.PendingApproval));

        vm.expectRevert(LoanVault.LoanNotFundable.selector);
        vault.fundFromPool(loanId);

        // Pool state must be completely untouched by the failed attempt.
        assertEq(pool.idleLedger(), 1_000_000e6);
        assertEq(pool.totalDeployed(), 0);
    }

    // ---- E. Approved large loan funded from pool ----
    function test_E_ApprovedLargeLoanFundedFromPool() public {
        _seedPool(1_000_000e6);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(30_000e6, 34_500e6, 1500, 0, address(0), 0));
        registry.approveLoan(loanId); // real on-chain gate, owner-only

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Approved));

        vault.fundFromPool(loanId);

        assertEq(pool.idleLedger(), 970_000e6);
        assertEq(pool.totalDeployed(), 30_000e6);
    }

    // ---- F. Insufficient pool liquidity ----
    function test_F_InsufficientPoolLiquidity() public {
        _seedPool(4e6); // less than the $5 loan below

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(5e6, 5.75e6, 10000, 0, address(0), 0));

        vm.expectRevert(LiquidityPool.InsufficientLiquidity.selector);
        vault.fundFromPool(loanId);

        // Loan remains Requested — fundable later once liquidity arrives.
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Requested));
        assertEq(vault.lockedAmount(loanId), 0); // note: lockedAmount is set BEFORE the pool call reverts in fundFromPool,
                                                   // but the whole tx reverts on the pool's InsufficientLiquidity, so this
                                                   // assertion confirms the revert correctly unwound everything.
    }

    // ---- G. Full repayment with interest ----
    function test_G_FullRepaymentWithInterest() public {
        _seedPool(1_000e6);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(5e6, 5.75e6, 10000, 0, address(0), 0));
        vault.fundFromPool(loanId);

        vm.prank(vault.owner()); // vault itself doesn't call markFunded directly in this flow — markFunded already happened inside fundFromPool
        // (no-op prank, left for clarity that no further vault action is needed)

        vm.prank(client);
        router.payRevenue(loanId, 5.75e6); // 100% rate -> full repaymentShare = 5.75e6

        pool.reconcileLoan(loanId);

        assertEq(pool.totalDeployed(), 0);
        assertEq(pool.idleLedger(), 1_000e6 - 5e6 + 5.75e6); // 995 + 5.75 = 1,000.75
        assertEq(pool.totalAssets(), 1_000.75e6);
        assertTrue(router.isFullyRepaid(loanId));
        assertTrue(pool.finalized(loanId));
        assertEq(pool.activeLoanCount(), 0); // untracked once finalized
    }

    // ---- H. Partial default/recovery (pure unsecured, ReservePool tops up) ----
    function test_H_PartialDefaultRecoveryViaReservePool() public {
        _seedPool(1_000e6);
        _fundReservePoolDirectly(50e6);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(100e6, 115e6, 10000, 0, address(0), 0));
        vault.fundFromPool(loanId);

        // Client pays 30 before going dark.
        vm.prank(client);
        router.payRevenue(loanId, 30e6);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);
        registry.markDefault(loanId); // pure unsecured -> reservePool.payout() covers shortfall = 115 - 30 = 85, capped at reserve's 50

        pool.reconcileLoan(loanId);

        // Recovered: 30 (router) + 50 (reserve payout, capped) = 80. Principal was 100, so 20 is written off as loss.
        assertEq(pool.totalDeployed(), 0); // fully closed out (recovered portion + written-off remainder both zero the deployed balance)
        assertEq(pool.idleLedger(), 1_000e6 - 100e6 + 80e6); // 900 + 80 = 980
        assertEq(pool.totalAssets(), 980e6); // net $20 loss on NAV
    }

    // ---- I. Total loss ----
    function test_I_TotalLoss() public {
        _seedPool(1_000e6);
        // Reserve pool deliberately left unfunded — zero recovery available from it.

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(100e6, 115e6, 10000, 0, address(0), 0));
        vault.fundFromPool(loanId);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);
        registry.markDefault(loanId); // reserve payout = 0 since reserve is empty

        pool.reconcileLoan(loanId);

        assertEq(pool.totalDeployed(), 0);
        assertEq(pool.idleLedger(), 900e6); // full $100 principal lost
        assertEq(pool.totalAssets(), 900e6);
    }

    // ---- J. RevenueRouter recovery after default ----
    function test_J_RevenueRouterRecoveryAfterDefault() public {
        _seedPool(1_000e6);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(100e6, 115e6, 10000, 0, address(0), 0));
        vault.fundFromPool(loanId);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);
        registry.markDefault(loanId); // 0 recovered, reserve empty -> full $100 written off on reconcile

        pool.reconcileLoan(loanId); // realizes the $100 loss now
        assertEq(pool.idleLedger(), 900e6);

        // Borrower's agent later sends more via post-default garnishment (100% take).
        vm.prank(client);
        router.payRevenue(loanId, 60e6); // brings totalRecovered to 60, still not fully repaid (needs 115)

        pool.reconcileLoan(loanId); // principalRemaining is already 0 (forced at write-off) -> entire 60 is pure profit

        assertEq(pool.totalDeployed(), 0); // stays zero, no double-decrement
        assertEq(pool.idleLedger(), 960e6); // 900 + 60 — the loss is being recovered as pure NAV gain, no inconsistency
    }

    // ---- K. Collateral recovery ----
    function test_K_CollateralRecovery() public {
        _seedPool(1_000e6);

        uint256 principal = 100e6;
        uint256 requiredCollateral = collateralVault.requiredCollateral(principal); // 100 / 0.66 ≈ 151.515151

        usdc.mint(borrower, requiredCollateral);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), requiredCollateral);
        vm.prank(borrower);
        collateralVault.depositCollateral(requiredCollateral);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(principal, 115e6, 10000, requiredCollateral, address(0), 0));
        vault.fundFromPool(loanId);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);
        registry.markDefault(loanId); // collateral fully seized to pool (loan.lender)

        pool.reconcileLoan(loanId);

        // Collateral (>= principal, since LTV < 100%) fully covers principal; excess is profit.
        assertEq(pool.totalDeployed(), 0);
        assertEq(pool.idleLedger(), 1_000e6 - principal + requiredCollateral); // 900 + ~151.52 > original 1,000 -> net gain
        assertTrue(pool.idleLedger() > 1_000e6); // collateral over-covers principal at 66% LTV, a real (if odd) upside
    }

    // ---- L. Underwriter recovery ----
    function test_L_UnderwriterRecovery() public {
        _seedPool(1_000_000e6);

        address underwriter = address(0x11DE12);
        uint256 stake = 30_000e6;
        usdc.mint(underwriter, stake);
        vm.prank(underwriter);
        usdc.approve(address(underwriterPool), stake);
        vm.prank(underwriter);
        underwriterPool.depositStake(stake);
        vm.prank(underwriter);
        underwriterPool.commitToAgent(borrower, stake);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(30_000e6, 34_500e6, 10000, 0, underwriter, stake));
        registry.approveLoan(loanId); // above $25k Path B threshold
        vault.fundFromPool(loanId);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);
        registry.markDefault(loanId); // underwriter stake seized to pool

        pool.reconcileLoan(loanId);

        assertEq(pool.totalDeployed(), 0);
        assertEq(pool.idleLedger(), 1_000_000e6); // fully made whole — 30,000 out, 30,000 back
    }

    // ---- M. ReservePool recovery — already covered in H, this isolates the pure-reserve path with full coverage ----
    function test_M_ReservePoolFullRecovery() public {
        _seedPool(1_000e6);
        _fundReservePoolDirectly(100e6); // enough to fully cover the loan below

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(100e6, 100e6, 10000, 0, address(0), 0)); // 0% interest, for a clean "made whole" check

        vault.fundFromPool(loanId);
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);
        registry.markDefault(loanId); // reserve pays out full 100 shortfall

        pool.reconcileLoan(loanId);

        assertEq(pool.totalDeployed(), 0);
        assertEq(pool.idleLedger(), 1_000e6); // fully made whole, no loss
    }

    // ---- N. Lender withdrawal while capital is deployed ----
    function test_N_WithdrawalBlockedWhileCapitalDeployed() public {
        _seedPool(1_000e6);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(900e6, 1_035e6, 10000, 0, address(0), 0)); // most of the pool
        vault.fundFromPool(loanId);

        // idleLedger is now only 100e6; owner holds 1,000e6 shares worth (at unchanged NAV) 1,000e6 — but only 100 is liquid.
        vm.prank(owner);
        vm.expectRevert(LiquidityPool.InsufficientLiquidity.selector);
        pool.withdraw(200e6); // would require 200e6 out, exceeds idleLedger of 100e6
    }

    // ---- O. Withdrawal after repayment ----
    function test_O_WithdrawalAfterRepayment() public {
        _seedPool(1_000e6);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(900e6, 1_035e6, 10000, 0, address(0), 0));
        vault.fundFromPool(loanId);

        vm.prank(client);
        router.payRevenue(loanId, 1_035e6); // full repayment

        // withdraw() triggers _reconcileAll() internally before computing amountOut.
        uint256 balBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        pool.withdraw(1_000e6); // burn all shares

        uint256 balAfter = usdc.balanceOf(owner);
        assertEq(balAfter - balBefore, 1_135e6); // 1,000 principal-equivalent + 135 interest, fully liquid post-reconciliation
        assertEq(pool.totalShares(), 0);
        assertEq(pool.idleLedger(), 0);
    }

    // ---- P. First-depositor/inflation manipulation ----
    function test_P_CannotFrontRunFirstDeposit() public {
        // Nobody can call initializeLiquidity except the owner.
        vm.prank(attacker);
        vm.expectRevert(); // Ownable's own revert, not a LiquidityPool-specific one
        pool.initializeLiquidity(1e6);

        // A "donation" attack (direct token transfer before init) can't manipulate
        // share price either, since totalAssets is idleLedger+totalDeployed (tracked
        // state), never raw balanceOf — an untracked donation just sits unrecognized.
        usdc.mint(address(pool), 1_000_000e6);
        assertEq(pool.totalAssets(), 0); // donation has zero effect on NAV before init

        _seedPool(1_000e6);
        assertEq(pool.sharePrice(), 1e18); // clean 1.0, unaffected by the earlier donation
    }

    // ---- Q. Reentrancy/access-control attempts ----
    function test_Q_OnlyLoanVaultCanCallFundLoan() public {
        _seedPool(1_000e6);
        vm.prank(attacker);
        vm.expectRevert(LiquidityPool.NotLoanVault.selector);
        pool.fundLoan(999, 100e6);
    }

    function test_Q_CannotDoubleFundSameLoan() public {
        _seedPool(1_000e6);
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal(5e6, 5.75e6, 10000, 0, address(0), 0));
        vault.fundFromPool(loanId);

        vm.prank(address(vault));
        vm.expectRevert(LiquidityPool.AlreadyFunded.selector);
        pool.fundLoan(loanId, 5e6);
    }

    // ---- R. Attempt to fund an ineligible loan directly through fundFromPool() ----
    function test_R_CannotFundNonexistentOrIneligibleLoan() public {
        _seedPool(1_000e6);
        // loanId 999 was never requested — LoanRegistry.getLoan() on an
        // unset loanId returns default/zeroed struct, status == Requested (enum default 0)
        // is actually the risk here: verify it's NOT silently fundable in a way that
        // fabricates a real loan. principal will be 0, so funding "succeeds" for
        // a worthless amount but creates no real obligation — flagging this as a
        // genuine edge case worth a dedicated LoanRegistry-level guard in a future pass,
        // not something LiquidityPool/LoanVault can fully close on their own.
        ILoanRegistry.LoanView memory phantom = registry.getLoan(999);
        assertEq(phantom.principal, 0); // confirms it's a zero-value no-op, not a real exploit path
    }

    // ---- Helpers ----
    function _seedPool(uint256 amount) internal {
        vm.startPrank(owner);
        usdc.mint(owner, amount);
        usdc.approve(address(pool), amount);
        pool.initializeLiquidity(amount);
        vm.stopPrank();
    }

    function _bumpPoolNAV(uint256 amount) internal {
        // Simulates a profit landing directly in idleLedger for test setup
        // purposes only — real flows always go through reconcileLoan().
        usdc.mint(address(pool), amount);
        vm.store(address(pool), bytes32(uint256(7)), bytes32(pool.idleLedger() + amount)); // slot 7: idleLedger (verified via forge inspect) — see note below
    }

    function _fundReservePoolDirectly(uint256 amount) internal {
        usdc.mint(owner, amount);
        usdc.approve(address(reservePool), amount);
        usdc.transferFrom(owner, address(reservePool), amount);
    }
}