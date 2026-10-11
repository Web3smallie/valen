// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// DirectDisbursement.t.sol
//
// Tests for the directDisbursement flag introduced in V1.1.
//
// Covers the acceptance criteria from the feature spec:
//   A. Collateral-backed direct disbursement — full lifecycle
//   B. Milestone-based loan is unaffected (regression)
//   C. Security: insufficient collateral cannot qualify
//   D. Security: releaseMilestone reverts on direct loans
//   E. Security: cannot be disbursed twice
//   F. Repayment, default, and collateral release remain correct
//   G. LiquidityPool accounting (pool-funded direct loan)
//   H. Unauthorized wallets cannot redirect disbursements
//   I. Pool-funded direct disbursement (fundFromPool path)
//   J. EURC collateral with direct disbursement
// ─────────────────────────────────────────────────────────────────────────────

import {Test}         from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20}        from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AgentRegistry}     from "../src/AgentRegistry.sol";
import {CreditRegistry}    from "../src/CreditRegistry.sol";
import {LoanRegistry}      from "../src/LoanRegistry.sol";
import {RevenueRouter}     from "../src/RevenueRouter.sol";
import {LoanVault}         from "../src/LoanVault.sol";
import {CollateralVault}   from "../src/CollateralVault.sol";
import {UnderwriterPool}   from "../src/UnderwriterPool.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ReservePool}       from "../src/ReservePool.sol";
import {LiquidityPool}     from "../src/LiquidityPool.sol";
import {ILoanRegistry}     from "../src/interfaces/ILoanRegistry.sol";

// ─── Test tokens ──────────────────────────────────────────────────────────────
contract MockUSDC_DD is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockEURC_DD is ERC20 {
    constructor() ERC20("Mock EURC", "EURC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

// ─────────────────────────────────────────────────────────────────────────────
contract DirectDisbursementTest is Test {

    // ── Actors ────────────────────────────────────────────────────────────────
    address owner        = address(0xA1);
    address borrower     = address(0xB1);
    address creditWallet = address(0xC1);
    address lender       = address(0xD1);

    // ── Tokens ────────────────────────────────────────────────────────────────
    MockUSDC_DD usdc;
    MockEURC_DD eurc;

    // ── Contracts ─────────────────────────────────────────────────────────────
    AgentRegistry     agentReg;
    CreditRegistry    creditReg;
    LoanRegistry      registry;
    RevenueRouter     router;
    LoanVault         vault;
    CollateralVault   collateralVault;
    UnderwriterPool   underwriterPool;
    RecipientRegistry recipientReg;
    ReservePool       reservePool;
    LiquidityPool     liquidityPool;

    uint256 agentId;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 constant INITIAL_LIMIT            = 5e6;
    uint16  constant GROWTH_BPS               = 2500;
    uint16  constant EARLY_BONUS_BPS          = 1000;
    uint256 constant MAX_STEP_INCREASE        = 2000e6;
    uint16  constant DEFAULT_PENALTY_BPS      = 2000;
    uint256 constant APPROVAL_THRESHOLD       = 25_000e6;
    uint16  constant ACTIVITY_GROWTH_BPS      = 500;
    uint256 constant MAX_ACTIVITY_PER_EVT     = 50e6;
    uint256 constant MAX_ACTIVITY_LIMIT       = 50_000e6;
    uint256 constant MIN_DUR                  = 1 days;
    uint256 constant MAX_DUR                  = 365 days;
    uint256 constant GRACE                    = 3 days;
    uint256 constant COL_THRESH               = 10_000e6;
    uint16  constant MAX_LTV                  = 6600;     // 66 %
    uint16  constant RESERVE_BPS              = 200;      // 2 %
    uint256 constant EURC_PRICE               = 1.08e18;  // $1.08 per EURC

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _proxy(address impl, bytes memory init) internal returns (address) {
        return address(new ERC1967Proxy(impl, init));
    }

    /// @dev Returns the minimum USDC collateral required for `principal` at the
    ///      configured LTV.  requiredCollateral = ceil(principal * 10000 / maxLTV).
    function _requiredUsdc(uint256 principal) internal pure returns (uint256) {
        // Use the same floor division as CollateralVault.requiredCollateralUsdc.
        return (principal * 10000) / MAX_LTV;
    }

    /// @dev Required EURC units to back `principal` USDC at 66 % LTV and $1.08/EURC.
    ///      Formula mirrors CollateralVault.requiredCollateral(principal, eurc):
    ///      req = (principal * 10000 / maxLTV) * 1e18 * 1e6 / (EURC_PRICE * 1e6)
    ///          = requiredUsdc * 1e18 / EURC_PRICE
    function _requiredEurc(uint256 principal) internal pure returns (uint256) {
        uint256 reqUsdc = (principal * 10000) / MAX_LTV;
        return (reqUsdc * 1e18 * 1e6) / (EURC_PRICE * 1e6);
    }

    function _buildDirectProposal(uint256 principal, address collAsset, uint256 collAmount)
        internal view returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});

        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "direct";

        return ILoanRegistry.LoanProposal({
            agentId:               agentId,
            creditWallet:          creditWallet,
            principal:             principal,
            repaymentRateBps:      10000,
            totalRepaymentDue:     principal + principal / 10,
            duration:              30 days,
            purpose:               "DD test",
            budget:                budget,
            permittedRecipients:   _one(creditWallet),
            milestoneAmounts:      ms,
            milestoneDescriptions: desc,
            collateralAmount:      collAmount,
            collateralAsset:       collAsset,
            underwriter:           address(0),
            underwriterAmount:     0,
            directDisbursement:    true
        });
    }

    function _buildMilestoneProposal(uint256 principal) internal view
        returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});

        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "m0";

        return ILoanRegistry.LoanProposal({
            agentId:               agentId,
            creditWallet:          creditWallet,
            principal:             principal,
            repaymentRateBps:      10000,
            totalRepaymentDue:     principal + principal / 10,
            duration:              30 days,
            purpose:               "milestone test",
            budget:                budget,
            permittedRecipients:   _one(creditWallet),
            milestoneAmounts:      ms,
            milestoneDescriptions: desc,
            collateralAmount:      0,
            collateralAsset:       address(0),
            underwriter:           address(0),
            underwriterAmount:     0,
            directDisbursement:    false
        });
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1); arr[0] = a;
    }

    function _seedCredit(uint256 amount) internal {
        vm.prank(address(router));
        creditReg.recordRepayment(agentId, amount, false);
    }

    // ── setUp ─────────────────────────────────────────────────────────────────
    function setUp() public {
        usdc = new MockUSDC_DD();
        eurc = new MockEURC_DD();

        agentReg = AgentRegistry(_proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        ));

        creditReg = CreditRegistry(_proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize, (
                owner, INITIAL_LIMIT, GROWTH_BPS, EARLY_BONUS_BPS,
                MAX_STEP_INCREASE, DEFAULT_PENALTY_BPS, APPROVAL_THRESHOLD,
                ACTIVITY_GROWTH_BPS, MAX_ACTIVITY_PER_EVT, MAX_ACTIVITY_LIMIT
            ))
        ));

        registry = LoanRegistry(_proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize, (
                owner, address(creditReg), MIN_DUR, MAX_DUR, GRACE, COL_THRESH
            ))
        ));

        router = RevenueRouter(_proxy(
            address(new RevenueRouter()),
            abi.encodeCall(RevenueRouter.initialize, (
                owner, address(registry), address(creditReg), address(usdc)
            ))
        ));

        vault = LoanVault(_proxy(
            address(new LoanVault()),
            abi.encodeCall(LoanVault.initialize, (owner, address(registry), address(usdc)))
        ));

        collateralVault = CollateralVault(_proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, (owner, address(usdc), address(registry), MAX_LTV))
        ));

        underwriterPool = UnderwriterPool(_proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize, (owner, address(usdc), address(registry)))
        ));

        recipientReg = RecipientRegistry(_proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        ));

        reservePool = ReservePool(_proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        ));

        liquidityPool = LiquidityPool(_proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc), address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reservePool), address(vault)
            ))
        ));

        // Wiring
        vm.startPrank(owner);
        registry.setContracts(address(vault), address(router));
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        registry.setRecipientRegistry(address(recipientReg));
        registry.setReservePool(address(reservePool));
        registry.setAgentRegistry(address(agentReg));

        router.setAgentRegistry(address(agentReg));
        router.setReservePool(address(reservePool), RESERVE_BPS);

        vault.setLiquidityPool(address(liquidityPool));

        creditReg.setAuthorizedCaller(address(router), true);
        creditReg.setAuthorizedCaller(address(registry), true);

        reservePool.setAuthorizedContributor(address(router), true);

        // Approve EURC as collateral
        collateralVault.setAssetConfig(address(eurc), true, 6, EURC_PRICE);

        // Approve creditWallet as a valid recipient
        recipientReg.approveRecipient(creditWallet, keccak256("COMPUTE"), "Credit wallet");

        vm.stopPrank();

        // Register agent (borrower is owner + first wallet; creditWallet is second)
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        // Fund actors
        usdc.mint(borrower, 1_000_000e6);
        usdc.mint(lender, 1_000_000e6);
        eurc.mint(borrower, 1_000_000e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // A. Collateral-backed direct disbursement — full lifecycle (P2P funder)
    // ═════════════════════════════════════════════════════════════════════════

    function test_A_DirectDisbursement_CollateralBacked_FullLifecycle() public {
        uint256 principal = 100e6;
        uint256 collAmount = _requiredUsdc(principal);
        uint256 repaymentDue = principal + principal / 10;

        // Deposit collateral
        vm.prank(borrower);
        usdc.approve(address(collateralVault), collAmount);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(usdc), collAmount);

        // Request loan with directDisbursement = true
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _buildDirectProposal(principal, address(usdc), collAmount)
        );

        // Verify stored flag
        assertTrue(registry.getDirectDisbursement(loanId), "directDisbursement not stored");

        // Status is Requested (collateral path, below COL_THRESH=10_000e6)
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Requested), "not Requested");

        // collateral reserved
        assertEq(registry.getCollateralAmount(loanId), collAmount, "collateralAmount wrong");
        assertEq(collateralVault.availableBalance(borrower, address(usdc)), 0, "available not zero");

        uint256 creditWalletBefore = usdc.balanceOf(creditWallet);

        // Fund the loan (P2P lender)
        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        // creditWallet should have received the full principal immediately
        assertEq(
            usdc.balanceOf(creditWallet),
            creditWalletBefore + principal,
            "creditWallet did not receive principal at funding"
        );

        // lockedAmount must be zero — no milestone funds sitting in vault
        assertEq(vault.lockedAmount(loanId), 0, "lockedAmount should be zero for direct loan");

        // Loan is Active
        loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Active), "not Active");

        // Repay in full
        vm.prank(borrower);
        usdc.approve(address(router), repaymentDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repaymentDue);

        // Loan is Repaid
        loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Repaid), "not Repaid");

        // Collateral released back to borrower
        (, , , bool resolved) = collateralVault.reservations(loanId);
        assertTrue(resolved, "collateral not released");
        assertEq(
            collateralVault.availableBalance(borrower, address(usdc)),
            0,
            "availableBalance should be zero (collateral transferred to borrower, not re-deposited)"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // B. Milestone-based loan is unaffected (regression guard)
    // ═════════════════════════════════════════════════════════════════════════

    function test_B_MilestoneLoan_UnaffectedByNewField() public {
        _seedCredit(5_000e6);
        uint256 principal = 500e6;

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildMilestoneProposal(principal));

        assertFalse(registry.getDirectDisbursement(loanId), "should not be direct");

        uint256 creditWalletBefore = usdc.balanceOf(creditWallet);

        // Fund via P2P
        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        // creditWallet should NOT have received funds yet
        assertEq(
            usdc.balanceOf(creditWallet),
            creditWalletBefore,
            "milestone loan: creditWallet should not receive at fund time"
        );

        // lockedAmount should hold the full principal
        assertEq(vault.lockedAmount(loanId), principal, "milestone loan: lockedAmount wrong");

        // Release milestone — funds flow to creditWallet
        vm.prank(lender);
        vault.releaseMilestone(loanId, 0);
        assertEq(
            usdc.balanceOf(creditWallet),
            creditWalletBefore + principal,
            "milestone not released correctly"
        );

        // Repay
        uint256 repaymentDue = principal + principal / 10;
        vm.prank(borrower);
        usdc.approve(address(router), repaymentDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repaymentDue);
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Repaid),
            "milestone loan not Repaid"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // C. Insufficient collateral cannot qualify for a secured direct loan
    // ═════════════════════════════════════════════════════════════════════════

    function test_C_InsufficientCollateral_Reverts() public {
        uint256 principal = 100e6;
        uint256 required = _requiredUsdc(principal);
        uint256 insufficient = required - 1;

        vm.prank(borrower);
        usdc.approve(address(collateralVault), insufficient);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(usdc), insufficient);

        vm.prank(borrower);
        vm.expectRevert(CollateralVault.InsufficientCollateralForLTV.selector);
        registry.requestLoan(
            _buildDirectProposal(principal, address(usdc), insufficient)
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // D. releaseMilestone reverts on a direct-disbursement loan
    // ═════════════════════════════════════════════════════════════════════════

    function test_D_ReleaseMilestone_RevertsOnDirectLoan() public {
        uint256 principal = 100e6;
        uint256 collAmount = _requiredUsdc(principal);

        vm.prank(borrower);
        usdc.approve(address(collateralVault), collAmount);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(usdc), collAmount);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _buildDirectProposal(principal, address(usdc), collAmount)
        );

        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        // Attempting releaseMilestone on a direct loan must revert
        vm.prank(lender);
        vm.expectRevert(LoanVault.DirectLoanCannotReleaseMilestone.selector);
        vault.releaseMilestone(loanId, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // E. Cannot disburse a direct loan twice
    // ═════════════════════════════════════════════════════════════════════════

    function test_E_CannotFundTwice() public {
        uint256 principal = 100e6;
        uint256 collAmount = _requiredUsdc(principal);

        vm.prank(borrower);
        usdc.approve(address(collateralVault), collAmount);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(usdc), collAmount);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _buildDirectProposal(principal, address(usdc), collAmount)
        );

        vm.prank(lender);
        usdc.approve(address(vault), principal * 2);
        vm.prank(lender);
        vault.fundLoan(loanId);

        // Second fund attempt: loan is now Active, not Requested — must revert
        vm.prank(lender);
        vm.expectRevert(LoanVault.LoanNotFundable.selector);
        vault.fundLoan(loanId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F. Default path: collateral is seized to lender, no double-release
    // ═════════════════════════════════════════════════════════════════════════

    function test_F_Default_CollateralSeized_DirectLoan() public {
        uint256 principal = 100e6;
        uint256 collAmount = _requiredUsdc(principal);

        vm.prank(borrower);
        usdc.approve(address(collateralVault), collAmount);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(usdc), collAmount);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _buildDirectProposal(principal, address(usdc), collAmount)
        );

        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        // creditWallet has the funds; borrower does not repay
        // Advance time past expiry + grace
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);

        // Mark default (owner is keeper)
        vm.prank(owner);
        registry.markDefault(loanId);

        loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Defaulted), "not Defaulted");

        // Collateral reservation resolved, USDC went to lender
        (, , , bool resolved) = collateralVault.reservations(loanId);
        assertTrue(resolved, "reservation not resolved on default");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // G. LiquidityPool accounting — pool-funded direct loan
    // ═════════════════════════════════════════════════════════════════════════

    function test_G_PoolFunded_DirectDisbursement_Accounting() public {
        uint256 principal = 100e6;
        uint256 collAmount = _requiredUsdc(principal);
        uint256 repaymentDue = principal + principal / 10;

        // Seed LP
        usdc.mint(owner, 500_000e6);
        vm.prank(owner);
        usdc.approve(address(liquidityPool), 500_000e6);
        vm.prank(owner);
        liquidityPool.initializeLiquidity(500_000e6);

        uint256 idleBefore = liquidityPool.idleLedger();

        // Deposit collateral
        vm.prank(borrower);
        usdc.approve(address(collateralVault), collAmount);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(usdc), collAmount);

        // Request direct loan
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _buildDirectProposal(principal, address(usdc), collAmount)
        );

        uint256 creditWalletBefore = usdc.balanceOf(creditWallet);

        // Fund from pool
        vm.prank(owner);
        vault.fundFromPool(loanId);

        // Pool deployed principal
        assertEq(liquidityPool.idleLedger(), idleBefore - principal, "idle not decreased");
        assertEq(liquidityPool.totalDeployed(), principal, "deployed not increased");

        // creditWallet has the funds immediately
        assertEq(
            usdc.balanceOf(creditWallet),
            creditWalletBefore + principal,
            "creditWallet did not receive principal from pool-funded direct loan"
        );

        // lockedAmount is zero
        assertEq(vault.lockedAmount(loanId), 0, "lockedAmount should be zero");

        // Repay
        vm.prank(borrower);
        usdc.approve(address(router), repaymentDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repaymentDue);

        // Reconcile — pool recovers its principal
        liquidityPool.reconcileLoan(loanId);

        assertTrue(
            liquidityPool.idleLedger() > idleBefore - principal,
            "pool did not recover after repayment+reconcile"
        );
        assertTrue(liquidityPool.finalized(loanId), "loan not finalized in pool");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // H. Unauthorized wallets cannot redirect disbursement
    //    (creditWallet validation happens in requestLoan, not at fund time)
    // ═════════════════════════════════════════════════════════════════════════

    function test_H_UnauthorizedCreditWallet_CannotRequest() public {
        uint256 principal = 100e6;
        uint256 collAmount = _requiredUsdc(principal);

        vm.prank(borrower);
        usdc.approve(address(collateralVault), collAmount);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(usdc), collAmount);

        // Build proposal with a non-approved creditWallet
        ILoanRegistry.LoanProposal memory p = _buildDirectProposal(principal, address(usdc), collAmount);
        address attacker = address(0xBAD);
        p.creditWallet = attacker;
        p.permittedRecipients = _one(attacker);

        vm.prank(borrower);
        vm.expectRevert(); // UnapprovedRecipient — attacker not in RecipientRegistry
        registry.requestLoan(p);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I. Pool-funded direct loan — no releaseMilestone required by operator
    // ═════════════════════════════════════════════════════════════════════════

    function test_I_PoolFunded_DirectLoan_NoMilestoneNeeded() public {
        uint256 principal = 100e6;
        uint256 collAmount = _requiredUsdc(principal);

        usdc.mint(owner, 500_000e6);
        vm.prank(owner);
        usdc.approve(address(liquidityPool), 500_000e6);
        vm.prank(owner);
        liquidityPool.initializeLiquidity(500_000e6);

        vm.prank(borrower);
        usdc.approve(address(collateralVault), collAmount);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(usdc), collAmount);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _buildDirectProposal(principal, address(usdc), collAmount)
        );

        uint256 beforeFund = usdc.balanceOf(creditWallet);

        vm.prank(owner);
        vault.fundFromPool(loanId);

        // Funds arrived without any releaseMilestone call
        assertEq(
            usdc.balanceOf(creditWallet) - beforeFund,
            principal,
            "funds should arrive without milestone release"
        );

        // releaseMilestone should revert
        vm.prank(owner);
        vm.expectRevert(LoanVault.DirectLoanCannotReleaseMilestone.selector);
        vault.releaseMilestone(loanId, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // J. EURC collateral with direct disbursement
    // ═════════════════════════════════════════════════════════════════════════

    function test_J_EURC_Collateral_DirectDisbursement() public {
        uint256 principal = 10e6; // 10 USDC
        uint256 collAmount = _requiredEurc(principal);
        uint256 repaymentDue = principal + principal / 10;

        // Deposit EURC collateral
        vm.prank(borrower);
        eurc.approve(address(collateralVault), collAmount);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(eurc), collAmount);

        // Request direct loan against EURC
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _buildDirectProposal(principal, address(eurc), collAmount)
        );

        assertEq(registry.getCollateralAsset(loanId), address(eurc), "wrong collateral asset");
        assertTrue(registry.getDirectDisbursement(loanId), "not direct");

        uint256 creditWalletBefore = usdc.balanceOf(creditWallet);

        // Fund (P2P lender supplies USDC)
        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        // Borrower's creditWallet received USDC immediately
        assertEq(
            usdc.balanceOf(creditWallet),
            creditWalletBefore + principal,
            "EURC-collateral direct loan: USDC not disbursed immediately"
        );

        // Repay in USDC
        vm.prank(borrower);
        usdc.approve(address(router), repaymentDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repaymentDue);

        // Loan is Repaid
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Repaid),
            "EURC-collateral direct loan not Repaid"
        );

        // EURC collateral returned to borrower
        (, , , bool resolved) = collateralVault.reservations(loanId);
        assertTrue(resolved, "EURC collateral not released");

        // Borrower's EURC balance restored
        // collAmount was transferred from borrower → CV → back to borrower on release
        assertGe(eurc.balanceOf(borrower), 1_000_000e6 - collAmount + collAmount - 1,
            "EURC not returned");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // K. Partial repayment does not release collateral until full repayment
    // ═════════════════════════════════════════════════════════════════════════

    function test_K_PartialRepayment_CollateralNotReleasedEarly() public {
        uint256 principal = 100e6;
        uint256 collAmount = _requiredUsdc(principal);
        uint256 repaymentDue = principal + principal / 10;
        uint256 halfPayment = repaymentDue / 2;

        vm.prank(borrower);
        usdc.approve(address(collateralVault), collAmount);
        vm.prank(borrower);
        collateralVault.depositCollateral(address(usdc), collAmount);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(
            _buildDirectProposal(principal, address(usdc), collAmount)
        );

        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        // Partial repayment
        vm.prank(borrower);
        usdc.approve(address(router), halfPayment);
        vm.prank(borrower);
        router.repayLoan(loanId, halfPayment);

        // Loan still Active
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan should still be Active after halfPayment repayment"
        );

        // Collateral not yet released
        (, , , bool resolved) = collateralVault.reservations(loanId);
        assertFalse(resolved, "collateral should not be released before full repayment");

        // Complete repayment
        uint256 remaining = repaymentDue - halfPayment;
        vm.prank(borrower);
        usdc.approve(address(router), remaining);
        vm.prank(borrower);
        router.repayLoan(loanId, remaining);

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Repaid),
            "loan not Repaid after full repayment"
        );
        (, , , bool resolvedFinal) = collateralVault.reservations(loanId);
        assertTrue(resolvedFinal, "collateral not released after full repayment");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // L. getDirectDisbursement returns false for old milestone loans (default)
    // ═════════════════════════════════════════════════════════════════════════

    function test_L_GetDirectDisbursement_DefaultsFalse() public {
        _seedCredit(5_000e6);
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildMilestoneProposal(100e6));
        assertFalse(registry.getDirectDisbursement(loanId), "default should be false");
    }
}
