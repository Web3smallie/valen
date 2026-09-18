// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------
// RISK-03 regression tests — vault-settlement ordering independence
//
// The defect: if reconcileLoan() is called before settleExpiredLoan(),
// defaultRecoveryCounted[loanId] is set to true. The subsequent call
// to settleExpiredLoan() transfers USDC to the pool but the second
// reconcileLoan() cannot enter the default-recovery block and never
// credits settledDefaultAmount into idleLedger.
//
// The fix: vaultSettlementCounted[loanId] is an independent one-time
// guard so vault settlement is always credited exactly once, regardless
// of whether settleExpiredLoan() runs before or after reconcileLoan().
//
// Uses ERC1967Proxy deployment to avoid MemoryOOG from 9-proxy setUp.
// -----------------------------------------------------------------

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy}        from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoanRegistry}        from "../src/LoanRegistry.sol";
import {LoanVault}           from "../src/LoanVault.sol";
import {CreditRegistry}      from "../src/CreditRegistry.sol";
import {RevenueRouter}       from "../src/RevenueRouter.sol";
import {CollateralVault}     from "../src/CollateralVault.sol";
import {UnderwriterPool}     from "../src/UnderwriterPool.sol";
import {RecipientRegistry}   from "../src/RecipientRegistry.sol";
import {ReservePool}         from "../src/ReservePool.sol";
import {LiquidityPool}       from "../src/LiquidityPool.sol";
import {ILoanRegistry}       from "../src/interfaces/ILoanRegistry.sol";
import {ERC20}               from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC_R03 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract Risk03_VaultSettlementOrderingTest is Test {

    LoanRegistry      registry;
    LoanVault         vault;
    CreditRegistry    creditReg;
    RevenueRouter     router;
    CollateralVault   collateralVault;
    UnderwriterPool   underwriterPool;
    RecipientRegistry recipientRegistry;
    ReservePool       reservePool;
    LiquidityPool     pool;
    MockUSDC_R03      usdc;

    address owner        = address(this);
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address client       = address(0xC1E4);
    address underwriter  = address(0x11DE12);

    uint256 constant GRACE   = 3 days;
    uint256 constant CAT     = 10_000e6;
    uint16  constant MAX_LTV = 6600;

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        usdc = new MockUSDC_R03();

        creditReg = CreditRegistry(_proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize,
                (owner, 5e6, 2500, 1000, 2_000_000e6, 2000, 25_000e6))
        ));

        registry = LoanRegistry(_proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), 1 days, 365 days, GRACE, CAT))
        ));

        router = RevenueRouter(_proxy(
            address(new RevenueRouter()),
            abi.encodeCall(RevenueRouter.initialize,
                (owner, address(registry), address(creditReg), address(usdc)))
        ));

        vault = LoanVault(_proxy(
            address(new LoanVault()),
            abi.encodeCall(LoanVault.initialize,
                (owner, address(registry), address(usdc)))
        ));

        collateralVault = CollateralVault(_proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize,
                (owner, address(usdc), address(registry), MAX_LTV))
        ));

        underwriterPool = UnderwriterPool(_proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize,
                (owner, address(usdc), address(registry)))
        ));

        recipientRegistry = RecipientRegistry(_proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        ));

        reservePool = ReservePool(_proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize,
                (owner, address(usdc), address(registry)))
        ));

        pool = LiquidityPool(_proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc), address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reservePool), address(vault)
            ))
        ));

        registry.setContracts(address(vault), address(router));
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        registry.setRecipientRegistry(address(recipientRegistry));
        registry.setReservePool(address(reservePool));
        vault.setLiquidityPool(address(pool));
        creditReg.setAuthorizedCaller(address(router), true);
        creditReg.setAuthorizedCaller(address(registry), true);
        reservePool.setAuthorizedContributor(address(router), true);
        router.setReservePool(address(reservePool), 0);
        recipientRegistry.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Provider");

        // Seed borrower credit
        vm.prank(address(router));
        creditReg.recordRepayment(borrower, 5_000e6, false);

        usdc.mint(client,      10_000_000e6);
        usdc.mint(underwriter, 10_000_000e6);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(underwriter);
        usdc.approve(address(underwriterPool), type(uint256).max);
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    function _seedPool(uint256 amount) internal {
        usdc.mint(owner, amount);
        usdc.approve(address(pool), amount);
        pool.initializeLiquidity(amount);
    }

    /// 2-milestone loan funded from pool; releases milestone 0 only.
    function _setupLoan(uint256 principal) internal returns (uint256 loanId, uint256 locked) {
        _seedPool(principal * 2);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256 half = principal / 2;
        uint256[] memory ms = new uint256[](2); ms[0] = half; ms[1] = principal - half;
        string[] memory desc = new string[](2); desc[0] = "M1"; desc[1] = "M2";

        vm.prank(borrower);
        loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: principal,
            repaymentRateBps: 10000, totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days, purpose: "RISK-03 test",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: 0, underwriter: address(0), underwriterAmount: 0
        }));

        vault.fundFromPool(loanId);
        vault.releaseMilestone(loanId, 0);      // releases half

        locked = vault.lockedAmount(loanId);     // remaining = half
    }

    function _defaultLoan(uint256 loanId) internal {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);
        registry.markDefault(loanId);
    }

    // ================================================================
    // TEST 01: markDefault → settleExpiredLoan → reconcileLoan
    //          (original RISK-01 order — must still work correctly)
    // ================================================================
    function test_01_SettleThenReconcile() public {
        (uint256 loanId, uint256 locked) = _setupLoan(100e6);
        _defaultLoan(loanId);

        vault.settleExpiredLoan(loanId);
        assertEq(vault.settledDefaultAmount(loanId), locked);

        uint256 idleBefore = pool.idleLedger();
        pool.reconcileLoan(loanId);

        // idleLedger must have grown by at least the vault-locked amount
        assertGe(pool.idleLedger(), idleBefore + locked,
            "vault recovery must be credited on first reconcile (settle-first order)");
        assertTrue(pool.vaultSettlementCounted(loanId), "vaultSettlementCounted must be set");
        assertEq(pool.totalDeployed(), 0, "totalDeployed must be 0");
    }

    // ================================================================
    // TEST 02: markDefault → reconcileLoan → settleExpiredLoan → reconcileLoan
    //          (RISK-03 ordering — vault settlement must land on 2nd reconcile)
    // ================================================================
    function test_02_ReconcileFirstThenSettle_VaultCreditedOnSecondReconcile() public {
        (uint256 loanId, uint256 locked) = _setupLoan(100e6);
        _defaultLoan(loanId);

        // First reconcile: defaultRecoveryCounted fires, but settledDefaultAmount == 0
        pool.reconcileLoan(loanId);
        assertTrue(pool.defaultRecoveryCounted(loanId), "defaultRecoveryCounted must be set");
        assertFalse(pool.vaultSettlementCounted(loanId), "vaultSettlementCounted must NOT yet be set");

        // Record idle after first reconcile (vault funds not yet counted)
        uint256 idleAfterFirst = pool.idleLedger();

        // Now vault settlement happens
        vault.settleExpiredLoan(loanId);
        assertEq(vault.settledDefaultAmount(loanId), locked);

        // Raw pool USDC has increased but idleLedger is still stale
        assertEq(usdc.balanceOf(address(pool)), idleAfterFirst + locked,
            "raw USDC must reflect vault transfer before second reconcile");

        // Second reconcile: must pick up settledDefaultAmount via independent guard
        pool.reconcileLoan(loanId);

        assertEq(pool.idleLedger(), idleAfterFirst + locked,
            "idleLedger must be credited with vault settlement on second reconcile");
        assertTrue(pool.vaultSettlementCounted(loanId), "vaultSettlementCounted must be set after second reconcile");
        assertEq(pool.totalDeployed(), 0, "totalDeployed must remain 0");
    }

    // ================================================================
    // TEST 03: markDefault → settleExpiredLoan → reconcileLoan → reconcileLoan
    //          (double-reconcile must not double-count)
    // ================================================================
    function test_03_NoDoubleCountOnRepeatedReconcile() public {
        (uint256 loanId,) = _setupLoan(100e6);
        _defaultLoan(loanId);

        vault.settleExpiredLoan(loanId);
        pool.reconcileLoan(loanId);

        uint256 idleAfterFirst  = pool.idleLedger();
        uint256 deployedAfter   = pool.totalDeployed();

        // Second reconcile must be a no-op
        pool.reconcileLoan(loanId);

        assertEq(pool.idleLedger(),    idleAfterFirst, "idleLedger must not change on second reconcile");
        assertEq(pool.totalDeployed(), deployedAfter,  "totalDeployed must not change on second reconcile");
    }

    // ================================================================
    // TEST 04: markDefault → reconcileLoan → reconcileLoan → settleExpiredLoan → reconcileLoan
    //          (triple-reconcile ordering variant — must credit exactly once)
    // ================================================================
    function test_04_TripleReconcileWithLateSettle() public {
        (uint256 loanId, uint256 locked) = _setupLoan(100e6);
        _defaultLoan(loanId);

        // Two reconciles before settlement
        pool.reconcileLoan(loanId);
        pool.reconcileLoan(loanId); // no-op

        uint256 idleBefore = pool.idleLedger();

        vault.settleExpiredLoan(loanId);
        pool.reconcileLoan(loanId); // must credit now

        assertEq(pool.idleLedger(), idleBefore + locked,
            "vault recovery must appear exactly once after late settlement");
        assertEq(pool.totalDeployed(), 0);

        // Fourth reconcile: no further change
        pool.reconcileLoan(loanId);
        assertEq(pool.idleLedger(), idleBefore + locked, "fourth reconcile must be a no-op");
    }

    // ================================================================
    // TEST 05: Vault settlement + collateral recovery (combined sources)
    //          Order: reconcileLoan first, then settleExpiredLoan
    // ================================================================
    function test_05_CollateralPlusVaultSettlement_LateSettle() public {
        uint256 principal = 100e6;
        uint256 required  = collateralVault.requiredCollateral(principal);

        usdc.mint(borrower, required);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), type(uint256).max);
        vm.prank(borrower);
        collateralVault.depositCollateral(required);

        // Seed pool
        _seedPool(principal * 2);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256 half = principal / 2;
        uint256[] memory ms = new uint256[](2); ms[0] = half; ms[1] = principal - half;
        string[] memory desc = new string[](2); desc[0] = "M1"; desc[1] = "M2";

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: principal,
            repaymentRateBps: 10000, totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days, purpose: "collateral+vault",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: required, underwriter: address(0), underwriterAmount: 0
        }));

        vault.fundFromPool(loanId);
        vault.releaseMilestone(loanId, 0);
        uint256 locked = vault.lockedAmount(loanId);

        _defaultLoan(loanId);

        // Collateral seized to pool at markDefault.
        // reconcileLoan first: picks up collateral, but vault not yet settled.
        pool.reconcileLoan(loanId);
        assertTrue(pool.defaultRecoveryCounted(loanId));
        assertFalse(pool.vaultSettlementCounted(loanId));

        uint256 idleAfterFirst = pool.idleLedger();

        // Now settle vault
        vault.settleExpiredLoan(loanId);
        pool.reconcileLoan(loanId); // must credit vault

        assertEq(pool.idleLedger(), idleAfterFirst + locked,
            "vault settlement must be credited independently of collateral recovery");
        assertTrue(pool.vaultSettlementCounted(loanId));
        assertEq(pool.totalDeployed(), 0);
    }

    // ================================================================
    // TEST 06: Vault settlement + underwriter recovery (combined sources)
    //          Order: settleExpiredLoan first, then reconcileLoan
    // ================================================================
    function test_06_UnderwriterPlusVaultSettlement_EarlySettle() public {
        uint256 principal = 30_000e6;
        uint256 stake     = 30_000e6;

        vm.prank(underwriter);
        underwriterPool.depositStake(stake);
        vm.prank(underwriter);
        underwriterPool.commitToAgent(borrower, stake);

        _seedPool(principal * 2);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256 half = principal / 2;
        uint256[] memory ms = new uint256[](2); ms[0] = half; ms[1] = principal - half;
        string[] memory desc = new string[](2); desc[0] = "M1"; desc[1] = "M2";

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: principal,
            repaymentRateBps: 10000, totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days, purpose: "underwriter+vault",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: 0, underwriter: underwriter, underwriterAmount: stake
        }));

        registry.approveLoan(loanId);
        vault.fundFromPool(loanId);
        vault.releaseMilestone(loanId, 0);
        uint256 locked = vault.lockedAmount(loanId);

        _defaultLoan(loanId);

        // settleExpiredLoan first, then reconcileLoan (early-settle order)
        vault.settleExpiredLoan(loanId);
        assertEq(vault.settledDefaultAmount(loanId), locked);

        uint256 idleBefore = pool.idleLedger();
        pool.reconcileLoan(loanId); // must pick up both underwriter stake + vault

        // underwriter amount == principal → full principal covered + vault recovery is profit
        assertGe(pool.idleLedger(), idleBefore + locked,
            "vault recovery must be credited together with underwriter on first reconcile");
        assertTrue(pool.vaultSettlementCounted(loanId));
        assertTrue(pool.defaultRecoveryCounted(loanId));
        assertEq(pool.totalDeployed(), 0);
    }

    // ================================================================
    // TEST 07: Vault settlement + ReservePool payout
    //          Order: reconcileLoan → settleExpiredLoan → reconcileLoan
    // ================================================================
    function test_07_ReservePoolPlusVaultSettlement_LateSettle() public {
        uint256 principal = 100e6;

        // Seed reserve with enough to cover full shortfall
        usdc.mint(address(reservePool), (principal * 115) / 100);

        (uint256 loanId, uint256 locked) = _setupLoan(principal);
        _defaultLoan(loanId);

        // reconcileLoan first: reserve payout credited
        pool.reconcileLoan(loanId);
        uint256 idleAfterFirst = pool.idleLedger();
        assertFalse(pool.vaultSettlementCounted(loanId));

        // Late vault settlement
        vault.settleExpiredLoan(loanId);
        pool.reconcileLoan(loanId);

        assertEq(pool.idleLedger(), idleAfterFirst + locked,
            "vault recovery must be added after reserve payout on second reconcile");
        assertTrue(pool.vaultSettlementCounted(loanId));
        assertEq(pool.totalDeployed(), 0);

        // Third reconcile: no-op
        pool.reconcileLoan(loanId);
        assertEq(pool.idleLedger(), idleAfterFirst + locked, "third reconcile is a no-op");
    }

    // ================================================================
    // TEST 08: Zero settledDefaultAmount does not affect accounting
    //          (all milestones released before default → no vault funds)
    // ================================================================
    function test_08_ZeroSettledDefaultAmount_NoEffect() public {
        _seedPool(200e6);

        // Single-milestone loan: full principal released before default
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: 50e6});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256[] memory ms = new uint256[](1); ms[0] = 50e6;
        string[] memory desc = new string[](1); desc[0] = "Full";

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: 50e6,
            repaymentRateBps: 10000, totalRepaymentDue: 57.5e6,
            duration: 30 days, purpose: "zero-vault",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: 0, underwriter: address(0), underwriterAmount: 0
        }));

        vault.fundFromPool(loanId);
        vault.releaseMilestone(loanId, 0);   // lockedAmount → 0
        assertEq(vault.lockedAmount(loanId), 0);

        _defaultLoan(loanId);

        pool.reconcileLoan(loanId);
        uint256 idleAfter1 = pool.idleLedger();
        assertFalse(pool.vaultSettlementCounted(loanId),
            "vaultSettlementCounted must not be set when settledDefaultAmount == 0");

        // Second reconcile: still no vault effect
        pool.reconcileLoan(loanId);
        assertEq(pool.idleLedger(), idleAfter1, "no change when settledDefaultAmount is zero");
    }

    // ================================================================
    // TEST 09: Direct lender loan is completely unaffected
    // ================================================================
    function test_09_DirectLenderLoanUnaffected() public {
        // Fund with direct lender — principalAdvanced[loanId] is never set in pool
        address directLender = address(0x1E4DE4);
        usdc.mint(directLender, 10_000_000e6);
        vm.prank(directLender);
        usdc.approve(address(vault), type(uint256).max);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: 100e6});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256[] memory ms = new uint256[](1); ms[0] = 100e6;
        string[] memory desc = new string[](1); desc[0] = "Full";

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: 100e6,
            repaymentRateBps: 10000, totalRepaymentDue: 115e6,
            duration: 30 days, purpose: "direct lender",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: 0, underwriter: address(0), underwriterAmount: 0
        }));

        vm.prank(directLender);
        vault.fundLoan(loanId);

        uint256 idleBefore      = pool.idleLedger();
        uint256 deployedBefore  = pool.totalDeployed();

        _defaultLoan(loanId);
        vault.settleExpiredLoan(loanId); // returns funds to directLender

        // Pool accounting completely untouched
        pool.reconcileLoan(loanId); // returns immediately (principalAdvanced == 0)
        assertEq(pool.idleLedger(),    idleBefore,     "pool idleLedger must be unchanged");
        assertEq(pool.totalDeployed(), deployedBefore, "pool totalDeployed must be unchanged");
        assertFalse(pool.vaultSettlementCounted(loanId), "vaultSettlementCounted must not be set");
    }

    // ================================================================
    // TEST 10: Full combined recovery — router + reserve + vault
    //          (multiple sources, late vault settlement)
    // ================================================================
    function test_10_FullCombinedRecovery_LateVaultSettle() public {
        uint256 principal = 100e6;

        // Fund reserve with 30e6 (partial coverage)
        usdc.mint(address(reservePool), 30e6);

        (uint256 loanId, uint256 locked) = _setupLoan(principal);

        // Revenue payment before default
        vm.prank(client);
        router.payRevenue(loanId, 20e6); // totalRecovered[loanId] = 20 * repaymentBps/10000

        _defaultLoan(loanId); // shortfall = totalDue - routerTotal; reserve pays min(shortfall, 30)

        // First reconcile: router + reserve counted
        pool.reconcileLoan(loanId);
        uint256 idleAfterFirst = pool.idleLedger();
        assertFalse(pool.vaultSettlementCounted(loanId));

        // Late vault settlement
        vault.settleExpiredLoan(loanId);
        pool.reconcileLoan(loanId);

        assertEq(pool.idleLedger(), idleAfterFirst + locked,
            "vault funds must be credited on second reconcile even with multi-source first reconcile");
        assertTrue(pool.vaultSettlementCounted(loanId));
        assertEq(pool.totalDeployed(), 0);
    }

    // ================================================================
    // TEST 11: RISK-01 backward-compatibility — early-settle path
    //          works exactly as before (settleExpiredLoan before reconcileLoan)
    // ================================================================
    function test_11_BackwardCompatibility_EarlySettleOrder() public {
        (uint256 loanId, uint256 locked) = _setupLoan(100e6);
        _defaultLoan(loanId);

        vault.settleExpiredLoan(loanId);

        uint256 poolBalBefore = usdc.balanceOf(address(pool));
        uint256 idleBefore    = pool.idleLedger();

        pool.reconcileLoan(loanId);

        // Both vault settlement and one-time default recovery counted in one call
        assertTrue(pool.defaultRecoveryCounted(loanId));
        assertTrue(pool.vaultSettlementCounted(loanId));
        assertGe(pool.idleLedger(), idleBefore + locked,
            "early-settle order must still credit vault recovery exactly once");
        // Ensure raw balance matches accounting
        assertEq(
            usdc.balanceOf(address(pool)),
            poolBalBefore,   // no USDC moved during reconcileLoan itself
            "reconcileLoan must not move USDC"
        );
    }

    // ================================================================
    // TEST 12: vaultSettlementCounted prevents double-count even if
    //          settleExpiredLoan were somehow callable twice (guard test)
    // ================================================================
    function test_12_DoubleCountPrevented() public {
        (uint256 loanId, uint256 locked) = _setupLoan(100e6);
        _defaultLoan(loanId);

        vault.settleExpiredLoan(loanId);

        // First reconcile: vault credited
        pool.reconcileLoan(loanId);
        uint256 idleAfterFirst = pool.idleLedger();
        assertTrue(pool.vaultSettlementCounted(loanId));

        // Simulate a second reconcile — vaultSettlementCounted guards it
        pool.reconcileLoan(loanId);
        assertEq(pool.idleLedger(), idleAfterFirst,
            "vault settlement must not be double-counted");

        // And a third for good measure
        pool.reconcileLoan(loanId);
        assertEq(pool.idleLedger(), idleAfterFirst);
        assertEq(pool.totalDeployed(), 0);

        // settledDefaultAmount value is still readable (not cleared)
        assertEq(vault.settledDefaultAmount(loanId), locked);
    }
}
