// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {ReservePool} from "../src/ReservePool.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC_R15 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title Risk15_RecipientValidation
/// @notice Focused tests for RISK-15: creditWallet must be registry-approved
///         and must appear in permittedRecipients.
contract Risk15_RecipientValidation is Test {
    // ── contracts ──────────────────────────────────────────────────────────
    AgentRegistry      internal agentReg;
    uint256            internal agentId;
    MockUSDC_R15       internal usdc;
    CreditRegistry     internal creditReg;
    RecipientRegistry  internal recipientReg;
    LoanRegistry       internal registry;
    LoanVault          internal vault;
    RevenueRouter      internal router;
    CollateralVault    internal collateralVault;
    UnderwriterPool    internal underwriterPool;
    ReservePool        internal reserve;

    // ── actors ─────────────────────────────────────────────────────────────
    address internal owner    = address(this);
    address internal borrower = address(0xB0);
    address internal lender   = address(0xC0);

    // ── approved addresses ─────────────────────────────────────────────────
    address internal vendorA  = address(0xA1);
    address internal vendorB  = address(0xA2);
    address internal vendorC  = address(0xA3);
    address internal unregAddr = address(0xFF);   // never registered

    // ── loan constants ─────────────────────────────────────────────────────
    uint256 internal constant PRINCIPAL  = 1_000e6;
    uint256 internal constant TOTAL_DUE  = 1_150e6;
    uint256 internal constant DURATION   = 90 days;
    bytes32 internal constant CATEGORY   = keccak256("COMPUTE");

    // ───────────────────────────────────────────────────────────────────────
    function setUp() public {
        usdc = new MockUSDC_R15();

        // AgentRegistry
        agentReg = AgentRegistry(address(new ERC1967Proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        )));
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        // Authorize all addresses used as creditWallet so the AgentRegistry check (check 2 in
        // _validateProposal) passes; RecipientRegistry approval is the downstream gate being tested.
        vm.prank(borrower);
        agentReg.addWallet(agentId, vendorA);
        vm.prank(borrower);
        agentReg.addWallet(agentId, vendorB);
        vm.prank(borrower);
        agentReg.addWallet(agentId, vendorC);
        vm.prank(borrower);
        agentReg.addWallet(agentId, unregAddr); // authorized in AgentRegistry but NOT in RecipientRegistry

        // CreditRegistry
        address crImpl = address(new CreditRegistry());
        creditReg = CreditRegistry(address(new ERC1967Proxy(crImpl,
            abi.encodeCall(CreditRegistry.initialize, (
                owner, 5e6, 2500, 1000, 2_000e6, 2000, 25_000e6, 500, 50e6, 50_000e6
            )))));

        // RecipientRegistry
        address rrImpl = address(new RecipientRegistry());
        recipientReg = RecipientRegistry(address(new ERC1967Proxy(rrImpl,
            abi.encodeCall(RecipientRegistry.initialize, (owner)))));

        // LoanRegistry (deployed before all registry-dependent contracts so their
        // initialize calls can receive the real registry address — RISK-15 fix)
        address regImpl = address(new LoanRegistry());
        registry = LoanRegistry(address(new ERC1967Proxy(regImpl,
            abi.encodeCall(LoanRegistry.initialize, (
                owner, address(creditReg), 30 days, 365 days,
                1_000_000e6, 1_500
            )))));

        // ReservePool — pass registry address directly (no setter needed)
        address rpImpl = address(new ReservePool());
        reserve = ReservePool(address(new ERC1967Proxy(rpImpl,
            abi.encodeCall(ReservePool.initialize, (
                owner, address(usdc), address(registry)
            )))));

        // CollateralVault — pass registry address directly (no setRegistry needed)
        address cvImpl = address(new CollateralVault());
        collateralVault = CollateralVault(address(new ERC1967Proxy(cvImpl,
            abi.encodeCall(CollateralVault.initialize, (
                owner, address(usdc), address(registry), 7500
            )))));

        // UnderwriterPool — pass registry address directly (no setRegistry needed)
        address upImpl = address(new UnderwriterPool());
        underwriterPool = UnderwriterPool(address(new ERC1967Proxy(upImpl,
            abi.encodeCall(UnderwriterPool.initialize, (
                owner, address(usdc), address(registry)
            )))));

        // LoanVault
        address lvImpl = address(new LoanVault());
        vault = LoanVault(address(new ERC1967Proxy(lvImpl,
            abi.encodeCall(LoanVault.initialize, (
                owner, address(registry), address(usdc)
            )))));

        // RevenueRouter
        address routerImpl = address(new RevenueRouter());
        router = RevenueRouter(address(new ERC1967Proxy(routerImpl,
            abi.encodeCall(RevenueRouter.initialize, (
                owner, address(registry), address(creditReg), address(usdc)
            )))));

        // Wire up
        registry.setContracts(address(vault), address(router));
        registry.setCollateralVault(address(collateralVault));
        registry.setUnderwriterPool(address(underwriterPool));
        registry.setRecipientRegistry(address(recipientReg));
        // Configure reserve pool BEFORE any loan is created (RISK-12 guard requires nextLoanId == 0)
        registry.setReservePool(address(reserve));
        registry.setAgentRegistry(address(agentReg));
        router.setAgentRegistry(address(agentReg));
        router.setReservePool(address(reserve), 200); // 2% reserve bps
        reserve.setAuthorizedContributor(address(router), true); // router may skim into reserve
        creditReg.setAuthorizedCaller(address(registry), true);
        creditReg.setAuthorizedCaller(address(router), true);

        // Seed borrower credit against the real agentId slot
        vm.prank(address(router));
        creditReg.recordRepayment(agentId, 5_000e6, false);

        // Register approved vendors
        recipientReg.approveRecipient(vendorA, CATEGORY, "Vendor A");
        recipientReg.approveRecipient(vendorB, CATEGORY, "Vendor B");
        recipientReg.approveRecipient(vendorC, CATEGORY, "Vendor C");
        // NOTE: unregAddr is intentionally NOT registered
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// Build a minimal valid proposal with `creditWallet` and one permitted recipient.
    function _proposal(address cw, address[] memory permitted)
        internal view returns (ILoanRegistry.LoanProposal memory p)
    {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: CATEGORY, cap: PRINCIPAL});

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PRINCIPAL;
        string[] memory descs = new string[](1);
        descs[0] = "Milestone 1";

        p = ILoanRegistry.LoanProposal({
            agentId:               agentId,
            creditWallet:          cw,
            principal:             PRINCIPAL,
            totalRepaymentDue:     TOTAL_DUE,
            repaymentRateBps:      1500,
            duration:              DURATION,
            purpose:               "RISK-15 test loan",
            collateralAmount:      0,
            collateralAsset:       address(0),
            underwriterAmount:     0,
            underwriter:           address(0),
            budget:                budget,
            permittedRecipients:   permitted,
            milestoneAmounts:      amounts,
            milestoneDescriptions: descs
        });
    }

    function _oneRecipient(address r) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = r;
    }

    function _twoRecipients(address r0, address r1) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = r0;
        arr[1] = r1;
    }

    function _threeRecipients(address r0, address r1, address r2) internal pure returns (address[] memory arr) {
        arr = new address[](3);
        arr[0] = r0;
        arr[1] = r1;
        arr[2] = r2;
    }

    // ── test_01: unapproved creditWallet → UnapprovedRecipient ──────────────
    function test_01_UnapprovedCreditWallet() public {
        ILoanRegistry.LoanProposal memory p = _proposal(
            unregAddr,
            _oneRecipient(unregAddr)
        );
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.UnapprovedRecipient.selector);
        registry.requestLoan(p);
    }

    // ── test_02: approved cw not in permittedRecipients → CreditWalletNotInRecipients
    function test_02_CreditWalletNotInPermittedRecipients() public {
        // vendorA is approved, vendorB is permitted — but creditWallet = vendorA
        // and permittedRecipients only contains vendorB
        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorA,
            _oneRecipient(vendorB)
        );
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.CreditWalletNotInRecipients.selector);
        registry.requestLoan(p);
    }

    // ── test_03: approved cw in permittedRecipients → succeeds ─────────────
    function test_03_ValidCreditWalletInRecipients() public {
        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorA,
            _oneRecipient(vendorA)
        );
        vm.prank(borrower);
        uint256 id = registry.requestLoan(p);
        assertEq(id, 0, "first loan id should be 0");
    }

    // ── test_04: creditWallet is second permitted recipient → succeeds ──────
    function test_04_CreditWalletSecondInList() public {
        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorB,
            _twoRecipients(vendorA, vendorB)
        );
        vm.prank(borrower);
        uint256 id = registry.requestLoan(p);
        assertEq(id, 0);
    }

    // ── test_05: creditWallet is last in a 3-recipient list → succeeds ──────
    function test_05_CreditWalletLastInList() public {
        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorC,
            _threeRecipients(vendorA, vendorB, vendorC)
        );
        vm.prank(borrower);
        uint256 id = registry.requestLoan(p);
        assertEq(id, 0);
    }

    // ── test_06: recipient revoked before new request → reverts ────────────
    function test_06_RevokedRecipientBeforeRequest() public {
        // Revoke vendorA
        recipientReg.revokeRecipient(vendorA);

        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorA,
            _oneRecipient(vendorA)
        );
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.UnapprovedRecipient.selector);
        registry.requestLoan(p);
    }

    // ── test_07: existing loan unaffected when recipient approval changes ───
    function test_07_ExistingLoanUnaffectedByRevocation() public {
        // Create a valid loan first
        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorA,
            _oneRecipient(vendorA)
        );
        vm.prank(borrower);
        uint256 id = registry.requestLoan(p);

        // Now revoke vendorA
        recipientReg.revokeRecipient(vendorA);

        // Existing loan still has correct creditWallet
        ILoanRegistry.LoanView memory loan = registry.getLoan(id);
        assertEq(loan.creditWallet, vendorA, "existing loan creditWallet unchanged");
        // Loan status still Requested — lifecycle unaffected
        assertEq(uint256(loan.status), uint256(ILoanRegistry.LoanStatus.Requested));
    }

    // ── test_08: RevenueRouter creditWalletShare still goes to creditWallet ─
    function test_08_RevenueRouterCreditWalletShareUnchanged() public {
        // Create valid loan
        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorA,
            _oneRecipient(vendorA)
        );
        vm.prank(borrower);
        uint256 id = registry.requestLoan(p);

        // Fund the loan (direct lender path)
        usdc.mint(lender, PRINCIPAL);
        vm.startPrank(lender);
        usdc.approve(address(vault), PRINCIPAL);
        vault.fundLoan(id);
        vm.stopPrank();

        // Third party pays revenue
        address payer = address(0xDEAD);
        usdc.mint(payer, 500e6);
        vm.startPrank(payer);
        usdc.approve(address(router), 500e6);
        router.payRevenue(id, 500e6);
        vm.stopPrank();

        // creditWalletShare (non-repayment portion) should reach vendorA
        uint256 repayShare = (500e6 * 1500) / 10000; // 75e6
        uint256 expectedCreditWalletShare = 500e6 - repayShare; // 425e6
        assertGt(usdc.balanceOf(vendorA), 0, "vendorA should have received creditWalletShare");
        assertEq(usdc.balanceOf(vendorA), expectedCreditWalletShare, "creditWalletShare routes correctly");
    }

    // ── test_09: multiple permitted recipients remain supported ─────────────
    function test_09_MultiplePermittedRecipientsSupported() public {
        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorA,
            _threeRecipients(vendorA, vendorB, vendorC)
        );
        vm.prank(borrower);
        uint256 id = registry.requestLoan(p);

        address[] memory stored = registry.getPermittedRecipients(id);
        assertEq(stored.length, 3, "all three recipients stored");
        assertEq(stored[0], vendorA);
        assertEq(stored[1], vendorB);
        assertEq(stored[2], vendorC);
    }

    // ── test_10: borrower cannot bypass by putting other approved addr in list
    function test_10_CannotBypassWithDifferentApprovedAddress() public {
        // creditWallet = vendorA (approved), permittedRecipients = [vendorB]
        // vendorB is approved but creditWallet is NOT in the list
        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorA,
            _oneRecipient(vendorB)
        );
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.CreditWalletNotInRecipients.selector);
        registry.requestLoan(p);
    }

    // ── test_11: unapproved permittedRecipient also reverts (existing check) ─
    function test_11_UnapprovedPermittedRecipientReverts() public {
        // vendorA approved, unregAddr is not — mix them in permittedRecipients
        ILoanRegistry.LoanProposal memory p = _proposal(
            vendorA,
            _twoRecipients(vendorA, unregAddr)
        );
        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.UnapprovedRecipient.selector);
        registry.requestLoan(p);
    }
}
