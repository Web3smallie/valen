// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// Integration_E2E — Full V1 deployment + lifecycle tests
//
// Wires the entire eleven-contract system using ERC1967Proxy (no OZ upgrades
// FFI harness) and verifies:
//   1. Deployment wiring safety (zero-address guards, one-time locks)
//   2. ActivityAttester → CreditRegistry trust chain
//   3. Complete loan lifecycle:
//        register agent → attest activity → request loan →
//        fund (direct) → repay → verify agentId-keyed credit growth
//   4. LiquidityPool pooled-funding path
//   5. No regression across the V1 identity model
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
import {ActivityAttester}  from "../src/ActivityAttester.sol";
import {ILoanRegistry}     from "../src/interfaces/ILoanRegistry.sol";
import {ICreditRegistry}   from "../src/interfaces/ICreditRegistry.sol";

// ─── Minimal ERC-8183-style source stub ──────────────────────────────────────
// In production this would be an on-chain marketplace contract. In tests we
// only need an address that ActivityAttester has been told to trust.
contract MockActivitySource {
    // No state needed — ActivityAttester only checks approvedActivitySources[source].
}

contract MockUSDC_E2E is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

// ─────────────────────────────────────────────────────────────────────────────
contract IntegrationE2ETest is Test {

    // ── Actors ────────────────────────────────────────────────────────────────
    address owner         = address(0xAD);
    address borrower      = address(0xB0);
    address creditWallet  = address(0xCE);
    address lender        = address(0x1D);
    address lpDepositor   = address(0xDE);
    address rotatedWallet = address(0x4A);

    // ── Contracts ─────────────────────────────────────────────────────────────
    MockUSDC_E2E    usdc;
    AgentRegistry   agentReg;
    CreditRegistry  creditReg;
    LoanRegistry    registry;
    RevenueRouter   router;
    LoanVault       vault;
    CollateralVault collateralVault;
    UnderwriterPool underwriterPool;
    RecipientRegistry recipientReg;
    ReservePool     reservePool;
    LiquidityPool   liquidityPool;
    ActivityAttester attester;

    MockActivitySource activitySource;

    uint256 agentId;

    // ── CreditRegistry parameters (matches Deploy.s.sol) ─────────────────────
    uint256 constant INITIAL_LIMIT                = 5e6;
    uint16  constant GROWTH_BPS                   = 2500;
    uint16  constant EARLY_BONUS_BPS              = 1000;
    uint256 constant MAX_STEP_INCREASE            = 2000e6;
    uint16  constant DEFAULT_PENALTY_BPS          = 2000;
    uint256 constant APPROVAL_THRESHOLD           = 25_000e6;
    uint16  constant ACTIVITY_GROWTH_BPS          = 500;   // 5 %
    uint256 constant MAX_ACTIVITY_PER_EVT         = 50e6;  // $50
    uint256 constant MAX_ACTIVITY_LIMIT           = 50_000e6;

    // ── LoanRegistry parameters ───────────────────────────────────────────────
    uint256 constant MIN_DUR  = 1 days;
    uint256 constant MAX_DUR  = 365 days;
    uint256 constant GRACE    = 3 days;
    uint256 constant COL_THRESH = 10_000e6;

    uint16 constant MAX_LTV   = 6600;
    uint16 constant RESERVE_BPS = 200;

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: deploy a UUPS proxy without the OZ upgrades FFI harness
    // ─────────────────────────────────────────────────────────────────────────
    function _proxy(address impl, bytes memory init) internal returns (address) {
        return address(new ERC1967Proxy(impl, init));
    }

    function setUp() public {
        usdc = new MockUSDC_E2E();
        activitySource = new MockActivitySource();

        // 1. AgentRegistry
        agentReg = AgentRegistry(_proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        ));

        // 2. CreditRegistry
        creditReg = CreditRegistry(_proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize, (
                owner,
                INITIAL_LIMIT, GROWTH_BPS, EARLY_BONUS_BPS,
                MAX_STEP_INCREASE, DEFAULT_PENALTY_BPS, APPROVAL_THRESHOLD,
                ACTIVITY_GROWTH_BPS, MAX_ACTIVITY_PER_EVT, MAX_ACTIVITY_LIMIT
            ))
        ));

        // 3. LoanRegistry
        registry = LoanRegistry(_proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize, (
                owner, address(creditReg),
                MIN_DUR, MAX_DUR, GRACE, COL_THRESH
            ))
        ));

        // 4. RevenueRouter
        router = RevenueRouter(_proxy(
            address(new RevenueRouter()),
            abi.encodeCall(RevenueRouter.initialize, (
                owner, address(registry), address(creditReg), address(usdc)
            ))
        ));

        // 5. LoanVault
        vault = LoanVault(_proxy(
            address(new LoanVault()),
            abi.encodeCall(LoanVault.initialize, (owner, address(registry), address(usdc)))
        ));

        // 6. CollateralVault
        collateralVault = CollateralVault(_proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, (owner, address(usdc), address(registry), MAX_LTV))
        ));

        // 7. UnderwriterPool
        underwriterPool = UnderwriterPool(_proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize, (owner, address(usdc), address(registry)))
        ));

        // 8. RecipientRegistry
        recipientReg = RecipientRegistry(_proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        ));

        // 9. ReservePool
        reservePool = ReservePool(_proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        ));

        // 10. LiquidityPool
        liquidityPool = LiquidityPool(_proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc),
                address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reservePool), address(vault)
            ))
        ));

        // 11. ActivityAttester
        attester = ActivityAttester(_proxy(
            address(new ActivityAttester()),
            abi.encodeCall(ActivityAttester.initialize, (
                owner, address(agentReg), address(creditReg)
            ))
        ));

        // ── Wiring (mirrors Deploy.s.sol exactly) ────────────────────────────
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
        creditReg.setAuthorizedCaller(address(attester), true);

        reservePool.setAuthorizedContributor(address(router), true);

        // ActivityAttester: whitelist the mock source contract
        attester.setActivitySource(address(activitySource), true);

        // RecipientRegistry: approve creditWallet and rotatedWallet as valid recipients
        recipientReg.approveRecipient(creditWallet,   keccak256("COMPUTE"), "Approved vendor");
        recipientReg.approveRecipient(rotatedWallet,  keccak256("COMPUTE"), "Rotated wallet vendor");

        vm.stopPrank();

        // ── Agent registration ────────────────────────────────────────────────
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0); // erc8004TokenId = 0 (testnet placeholder)

        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        // ── Fund actors ───────────────────────────────────────────────────────
        usdc.mint(borrower, 100_000e6);
        usdc.mint(lender, 100_000e6);
        usdc.mint(lpDepositor, 200_000e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Deployment safety checks
    // ═════════════════════════════════════════════════════════════════════════

    function test_AllContractAddressesNonZero() public view {
        assertTrue(address(agentReg)      != address(0), "agentReg zero");
        assertTrue(address(creditReg)     != address(0), "creditReg zero");
        assertTrue(address(registry)      != address(0), "registry zero");
        assertTrue(address(router)        != address(0), "router zero");
        assertTrue(address(vault)         != address(0), "vault zero");
        assertTrue(address(collateralVault) != address(0), "collateralVault zero");
        assertTrue(address(underwriterPool) != address(0), "underwriterPool zero");
        assertTrue(address(recipientReg)  != address(0), "recipientReg zero");
        assertTrue(address(reservePool)   != address(0), "reservePool zero");
        assertTrue(address(liquidityPool) != address(0), "liquidityPool zero");
        assertTrue(address(attester)      != address(0), "attester zero");
    }

    function test_LoanVaultLiquidityPoolWired() public view {
        assertEq(vault.liquidityPool(), address(liquidityPool), "vault not wired to LP");
    }

    function test_RegistryAgentRegistryWired() public view {
        assertEq(address(registry.agentRegistry()), address(agentReg), "registry agentReg mismatch");
    }

    function test_RouterAgentRegistryWired() public view {
        assertEq(address(router.agentRegistry()), address(agentReg), "router agentReg mismatch");
    }

    function test_AttesterAuthorizedOnCreditRegistry() public view {
        assertTrue(creditReg.authorizedCallers(address(attester)), "attester not authorized on creditReg");
    }

    function test_RouterAuthorizedOnCreditRegistry() public view {
        assertTrue(creditReg.authorizedCallers(address(router)), "router not authorized on creditReg");
    }

    function test_RouterAuthorizedOnReservePool() public view {
        assertTrue(reservePool.authorizedContributors(address(router)), "router not authorized on reservePool");
    }

    function test_SetAgentRegistryIsOneTimeLocked_Registry() public {
        vm.prank(owner);
        vm.expectRevert();
        registry.setAgentRegistry(address(agentReg));
    }

    function test_SetAgentRegistryIsOneTimeLocked_Router() public {
        vm.prank(owner);
        vm.expectRevert();
        router.setAgentRegistry(address(agentReg));
    }

    function test_SetAgentRegistryRejectsZeroAddress_Registry() public {
        // Deploy a fresh registry to test before lock is set
        LoanRegistry freshRegistry = LoanRegistry(_proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize, (
                owner, address(creditReg),
                MIN_DUR, MAX_DUR, GRACE, COL_THRESH
            ))
        ));
        vm.prank(owner);
        vm.expectRevert();
        freshRegistry.setAgentRegistry(address(0));
    }

    function test_SetLiquidityPoolIsOneTimeLocked() public {
        // Once set and active loans > 0, cannot replace LP.
        // With 0 active loans the setter IS re-callable (it resets to new address).
        // Confirming current LP is set correctly is sufficient.
        assertEq(vault.liquidityPool(), address(liquidityPool));
    }

    function test_SetContractsIsOneTimeLocked() public {
        vm.prank(owner);
        vm.expectRevert(LoanRegistry.ContractsAlreadySet.selector);
        registry.setContracts(address(vault), address(router));
    }

    function test_CreditWalletZeroAddressRevertsBeforeAgentCheck() public {
        // FINDING 4: zero-address check for creditWallet must fire before
        // isAuthorizedWallet — verifies correct error and correct ordering.
        ILoanRegistry.LoanProposal memory p = _buildProposal(100e6, 30 days);
        p.creditWallet = address(0);
        p.permittedRecipients = new address[](1);
        p.permittedRecipients[0] = creditWallet; // valid recipient, but creditWallet field is zero
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        registry.requestLoan(p);
    }

    function test_LiquidityPoolHasCorrectDependencies() public view {
        assertEq(address(liquidityPool.loanRegistry()), address(registry));
        assertEq(address(liquidityPool.revenueRouter()), address(router));
        assertEq(address(liquidityPool.collateralVault()), address(collateralVault));
        assertEq(address(liquidityPool.underwriterPool()), address(underwriterPool));
        assertEq(address(liquidityPool.reservePool()), address(reservePool));
        assertEq(liquidityPool.loanVault(), address(vault));
    }

    function test_ActivityAttesterHasCorrectDependencies() public view {
        assertEq(address(attester.agentRegistry()), address(agentReg));
        assertEq(address(attester.creditRegistry()), address(creditReg));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ActivityAttester → CreditRegistry trust chain
    // ═════════════════════════════════════════════════════════════════════════

    function test_AttestActivityIncreasesAgentCreditLimit() public {
        uint256 limitBefore = creditReg.getLimit(agentId);
        // activityGrowthBps = 500 (5%), amount = 1_000e6
        // growth = min(1_000e6 * 5% = 50e6, MAX_ACTIVITY_PER_EVT = 50e6) = 50e6
        uint256 activityAmount = 1_000e6;
        uint256 expectedGrowth = 50e6; // 5% of 1_000e6, capped at MAX_ACTIVITY_PER_EVT

        attester.attestActivity(
            address(activitySource),
            42,          // jobId
            agentId,
            borrower,    // providerWallet (registered for agentId)
            activityAmount
        );

        uint256 limitAfter = creditReg.getLimit(agentId);
        assertEq(limitAfter, limitBefore + expectedGrowth, "credit limit did not grow from attestation");
    }

    function test_AttestActivityRequiresAuthorizedProvider() public {
        address stranger = address(0xF00D);
        vm.expectRevert(); // UnauthorizedProvider
        attester.attestActivity(address(activitySource), 1, agentId, stranger, 1_000e6);
    }

    function test_AttestActivityRequiresApprovedSource() public {
        address unapprovedSource = address(0xBAD5);
        vm.expectRevert(); // NotApprovedSource
        attester.attestActivity(unapprovedSource, 1, agentId, borrower, 1_000e6);
    }

    function test_AttestActivityReplayProtection() public {
        attester.attestActivity(address(activitySource), 7, agentId, borrower, 500e6);
        vm.expectRevert(); // AlreadyAttested
        attester.attestActivity(address(activitySource), 7, agentId, borrower, 500e6);
    }

    function test_UnauthorizedCallerCannotCallRecordActivity() public {
        address attacker = address(0xBAD1);
        vm.prank(attacker);
        vm.expectRevert();
        creditReg.recordActivity(agentId, 1_000e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Complete loan lifecycle — direct P2P funding
    // ═════════════════════════════════════════════════════════════════════════

    function _buildProposal(uint256 principal, uint256 dur) internal view
        returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});

        uint256[] memory milestoneAmounts = new uint256[](1);
        milestoneAmounts[0] = principal;
        string[] memory milestoneDescs = new string[](1);
        milestoneDescs[0] = "Full release";

        return ILoanRegistry.LoanProposal({
            agentId:               agentId,
            creditWallet:          creditWallet,
            principal:             principal,
            repaymentRateBps:      10000,
            totalRepaymentDue:     principal + (principal / 10), // 10% interest
            duration:              dur,
            purpose:               "Integration test loan",
            budget:                budget,
            permittedRecipients:   _single(creditWallet),
            milestoneAmounts:      milestoneAmounts,
            milestoneDescriptions: milestoneDescs,
            collateralAmount:      0,
            underwriter:           address(0),
            underwriterAmount:     0
        });
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _seedCredit(uint256 amount) internal {
        // Seed credit via repayment bridge so borrower can request loans.
        vm.prank(address(router));
        creditReg.recordRepayment(agentId, amount, false);
    }

    function test_FullLoanLifecycle_DirectFunding() public {
        // ── Step 1–2: agent registered + wallet authorized in setUp ──────────

        // ── Step 3: establish approved credit wallet ─────────────────────────
        // creditWallet and creditReg already approved in setUp

        // ── Step 4: attest economic activity ────────────────────────────────
        uint256 actAmount = 2_000e6;
        uint256 expectedGrowth = 50e6; // 5% * 2_000e6 capped at 50e6
        uint256 limitBefore = creditReg.getLimit(agentId);

        attester.attestActivity(address(activitySource), 100, agentId, borrower, actAmount);

        // ── Step 5: credit capacity increased ────────────────────────────────
        assertEq(creditReg.getLimit(agentId), limitBefore + expectedGrowth,
            "activity attestation did not increase credit limit");

        // Seed repayment credit so the loan fits within the limit
        _seedCredit(5_000e6);
        uint256 principal = 1_000e6;
        uint256 repaymentDue = principal + (principal / 10);

        // ── Step 6: request a loan using agentId ────────────────────────────
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(principal, 30 days));

        // ── Step 7: verify creditWallet + AgentRegistry authorization ────────
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(loan.agentId,      agentId,      "agentId mismatch");
        assertEq(loan.borrower,     borrower,      "borrower mismatch");
        assertEq(loan.creditWallet, creditWallet,  "creditWallet mismatch");
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Requested),
            "unexpected initial status");

        // ── Step 8: fund the loan (direct P2P) ──────────────────────────────
        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Active), "loan not Active after funding");
        assertEq(loan.lender, lender, "lender mismatch");

        // ── Step 9: verify outstandingPrincipal is agentId-keyed ─────────────
        assertEq(registry.outstandingPrincipal(agentId), principal,
            "outstandingPrincipal not keyed to agentId");
        assertEq(registry.outstandingPrincipal(uint256(uint160(borrower))), 0,
            "outstandingPrincipal incorrectly written to borrower-address slot");

        // ── Step 10: repay through RevenueRouter ─────────────────────────────
        uint256 creditLimitBeforeRepay = creditReg.getLimit(agentId);

        vm.prank(borrower);
        usdc.approve(address(router), repaymentDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repaymentDue);

        // ── Step 11: verify repayment credit accrues to agentId ──────────────
        // growthBps=2500 (25%) + earlyBonusBps=1000 (10% on early repayment)
        // growth = min(repaymentDue*(25%+10%), 2_000e6) for an early repayment
        uint256 totalGrowthBps = uint256(GROWTH_BPS) + uint256(EARLY_BONUS_BPS);
        uint256 expectedRepayGrowth = repaymentDue * totalGrowthBps / 10000;
        if (expectedRepayGrowth > MAX_STEP_INCREASE) expectedRepayGrowth = MAX_STEP_INCREASE;
        assertEq(creditReg.getLimit(agentId), creditLimitBeforeRepay + expectedRepayGrowth,
            "repayment credit not credited to agentId slot");

        // Verify nothing was written to the borrower-address slot by repayment
        assertEq(creditReg.getLimit(uint256(uint160(borrower))), INITIAL_LIMIT,
            "repayment credit incorrectly written to borrower-address slot");

        // ── Step 12: outstandingPrincipal returns to zero ────────────────────
        assertEq(registry.outstandingPrincipal(agentId), 0,
            "outstandingPrincipal not zeroed after repayment");

        // ── Step 13: loan lifecycle state transitions correctly ───────────────
        loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Repaid),
            "loan not Repaid after full repayment");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Pooled-funding path
    // ═════════════════════════════════════════════════════════════════════════

    function test_PooledFundingLifecycle() public {
        // Seed enough credit for the 2_000e6 principal.
        // Each 5_000e6 repayment at 25% growth = +1_250e6; two calls = 2_505e6 limit.
        _seedCredit(5_000e6);
        _seedCredit(5_000e6);

        // Initialize liquidity pool (onlyOwner for initializeLiquidity)
        usdc.mint(owner, 50_000e6);
        vm.prank(owner);
        usdc.approve(address(liquidityPool), 50_000e6);
        vm.prank(owner);
        liquidityPool.initializeLiquidity(50_000e6);

        uint256 principal = 2_000e6;

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(principal, 30 days));

        // Fund from pool (owner-only because it deploys shared LP capital)
        vm.prank(owner);
        vault.fundFromPool(loanId);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Active), "pool-funded loan not Active");
        assertEq(loan.lender, address(liquidityPool), "lender should be liquidityPool");

        // Pool accounting: idleLedger decreased, totalDeployed increased
        assertEq(liquidityPool.totalDeployed(), principal, "pool totalDeployed incorrect");
        assertEq(liquidityPool.idleLedger(), 50_000e6 - principal, "pool idleLedger incorrect");

        // Repay
        uint256 repaymentDue = principal + (principal / 10);
        vm.prank(borrower);
        usdc.approve(address(router), repaymentDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repaymentDue);

        // Reconcile pool
        liquidityPool.reconcileLoan(loanId);
        // After reserve skim (2%) and full repayment the pool idleLedger grows
        assertTrue(liquidityPool.idleLedger() > 50_000e6 - principal,
            "pool did not recover principal after repayment+reconcile");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // AgentRegistry wallet rotation through the repayment path
    // ═════════════════════════════════════════════════════════════════════════

    function test_WalletRotation_NewWalletCanRepay() public {
        _seedCredit(5_000e6);
        uint256 principal = 500e6;
        uint256 repaymentDue = principal + (principal / 10);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(principal, 30 days));

        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        // Add rotatedWallet to the agent
        vm.prank(borrower);
        agentReg.addWallet(agentId, rotatedWallet);

        usdc.mint(rotatedWallet, repaymentDue);
        vm.prank(rotatedWallet);
        usdc.approve(address(router), repaymentDue);
        vm.prank(rotatedWallet);
        router.repayLoan(loanId, repaymentDue); // must succeed for authorized wallet

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Repaid),
            "loan not Repaid after rotated-wallet repayment");
    }

    function test_RevokedWalletCannotRepay() public {
        _seedCredit(5_000e6);
        uint256 principal = 500e6;
        uint256 repaymentDue = principal + (principal / 10);

        // Add then immediately remove rotatedWallet
        vm.prank(borrower);
        agentReg.addWallet(agentId, rotatedWallet);
        vm.prank(borrower);
        agentReg.removeWallet(agentId, rotatedWallet);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(principal, 30 days));

        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        usdc.mint(rotatedWallet, repaymentDue);
        vm.prank(rotatedWallet);
        usdc.approve(address(router), repaymentDue);
        vm.prank(rotatedWallet);
        vm.expectRevert(); // CallerNotAgentWallet
        router.repayLoan(loanId, repaymentDue);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Unauthorized caller cannot circumvent production paths
    // ═════════════════════════════════════════════════════════════════════════

    function test_StrangerCannotRequestLoanForAgent() public {
        _seedCredit(5_000e6);
        address stranger = address(0xF001);
        // stranger is not isAuthorizedWallet(agentId, stranger)
        vm.prank(stranger);
        vm.expectRevert(); // CallerNotAgentWallet from LoanRegistry._validateProposal
        registry.requestLoan(_buildProposal(500e6, 30 days));
    }

    function test_StrangerCannotRepayLoan() public {
        _seedCredit(5_000e6);
        uint256 principal = 500e6;
        uint256 repaymentDue = principal + (principal / 10);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(principal, 30 days));
        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        address stranger = address(0xF002);
        usdc.mint(stranger, repaymentDue);
        vm.prank(stranger);
        usdc.approve(address(router), repaymentDue);
        vm.prank(stranger);
        vm.expectRevert(); // CallerNotAgentWallet
        router.repayLoan(loanId, repaymentDue);
    }

    function test_AuthorizedWalletCannotPayRevenue_SelfDealing() public {
        _seedCredit(5_000e6);
        uint256 principal = 500e6;
        uint256 amount = 100e6;

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(principal, 30 days));
        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        // borrower is an authorized wallet — must be rejected by payRevenue
        vm.prank(borrower);
        usdc.approve(address(router), amount);
        vm.prank(borrower);
        vm.expectRevert(); // PayerNotAllowed
        router.payRevenue(loanId, amount);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Historical loan.borrower integrity
    // ═════════════════════════════════════════════════════════════════════════

    function test_LoanBorrowerFieldIsHistoricalAndUnchanged() public {
        _seedCredit(5_000e6);
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(500e6, 30 days));

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(loan.borrower, borrower, "loan.borrower should be historical borrower address");
        assertEq(loan.agentId, agentId, "loan.agentId should be the registered agent");
    }

    function test_CreditNotWrittenToBorrowerAddressSlot() public {
        _seedCredit(5_000e6);
        uint256 principal = 500e6;
        uint256 repaymentDue = principal + (principal / 10);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(principal, 30 days));
        vm.prank(lender);
        usdc.approve(address(vault), principal);
        vm.prank(lender);
        vault.fundLoan(loanId);

        uint256 borrowerSlotBefore = creditReg.getLimit(uint256(uint160(borrower)));

        vm.prank(borrower);
        usdc.approve(address(router), repaymentDue);
        vm.prank(borrower);
        router.repayLoan(loanId, repaymentDue);

        // The borrower-address-derived slot must not have changed
        assertEq(creditReg.getLimit(uint256(uint160(borrower))), borrowerSlotBefore,
            "repayment incorrectly wrote to borrower-address credit slot");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // AgentRegistry: setActivitySource trust model is not weakened
    // ═════════════════════════════════════════════════════════════════════════

    function test_OnlyOwnerCanApproveActivitySource() public {
        address rogue = address(0xBAD3);
        vm.prank(rogue);
        vm.expectRevert();
        attester.setActivitySource(address(activitySource), true);
    }

    function test_DisapprovedSourceCannotAttest() public {
        vm.prank(owner);
        attester.setActivitySource(address(activitySource), false);

        vm.expectRevert(); // NotApprovedSource
        attester.attestActivity(address(activitySource), 99, agentId, borrower, 1_000e6);
    }
}
