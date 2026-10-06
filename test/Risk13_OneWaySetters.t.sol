// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------
// RISK-13 regression tests -- LoanRegistry one-way setters
//
// Verifies that setContracts is a one-time operation (ContractsAlreadySet
// on any second call), that setRecipientRegistry is repeatable,
// that authorization and zero-address checks are preserved, and that
// existing loan state is unaffected by a RecipientRegistry rotation.
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
import {AgentRegistry}      from "../src/AgentRegistry.sol";
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

    AgentRegistry     agentReg;
    uint256           agentId;
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

        // AgentRegistry
        agentReg = AgentRegistry(address(new ERC1967Proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        )));
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
        registry.setAgentRegistry(address(agentReg));
        vault.setLiquidityPool(address(pool));
        reserve.setAuthorizedContributor(address(router), true);
        creditReg.setAuthorizedCaller(address(registry), true);
        creditReg.setAuthorizedCaller(address(router), true);

        // Borrower credit seed — write to credits[agentId] so _validateProposal passes
        vm.prank(address(router));
        creditReg.recordRepayment(agentId, 5_000e6, false);

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
            agentId:               agentId,
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

    function test_SC_02_SecondCallRevertsContractsAlreadySet() public {
        // setContracts is one-time: any second call must revert regardless of args.
        FakeVault  vault2  = new FakeVault(address(registry));
        FakeRouter router2 = new FakeRouter(address(registry));

        vm.expectRevert(LoanRegistry.ContractsAlreadySet.selector);
        registry.setContracts(address(vault2), address(router2));
    }

    function test_SC_03_SecondCallWithSameArgsAlsoReverts() public {
        // Even passing identical addresses must revert after first set.
        vm.expectRevert(LoanRegistry.ContractsAlreadySet.selector);
        registry.setContracts(address(vault), address(router));
    }

    function test_SC_04_SetContractsIsImmutable_VaultUnchanged() public {
        FakeVault  vault2  = new FakeVault(address(registry));
        FakeRouter router2 = new FakeRouter(address(registry));

        // Attempt rotation — must revert.
        vm.expectRevert(LoanRegistry.ContractsAlreadySet.selector);
        registry.setContracts(address(vault2), address(router2));

        // vault is unchanged.
        assertEq(registry.vault(), address(vault), "vault immutable");
    }

    function test_SC_05_SetContractsIsImmutable_RouterUnchanged() public {
        FakeRouter router2 = new FakeRouter(address(registry));

        vm.expectRevert(LoanRegistry.ContractsAlreadySet.selector);
        registry.setContracts(address(vault), address(router2));

        assertEq(registry.router(), address(router), "router immutable");
    }

    function test_SC_06_OriginalVaultStillPassesOnlyVault() public {
        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_proposal());

        // Original vault is still the authorized vault.
        vm.prank(directLender);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(directLender);
        vault.fundLoan(loanId);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Active), "loan active via original vault");
    }

    function test_SC_07_NonOwnerCannotCallSetContracts() public {
        FakeVault  vault2  = new FakeVault(address(registry));
        FakeRouter router2 = new FakeRouter(address(registry));

        vm.expectRevert();
        vm.prank(nonOwner);
        registry.setContracts(address(vault2), address(router2));
    }

    function test_SC_08_ZeroVaultRevertsOnFreshRegistry() public {
        // Deploy a fresh registry that hasn't had setContracts called yet.
        LoanRegistry fresh = LoanRegistry(_proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), 1 days, 365 days, GRACE, CAT))
        ));
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        fresh.setContracts(address(0), address(router));
    }

    function test_SC_09_ZeroRouterRevertsOnFreshRegistry() public {
        LoanRegistry fresh = LoanRegistry(_proxy(
            address(new LoanRegistry()),
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), 1 days, 365 days, GRACE, CAT))
        ));
        vm.expectRevert(LoanRegistry.ZeroAddress.selector);
        fresh.setContracts(address(vault), address(0));
    }

    function test_SC_10_ExistingLoanStateStableAfterAttemptedRotation() public {
        uint256 loanId = _requestAndFund();
        ILoanRegistry.LoanView memory before = registry.getLoan(loanId);

        // Attempted rotation must revert — but loan state must be unchanged.
        FakeVault  vault2  = new FakeVault(address(registry));
        FakeRouter router2 = new FakeRouter(address(registry));
        vm.expectRevert(LoanRegistry.ContractsAlreadySet.selector);
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
