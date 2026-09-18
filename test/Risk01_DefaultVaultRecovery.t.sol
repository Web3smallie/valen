// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------
// RISK-01 regression tests — "settleExpiredLoan after default"
//
// Uses ERC1967Proxy deployment (no OZ upgrades FFI harness) to
// avoid the MemoryOOG that affects 9-proxy setUp() calls in the
// full UUPS harness. The fix being tested is contract *logic*.
// -----------------------------------------------------------------

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoanRegistry}       from "../src/LoanRegistry.sol";
import {LoanVault}           from "../src/LoanVault.sol";
import {CreditRegistry}      from "../src/CreditRegistry.sol";
import {RevenueRouter}       from "../src/RevenueRouter.sol";
import {CollateralVault}     from "../src/CollateralVault.sol";
import {UnderwriterPool}     from "../src/UnderwriterPool.sol";
import {RecipientRegistry}   from "../src/RecipientRegistry.sol";
import {ReservePool}         from "../src/ReservePool.sol";
import {LiquidityPool}       from "../src/LiquidityPool.sol";
import {ILoanRegistry}       from "../src/interfaces/ILoanRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC_R01 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract Risk01_DefaultVaultRecoveryTest is Test {

    LoanRegistry      registry;
    LoanVault         vault;
    CreditRegistry    creditReg;
    RevenueRouter     router;
    CollateralVault   collateralVault;
    UnderwriterPool   underwriterPool;
    RecipientRegistry recipientRegistry;
    ReservePool       reservePool;
    LiquidityPool     pool;
    MockUSDC_R01      usdc;

    address owner        = address(this);
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address directLender = address(0x1E4DE4);
    address underwriter  = address(0x11DE12);
    address client       = address(0xC1E4);

    uint256 constant GRACE   = 3 days;
    uint256 constant CAT     = 10_000e6;
    uint16  constant MAX_LTV = 6600;

    // -----------------------------------------------------------------
    // Minimal ERC1967Proxy deploy helper — skips FFI upgrade validation
    // -----------------------------------------------------------------
    function _proxy(address impl, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(impl, initData));
    }

    function setUp() public {
        usdc = new MockUSDC_R01();

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
                owner,
                address(usdc),
                address(registry),
                address(router),
                address(collateralVault),
                address(underwriterPool),
                address(reservePool),
                address(vault)
            ))
        ));

        // Wire registry
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

        // Give borrower enough credit for large test loans
        vm.prank(address(router));
        creditReg.recordRepayment(borrower, 5_000e6, false);

        usdc.mint(directLender, 10_000_000e6);
        usdc.mint(client,       10_000_000e6);
        usdc.mint(borrower,     10_000_000e6);
        usdc.mint(underwriter,  10_000_000e6);

        vm.prank(directLender);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), type(uint256).max);
        vm.prank(underwriter);
        usdc.approve(address(underwriterPool), type(uint256).max);
    }

    // -----------------------------------------------------------------
    // Proposal factory: 2 equal milestones, direct lender
    // -----------------------------------------------------------------
    function _proposal2ms(uint256 principal)
        internal view returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256 half = principal / 2;
        uint256[] memory ms = new uint256[](2);
        ms[0] = half; ms[1] = principal - half;
        string[] memory desc = new string[](2);
        desc[0] = "M1"; desc[1] = "M2";
        return ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: principal,
            repaymentRateBps: 1500, totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days, purpose: "RISK-01 test",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: 0, underwriter: address(0), underwriterAmount: 0
        });
    }

    /// Fund via direct lender, release milestone 0; returns loanId.
    function _fundRelease1_Direct(uint256 principal) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = registry.requestLoan(_proposal2ms(principal));
        vm.prank(directLender);
        vault.fundLoan(loanId);
        vm.prank(directLender);
        vault.releaseMilestone(loanId, 0);
    }

    /// Seed pool and fund via pool, release milestone 0; returns loanId.
    function _fundRelease1_Pool(uint256 principal) internal returns (uint256 loanId) {
        usdc.mint(owner, principal * 2);
        vm.startPrank(owner);
        usdc.approve(address(pool), principal * 2);
        pool.initializeLiquidity(principal * 2);
        vm.stopPrank();

        vm.prank(borrower);
        loanId = registry.requestLoan(_proposal2ms(principal));
        vault.fundFromPool(loanId);
        // pool owner releases on pool's behalf
        vault.releaseMilestone(loanId, 0);
    }

    function _warpDefault(uint256 loanId) internal {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);
        registry.markDefault(loanId);
    }

    // =================================================================
    // TEST 1: Defaulted loan with unreleased vault funds can be recovered
    // =================================================================
    function test_01_DefaultedLoanCanBeSettled() public {
        uint256 loanId = _fundRelease1_Direct(100e6);
        _warpDefault(loanId);

        assertGt(vault.lockedAmount(loanId), 0, "must have unreleased funds");
        vault.settleExpiredLoan(loanId); // must not revert
        assertEq(vault.lockedAmount(loanId), 0, "lockedAmount must be cleared");
    }

    // =================================================================
    // TEST 2: Direct lender receives the remaining funds
    // =================================================================
    function test_02_DirectLenderReceivesRemainingFunds() public {
        uint256 loanId   = _fundRelease1_Direct(100e6);
        uint256 expected = vault.lockedAmount(loanId); // not yet defaulted, but amount is set
        _warpDefault(loanId);

        uint256 balBefore = usdc.balanceOf(directLender);
        vault.settleExpiredLoan(loanId);
        assertEq(usdc.balanceOf(directLender) - balBefore, expected,
            "direct lender must receive unreleased vault balance");
    }

    // =================================================================
    // TEST 3: Pooled loan returns remaining funds to LiquidityPool address
    // =================================================================
    function test_03_PooledFundsReturnToPool() public {
        uint256 loanId = _fundRelease1_Pool(100e6);
        uint256 locked = vault.lockedAmount(loanId);
        _warpDefault(loanId);

        uint256 poolBalBefore = usdc.balanceOf(address(pool));
        vault.settleExpiredLoan(loanId);
        assertEq(usdc.balanceOf(address(pool)) - poolBalBefore, locked,
            "pool USDC balance must increase by locked amount");
    }

    // =================================================================
    // TEST 4: Pooled recovery is reflected exactly once in accounting
    // =================================================================
    function test_04_PoolAccountingCreditedExactlyOnce() public {
        uint256 principal = 100e6;
        uint256 loanId    = _fundRelease1_Pool(principal);
        uint256 locked    = vault.lockedAmount(loanId);

        _warpDefault(loanId);
        vault.settleExpiredLoan(loanId); // funds now in pool as raw transfer

        uint256 idleBefore = pool.idleLedger();

        pool.reconcileLoan(loanId); // must credit vault recovery into idleLedger

        uint256 idleAfter = pool.idleLedger();

        // idleLedger must have grown by at least the vault-locked amount
        assertGe(idleAfter, idleBefore + locked,
            "idleLedger must include vault recovery");
        // totalDeployed must be 0
        assertEq(pool.totalDeployed(), 0, "totalDeployed must be 0 after reconcile");

        // Second reconcile is a no-op
        uint256 idleAfter2 = pool.idleLedger();
        pool.reconcileLoan(loanId);
        assertEq(pool.idleLedger(),    idleAfter2, "double reconcile must not re-credit idle");
        assertEq(pool.totalDeployed(), 0,          "double reconcile must not re-credit deployed");
    }

    // =================================================================
    // TEST 5: Zero remaining balance reverts NothingToSettle
    // =================================================================
    function test_05_ZeroLockedRevertsNothingToSettle() public {
        // Single-milestone loan: full principal released before default
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: 50e6});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256[] memory ms = new uint256[](1); ms[0] = 50e6;
        string[] memory desc = new string[](1); desc[0] = "Full";
        ILoanRegistry.LoanProposal memory prop = ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: 50e6, repaymentRateBps: 1500,
            totalRepaymentDue: 57.5e6, duration: 30 days, purpose: "zero-test",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: 0, underwriter: address(0), underwriterAmount: 0
        });

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(prop);
        vm.prank(directLender);
        vault.fundLoan(loanId);
        vm.prank(directLender);
        vault.releaseMilestone(loanId, 0);      // lockedAmount -> 0
        assertEq(vault.lockedAmount(loanId), 0);

        _warpDefault(loanId);

        vm.expectRevert(LoanVault.NothingToSettle.selector);
        vault.settleExpiredLoan(loanId);
    }

    // =================================================================
    // TEST 6: Cannot settle while loan is Active (not yet expired)
    // =================================================================
    function test_06_CannotSettleActiveNotExpired() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal2ms(50e6));
        vm.prank(directLender);
        vault.fundLoan(loanId);
        // Active, expiry has not elapsed
        vm.expectRevert(LoanVault.LoanNotExpired.selector);
        vault.settleExpiredLoan(loanId);
    }

    // =================================================================
    // TEST 7: Cannot recover twice (double-recovery prevention)
    // =================================================================
    function test_07_CannotRecoverTwice() public {
        uint256 loanId = _fundRelease1_Direct(100e6);
        _warpDefault(loanId);
        vault.settleExpiredLoan(loanId);       // succeeds
        vm.expectRevert(LoanVault.NothingToSettle.selector);
        vault.settleExpiredLoan(loanId);       // reverts
    }

    // =================================================================
    // TEST 8: Existing collateral recovery remains unaffected
    // =================================================================
    function test_08_CollateralRecoveryUnaffected() public {
        uint256 principal = 100e6;
        uint256 required  = collateralVault.requiredCollateral(principal);
        vm.prank(borrower);
        collateralVault.depositCollateral(required);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256 half = principal / 2;
        uint256[] memory ms = new uint256[](2); ms[0] = half; ms[1] = principal - half;
        string[] memory desc = new string[](2); desc[0] = "M1"; desc[1] = "M2";
        ILoanRegistry.LoanProposal memory prop = ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: principal, repaymentRateBps: 1500,
            totalRepaymentDue: (principal * 115) / 100, duration: 30 days,
            purpose: "collateral test",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: required, underwriter: address(0), underwriterAmount: 0
        });

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(prop);
        vm.prank(directLender);
        vault.fundLoan(loanId);
        vm.prank(directLender);
        vault.releaseMilestone(loanId, 0);

        uint256 lenderBefore = usdc.balanceOf(directLender);
        _warpDefault(loanId);
        // Collateral seized to lender on default
        assertEq(usdc.balanceOf(directLender) - lenderBefore, required,
            "collateral must be seized to lender");

        // Vault unreleased half is also recoverable
        uint256 locked = vault.lockedAmount(loanId);
        assertGt(locked, 0);
        uint256 bal2 = usdc.balanceOf(directLender);
        vault.settleExpiredLoan(loanId);
        assertEq(usdc.balanceOf(directLender) - bal2, locked,
            "vault funds returned after collateral seizure");
    }

    // =================================================================
    // TEST 9: Existing underwriter recovery remains unaffected
    // =================================================================
    function test_09_UnderwriterRecoveryUnaffected() public {
        uint256 principal = 30_000e6;
        uint256 stake     = 30_000e6;

        vm.prank(underwriter);
        underwriterPool.depositStake(stake);
        vm.prank(underwriter);
        underwriterPool.commitToAgent(borrower, stake);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256 half = principal / 2;
        uint256[] memory ms = new uint256[](2); ms[0] = half; ms[1] = principal - half;
        string[] memory desc = new string[](2); desc[0] = "M1"; desc[1] = "M2";
        ILoanRegistry.LoanProposal memory prop = ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: principal, repaymentRateBps: 1500,
            totalRepaymentDue: (principal * 115) / 100, duration: 30 days,
            purpose: "underwriter test",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: 0, underwriter: underwriter, underwriterAmount: stake
        });

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(prop);
        registry.approveLoan(loanId);
        vm.prank(directLender);
        vault.fundLoan(loanId);
        vm.prank(directLender);
        vault.releaseMilestone(loanId, 0);

        uint256 lenderBefore = usdc.balanceOf(directLender);
        _warpDefault(loanId);
        assertEq(usdc.balanceOf(directLender) - lenderBefore, stake,
            "underwriter stake must be seized to lender");

        uint256 locked = vault.lockedAmount(loanId);
        assertGt(locked, 0);
        uint256 bal2 = usdc.balanceOf(directLender);
        vault.settleExpiredLoan(loanId);
        assertEq(usdc.balanceOf(directLender) - bal2, locked,
            "vault funds returned after underwriter seizure");
    }

    // =================================================================
    // TEST 10: Existing reserve pool recovery remains unaffected
    // =================================================================
    function test_10_ReservePoolRecoveryUnaffected() public {
        uint256 principal    = 100e6;
        uint256 totalDue     = (principal * 115) / 100;
        usdc.mint(address(reservePool), totalDue + 100e6); // more than enough

        uint256 loanId = _fundRelease1_Direct(principal);

        uint256 lenderBefore = usdc.balanceOf(directLender);
        _warpDefault(loanId);
        // Reserve payout on unsecured default: shortfall = totalDue - 0 = 115e6
        assertEq(usdc.balanceOf(directLender) - lenderBefore, totalDue,
            "reserve must pay shortfall to lender");

        uint256 locked = vault.lockedAmount(loanId);
        assertGt(locked, 0);
        uint256 bal2 = usdc.balanceOf(directLender);
        vault.settleExpiredLoan(loanId);
        assertEq(usdc.balanceOf(directLender) - bal2, locked,
            "vault funds returned after reserve payout");
    }
}
