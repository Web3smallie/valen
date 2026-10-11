// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ILoanRegistry} from "../src/interfaces/ILoanRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC2 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract CollateralVaultTest is Test {
    function _opts() internal pure returns (Options memory o) { o.unsafeSkipAllChecks = true; }
    AgentRegistry     agentReg;
    LoanRegistry      registry;
    CreditRegistry    creditRegistry;
    RevenueRouter     router;
    CollateralVault   vault;
    RecipientRegistry recipientRegistry;
    MockUSDC2 usdc;

    address owner        = address(this);
    address loanVault    = address(0xBEEF);
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address lender       = address(0x1E4DE4);

    uint256 agentId;
    uint256 principal           = 1_000e6;
    uint16  constant MAX_LTV_BPS = 6600;
    uint256 constant DEFAULT_GRACE_PERIOD          = 3 days;
    uint256 constant COLLATERAL_APPROVAL_THRESHOLD = 10_000e6;

    function setUp() public {
        usdc = new MockUSDC2();

        // ── AgentRegistry ──────────────────────────────────────────────────────
        agentReg = AgentRegistry(address(new ERC1967Proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        )));
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        // ── CreditRegistry ─────────────────────────────────────────────────────
        address creditRegistryProxy = Upgrades.deployUUPSProxy(
            "CreditRegistry.sol",
            abi.encodeCall(CreditRegistry.initialize,
                (owner, 5e6, 2500, 1000, 2000e6, 2000, 25_000e6, 500, 50e6, 50_000e6))
                    , _opts()
            );
        creditRegistry = CreditRegistry(creditRegistryProxy);

        // ── LoanRegistry ───────────────────────────────────────────────────────
        address registryProxy = Upgrades.deployUUPSProxy(
            "LoanRegistry.sol",
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditRegistry), 1 days, 365 days,
                 DEFAULT_GRACE_PERIOD, COLLATERAL_APPROVAL_THRESHOLD))
                    , _opts()
            );
        registry = LoanRegistry(registryProxy);

        // ── RevenueRouter ──────────────────────────────────────────────────────
        address routerProxy = Upgrades.deployUUPSProxy(
            "RevenueRouter.sol",
            abi.encodeCall(RevenueRouter.initialize,
                (owner, address(registry), address(creditRegistry), address(usdc)))
                    , _opts()
            );
        router = RevenueRouter(routerProxy);

        // ── CollateralVault ────────────────────────────────────────────────────
        address vaultProxy = Upgrades.deployUUPSProxy(
            "CollateralVault.sol",
            abi.encodeCall(CollateralVault.initialize,
                (owner, address(usdc), address(registry), MAX_LTV_BPS))
                    , _opts()
            );
        vault = CollateralVault(vaultProxy);

        // ── RecipientRegistry ──────────────────────────────────────────────────
        address recipientRegistryProxy = Upgrades.deployUUPSProxy(
            "RecipientRegistry.sol",
            abi.encodeCall(RecipientRegistry.initialize, (owner))
                    , _opts()
            );
        recipientRegistry = RecipientRegistry(recipientRegistryProxy);

        // ── Wire ───────────────────────────────────────────────────────────────
        registry.setContracts(loanVault, address(router));
        registry.setCollateralVault(address(vault));
        registry.setRecipientRegistry(address(recipientRegistry));
        registry.setAgentRegistry(address(agentReg));
        router.setAgentRegistry(address(agentReg));
        creditRegistry.setAuthorizedCaller(address(router), true);
        creditRegistry.setAuthorizedCaller(address(registry), true);

        recipientRegistry.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Test Provider");
        recipientRegistry.approveRecipient(creditWallet,    keccak256("COMPUTE"), "CreditWallet");

        usdc.mint(borrower, 10_000e6);
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _buildProposal(uint256 collateralAmount) internal view returns (ILoanRegistry.LoanProposal memory) {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: principal});

        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet;

        uint256[] memory milestoneAmounts = new uint256[](1);
        milestoneAmounts[0] = principal;
        string[] memory milestoneDescs = new string[](1);
        milestoneDescs[0] = "Full release";

        return ILoanRegistry.LoanProposal({
            agentId:               agentId,
            creditWallet:          creditWallet,
            principal:             principal,
            repaymentRateBps:      1500,
            totalRepaymentDue:     1_150e6,
            duration:              30 days,
            purpose:               "Test collateralized loan",
            budget:                budget,
            permittedRecipients:   recipients,
            milestoneAmounts:      milestoneAmounts,
            milestoneDescriptions: milestoneDescs,
            collateralAmount:      collateralAmount,
            collateralAsset:    address(0),
            underwriter:           address(0),
            underwriterAmount:     0,
            directDisbursement:    false
        });
    }

    function test_RequiredCollateralMath() public view {
        uint256 expected = (principal * 10000) / MAX_LTV_BPS;
        assertEq(vault.requiredCollateral(principal, address(usdc)), expected);
    }

    function test_DepositAndWithdraw() public {
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), 500e6);
        assertEq(vault.availableBalance(borrower, address(usdc)), 500e6);

        vm.prank(borrower);
        vault.withdrawCollateral(address(usdc), 200e6);
        assertEq(vault.availableBalance(borrower, address(usdc)), 300e6);
    }

    function test_CollateralBackedLoanBypassesCreditLimit() public {
        // agentId has no credit history: getLimit(agentId) = initialLimit = 5e6
        assertEq(creditRegistry.getLimit(agentId), 5e6);

        uint256 requiredCollateral = vault.requiredCollateral(principal, address(usdc));
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), requiredCollateral);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(requiredCollateral));

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ILoanRegistry.LoanStatus.Requested));
        assertEq(vault.availableBalance(borrower, address(usdc)), 0);
    }

    function test_RevertsOnInsufficientCollateralForLTV() public {
        uint256 tooLittle = vault.requiredCollateral(principal, address(usdc)) - 1;
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), tooLittle);

        vm.prank(borrower);
        vm.expectRevert(CollateralVault.InsufficientCollateralForLTV.selector);
        registry.requestLoan(_buildProposal(tooLittle));
    }

    function test_RepaymentReleasesCollateral() public {
        uint256 requiredCollateral = vault.requiredCollateral(principal, address(usdc));
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), requiredCollateral);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(requiredCollateral));

        vm.prank(loanVault);
        registry.markFunded(loanId, lender);

        address client = address(0xC1E4);
        usdc.mint(client, 10_000e6);
        vm.prank(client);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(client);
        router.payRevenue(loanId, 8_000e6);

        assertEq(usdc.balanceOf(borrower), 10_000e6 - requiredCollateral + requiredCollateral);
    }

    function test_DefaultSeizesCollateralToLender() public {
        uint256 requiredCollateral = vault.requiredCollateral(principal, address(usdc));
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), requiredCollateral);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(requiredCollateral));

        vm.prank(loanVault);
        registry.markFunded(loanId, lender);

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        vm.warp(loan.expiresAt + DEFAULT_GRACE_PERIOD + 1);

        uint256 lenderBalanceBefore = usdc.balanceOf(lender);
        registry.markDefault(loanId);
        uint256 lenderBalanceAfter = usdc.balanceOf(lender);

        assertEq(lenderBalanceAfter - lenderBalanceBefore, requiredCollateral);
        // recordDefault(agentId, false) for collateral default: penalty on initialLimit.
        // initialLimit=5e6, exists=false → oldLimit=5e6, penalty=5e6*2000/10000=1e6
        assertEq(creditRegistry.getLimit(agentId), 1e6);
    }

    function test_RevertsOnDoubleReservation() public {
        uint256 requiredCollateral = vault.requiredCollateral(principal, address(usdc));
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), requiredCollateral * 2);

        vm.prank(borrower);
        registry.requestLoan(_buildProposal(requiredCollateral));

        vm.prank(address(registry));
        vm.expectRevert(CollateralVault.AlreadyReserved.selector);
        vault.reserveCollateral(0, borrower, address(usdc), requiredCollateral, principal);
    }

    function test_OnlyRegistryCanReserve() public {
        vm.expectRevert(CollateralVault.NotRegistry.selector);
        vault.reserveCollateral(999, borrower, address(usdc), 100e6, 100e6);
    }

    function test_ProposalWithApprovedRecipientSucceeds() public {
        uint256 requiredCollateral = vault.requiredCollateral(principal, address(usdc));
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), requiredCollateral);

        vm.prank(borrower);
        uint256 loanId = registry.requestLoan(_buildProposal(requiredCollateral));

        ILoanRegistry.LoanView memory loan = registry.getLoan(loanId);
        assertEq(loan.principal, principal);
    }

    function test_ProposalWithUnapprovedRecipientReverts() public {
        uint256 requiredCollateral = vault.requiredCollateral(principal, address(usdc));
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), requiredCollateral);

        address[] memory badRecipients = new address[](1);
        badRecipients[0] = address(0xBADBAD);

        ILoanRegistry.LoanProposal memory proposal = _buildProposal(requiredCollateral);
        proposal.permittedRecipients = badRecipients;

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.UnapprovedRecipient.selector);
        registry.requestLoan(proposal);
    }

    function test_MixedApprovedAndUnapprovedRecipientsRevertsEntirely() public {
        uint256 requiredCollateral = vault.requiredCollateral(principal, address(usdc));
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), requiredCollateral);

        address[] memory mixedRecipients = new address[](2);
        mixedRecipients[0] = address(0xD00D);
        mixedRecipients[1] = address(0xBADBAD);

        ILoanRegistry.LoanProposal memory proposal = _buildProposal(requiredCollateral);
        proposal.permittedRecipients = mixedRecipients;

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.UnapprovedRecipient.selector);
        registry.requestLoan(proposal);
    }

    function test_RevokedRecipientCausesNewProposalToRevert() public {
        recipientRegistry.revokeRecipient(address(0xD00D));

        uint256 requiredCollateral = vault.requiredCollateral(principal, address(usdc));
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), requiredCollateral);

        vm.prank(borrower);
        vm.expectRevert(LoanRegistry.UnapprovedRecipient.selector);
        registry.requestLoan(_buildProposal(requiredCollateral));
    }
}
