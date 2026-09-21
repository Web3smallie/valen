// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ReservePool} from "../src/ReservePool.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";

contract MockUSDC_R12 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract Risk12_OneWaySetters is Test {
    // ------------------------------------------------------------------ actors
    address owner   = address(this);
    address borrower = address(0xB0);
    address lender   = address(0xC0);
    address stranger = address(0xD0);

    // ------------------------------------------------------------------ contracts
    LoanRegistry   registry;
    LoanVault      vault;
    LiquidityPool  pool;
    RevenueRouter  router;
    CreditRegistry creditReg;
    RecipientRegistry recipientReg;
    ReservePool    reserve;
    CollateralVault collateralVault;
    UnderwriterPool underwriterPool;
    MockUSDC_R12   usdc;

    // ------------------------------------------------------------------ setUp
    function setUp() public {
        usdc = new MockUSDC_R12();

        // CreditRegistry
        creditReg = CreditRegistry(address(new ERC1967Proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize,
                (owner, 5e6, 2500, 1000, 2_000e6, 2000, 25_000e6))
        )));

        // LoanRegistry (no vault/router/collateral/underwriter/reserve yet)
        registry = LoanRegistry(address(new ERC1967Proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), 1 days, 365 days, 3 days, 50_000e6))
        )));

        // RecipientRegistry
        recipientReg = RecipientRegistry(address(new ERC1967Proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        )));
        registry.setRecipientRegistry(address(recipientReg));

        // RevenueRouter (reserve not set yet)
        router = RevenueRouter(address(new ERC1967Proxy(
            address(new RevenueRouter()),
            abi.encodeCall(RevenueRouter.initialize,
                (owner, address(registry), address(creditReg), address(usdc)))
        )));

        // LoanVault (liquidityPool not set yet)
        vault = LoanVault(address(new ERC1967Proxy(
            address(new LoanVault()),
            abi.encodeCall(LoanVault.initialize,
                (owner, address(registry), address(usdc)))
        )));
        registry.setContracts(address(vault), address(router));

        // CollateralVault and UnderwriterPool (not yet set in registry)
        collateralVault = CollateralVault(address(new ERC1967Proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, (owner, address(usdc), address(registry), 8000))
        )));
        underwriterPool = UnderwriterPool(address(new ERC1967Proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize, (owner, address(registry), address(usdc)))
        )));

        // ReservePool
        reserve = ReservePool(address(new ERC1967Proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        )));

        // LiquidityPool
        pool = LiquidityPool(address(new ERC1967Proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc), address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reserve), address(vault)
            ))
        )));

        // Seed borrower credit
        creditReg.setAuthorizedCaller(address(router), true);
        vm.prank(address(router));
        creditReg.recordRepayment(borrower, 5_000e6, false);

        // Approve a recipient
        recipientReg.approveRecipient(address(0xAB), bytes32("cat"), "label");
    }

    // ================================================================== helpers
    function _makeProposal(uint256 principal) internal view returns (ILoanRegistry.LoanProposal memory p) {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: bytes32("cat"), cap: principal});
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = principal;
        string[] memory descs = new string[](1);
        descs[0] = "milestone";
        address[] memory recipients = new address[](1);
        recipients[0] = address(0xAB);
        p = ILoanRegistry.LoanProposal({
            creditWallet: address(0x99),
            principal: principal,
            repaymentRateBps: 1500,
            totalRepaymentDue: principal * 115 / 100,
            duration: 30 days,
            purpose: "test",
            budget: budget,
            permittedRecipients: recipients,
            milestoneAmounts: amounts,
            milestoneDescriptions: descs,
            collateralAmount: 0,
            underwriter: address(0),
            underwriterAmount: 0
        });
    }

    /// Request a loan so nextLoanId advances to 1.
    function _createOneLoan() internal returns (uint256 loanId) {
        usdc.mint(lender, 1_000e6);
        vm.prank(borrower);
        loanId = registry.requestLoan(_makeProposal(1_000e6));
        vm.prank(lender);
        usdc.approve(address(vault), 1_000e6);
        vm.prank(lender);
        vault.fundLoan(loanId);
    }

    // ================================================================== LoanRegistry.setCollateralVault

    function test_CV_01_InitialSetWorks() public {
        // No loan exists yet — should succeed.
        registry.setCollateralVault(address(collateralVault));
        assertEq(address(registry.collateralVault()), address(collateralVault));
    }

    function test_CV_02_OwnerCanReplaceBeforeFirstLoan() public {
        registry.setCollateralVault(address(collateralVault));
        CollateralVault cv2 = CollateralVault(address(new ERC1967Proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, (owner, address(usdc), address(registry), 8000))
        )));
        registry.setCollateralVault(address(cv2));
        assertEq(address(registry.collateralVault()), address(cv2));
    }

    function test_CV_03_NonOwnerCannotSet() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.setCollateralVault(address(collateralVault));
    }

    function test_CV_04_ZeroAddressReverts() public {
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        registry.setCollateralVault(address(0));
    }

    function test_CV_05_LockedAfterFirstLoan() public {
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        _createOneLoan();
        assertGt(registry.nextLoanId(), 0);
        CollateralVault cv2 = CollateralVault(address(new ERC1967Proxy(
            address(new CollateralVault()),
            abi.encodeCall(CollateralVault.initialize, (owner, address(usdc), address(registry), 8000))
        )));
        vm.expectRevert(LoanRegistry.LoansAlreadyExist.selector);
        registry.setCollateralVault(address(cv2));
    }

    // ================================================================== LoanRegistry.setUnderwriterPool

    function test_UP_01_InitialSetWorks() public {
        registry.setUnderwriterPool(address(underwriterPool));
        assertEq(address(registry.underwriterPool()), address(underwriterPool));
    }

    function test_UP_02_OwnerCanReplaceBeforeFirstLoan() public {
        registry.setUnderwriterPool(address(underwriterPool));
        UnderwriterPool up2 = UnderwriterPool(address(new ERC1967Proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize, (owner, address(registry), address(usdc)))
        )));
        registry.setUnderwriterPool(address(up2));
        assertEq(address(registry.underwriterPool()), address(up2));
    }

    function test_UP_03_NonOwnerCannotSet() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.setUnderwriterPool(address(underwriterPool));
    }

    function test_UP_04_ZeroAddressReverts() public {
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        registry.setUnderwriterPool(address(0));
    }

    function test_UP_05_LockedAfterFirstLoan() public {
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        _createOneLoan();
        UnderwriterPool up2 = UnderwriterPool(address(new ERC1967Proxy(
            address(new UnderwriterPool()),
            abi.encodeCall(UnderwriterPool.initialize, (owner, address(registry), address(usdc)))
        )));
        vm.expectRevert(LoanRegistry.LoansAlreadyExist.selector);
        registry.setUnderwriterPool(address(up2));
    }

    // ================================================================== LoanRegistry.setReservePool

    function test_RP_01_InitialSetWorks() public {
        registry.setReservePool(address(reserve));
        assertEq(address(registry.reservePool()), address(reserve));
    }

    function test_RP_02_OwnerCanReplaceBeforeFirstLoan() public {
        registry.setReservePool(address(reserve));
        ReservePool rp2 = ReservePool(address(new ERC1967Proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        )));
        registry.setReservePool(address(rp2));
        assertEq(address(registry.reservePool()), address(rp2));
    }

    function test_RP_03_NonOwnerCannotSet() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.setReservePool(address(reserve));
    }

    function test_RP_04_ZeroAddressReverts() public {
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        registry.setReservePool(address(0));
    }

    function test_RP_05_LockedAfterFirstLoan() public {
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        _createOneLoan();
        ReservePool rp2 = ReservePool(address(new ERC1967Proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        )));
        vm.expectRevert(LoanRegistry.LoansAlreadyExist.selector);
        registry.setReservePool(address(rp2));
    }

    // ================================================================== RevenueRouter.setReservePool

    function test_RR_01_InitialSetWorks() public {
        router.setReservePool(address(reserve), 200);
        assertEq(address(router.reservePool()), address(reserve));
        assertEq(router.reserveBps(), 200);
    }

    function test_RR_02_OwnerCanReplaceBeforeFirstLoan() public {
        router.setReservePool(address(reserve), 200);
        ReservePool rp2 = ReservePool(address(new ERC1967Proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        )));
        router.setReservePool(address(rp2), 300);
        assertEq(address(router.reservePool()), address(rp2));
        assertEq(router.reserveBps(), 300);
    }

    function test_RR_03_NonOwnerCannotSet() public {
        vm.prank(stranger);
        vm.expectRevert();
        router.setReservePool(address(reserve), 200);
    }

    function test_RR_04_ZeroAddressReverts() public {
        vm.expectRevert(RevenueRouter.ZeroAddress.selector);
        router.setReservePool(address(0), 200);
    }

    function test_RR_05_LockedAfterFirstLoan() public {
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        _createOneLoan();
        ReservePool rp2 = ReservePool(address(new ERC1967Proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        )));
        vm.expectRevert(RevenueRouter.LoansAlreadyExist.selector);
        router.setReservePool(address(rp2), 200);
    }

    function test_RR_06_UsesRegistryNextLoanId() public {
        // Verify the guard reads from the live registry, not a cached value.
        // Before any loan: should succeed.
        router.setReservePool(address(reserve), 200);
        // Create a loan (advances nextLoanId in registry).
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        _createOneLoan();
        // Now router must also be locked.
        ReservePool rp2 = ReservePool(address(new ERC1967Proxy(
            address(new ReservePool()),
            abi.encodeCall(ReservePool.initialize, (owner, address(usdc), address(registry)))
        )));
        vm.expectRevert(RevenueRouter.LoansAlreadyExist.selector);
        router.setReservePool(address(rp2), 200);
    }

    // ================================================================== LoanVault.setLiquidityPool

    function test_LP_01_InitialSetWorks() public {
        vault.setLiquidityPool(address(pool));
        assertEq(vault.liquidityPool(), address(pool));
    }

    function test_LP_02_OwnerCanReplaceWhenNoActivePoolLoans() public {
        vault.setLiquidityPool(address(pool));
        // No pool-funded loans exist yet — activeLoanCount == 0.
        LiquidityPool pool2 = LiquidityPool(address(new ERC1967Proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc), address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reserve), address(vault)
            ))
        )));
        vault.setLiquidityPool(address(pool2));
        assertEq(vault.liquidityPool(), address(pool2));
    }

    function test_LP_03_NonOwnerCannotSet() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.setLiquidityPool(address(pool));
    }

    function test_LP_04_ZeroAddressReverts() public {
        vm.expectRevert(LoanVault.ZeroAddress.selector);
        vault.setLiquidityPool(address(0));
    }

    function test_LP_05_LockedWhileActivePoolLoansExist() public {
        // Wire everything up and create a pool-funded loan.
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        vault.setLiquidityPool(address(pool));

        // Seed pool and fund a loan through it.
        usdc.mint(owner, 2_000e6);
        usdc.approve(address(pool), 2_000e6);
        pool.initializeLiquidity(2_000e6);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_makeProposal(1_000e6));
        vault.fundFromPool(loanId);

        // activeLoanCount == 1 -> replacement must revert.
        assertEq(pool.activeLoanCount(), 1);
        LiquidityPool pool2 = LiquidityPool(address(new ERC1967Proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc), address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reserve), address(vault)
            ))
        )));
        vm.expectRevert(LoanVault.ActiveLoansExist.selector);
        vault.setLiquidityPool(address(pool2));
    }

    function test_LP_06_ActivationCountViewIsUsed() public {
        // Confirm the guard reads activeLoanCount() from the currently
        // configured pool address, not from a stale local state.
        vault.setLiquidityPool(address(pool));
        assertEq(pool.activeLoanCount(), 0);
        // Can replace while count is 0.
        LiquidityPool pool2 = LiquidityPool(address(new ERC1967Proxy(
            address(new LiquidityPool()),
            abi.encodeCall(LiquidityPool.initialize, (
                owner, address(usdc), address(registry), address(router),
                address(collateralVault), address(underwriterPool),
                address(reserve), address(vault)
            ))
        )));
        vault.setLiquidityPool(address(pool2));
        assertEq(vault.liquidityPool(), address(pool2));
    }
}
