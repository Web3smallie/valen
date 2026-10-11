// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}             from "forge-std/Test.sol";
import {ERC1967Proxy}     from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Upgrades}         from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options}          from "openzeppelin-foundry-upgrades/Options.sol";
import {ERC20}            from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AgentRegistry}     from "../src/AgentRegistry.sol";
import {CreditRegistry}    from "../src/CreditRegistry.sol";
import {LoanRegistry}      from "../src/LoanRegistry.sol";
import {RevenueRouter}     from "../src/RevenueRouter.sol";
import {CollateralVault}   from "../src/CollateralVault.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ILoanRegistry}     from "../src/interfaces/ILoanRegistry.sol";

// ---------------------------------------------------------------------------
// Mock ERC-20s
// ---------------------------------------------------------------------------

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockEURC is ERC20 {
    constructor() ERC20("Mock EURC", "EURC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

contract MultiAssetCollateralTest is Test {
    function _opts() internal pure returns (Options memory o) { o.unsafeSkipAllChecks = true; }
    AgentRegistry     agentReg;
    LoanRegistry      loanReg;
    CreditRegistry    creditReg;
    RevenueRouter     router;
    CollateralVault   vault;
    RecipientRegistry recipientReg;

    MockUSDC usdc;
    MockEURC eurc;

    address owner        = address(this);
    address loanVaultAddr = address(0xBEEF);
    address borrower     = address(0xB0B);
    address creditWallet = address(0xCAFE);
    address lender       = address(0x1E4DE4);

    uint256 agentId;
    uint256 constant PRINCIPAL          = 1_000e6;  // 1 000 USDC
    uint16  constant MAX_LTV_BPS        = 6600;     // 66%
    uint256 constant GRACE_PERIOD       = 3 days;
    uint256 constant APPROVAL_THRESHOLD = 10_000e6;

    // EURC price: 1.08 USD per EURC, scaled by 1e18
    uint256 constant EURC_PRICE_E18 = 1_080_000_000_000_000_000;

    function setUp() public {
        usdc = new MockUSDC();
        eurc = new MockEURC();

        // AgentRegistry
        agentReg = AgentRegistry(address(new ERC1967Proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        )));
        vm.prank(borrower);
        agentId = agentReg.registerAgent(0);
        vm.prank(borrower);
        agentReg.addWallet(agentId, creditWallet);

        // CreditRegistry
        address crProxy = Upgrades.deployUUPSProxy(
            "CreditRegistry.sol",
            abi.encodeCall(CreditRegistry.initialize,
                (owner, 5e6, 2500, 1000, 2000e6, 2000, 25_000e6, 500, 50e6, 50_000e6))
            , _opts()
        );

        creditReg = CreditRegistry(crProxy);

        // LoanRegistry
        address lrProxy = Upgrades.deployUUPSProxy(
            "LoanRegistry.sol",
            abi.encodeCall(LoanRegistry.initialize,
                (owner, address(creditReg), 1 days, 365 days, GRACE_PERIOD, APPROVAL_THRESHOLD))
        , _opts());
        loanReg = LoanRegistry(lrProxy);

        // RevenueRouter
        address rrProxy = Upgrades.deployUUPSProxy(
            "RevenueRouter.sol",
            abi.encodeCall(RevenueRouter.initialize,
                (owner, address(loanReg), address(creditReg), address(usdc)))
        , _opts());
        router = RevenueRouter(rrProxy);

        // CollateralVault (USDC auto-approved at init)
        address cvProxy = Upgrades.deployUUPSProxy(
            "CollateralVault.sol",
            abi.encodeCall(CollateralVault.initialize,
                (owner, address(usdc), address(loanReg), MAX_LTV_BPS))
        , _opts());
        vault = CollateralVault(cvProxy);

        // Approve EURC as collateral at 1.08 USD, 6 decimals
        vault.setAssetConfig(address(eurc), true, 6, EURC_PRICE_E18);

        // RecipientRegistry
        address rreg = Upgrades.deployUUPSProxy(
            "RecipientRegistry.sol",
            abi.encodeCall(RecipientRegistry.initialize, (owner))
            , _opts()
        );

        recipientReg = RecipientRegistry(rreg);

        // Wire
        loanReg.setContracts(loanVaultAddr, address(router));
        loanReg.setCollateralVault(address(vault));
        loanReg.setRecipientRegistry(address(recipientReg));
        loanReg.setAgentRegistry(address(agentReg));
        router.setAgentRegistry(address(agentReg));
        creditReg.setAuthorizedCaller(address(router), true);
        creditReg.setAuthorizedCaller(address(loanReg), true);

        recipientReg.approveRecipient(address(0xD00D), keccak256("COMPUTE"), "Provider");
        recipientReg.approveRecipient(creditWallet,    keccak256("COMPUTE"), "CreditWallet");

        usdc.mint(borrower, 20_000e6);
        eurc.mint(borrower, 20_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _proposal(uint256 collateralAmount, address collateralAsset)
        internal view returns (ILoanRegistry.LoanProposal memory)
    {
        ILoanRegistry.BudgetCategory[] memory budget = new ILoanRegistry.BudgetCategory[](1);
        budget[0] = ILoanRegistry.BudgetCategory({categoryId: keccak256("COMPUTE"), cap: PRINCIPAL});

        address[] memory recipients = new address[](2);
        recipients[0] = address(0xD00D);
        recipients[1] = creditWallet;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = PRINCIPAL;
        string[] memory descs = new string[](1);
        descs[0] = "Full release";

        return ILoanRegistry.LoanProposal({
            agentId:               agentId,
            creditWallet:          creditWallet,
            principal:             PRINCIPAL,
            repaymentRateBps:      1500,
            totalRepaymentDue:     1_150e6,
            duration:              30 days,
            purpose:               "Multi-asset collateral test",
            budget:                budget,
            permittedRecipients:   recipients,
            milestoneAmounts:      amounts,
            milestoneDescriptions: descs,
            collateralAmount:      collateralAmount,
            collateralAsset:       collateralAsset,
            underwriter:           address(0),
            underwriterAmount:     0,
            directDisbursement:    false
        });
    }

    // -------------------------------------------------------------------------
    // Asset config tests
    // -------------------------------------------------------------------------

    function test_UsdcApprovedAtInit() public view {
        (bool approved, uint8 decimals, uint256 price) = vault.assetConfigs(address(usdc));
        assertTrue(approved);
        assertEq(decimals, 6);
        assertEq(price, 1e18);
    }

    function test_EurcApprovedAfterSetConfig() public view {
        (bool approved, uint8 decimals, uint256 price) = vault.assetConfigs(address(eurc));
        assertTrue(approved);
        assertEq(decimals, 6);
        assertEq(price, EURC_PRICE_E18);
    }

    function test_SetAssetConfigRevertsForUnapprovedZeroPrice() public {
        address fakeToken = address(0x1234);
        vm.expectRevert(CollateralVault.ZeroPrice.selector);
        vault.setAssetConfig(fakeToken, true, 6, 0);
    }

    function test_SetAssetConfigCanDisableAsset() public {
        vault.setAssetConfig(address(eurc), false, 6, EURC_PRICE_E18);
        (bool approved,,) = vault.assetConfigs(address(eurc));
        assertFalse(approved);
    }

    function test_OnlyOwnerCanSetAssetConfig() public {
        vm.prank(borrower);
        vm.expectRevert();
        vault.setAssetConfig(address(eurc), true, 6, EURC_PRICE_E18);
    }

    // -------------------------------------------------------------------------
    // requiredCollateral math
    // -------------------------------------------------------------------------

    function test_RequiredCollateralUsdc() public view {
        // principal = 1 000 USDC, maxLTV = 66%  =>  required = 1000 * 10000 / 6600 = 1515.15... = 1515
        uint256 expected = (PRINCIPAL * 10000) / MAX_LTV_BPS;
        assertEq(vault.requiredCollateral(PRINCIPAL, address(usdc)), expected);
        assertEq(vault.requiredCollateral(PRINCIPAL), expected); // backwards-compat overload
    }

    function test_RequiredCollateralEurc() public view {
        // EURC at 1.08 USD => less EURC needed than USDC for same principal
        // required_usdc6 = 1000e6 * 10000 / 6600 = 1515151515
        // required_eurc  = 1515151515 * 1e18 * 1e6 / (1.08e18 * 1e6)
        //                = 1515151515 / 1.08 = 1402918069
        uint256 requiredUsdc = (PRINCIPAL * 10000) / MAX_LTV_BPS;
        uint256 expectedEurc = (requiredUsdc * 1e18 * 1e6) / (EURC_PRICE_E18 * 1e6);
        assertEq(vault.requiredCollateral(PRINCIPAL, address(eurc)), expectedEurc);
        // EURC requirement must be strictly less than USDC requirement
        assertLt(expectedEurc, requiredUsdc);
    }

    function test_RequiredCollateralRevertsForUnapprovedAsset() public {
        address rando = address(0xABCD);
        vm.expectRevert(CollateralVault.UnapprovedAsset.selector);
        vault.requiredCollateral(PRINCIPAL, rando);
    }

    // -------------------------------------------------------------------------
    // USDC collateral — deposit / withdraw / reserve
    // -------------------------------------------------------------------------

    function test_DepositUsdcNewSignature() public {
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), 500e6);
        assertEq(vault.availableBalance(borrower, address(usdc)), 500e6);
    }

    function test_DepositUsdcLegacySignature() public {
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(500e6);  // uint256-only overload
        assertEq(vault.availableBalance(borrower, address(usdc)), 500e6);
    }

    function test_WithdrawUsdcNewSignature() public {
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), 500e6);
        vm.prank(borrower);
        vault.withdrawCollateral(address(usdc), 200e6);
        assertEq(vault.availableBalance(borrower, address(usdc)), 300e6);
    }

    function test_WithdrawUsdcLegacySignature() public {
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(500e6);
        vm.prank(borrower);
        vault.withdrawCollateral(200e6);
        assertEq(vault.availableBalance(borrower, address(usdc)), 300e6);
    }

    function test_DepositUnapprovedAssetReverts() public {
        address rando = address(0xDEAD);
        vm.prank(borrower);
        vm.expectRevert(CollateralVault.UnapprovedAsset.selector);
        vault.depositCollateral(rando, 100e6);
    }

    // -------------------------------------------------------------------------
    // EURC collateral — deposit / withdraw
    // -------------------------------------------------------------------------

    function test_DepositEurc() public {
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), 1_000e6);
        assertEq(vault.availableBalance(borrower, address(eurc)), 1_000e6);
    }

    function test_WithdrawEurc() public {
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), 1_000e6);
        vm.prank(borrower);
        vault.withdrawCollateral(address(eurc), 400e6);
        assertEq(vault.availableBalance(borrower, address(eurc)), 600e6);
    }

    function test_UsdcAndEurcBalancesAreIndependent() public {
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), 500e6);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), 300e6);
        assertEq(vault.availableBalance(borrower, address(usdc)), 500e6);
        assertEq(vault.availableBalance(borrower, address(eurc)), 300e6);
    }

    // -------------------------------------------------------------------------
    // USDC collateral-backed loan (via LoanRegistry, zero address = default USDC)
    // -------------------------------------------------------------------------

    function test_UsdcCollateralLoanViaZeroAssetDefaultsToUsdc() public {
        uint256 required = vault.requiredCollateral(PRINCIPAL, address(usdc));
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), required);

        // collateralAsset = address(0) — should resolve to USDC
        vm.prank(borrower);
        uint256 loanId = loanReg.requestLoan(_proposal(required, address(0)));

        assertEq(loanReg.getCollateralAsset(loanId), address(usdc));
        assertEq(uint8(loanReg.getLoan(loanId).status), uint8(ILoanRegistry.LoanStatus.Requested));
        assertEq(vault.availableBalance(borrower, address(usdc)), 0);
    }

    function test_UsdcCollateralLoanViaExplicitAsset() public {
        uint256 required = vault.requiredCollateral(PRINCIPAL, address(usdc));
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), required);

        vm.prank(borrower);
        uint256 loanId = loanReg.requestLoan(_proposal(required, address(usdc)));

        assertEq(loanReg.getCollateralAsset(loanId), address(usdc));
        assertEq(uint8(loanReg.getLoan(loanId).status), uint8(ILoanRegistry.LoanStatus.Requested));
    }

    function test_UsdcCollateralReleasedOnRepayment() public {
        uint256 required = vault.requiredCollateral(PRINCIPAL, address(usdc));
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), required);

        vm.prank(borrower);
        uint256 loanId = loanReg.requestLoan(_proposal(required, address(usdc)));
        vm.prank(loanVaultAddr);
        loanReg.markFunded(loanId, lender);

        // Full repayment via repayLoan (borrower self-repay, triggers collateral release)
        uint256 repayAmt = 1_150e6; // principal 1000 + 15% interest
        usdc.mint(borrower, repayAmt);
        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);
        uint256 balBefore = usdc.balanceOf(borrower); // captured after mint, before repay
        vm.prank(borrower);
        router.repayLoan(loanId, repayAmt);

        // Collateral released back to borrower: balance should recover the required USDC
        assertEq(usdc.balanceOf(borrower), balBefore - repayAmt + required);
    }

    function test_UsdcCollateralSeizedOnDefault() public {
        uint256 required = vault.requiredCollateral(PRINCIPAL, address(usdc));
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), required);

        vm.prank(borrower);
        uint256 loanId = loanReg.requestLoan(_proposal(required, address(usdc)));
        vm.prank(loanVaultAddr);
        loanReg.markFunded(loanId, lender);

        ILoanRegistry.LoanView memory loan = loanReg.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE_PERIOD + 1);

        uint256 lenderBefore = usdc.balanceOf(lender);
        loanReg.markDefault(loanId);
        assertEq(usdc.balanceOf(lender) - lenderBefore, required);
    }

    // -------------------------------------------------------------------------
    // EURC collateral-backed loan
    // -------------------------------------------------------------------------

    function test_EurcCollateralLoanSucceeds() public {
        uint256 required = vault.requiredCollateral(PRINCIPAL, address(eurc));
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), required);

        vm.prank(borrower);
        uint256 loanId = loanReg.requestLoan(_proposal(required, address(eurc)));

        assertEq(loanReg.getCollateralAsset(loanId), address(eurc));
        assertEq(uint8(loanReg.getLoan(loanId).status), uint8(ILoanRegistry.LoanStatus.Requested));
        assertEq(vault.availableBalance(borrower, address(eurc)), 0);
    }

    function test_EurcCollateralRequiresLessTokensThanUsdc() public view {
        uint256 eurcReq  = vault.requiredCollateral(PRINCIPAL, address(eurc));
        uint256 usdcReq  = vault.requiredCollateral(PRINCIPAL, address(usdc));
        assertLt(eurcReq, usdcReq, "EURC collateral should be less than USDC due to higher USD value");
    }

    function test_EurcCollateralReleasedOnRepayment() public {
        uint256 required = vault.requiredCollateral(PRINCIPAL, address(eurc));
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), required);

        vm.prank(borrower);
        uint256 loanId = loanReg.requestLoan(_proposal(required, address(eurc)));
        vm.prank(loanVaultAddr);
        loanReg.markFunded(loanId, lender);

        // Full USDC repayment via repayLoan (borrower self-repay, triggers EURC collateral release)
        uint256 repayAmt = 1_150e6;
        usdc.mint(borrower, repayAmt);
        vm.prank(borrower);
        usdc.approve(address(router), type(uint256).max);
        uint256 eurcBefore = eurc.balanceOf(borrower); // captured after EURC deposit, before repay
        vm.prank(borrower);
        router.repayLoan(loanId, repayAmt);

        // EURC collateral returned to borrower in EURC
        assertEq(eurc.balanceOf(borrower), eurcBefore + required);
    }

    function test_EurcCollateralSeizedToLenderInEurc() public {
        uint256 required = vault.requiredCollateral(PRINCIPAL, address(eurc));
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), required);

        vm.prank(borrower);
        uint256 loanId = loanReg.requestLoan(_proposal(required, address(eurc)));
        vm.prank(loanVaultAddr);
        loanReg.markFunded(loanId, lender);

        ILoanRegistry.LoanView memory loan = loanReg.getLoan(loanId);
        vm.warp(loan.expiresAt + GRACE_PERIOD + 1);

        uint256 eurcBefore = eurc.balanceOf(lender);
        uint256 usdcBefore = usdc.balanceOf(lender);
        loanReg.markDefault(loanId);

        // Lender receives EURC, not USDC
        assertEq(eurc.balanceOf(lender) - eurcBefore, required, "lender should receive EURC");
        assertEq(usdc.balanceOf(lender), usdcBefore, "lender USDC balance must not change on EURC seizure");
    }

    function test_EurcBelowLtvRevertsOnReserve() public {
        uint256 required = vault.requiredCollateral(PRINCIPAL, address(eurc));
        uint256 tooLittle = required - 1;
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), tooLittle);

        vm.prank(borrower);
        vm.expectRevert(CollateralVault.InsufficientCollateralForLTV.selector);
        loanReg.requestLoan(_proposal(tooLittle, address(eurc)));
    }

    function test_EurcCollateralBypassesCreditLimit() public {
        // Agent has no credit history; credit limit = 5e6 (5 USDC).
        // PRINCIPAL = 1000 USDC, well above credit limit.
        assertLt(creditReg.getLimit(agentId), PRINCIPAL);

        uint256 required = vault.requiredCollateral(PRINCIPAL, address(eurc));
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), required);

        vm.prank(borrower);
        uint256 loanId = loanReg.requestLoan(_proposal(required, address(eurc)));
        assertEq(uint8(loanReg.getLoan(loanId).status), uint8(ILoanRegistry.LoanStatus.Requested));
    }

    function test_DisabledEurcRevertsDeposit() public {
        vault.setAssetConfig(address(eurc), false, 6, EURC_PRICE_E18);
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vm.expectRevert(CollateralVault.UnapprovedAsset.selector);
        vault.depositCollateral(address(eurc), 100e6);
    }

    function test_DisabledEurcRevertsReserveCollateral() public {
        // Deposit before disabling
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), 2_000e6);

        // Disable EURC
        vault.setAssetConfig(address(eurc), false, 6, EURC_PRICE_E18);

        // Try to request loan with EURC — should fail at vault.reserveCollateral
        vm.prank(borrower);
        vm.expectRevert(CollateralVault.UnapprovedAsset.selector);
        loanReg.requestLoan(_proposal(1_500e6, address(eurc)));
    }

    // -------------------------------------------------------------------------
    // Mixed-asset independence
    // -------------------------------------------------------------------------

    function test_UsdcAndEurcLoansAreIndependent() public {
        // Loan 0: USDC collateral
        uint256 usdcReq = vault.requiredCollateral(PRINCIPAL, address(usdc));
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(usdc), usdcReq);

        // Loan 1: EURC collateral
        uint256 eurcReq = vault.requiredCollateral(PRINCIPAL, address(eurc));
        vm.prank(borrower);
        eurc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        vault.depositCollateral(address(eurc), eurcReq);

        vm.prank(borrower);
        uint256 loan0 = loanReg.requestLoan(_proposal(usdcReq, address(usdc)));
        vm.prank(borrower);
        uint256 loan1 = loanReg.requestLoan(_proposal(eurcReq, address(eurc)));

        assertEq(loanReg.getCollateralAsset(loan0), address(usdc));
        assertEq(loanReg.getCollateralAsset(loan1), address(eurc));
        assertEq(vault.availableBalance(borrower, address(usdc)), 0);
        assertEq(vault.availableBalance(borrower, address(eurc)), 0);
    }

    // -------------------------------------------------------------------------
    // Price update
    // -------------------------------------------------------------------------

    function test_PriceUpdateChangesRequiredCollateral() public {
        uint256 reqBefore = vault.requiredCollateral(PRINCIPAL, address(eurc));

        // Update price to 1.10 USD per EURC
        vault.setAssetConfig(address(eurc), true, 6, 1_100_000_000_000_000_000);
        uint256 reqAfter = vault.requiredCollateral(PRINCIPAL, address(eurc));

        // Higher price => less EURC required
        assertLt(reqAfter, reqBefore, "higher EURC price => less collateral needed");
    }

    // -------------------------------------------------------------------------
    // Finding 4 — oracle price bounds
    // -------------------------------------------------------------------------

    function test_PriceBelowMinReverts() public {
        // 0.49e18 < 0.5e18 minimum → must revert
        vm.expectRevert(CollateralVault.PriceOutOfBounds.selector);
        vault.setAssetConfig(address(eurc), true, 6, 0.49e18);
    }

    function test_PriceAboveMaxReverts() public {
        // 100.01e18 > 100e18 maximum → must revert
        vm.expectRevert(CollateralVault.PriceOutOfBounds.selector);
        vault.setAssetConfig(address(eurc), true, 6, 100.01e18);
    }

    function test_PriceAtMinBoundarySucceeds() public {
        // Exactly 0.5e18 is allowed
        vault.setAssetConfig(address(eurc), true, 6, 0.5e18);
        (bool approved,, uint256 price) = vault.assetConfigs(address(eurc));
        assertTrue(approved);
        assertEq(price, 0.5e18);
    }

    function test_PriceAtMaxBoundarySucceeds() public {
        // Exactly 100e18 is allowed
        vault.setAssetConfig(address(eurc), true, 6, 100e18);
        (bool approved,, uint256 price) = vault.assetConfigs(address(eurc));
        assertTrue(approved);
        assertEq(price, 100e18);
    }

    function test_EurcPriceSucceeds() public {
        // 1.08e18 is within bounds
        vault.setAssetConfig(address(eurc), true, 6, 1.08e18);
        (, , uint256 price) = vault.assetConfigs(address(eurc));
        assertEq(price, 1.08e18);
    }

    function test_UsdcCollateralMathUnchanged() public {
        // USDC stays at price 1e18 — existing LTV math must not change
        uint256 req = vault.requiredCollateral(1_000e6, address(usdc));
        // (1_000e6 * 10000) / 6600 = 1_515_151_515
        assertEq(req, (1_000e6 * 10000) / MAX_LTV_BPS);
    }

    function test_PriceBoundsDoNotApplyOnDisable() public {
        // Disabling an asset (approved=false) skips the bounds check
        // regardless of the price value passed — the price is irrelevant
        // for a disabled asset.
        vault.setAssetConfig(address(eurc), false, 6, 0);  // zero price, disabled → must not revert
        (bool approved,,) = vault.assetConfigs(address(eurc));
        assertFalse(approved);
    }
}
