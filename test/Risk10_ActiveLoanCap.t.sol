// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------
// RISK-10 regression tests -- active-loan cap (maxActiveLoans)
//
// Verifies that LiquidityPool.fundLoan() enforces the
// maxActiveLoans cap so that _reconcileAll() cannot grow to a
// size that exceeds block gas limits.
//
// Uses ERC1967Proxy deployment (same pattern as Risk09) to avoid
// the MemoryOOG that afflicts the full UUPS FFI harness.
// -----------------------------------------------------------------

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy}       from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoanRegistry}       from "../src/LoanRegistry.sol";
import {LoanVault}          from "../src/LoanVault.sol";
import {CreditRegistry}     from "../src/CreditRegistry.sol";
import {RevenueRouter}      from "../src/RevenueRouter.sol";
import {CollateralVault}    from "../src/CollateralVault.sol";
import {UnderwriterPool}    from "../src/UnderwriterPool.sol";
import {RecipientRegistry}  from "../src/RecipientRegistry.sol";
import {ReservePool}        from "../src/ReservePool.sol";
import {LiquidityPool}      from "../src/LiquidityPool.sol";
import {ILoanRegistry}      from "../src/interfaces/ILoanRegistry.sol";
import {ERC20}              from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC_R10 is ERC20 {
    constructor() ERC20("Mock USDC R10", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract Risk10_ActiveLoanCapTest is Test {

    LoanRegistry      registry;
    LoanVault         vault;
    CreditRegistry    creditReg;
    RevenueRouter     router;
    CollateralVault   colVault;
    UnderwriterPool   uwPool;
    RecipientRegistry recipReg;
    ReservePool       reserve;
    LiquidityPool     pool;
    MockUSDC_R10      usdc;

    address owner        = address(this);
    address creditWallet = address(0xCAFE);
    address directLender = address(0x1E4DE4);
    address notOwner     = address(0xBAD);

    uint256 constant GRACE       = 3 days;
    uint256 constant CAT         = 25_000e6;
    uint16  constant MAX_LTV     = 6600;

    // Loan parameters -- small enough to stay well inside credit limits,
    // large enough to be realistic.
    uint256 constant PRINCIPAL   = 100e6;
    uint256 constant TOTAL_DUE   = 115e6;
    uint16  constant RATE_BPS    = 1500;
    // approvalThreshold = 25_000e6 so 100e6 loans auto-approve (status=Requested)
    // and do not need an explicit approveLoan() call.

    // ---------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        usdc = new MockUSDC_R10();

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

        colVault = CollateralVault(_proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize,
                (owner, address(usdc), address(registry), MAX_LTV))
        ));

        uwPool = UnderwriterPool(_proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize,
                (owner, address(usdc), address(registry)))
        ));

        recipReg = RecipientRegistry(_proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        ));

        reserve = ReservePool(_proxy(
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
                address(colVault),
                address(uwPool),
                address(reserve),
                address(vault)
            ))
        ));

        // Wire contracts
        registry.setContracts(address(vault), address(router));
        registry.setCollateralVault(address(colVault));
        registry.setUnderwriterPool(address(uwPool));
        registry.setRecipientRegistry(address(recipReg));
        registry.setReservePool(address(reserve));
        vault.setLiquidityPool(address(pool));
        creditReg.setAuthorizedCaller(address(registry), true);
        creditReg.setAuthorizedCaller(address(router), true);

        // Approved recipient
        recipReg.approveRecipient(creditWallet, keccak256("COMPUTE"), "CW");

        // Seed directLender USDC and approval
        usdc.mint(directLender, 1_000_000e6);
        vm.prank(directLender);
        usdc.approve(address(vault), type(uint256).max);

        // Seed owner USDC and initialize pool with ample liquidity
        usdc.mint(owner, 10_000_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.initializeLiquidity(5_000_000e6);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @dev Build a LoanProposal. borrower = msg.sender in requestLoan;
    ///      lender is set by markFunded during fund*.
    function _proposal(address /*unused*/) internal view returns (ILoanRegistry.LoanProposal memory) {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: PRINCIPAL});

        address[] memory recipients = new address[](1);
        recipients[0] = creditWallet;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PRINCIPAL;
        string[] memory descs = new string[](1);
        descs[0] = "M0";

        return ILoanRegistry.LoanProposal({
            creditWallet:          creditWallet,
            principal:             PRINCIPAL,
            repaymentRateBps:      RATE_BPS,
            totalRepaymentDue:     TOTAL_DUE,
            duration:              30 days,
            purpose:               "test",
            budget:                budget,
            permittedRecipients:   recipients,
            milestoneAmounts:      amounts,
            milestoneDescriptions: descs,
            collateralAmount:      0,
            underwriter:           address(0),
            underwriterAmount:     0
        });
    }

    /// @dev Borrow address for sequential test loans.
    ///      Returns a unique address for index i (0-based).
    function _borrower(uint256 i) internal pure returns (address) {
        return address(uint160(0xB0B0 + i));
    }

    /// @dev Seed credit history for a borrower so they have borrowing capacity.
    function _seedCredit(address b) internal {
        vm.prank(address(router));
        creditReg.recordRepayment(b, 5_000e6, false);
    }

    /// @dev Request and fund a pool loan for borrower at index i. Returns loanId.
    function _poolLoan(uint256 i) internal returns (uint256 loanId) {
        address b = _borrower(i);
        _seedCredit(b);
        vm.prank(b);
        loanId = registry.requestLoan(_proposal(b));
        vault.fundFromPool(loanId);
    }

    /// @dev Request and fund a direct-lender loan for borrower at index i. Returns loanId.
    function _directLoan(uint256 i) internal returns (uint256 loanId) {
        address b = _borrower(i);
        _seedCredit(b);
        vm.prank(b);
        loanId = registry.requestLoan(_proposal(b));
        vm.prank(directLender);
        vault.fundLoan(loanId);
    }

    // ---------------------------------------------------------------
    // Test 01: default maxActiveLoans is 150 after initialization
    // ---------------------------------------------------------------

    function test_01_DefaultCapIs150() public view {
        assertEq(pool.maxActiveLoans(), 150, "default cap should be 150");
    }

    // ---------------------------------------------------------------
    // Test 02: pool funding succeeds below the cap
    // ---------------------------------------------------------------

    function test_02_FundingSucceedsBelowCap() public {
        // Lower cap so we can test without creating 150 loans
        pool.setMaxActiveLoans(3);

        uint256 id0 = _poolLoan(0);
        uint256 id1 = _poolLoan(1);
        uint256 id2 = _poolLoan(2);

        assertEq(pool.activeLoanCount(), 3, "should have 3 active loans");
        assertEq(pool.principalAdvanced(id0), PRINCIPAL);
        assertEq(pool.principalAdvanced(id1), PRINCIPAL);
        assertEq(pool.principalAdvanced(id2), PRINCIPAL);
    }

    // ---------------------------------------------------------------
    // Test 03: funding reverts when activeLoanIds.length == maxActiveLoans
    // ---------------------------------------------------------------

    function test_03_FundingRevertsAtCap() public {
        pool.setMaxActiveLoans(2);

        _poolLoan(0);
        _poolLoan(1);
        assertEq(pool.activeLoanCount(), 2);

        // Third pool loan -- fundFromPool must revert
        address b2 = _borrower(2);
        _seedCredit(b2);
        vm.prank(b2);
        uint256 pendingId = registry.requestLoan(_proposal(b2));

        vm.expectRevert(LiquidityPool.TooManyActiveLoans.selector);
        vault.fundFromPool(pendingId);

        // Active count unchanged
        assertEq(pool.activeLoanCount(), 2, "count must not increase past cap");
    }

    // ---------------------------------------------------------------
    // Test 04: owner can change the cap and event is emitted
    // ---------------------------------------------------------------

    function test_04_OwnerCanChangeCap() public {
        uint256 oldMax = pool.maxActiveLoans(); // 150
        uint256 newMax = 300;

        vm.expectEmit(false, false, false, true);
        emit LiquidityPool.MaxActiveLoansChanged(oldMax, newMax);

        pool.setMaxActiveLoans(newMax);
        assertEq(pool.maxActiveLoans(), newMax);
    }

    // ---------------------------------------------------------------
    // Test 05: non-owner cannot change the cap
    // ---------------------------------------------------------------

    function test_05_NonOwnerCannotChangeCap() public {
        vm.prank(notOwner);
        vm.expectRevert();
        pool.setMaxActiveLoans(200);
        // cap unchanged
        assertEq(pool.maxActiveLoans(), 150);
    }

    // ---------------------------------------------------------------
    // Test 06: setting maxActiveLoans to zero reverts
    // ---------------------------------------------------------------

    function test_06_ZeroCapReverts() public {
        vm.expectRevert(LiquidityPool.InvalidMaxActiveLoans.selector);
        pool.setMaxActiveLoans(0);
        assertEq(pool.maxActiveLoans(), 150, "cap should remain unchanged");
    }

    // ---------------------------------------------------------------
    // Test 07: increasing the cap allows additional pool funding
    // ---------------------------------------------------------------

    function test_07_IncreasingCapUnblocksFunding() public {
        pool.setMaxActiveLoans(2);

        _poolLoan(0);
        _poolLoan(1);

        // Third loan prepared but blocked
        address b2 = _borrower(2);
        _seedCredit(b2);
        vm.prank(b2);
        uint256 pendingId = registry.requestLoan(_proposal(b2));

        vm.expectRevert(LiquidityPool.TooManyActiveLoans.selector);
        vault.fundFromPool(pendingId);

        // Raise cap
        pool.setMaxActiveLoans(3);

        // Now succeeds
        vault.fundFromPool(pendingId);
        assertEq(pool.activeLoanCount(), 3);
    }

    // ---------------------------------------------------------------
    // Test 08: direct lender funding is unaffected by the cap
    // ---------------------------------------------------------------

    function test_08_DirectLenderUnaffectedByCap() public {
        // Fill the cap with pool loans
        pool.setMaxActiveLoans(2);
        _poolLoan(0);
        _poolLoan(1);
        assertEq(pool.activeLoanCount(), 2);

        // Direct-lender loan must succeed regardless of pool cap
        uint256 directId = _directLoan(2);

        // Direct loan is NOT tracked in the pool
        assertEq(pool.principalAdvanced(directId), 0, "direct loan must not be tracked in pool");
        // Active count still 2 (direct loans never enter activeLoanIds)
        assertEq(pool.activeLoanCount(), 2, "cap must not affect direct-lender loans");
    }

    // ---------------------------------------------------------------
    // Test 09: accounting unchanged after cap enforcement
    // ---------------------------------------------------------------

    function test_09_AccountingUnchangedAfterCap() public {
        uint256 idleBefore     = pool.idleLedger();
        uint256 deployedBefore = pool.totalDeployed();

        uint256 id0 = _poolLoan(0);

        assertEq(pool.idleLedger(),           idleBefore     - PRINCIPAL, "idleLedger");
        assertEq(pool.totalDeployed(),        deployedBefore + PRINCIPAL, "totalDeployed");
        assertEq(pool.principalAdvanced(id0), PRINCIPAL,                  "principalAdvanced");
        assertEq(pool.activeLoanCount(),      1,                          "activeLoanCount");
        // NAV invariant: idleLedger + totalDeployed = idleBefore (pool got PRINCIPAL from owner init, vault took it)
        assertEq(pool.idleLedger() + pool.totalDeployed(), idleBefore, "NAV invariant");
    }

    // ---------------------------------------------------------------
    // Test 10: poolRecovered invariant: poolRecovered == totalRecovered - reserveRepaid
    // ---------------------------------------------------------------

    function test_10_PoolRecoveredInvariant() public {
        uint256 id0 = _poolLoan(0);

        // Before any payments both are zero
        assertEq(router.totalRecovered(id0),  0, "totalRecovered");
        assertEq(router.reserveRepaid(id0),   0, "reserveRepaid");
        assertEq(router.poolRecovered(id0),   0, "poolRecovered");

        // Invariant holds
        assertEq(
            router.poolRecovered(id0),
            router.totalRecovered(id0) - router.reserveRepaid(id0),
            "poolRecovered == totalRecovered - reserveRepaid"
        );
    }
}
