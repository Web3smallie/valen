// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------
// Phantom-loan regression tests — loan existence invariant
//
// The defect: LoanStatus.Requested is the enum zero value, so any
// never-created loanId read as Requested and passed the status-only
// funding checks. fundLoan()/fundFromPool()/markFunded() would then
// "fund" the phantom: writing status=Active plus lender into empty
// storage (P2P path, permissionless) and permanently consuming one
// maxActiveLoans pool slot (pool path, via principalAdvanced==0).
//
// The fix: every state-changing function taking a loanId requires
// loanId < nextLoanId (LoanDoesNotExist); requestLoan rejects
// zero-principal proposals (ZeroPrincipal); _storeLoan resets the
// lender field; reconcileLoan self-heals legacy zero-principal
// tracking slots instead of stranding them.
//
// Uses ERC1967Proxy deployment to avoid MemoryOOG from 11-proxy setUp.
// -----------------------------------------------------------------

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy}      from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoanRegistry}      from "../src/LoanRegistry.sol";
import {LoanVault}         from "../src/LoanVault.sol";
import {CreditRegistry}    from "../src/CreditRegistry.sol";
import {RevenueRouter}     from "../src/RevenueRouter.sol";
import {CollateralVault}   from "../src/CollateralVault.sol";
import {UnderwriterPool}   from "../src/UnderwriterPool.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ReservePool}       from "../src/ReservePool.sol";
import {LiquidityPool}     from "../src/LiquidityPool.sol";
import {ILoanRegistry}     from "../src/interfaces/ILoanRegistry.sol";
import {AgentRegistry}     from "../src/AgentRegistry.sol";
import {ERC20}             from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC_Phantom is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PhantomLoanTest is Test {

    AgentRegistry     agentReg;
    LoanRegistry      registry;
    LoanVault         vault;
    CreditRegistry    creditReg;
    RevenueRouter     router;
    CollateralVault   collateralVault;
    UnderwriterPool   underwriterPool;
    RecipientRegistry recipientRegistry;
    ReservePool       reservePool;
    LiquidityPool     pool;
    MockUSDC_Phantom  usdc;

    address owner        = address(this);   // proxy owner == test contract
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address stranger     = address(0x57121);
    address directLender = address(0x1E4DE4);
    address attacker     = address(0xA77AC4);
    address payer        = address(0x9A7E2);

    uint256 agentId;

    uint256 constant GRACE   = 3 days;
    uint256 constant CAT     = 10_000e6;
    uint16  constant MAX_LTV = 6600;

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        usdc = new MockUSDC_Phantom();

        agentReg = AgentRegistry(_proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        ));
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        creditReg = CreditRegistry(_proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize,
                (owner, 5e6, 2500, 1000, 2_000_000e6, 2000, 25_000e6, 500, 50e6, 50_000e6))
        ));

        registry = LoanRegistry(_proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), 1 days, 365 days, GRACE, CAT))
        ));

        router = RevenueRouter(_proxy(
            address(new RevenueRouter()),
            abi.encodeCall(RevenueRouter.initialize,
                (owner, address(registry), address(creditReg), address(usdc))))
        );

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

        // Wire everything
        registry.setContracts(address(vault), address(router));
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        registry.setRecipientRegistry(address(recipientRegistry));
        registry.setReservePool(address(reservePool));
        registry.setAgentRegistry(address(agentReg));
        vault.setLiquidityPool(address(pool));
        creditReg.setAuthorizedCaller(address(router), true);
        creditReg.setAuthorizedCaller(address(registry), true);
        reservePool.setAuthorizedContributor(address(router), true);
        router.setReservePool(address(reservePool), 0);
        router.setAgentRegistry(address(agentReg));
        recipientRegistry.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Provider");
        recipientRegistry.approveRecipient(creditWallet, keccak256("COMPUTE"), "CreditWallet");

        // Seed borrower credit
        vm.prank(address(router));
        creditReg.recordRepayment(agentId, 5_000e6, false);

        usdc.mint(directLender, 10_000_000e6);
        vm.prank(directLender);
        usdc.approve(address(vault), type(uint256).max);

        usdc.mint(stranger, 10_000_000e6);
        vm.prank(stranger);
        usdc.approve(address(vault), type(uint256).max);

        usdc.mint(creditWallet, 10_000_000e6);
        vm.prank(creditWallet);
        usdc.approve(address(router), type(uint256).max);

        usdc.mint(payer, 10_000_000e6);
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    /// Seeds the pool with `amount` USDC from owner.
    function _seedPool(uint256 amount) internal {
        usdc.mint(owner, amount);
        usdc.approve(address(pool), amount);
        pool.initializeLiquidity(amount);
    }

    /// Builds a minimal unsecured proposal for `principal`.
    function _buildProposal(uint256 principal)
        internal
        view
        returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet;
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "Full";

        return ILoanRegistry.LoanProposal({
            agentId: agentId,
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "Phantom test",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: 0,
            collateralAsset: address(0),
            underwriter: address(0),
            underwriterAmount: 0,
            directDisbursement: false
        });
    }

    /// Creates a minimal Requested loan and returns its id.
    function _requestLoan(uint256 principal) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = registry.requestLoan(_buildProposal(principal));
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan must be Requested"
        );
    }

    /// Phantom id battery: the nextLoanId boundary, above it, and the max id.
    function _phantomIds() internal view returns (uint256[] memory ids) {
        uint256 next = registry.nextLoanId();
        ids = new uint256[](3);
        ids[0] = next;
        ids[1] = next + 1;
        ids[2] = type(uint256).max;
    }

    // ----------------------------------------------------------------
    // fundLoan / fundFromPool / markFunded reject nonexistent ids
    // ----------------------------------------------------------------

    function test_FundLoan_RevertsOnNonexistentIds() public {
        // Empty registry: id 0 is already a phantom.
        vm.prank(stranger);
        vm.expectRevert(LoanVault.LoanDoesNotExist.selector);
        vault.fundLoan(0);

        // With a real loan present, every id at/above the boundary reverts.
        _requestLoan(1_000e6);
        uint256[] memory ids = _phantomIds();
        for (uint256 i = 0; i < ids.length; i++) {
            vm.prank(stranger);
            vm.expectRevert(LoanVault.LoanDoesNotExist.selector);
            vault.fundLoan(ids[i]);
        }

        // No phantom Active loan was created anywhere.
        assertEq(registry.nextLoanId(), 1, "no loans may be created by funding");
    }

    function test_FundFromPool_RevertsOnNonexistentIds() public {
        _seedPool(5_000_000e6);
        _requestLoan(1_000e6);

        uint256 idleBefore = pool.idleLedger();
        uint256 deployedBefore = pool.totalDeployed();

        uint256[] memory ids = _phantomIds();
        for (uint256 i = 0; i < ids.length; i++) {
            vm.expectRevert(LoanVault.LoanDoesNotExist.selector);
            vault.fundFromPool(ids[i]);
        }

        assertEq(pool.activeLoanCount(), 0, "phantoms must not consume pool slots");
        assertEq(pool.idleLedger(), idleBefore, "idleLedger must be untouched");
        assertEq(pool.totalDeployed(), deployedBefore, "totalDeployed must be untouched");
    }

    function test_MarkFunded_RevertsOnNonexistentIds() public {
        _requestLoan(1_000e6);

        uint256[] memory ids = _phantomIds();
        for (uint256 i = 0; i < ids.length; i++) {
            vm.prank(address(vault));
            vm.expectRevert(LoanRegistry.LoanDoesNotExist.selector);
            registry.markFunded(ids[i], stranger);

            // The phantom slot is still pristine empty storage.
            ILoanRegistry.LoanView memory loanView = registry.getLoan(ids[i]);
            assertEq(uint8(loanView.status), uint8(ILoanRegistry.LoanStatus.Requested));
            assertEq(loanView.lender, address(0));
            assertEq(loanView.principal, 0);
        }
    }

    // ----------------------------------------------------------------
    // Capacity and repeated-attempt invariance
    // ----------------------------------------------------------------

    function test_PhantomCannotConsumeMaxActiveLoans() public {
        _seedPool(5_000_000e6);
        _requestLoan(1_000e6);

        // Repeated phantom pool-funding attempts: all revert, no slots taken.
        uint256 phantom = registry.nextLoanId();
        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(LoanVault.LoanDoesNotExist.selector);
            vault.fundFromPool(phantom + i);
        }
        assertEq(pool.activeLoanCount(), 0);

        // A real loan still takes exactly one slot.
        vault.fundFromPool(0);
        assertEq(pool.activeLoanCount(), 1);
        assertEq(
            uint8(registry.getLoan(0).status),
            uint8(ILoanRegistry.LoanStatus.Active)
        );
    }

    function test_RepeatedPhantomAttempts_AlterNoState() public {
        _seedPool(5_000_000e6);
        _requestLoan(1_000e6);
        uint256 phantom = registry.nextLoanId();

        for (uint256 round = 0; round < 3; round++) {
            uint256 nextBefore = registry.nextLoanId();
            uint256 slotsBefore = pool.activeLoanCount();
            uint256 idleBefore = pool.idleLedger();
            uint256 deployedBefore = pool.totalDeployed();
            uint256 vaultBalBefore = usdc.balanceOf(address(vault));
            uint256 poolBalBefore = usdc.balanceOf(address(pool));
            uint256 routerBalBefore = usdc.balanceOf(address(router));

            vm.prank(stranger);
            vm.expectRevert(LoanVault.LoanDoesNotExist.selector);
            vault.fundLoan(phantom);

            vm.expectRevert(LoanVault.LoanDoesNotExist.selector);
            vault.fundFromPool(phantom);

            vm.expectRevert(LoanRegistry.LoanDoesNotExist.selector);
            registry.approveLoan(phantom);

            vm.expectRevert(LoanRegistry.LoanDoesNotExist.selector);
            registry.markDefault(phantom);

            vm.prank(address(vault));
            vm.expectRevert(LoanRegistry.LoanDoesNotExist.selector);
            registry.markFunded(phantom, stranger);

            vm.prank(address(router));
            vm.expectRevert(LoanRegistry.LoanDoesNotExist.selector);
            registry.markRepaid(phantom);

            vm.prank(address(vault));
            vm.expectRevert(LoanRegistry.LoanDoesNotExist.selector);
            registry.markMilestoneReleased(phantom, 0);

            vm.prank(stranger);
            vm.expectRevert(LoanVault.LoanDoesNotExist.selector);
            vault.releaseMilestone(phantom, 0);

            vm.prank(stranger);
            vm.expectRevert(LoanVault.LoanDoesNotExist.selector);
            vault.settleExpiredLoan(phantom);

            vm.prank(payer);
            vm.expectRevert(RevenueRouter.LoanDoesNotExist.selector);
            router.payRevenue(phantom, 1e6);

            vm.prank(creditWallet);
            vm.expectRevert(RevenueRouter.LoanDoesNotExist.selector);
            router.repayLoan(phantom, 1e6);

            // reconcileLoan stays a safe no-op on unknown ids (it runs
            // inside _reconcileAll on every deposit/withdraw, so it must
            // never revert for them).
            pool.reconcileLoan(phantom);

            assertEq(registry.nextLoanId(), nextBefore, "nextLoanId changed");
            assertEq(pool.activeLoanCount(), slotsBefore, "pool slots changed");
            assertEq(pool.idleLedger(), idleBefore, "idleLedger changed");
            assertEq(pool.totalDeployed(), deployedBefore, "totalDeployed changed");
            assertEq(usdc.balanceOf(address(vault)), vaultBalBefore, "vault balance changed");
            assertEq(usdc.balanceOf(address(pool)), poolBalBefore, "pool balance changed");
            assertEq(usdc.balanceOf(address(router)), routerBalBefore, "router balance changed");
        }
    }

    // ----------------------------------------------------------------
    // Zero-principal safeguard
    // ----------------------------------------------------------------

    function test_ZeroPrincipal_RequestReverts() public {
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.ZeroPrincipal.selector);
        registry.requestLoan(_buildProposal(0));

        assertEq(registry.nextLoanId(), 0, "no loan may be created");
    }

    function test_ZeroPrincipal_PoolFundingReverts() public {
        _seedPool(5_000_000e6);
        uint256 loanId = _requestLoan(1_000e6);

        // The pool refuses zero-amount advances even when called correctly.
        vm.prank(address(vault));
        vm.expectRevert(LiquidityPool.ZeroAmount.selector);
        pool.fundLoan(loanId, 0);

        assertEq(pool.activeLoanCount(), 0);
        assertEq(pool.principalAdvanced(loanId), 0);
    }

    // ----------------------------------------------------------------
    // Lender reset on id reuse
    // ----------------------------------------------------------------

    function test_LenderResetOnIdReuse() public {
        // Simulate legacy state: a pre-fix phantom funding wrote lender
        // into loan slot 0 before the real loan 0 was ever requested.
        // Layout: _loans is mapping slot 9, lender is struct offset +2.
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(9)));
        vm.store(
            address(registry),
            bytes32(uint256(base) + 2),
            bytes32(uint256(uint160(attacker)))
        );
        // Self-validating simulation: the squat must be visible first.
        assertEq(registry.getLoan(0).lender, attacker, "simulation must land");

        uint256 loanId = _requestLoan(1_000e6);
        assertEq(loanId, 0);
        assertEq(
            registry.getLoan(0).lender,
            address(0),
            "fresh loan must not inherit a squatted lender"
        );
    }

    // ----------------------------------------------------------------
    // Reconcile self-healing for legacy phantom slots
    // ----------------------------------------------------------------

    function test_ReconcileSelfHealsLegacyPhantomSlot() public {
        _seedPool(5_000_000e6);
        uint256 idleBefore = pool.idleLedger();
        uint256 deployedBefore = pool.totalDeployed();

        // Simulate legacy state: a pre-fix phantom fundFromPool tracked
        // id 999 with zero principal. Layout: activeLoanIds is slot 16,
        // _activeLoanIndexPlusOne is slot 17.
        uint256 phantom = 999;
        vm.store(address(pool), bytes32(uint256(16)), bytes32(uint256(1)));
        vm.store(address(pool), keccak256(abi.encode(uint256(16))), bytes32(phantom));
        vm.store(
            address(pool),
            keccak256(abi.encode(phantom, uint256(17))),
            bytes32(uint256(1))
        );
        // Self-validating simulation: the stuck slot must be visible first.
        assertEq(pool.activeLoanCount(), 1, "simulation must land");
        assertEq(pool.activeLoanIds(0), phantom);
        assertEq(pool.principalAdvanced(phantom), 0);

        // One reconcile releases the slot without touching accounting.
        pool.reconcileLoan(phantom);
        assertEq(pool.activeLoanCount(), 0, "stuck slot must be released");
        assertEq(pool.idleLedger(), idleBefore, "idleLedger must be untouched");
        assertEq(pool.totalDeployed(), deployedBefore, "totalDeployed must be untouched");

        // Deposits (which run _reconcileAll over tracked ids) still work.
        usdc.mint(stranger, 100e6);
        vm.prank(stranger);
        usdc.approve(address(pool), 100e6);
        vm.prank(stranger);
        pool.deposit(100e6);
    }

    // ----------------------------------------------------------------
    // Valid loans still fund normally (both paths, full lifecycle)
    // ----------------------------------------------------------------

    function test_ValidLoan_P2PLifecycle() public {
        uint256 principal = 1_000e6;
        uint256 due = (principal * 115) / 100;
        uint256 loanId = _requestLoan(principal);

        vm.prank(directLender);
        vault.fundLoan(loanId);
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active)
        );
        assertEq(registry.getLoan(loanId).lender, directLender);

        uint256 cwBefore = usdc.balanceOf(creditWallet);
        vm.prank(directLender);
        vault.releaseMilestone(loanId, 0);
        assertEq(usdc.balanceOf(creditWallet) - cwBefore, principal);

        vm.prank(creditWallet);
        router.repayLoan(loanId, due);
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Repaid)
        );
    }

    function test_ValidLoan_PoolLifecycle() public {
        _seedPool(5_000_000e6);
        uint256 principal = 1_000e6;
        uint256 due = (principal * 115) / 100;
        uint256 loanId = _requestLoan(principal);

        vault.fundFromPool(loanId);
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active)
        );
        assertEq(registry.getLoan(loanId).lender, address(pool));
        assertEq(pool.activeLoanCount(), 1);

        vm.prank(creditWallet);
        router.repayLoan(loanId, due);

        pool.reconcileLoan(loanId);
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Repaid)
        );
        assertTrue(pool.finalized(loanId), "loan must finalize");
        assertEq(pool.activeLoanCount(), 0, "slot must be released");
        assertEq(pool.totalDeployed(), 0, "deployment must be unwound");
        assertEq(pool.idleLedger(), 5_000_000e6 + (due - principal), "pool must recover principal plus profit");
    }
}
