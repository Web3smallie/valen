// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------
// RISK-04 regression tests — keeper authorization on markDefault()
//
// Uses ERC1967Proxy deployment (no OZ upgrades FFI harness) to
// avoid MemoryOOG from 9-proxy setUp() calls. The fix being tested
// is access-control logic in LoanRegistry.
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

contract MockUSDC_R04 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract Risk04_KeeperAuthorizationTest is Test {

    LoanRegistry      registry;
    LoanVault         vault;
    CreditRegistry    creditReg;
    RevenueRouter     router;
    CollateralVault   collateralVault;
    UnderwriterPool   underwriterPool;
    RecipientRegistry recipientRegistry;
    ReservePool       reservePool;
    LiquidityPool     pool;
    MockUSDC_R04      usdc;

    address owner        = address(this);
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address directLender = address(0x1E4DE4);
    address keeper       = address(0xBEEBEE);
    address stranger     = address(0xBAD);

    uint256 constant GRACE = 3 days;
    uint256 constant CAT   = 10_000e6;
    uint16  constant MAX_LTV = 6600;

    function _proxy(address impl, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(impl, initData));
    }

    function setUp() public {
        usdc = new MockUSDC_R04();

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

        // Wire
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

        // Give borrower enough credit
        vm.prank(address(router));
        creditReg.recordRepayment(borrower, 5_000e6, false);

        usdc.mint(directLender, 10_000_000e6);
        vm.prank(directLender);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        usdc.approve(address(collateralVault), type(uint256).max);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _proposal(uint256 principal) internal view returns (ILoanRegistry.LoanProposal memory) {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xD00D);
        uint256[] memory ms = new uint256[](1); ms[0] = principal;
        string[] memory desc = new string[](1); desc[0] = "M1";
        return ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: principal,
            repaymentRateBps: 1500, totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days, purpose: "RISK-04 test",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: 0, underwriter: address(0), underwriterAmount: 0
        });
    }

    /// Create an Active loan funded by directLender; return loanId.
    function _activeLoan(uint256 principal) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = registry.requestLoan(_proposal(principal));
        vm.prank(directLender);
        vault.fundLoan(loanId);
    }

    /// Warp past expiry + grace so the loan is eligible for default.
    function _warpEligible(uint256 loanId) internal {
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE + 1);
    }

    // =================================================================
    // TEST 1: Arbitrary unauthorized address cannot call markDefault
    // =================================================================
    function test_01_StrangerCannotMarkDefault() public {
        uint256 loanId = _activeLoan(50e6);
        _warpEligible(loanId);

        vm.prank(stranger);
        vm.expectRevert(LoanRegistry.NotAuthorized.selector);
        registry.markDefault(loanId);
    }

    // =================================================================
    // TEST 2: Owner can call markDefault
    // =================================================================
    function test_02_OwnerCanMarkDefault() public {
        uint256 loanId = _activeLoan(50e6);
        _warpEligible(loanId);

        // owner == address(this), no prank needed
        registry.markDefault(loanId);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Defaulted));
    }

    // =================================================================
    // TEST 3: Authorized keeper can call markDefault
    // =================================================================
    function test_03_AuthorizedKeeperCanMarkDefault() public {
        registry.setKeeper(keeper, true);
        assertTrue(registry.keepers(keeper));

        uint256 loanId = _activeLoan(50e6);
        _warpEligible(loanId);

        vm.prank(keeper);
        registry.markDefault(loanId);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Defaulted));
    }

    // =================================================================
    // TEST 4: Revoked keeper can no longer call markDefault
    // =================================================================
    function test_04_RevokedKeeperCannotMarkDefault() public {
        registry.setKeeper(keeper, true);
        registry.setKeeper(keeper, false);
        assertFalse(registry.keepers(keeper));

        uint256 loanId = _activeLoan(50e6);
        _warpEligible(loanId);

        vm.prank(keeper);
        vm.expectRevert(LoanRegistry.NotAuthorized.selector);
        registry.markDefault(loanId);
    }

    // =================================================================
    // TEST 5: Unauthorized address cannot call setKeeper
    // =================================================================
    function test_05_StrangerCannotSetKeeper() public {
        vm.prank(stranger);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        registry.setKeeper(keeper, true);

        assertFalse(registry.keepers(keeper), "stranger must not have set the keeper");
    }

    // =================================================================
    // TEST 6: Owner can add and remove a keeper
    // =================================================================
    function test_06_OwnerCanAddAndRemoveKeeper() public {
        assertFalse(registry.keepers(keeper));

        vm.expectEmit(true, false, false, true);
        emit LoanRegistry.KeeperSet(keeper, true);
        registry.setKeeper(keeper, true);
        assertTrue(registry.keepers(keeper));

        vm.expectEmit(true, false, false, true);
        emit LoanRegistry.KeeperSet(keeper, false);
        registry.setKeeper(keeper, false);
        assertFalse(registry.keepers(keeper));
    }

    // =================================================================
    // TEST 7: Zero address keeper is rejected
    // =================================================================
    function test_07_ZeroAddressKeeperRejected() public {
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        registry.setKeeper(address(0), true);
    }

    // =================================================================
    // TEST 8: Existing grace-period check still enforced (owner call)
    // =================================================================
    function test_08_GracePeriodCheckPreserved() public {
        uint256 loanId = _activeLoan(50e6);
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);

        // Warp to exactly expiresAt + GRACE (boundary — not yet elapsed)
        vm.warp(loan.expiresAt + GRACE);
        vm.expectRevert(LoanRegistry.DefaultGraceNotElapsed.selector);
        registry.markDefault(loanId);
    }

    // =================================================================
    // TEST 9: Existing grace-period check still enforced (keeper call)
    // =================================================================
    function test_09_GracePeriodCheckPreservedForKeeper() public {
        registry.setKeeper(keeper, true);
        uint256 loanId = _activeLoan(50e6);
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);

        vm.warp(loan.expiresAt + GRACE);
        vm.prank(keeper);
        vm.expectRevert(LoanRegistry.DefaultGraceNotElapsed.selector);
        registry.markDefault(loanId);
    }

    // =================================================================
    // TEST 10: Already-defaulted loan cannot be defaulted twice
    // =================================================================
    function test_10_CannotDefaultTwice() public {
        uint256 loanId = _activeLoan(50e6);
        _warpEligible(loanId);

        registry.markDefault(loanId); // first — succeeds

        vm.expectRevert(LoanRegistry.LoanNotDefaultable.selector);
        registry.markDefault(loanId); // second — must revert
    }

    // =================================================================
    // TEST 11: Multiple keepers can each independently mark different loans
    // =================================================================
    function test_11_MultipleKeepersWork() public {
        address keeper2 = address(0xBEEBEE2);
        registry.setKeeper(keeper,  true);
        registry.setKeeper(keeper2, true);

        uint256 loanId1 = _activeLoan(50e6);
        uint256 loanId2 = _activeLoan(50e6);
        _warpEligible(loanId1);
        _warpEligible(loanId2);

        vm.prank(keeper);
        registry.markDefault(loanId1);
        vm.prank(keeper2);
        registry.markDefault(loanId2);

        assertEq(uint8(registry.getLoan(loanId1).status), uint8(ILoanRegistry.LoanStatus.Defaulted));
        assertEq(uint8(registry.getLoan(loanId2).status), uint8(ILoanRegistry.LoanStatus.Defaulted));
    }

    // =================================================================
    // TEST 12: Downstream effects (collateral seizure) still execute
    //          correctly when keeper triggers the default
    // =================================================================
    function test_12_CollateralSeizedWhenKeeperDefaults() public {
        registry.setKeeper(keeper, true);

        uint256 principal = 100e6;
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
        string[] memory desc = new string[](1); desc[0] = "M1";
        ILoanRegistry.LoanProposal memory prop = ILoanRegistry.LoanProposal({
            creditWallet: creditWallet, principal: principal,
            repaymentRateBps: 1500, totalRepaymentDue: (principal * 115) / 100,
            duration: 30 days, purpose: "collateral test",
            budget: budget, permittedRecipients: recipients,
            milestoneAmounts: ms, milestoneDescriptions: desc,
            collateralAmount: required, underwriter: address(0), underwriterAmount: 0
        });

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(prop);
        vm.prank(directLender);
        vault.fundLoan(loanId);
        _warpEligible(loanId);

        uint256 lenderBefore = usdc.balanceOf(directLender);
        vm.prank(keeper);
        registry.markDefault(loanId);
        assertEq(usdc.balanceOf(directLender) - lenderBefore, required,
            "collateral must be seized to lender when keeper marks default");
    }
}
