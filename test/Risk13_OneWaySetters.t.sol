// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------
// RISK-13 regression tests -- LoanRegistry one-way setters
//
// Verifies that setContracts and setRecipientRegistry are repeatable
// after the AlreadySet guards are removed, that authorization and
// zero-address checks are preserved, that rotation correctly changes
// which callers pass onlyVault / onlyRouter guards, and that
// existing loan state is unaffected by a configuration rotation.
//
// Uses ERC1967Proxy deployment to avoid the OZ-FFI MemoryOOG.
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

contract MockUSDC_R13 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// Minimal stand-in for a second vault/router/recipientRegistry so we can test rotation.
// Only needs to pass the onlyVault / onlyRouter checks in LoanRegistry.
contract FakeVault {
    LoanRegistry public registry;
    constructor(address _registry) { registry = LoanRegistry(_registry); }
    function callMarkFunded(uint256 loanId, address lender) external {
        registry.markFunded(loanId, lender);
    }
    function callMarkMilestoneReleased(uint256 loanId, uint256 idx) external {
        registry.markMilestoneReleased(loanId, idx);
    }
}

contract FakeRouter {
    LoanRegistry public registry;
    constructor(address _registry) { registry = LoanRegistry(_registry); }
    function callMarkRepaid(uint256 loanId) external {
        registry.markRepaid(loanId);
    }
}

// Minimal RecipientRegistry stand-in that approves everything.
contract ApproveAllRegistry {
    function isApproved(address) external pure returns (bool) { return true; }
}

// Minimal RecipientRegistry stand-in that approves nothing.
contract ApproveNoneRegistry {
    function isApproved(address) external pure returns (bool) { return false; }
}

contract Risk13_OneWaySettersTest is Test {

    LoanRegistry      registry;
    LoanVault         vault;
    CreditRegistry    creditReg;
    RevenueRouter     router;
    CollateralVault   colVault;
    UnderwriterPool   uwPool;
    RecipientRegistry recipReg;
    ReservePool       reserve;
    LiquidityPool     pool;
    MockUSDC_R13      usdc;

    address owner        = address(this);
    address nonOwner     = address(0xDEAD);
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address directLender = address(0x1E4DE4);

    uint256 constant GRACE = 3 days;
    uint256 constant CAT   = 25_000e6;
    uint16  constant MAX_LTV = 6600;

    uint256 constant PRINCIPAL = 100e6;
    uint256 constant TOTAL_DUE = 115e6;
    uint16  constant RATE_BPS  = 1500;

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        usdc = new MockUSDC_R13();

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
        reserve.setAuthorizedContributor(address(router), true);
        creditReg.setAuthorizedCaller(address(registry), true);
        creditReg.setAuthorizedCaller(address(router), true);

        // Borrower credit seed
        vm.prank(address(router));
        creditReg.recordRepayment(borrower, 5_000e6, false);

        // Recipient
        recipReg.approveRecipient(creditWallet, keccak256("COMPUTE"), "CW");

        // Direct lender has USDC
        usdc.mint(directLender, 100_000e6);
        vm.prank(directLender);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _proposal() internal view returns (ILoanRegistry.LoanProposal memory) {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PRINCIPAL;
        string[] memory descs = new string[](1);
        descs[0] = "Phase 1";
        address[] memory recipients = new address[](1);
        recipients[0] = creditWallet;
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("ops"), cap: PRINCIPAL});
        return ILoanRegistry.LoanProposal({
            creditWallet:          creditWallet,
            principal:             PRINCIPAL,
            totalRepaymentDue:     TOTAL_DUE,
            repaymentRateBps:      RATE_BPS,
            duration:              30 days,
            collateralAmount:      0,
            underwriterAmount:     0,
            underwriter:           address(0),
            purpose:               "test",
            budget:                budget,
            permittedRecipients:   recipients,
            milestoneAmounts:      amounts,
            milestoneDescriptions: descs
        });
    }

    function _requestAndFund() internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = registry.requestLoan(_proposal());
        vm.prank(directLender);
        vault.fundLoan(loanId);
    }

    // ------------------------------------------------------------------
    // setContracts tests
    // ------------------------------------------------------------------

    function test_SC_01_InitialSetWorks() public view {
        assertEq(registry.vault(),  address(vault),  "vault set");
        assertEq(registry.router(), address(router), "router set");
    }

    function test_SC_02_OwnerCanRotateContracts() public {
        FakeVault  vault2  = new FakeVault(address(registry));
        FakeRouter router2 = new FakeRouter(address(registry));

        vm.expectEmit(true, false, false, false);
        emit LoanRegistry.VaultSet(address(vault2));
        vm.expectEmit(true, false, false, false);
        emit LoanRegistry.RouterSet(address(router2));

        registry.setContracts(address(vault2), address(router2));

        assertEq(registry.vault(),  address(vault2),  "vault updated");
        assertEq(registry.router(), address(router2), "router updated");
    }

    function test_SC_03_NewVaultPassesOnlyVaultAfterRotation() public {
        // Create a loan so there is something to call markFunded on.
        // Use a fresh request after rotation — markFunded is called on Requested loans.
        FakeVault  vault2  = new FakeVault(address(registry));
        FakeRouter router2 = new FakeRouter(address(registry));
        registry.setContracts(address(vault2), address(router2));

        // Request a loan (recipReg still set, borrower has credit)
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal());

        // New vault can call markFunded
        vault2.callMarkFunded(loanId, directLender);
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(loan.lender, directLender, "lender set by new vault");
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Active), "loan active");
    }

    function test_SC_04_OldVaultRejectedAfterRotation() public {
        FakeVault  vault2  = new FakeVault(address(registry));
        FakeRouter router2 = new FakeRouter(address(registry));
        registry.setContracts(address(vault2), address(router2));

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal());

        // Old vault (real LoanVault) is no longer authorized
        vm.expectRevert(LoanRegistry.NotVault.selector);
        vm.prank(address(vault));
        registry.markFunded(loanId, directLender);
    }

    function test_SC_05_NewRouterPassesOnlyRouterAfterRotation() public {
        // Fund a loan first with the real vault (still authorized at that point)
        uint256 loanId = _requestAndFund();
        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Active));

        // Now rotate to new router
        FakeRouter router2 = new FakeRouter(address(registry));
        registry.setContracts(address(vault), address(router2));

        // New router can call markRepaid
        router2.callMarkRepaid(loanId);
        loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Repaid), "loan repaid by new router");
    }

    function test_SC_06_OldRouterRejectedAfterRotation() public {
        uint256 loanId = _requestAndFund();

        FakeRouter router2 = new FakeRouter(address(registry));
        registry.setContracts(address(vault), address(router2));

        // Old router (real RevenueRouter) is no longer authorized
        vm.expectRevert(LoanRegistry.NotRouter.selector);
        vm.prank(address(router));
        registry.markRepaid(loanId);
    }

    function test_SC_07_NonOwnerCannotRotate() public {
        FakeVault  vault2  = new FakeVault(address(registry));
        FakeRouter router2 = new FakeRouter(address(registry));

        vm.expectRevert();
        vm.prank(nonOwner);
        registry.setContracts(address(vault2), address(router2));
    }

    function test_SC_08_ZeroVaultReverts() public {
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        registry.setContracts(address(0), address(router));
    }

    function test_SC_09_ZeroRouterReverts() public {
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        registry.setContracts(address(vault), address(0));
    }

    function test_SC_10_ExistingLoanStateUnchangedByRotation() public {
        // Fund a loan, verify state, rotate, verify state is identical
        uint256 loanId = _requestAndFund();
        ILoanRegistry.LoanView memory before = registry.getLoan(loanId);

        FakeVault  vault2  = new FakeVault(address(registry));
        FakeRouter router2 = new FakeRouter(address(registry));
        registry.setContracts(address(vault2), address(router2));

        ILoanRegistry.LoanView memory after_ = registry.getLoan(loanId);
        assertEq(after_.borrower,          before.borrower,          "borrower unchanged");
        assertEq(after_.lender,            before.lender,            "lender unchanged");
        assertEq(after_.principal,         before.principal,         "principal unchanged");
        assertEq(after_.totalRepaymentDue, before.totalRepaymentDue, "totalRepaymentDue unchanged");
        assertEq(uint8(after_.status),     uint8(before.status),     "status unchanged");
    }

    // ------------------------------------------------------------------
    // setRecipientRegistry tests
    // ------------------------------------------------------------------

    function test_RR_01_InitialSetWorks() public view {
        assertEq(address(registry.recipientRegistry()), address(recipReg), "recipientRegistry set");
    }

    function test_RR_02_OwnerCanReplace() public {
        RecipientRegistry recipReg2 = RecipientRegistry(_proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        ));

        vm.expectEmit(true, false, false, false);
        emit LoanRegistry.RecipientRegistrySet(address(recipReg2));
        registry.setRecipientRegistry(address(recipReg2));

        assertEq(address(registry.recipientRegistry()), address(recipReg2), "recipientRegistry updated");
    }

    function test_RR_03_NonOwnerCannotReplace() public {
        RecipientRegistry recipReg2 = RecipientRegistry(_proxy(
            address(new RecipientRegistry()),
            abi.encodeCall(RecipientRegistry.initialize, (owner))
        ));

        vm.expectRevert();
        vm.prank(nonOwner);
        registry.setRecipientRegistry(address(recipReg2));
    }

    function test_RR_04_ZeroAddressReverts() public {
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        registry.setRecipientRegistry(address(0));
    }

    function test_RR_05_NewRegistryUsedForSubsequentLoanValidation() public {
        // Switch to an approve-none registry -- new loan requests should fail
        ApproveNoneRegistry noneReg = new ApproveNoneRegistry();
        registry.setRecipientRegistry(address(noneReg));

        vm.expectRevert(LoanRegistry.UnapprovedRecipient.selector);
        vm.prank(borrower);
        registry.requestLoan(_proposal());

        // Switch to an approve-all registry -- new loan requests should succeed
        ApproveAllRegistry allReg = new ApproveAllRegistry();
        registry.setRecipientRegistry(address(allReg));

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal());
        assertEq(uint8(registry.getLoan(loanId).status), uint8(ILoanRegistry.LoanStatus.Requested));
    }

    function test_RR_06_ExistingLoanUnaffectedByRegistryRotation() public {
        uint256 loanId = _requestAndFund();
        ILoanRegistry.LoanView memory before = registry.getLoan(loanId);

        // Rotate to approve-none
        ApproveNoneRegistry noneReg = new ApproveNoneRegistry();
        registry.setRecipientRegistry(address(noneReg));

        // Existing loan state is unchanged
        ILoanRegistry.LoanView memory after_ = registry.getLoan(loanId);
        assertEq(after_.borrower,          before.borrower,          "borrower unchanged");
        assertEq(after_.lender,            before.lender,            "lender unchanged");
        assertEq(uint8(after_.status),     uint8(before.status),     "status unchanged");
        assertEq(after_.principal,         before.principal,         "principal unchanged");
    }
}
