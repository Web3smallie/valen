// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------
// RISK-05 regression tests — fundFromPool() access control
//
// The defect: LoanVault.fundFromPool() was permissionless, allowing
// any EOA to deploy shared LiquidityPool capital into an arbitrary
// Requested loan without the protocol operator's consent.
//
// The fix: fundFromPool() is restricted to onlyOwner (the Valen
// backend / DEPLOYER). fundLoan() intentionally remains permissionless
// as the direct P2P / A2A lending path.
//
// Uses ERC1967Proxy deployment to avoid MemoryOOG from 9-proxy setUp.
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
import {ERC20}             from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC_R05 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract Risk05_FundFromPoolAuthTest is Test {

    LoanRegistry      registry;
    LoanVault         vault;
    CreditRegistry    creditReg;
    RevenueRouter     router;
    CollateralVault   collateralVault;
    UnderwriterPool   underwriterPool;
    RecipientRegistry recipientRegistry;
    ReservePool       reservePool;
    LiquidityPool     pool;
    MockUSDC_R05      usdc;

    address owner        = address(this);   // proxy owner == test contract
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address stranger     = address(0x57121);
    address directLender = address(0x1E4DE4);

    uint256 constant GRACE   = 3 days;
    uint256 constant CAT     = 10_000e6;
    uint16  constant MAX_LTV = 6600;

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        usdc = new MockUSDC_R05();

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

        // Wire everything
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

        // Seed borrower credit and external addresses
        vm.prank(address(router));
        creditReg.recordRepayment(borrower, 5_000e6, false);

        usdc.mint(directLender, 10_000_000e6);
        vm.prank(directLender);
        usdc.approve(address(vault), type(uint256).max);

        usdc.mint(stranger, 10_000_000e6);
        vm.prank(stranger);
        usdc.approve(address(vault), type(uint256).max);
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

    /// Creates a minimal Requested (self-approved) loan and returns its id.
    function _requestLoan(uint256 principal) internal returns (uint256 loanId) {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "Full";

        vm.prank(borrower);
        loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "RISK-05 test",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: 0,
            underwriter: address(0),
            underwriterAmount: 0
        }));
        // Status should be Requested (within credit limit)
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan must be Requested"
        );
    }

    /// Creates a PendingApproval loan (principal > CAT with collateral).
    function _requestPendingApprovalLoan() internal returns (uint256 loanId) {
        uint256 principal = CAT + 1e6; // over threshold → PendingApproval
        uint256 required  = collateralVault.requiredCollateral(principal);

        usdc.mint(borrower, required);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), type(uint256).max);
        vm.prank(borrower);
        collateralVault.depositCollateral(required);

        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "Full";

        vm.prank(borrower);
        loanId = registry.requestLoan(ILoanRegistry.LoanProposal({
            creditWallet: creditWallet,
            principal: principal,
            repaymentRateBps: 10000,
            totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days,
            purpose: "pending approval",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: ms,
            milestoneDescriptions: desc,
            collateralAmount: required,
            underwriter: address(0),
            underwriterAmount: 0
        }));
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.PendingApproval),
            "loan must be PendingApproval"
        );
    }

    // ================================================================
    // TEST 01: Non-owner cannot call fundFromPool
    // ================================================================
    function test_01_StrangerCannotCallFundFromPool() public {
        _seedPool(1_000e6);
        uint256 loanId = _requestLoan(100e6);

        vm.prank(stranger);
        // OwnableUpgradeable reverts with OwnableUnauthorizedAccount(caller)
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger)
        );
        vault.fundFromPool(loanId);

        // Loan must remain Requested — no state change
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Requested),
            "loan status must remain Requested after failed fundFromPool"
        );
        // Pool accounting must be untouched
        assertEq(vault.lockedAmount(loanId), 0, "lockedAmount must remain 0");
    }

    // ================================================================
    // TEST 02: Owner can call fundFromPool successfully
    // ================================================================
    function test_02_OwnerCanCallFundFromPool() public {
        _seedPool(1_000e6);
        uint256 loanId  = _requestLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;

        uint256 idleBefore     = pool.idleLedger();
        uint256 deployedBefore = pool.totalDeployed();

        // Called from owner (address(this) == owner in this test)
        vault.fundFromPool(loanId);

        // Loan must be Active
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after owner fundFromPool"
        );
        // Pool accounting updated
        assertEq(pool.idleLedger(),    idleBefore - principal,     "idleLedger must decrease");
        assertEq(pool.totalDeployed(), deployedBefore + principal, "totalDeployed must increase");
        // Vault locked
        assertEq(vault.lockedAmount(loanId), principal, "lockedAmount must equal principal");
        // Lender set to pool
        assertEq(registry.getLoan(loanId).lender, address(pool), "lender must be the pool");
    }

    // ================================================================
    // TEST 03: fundLoan remains permissionless (non-owner with USDC can fund)
    // ================================================================
    function test_03_FundLoanRemainsPermissionless() public {
        uint256 loanId    = _requestLoan(100e6);
        uint256 principal = registry.getLoan(loanId).principal;

        // directLender is NOT the owner
        assertFalse(directLender == vault.owner(), "directLender must not be owner");

        vm.prank(directLender);
        vault.fundLoan(loanId);  // must succeed without reverting

        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.Active),
            "loan must be Active after direct-lender fundLoan"
        );
        assertEq(vault.lockedAmount(loanId), principal, "lockedAmount must equal principal");
        assertEq(registry.getLoan(loanId).lender, directLender, "lender must be directLender");
    }

    // ================================================================
    // TEST 04: fundFromPool rejects a PendingApproval loan (status gate preserved)
    // ================================================================
    function test_04_FundFromPoolRevertsForPendingApprovalLoan() public {
        _seedPool(1_000_000e6);
        uint256 loanId = _requestPendingApprovalLoan();

        // Owner calls, but loan is PendingApproval → LoanNotFundable
        vm.expectRevert(LoanVault.LoanNotFundable.selector);
        vault.fundFromPool(loanId);

        // Status must remain PendingApproval
        assertEq(
            uint8(registry.getLoan(loanId).status),
            uint8(ILoanRegistry.LoanStatus.PendingApproval),
            "loan must remain PendingApproval"
        );
    }

    // ================================================================
    // TEST 05: Borrower (non-owner) cannot call fundFromPool
    // ================================================================
    function test_05_BorrowerCannotCallFundFromPool() public {
        _seedPool(1_000e6);
        uint256 loanId = _requestLoan(100e6);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", borrower)
        );
        vault.fundFromPool(loanId);
    }

    // ================================================================
    // TEST 06: Pool accounting is only affected by owner-initiated fundFromPool
    // ================================================================
    function test_06_PoolAccountingIntegrity() public {
        _seedPool(1_000e6);
        uint256 loanId = _requestLoan(100e6);

        uint256 idleBefore     = pool.idleLedger();
        uint256 deployedBefore = pool.totalDeployed();

        // Stranger attempts to call fundFromPool — reverts
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger)
        );
        vault.fundFromPool(loanId);

        // Pool accounting unchanged after failed call
        assertEq(pool.idleLedger(),    idleBefore,     "idleLedger must be unchanged after revert");
        assertEq(pool.totalDeployed(), deployedBefore, "totalDeployed must be unchanged after revert");
        assertEq(vault.lockedAmount(loanId), 0,        "lockedAmount must be 0 after revert");

        // Owner call succeeds and updates accounting correctly
        vault.fundFromPool(loanId);
        assertEq(pool.idleLedger(),    idleBefore - 100e6,     "idleLedger after owner fundFromPool");
        assertEq(pool.totalDeployed(), deployedBefore + 100e6, "totalDeployed after owner fundFromPool");
    }

    // ================================================================
    // TEST 07: fundLoan by a non-owner does not affect pool accounting
    // ================================================================
    function test_07_FundLoanDoesNotAffectPool() public {
        _seedPool(1_000e6);
        uint256 loanId = _requestLoan(100e6);

        uint256 idleBefore     = pool.idleLedger();
        uint256 deployedBefore = pool.totalDeployed();

        // directLender funds directly — pool must be untouched
        vm.prank(directLender);
        vault.fundLoan(loanId);

        assertEq(pool.idleLedger(),    idleBefore,     "pool idleLedger must not change on fundLoan");
        assertEq(pool.totalDeployed(), deployedBefore, "pool totalDeployed must not change on fundLoan");
        assertEq(pool.principalAdvanced(loanId), 0,    "principalAdvanced must be 0 for direct loan");
    }
}
