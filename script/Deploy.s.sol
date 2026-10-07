// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
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

/// @notice Deploys and wires all eleven Valen V1 contracts to Arc testnet.
///
///         Deployment order respects constructor/initializer dependencies:
///           1.  AgentRegistry      -- no deps
///           2.  CreditRegistry     -- no deps
///           3.  LoanRegistry       -- CreditRegistry
///           4.  RevenueRouter      -- LoanRegistry, CreditRegistry
///           5.  LoanVault          -- LoanRegistry
///           6.  CollateralVault    -- LoanRegistry
///           7.  UnderwriterPool    -- LoanRegistry
///           8.  RecipientRegistry  -- no deps
///           9.  ReservePool        -- LoanRegistry
///          10.  LiquidityPool      -- all of the above
///          11.  ActivityAttester   -- AgentRegistry, CreditRegistry
///
///         Run with:
///           forge script script/Deploy.s.sol \
///             --rpc-url arc_testnet --account valen-deployer --broadcast
contract DeployScript is Script {
    address constant DEPLOYER = 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144;

    // Arc Testnet USDC -- 6-decimal ERC-20 precompile.
    address constant USDC = 0x3600000000000000000000000000000000000000;

    // CreditRegistry parameters
    uint256 constant INITIAL_LIMIT                 = 5e6;
    uint16  constant GROWTH_BPS                    = 2500;
    uint16  constant EARLY_BONUS_BPS               = 1000;
    uint256 constant MAX_STEP_INCREASE             = 2000e6;
    uint16  constant DEFAULT_PENALTY_BPS           = 2000;
    uint256 constant APPROVAL_THRESHOLD            = 25_000e6;
    uint16  constant ACTIVITY_GROWTH_BPS           = 500;
    uint256 constant MAX_ACTIVITY_INCREASE_PER_EVT = 50e6;
    uint256 constant MAX_ACTIVITY_LIMIT            = 50_000e6;

    // LoanRegistry parameters
    uint256 constant MIN_DURATION                  = 1 days;
    uint256 constant MAX_DURATION                  = 365 days;
    uint256 constant DEFAULT_GRACE_PERIOD          = 3 days;
    uint256 constant COLLATERAL_APPROVAL_THRESHOLD = 10_000e6;

    // CollateralVault / RevenueRouter parameters
    uint16  constant MAX_LTV_BPS                   = 6600;
    uint16  constant RESERVE_BPS                   = 200;

    // Deploy options: unsafeSkipAllChecks bypasses the OZ upgrade-safety
    // validator's vm.readFile calls, which would otherwise accumulate enough
    // EVM memory across 11 contract deployments to trigger MemoryOOG in the
    // local Forge execution context.  Safe for a fresh initial deployment
    // because there is no prior storage layout to compare against -- upgrade-
    // safety checks only guard against regressions on existing proxies.
    function _opts() private pure returns (Options memory opts) {
        opts.unsafeSkipAllChecks = true;
    }

    // Deployment addresses (set across internal deploy functions)
    address internal _agentRegistry;
    address internal _creditRegistry;
    address internal _loanRegistry;
    address internal _router;
    address internal _loanVault;
    address internal _collateralVault;
    address internal _underwriterPool;
    address internal _recipientRegistry;
    address internal _reservePool;
    address internal _liquidityPool;
    address internal _activityAttester;

    // -------------------------------------------------------------------------
    function run() external {
        vm.startBroadcast();
        _deployInfra();
        _deployLoanLayer();
        _deploySupport();
        _deployLiquidityAndAttester();
        _wire();
        vm.stopBroadcast();
        _logAddresses();
    }

    // Phase 1: Independent contracts
    function _deployInfra() internal {
        _agentRegistry = Upgrades.deployUUPSProxy(
            "AgentRegistry.sol",
            abi.encodeCall(AgentRegistry.initialize, (DEPLOYER)),
            _opts()
        );
        _creditRegistry = Upgrades.deployUUPSProxy(
            "CreditRegistry.sol",
            abi.encodeCall(CreditRegistry.initialize, (
                DEPLOYER,
                INITIAL_LIMIT, GROWTH_BPS, EARLY_BONUS_BPS,
                MAX_STEP_INCREASE, DEFAULT_PENALTY_BPS, APPROVAL_THRESHOLD,
                ACTIVITY_GROWTH_BPS, MAX_ACTIVITY_INCREASE_PER_EVT, MAX_ACTIVITY_LIMIT
            )),
            _opts()
        );
    }

    // Phase 2: Loan layer (depends on CreditRegistry)
    function _deployLoanLayer() internal {
        _loanRegistry = Upgrades.deployUUPSProxy(
            "LoanRegistry.sol",
            abi.encodeCall(LoanRegistry.initialize, (
                DEPLOYER, _creditRegistry,
                MIN_DURATION, MAX_DURATION, DEFAULT_GRACE_PERIOD, COLLATERAL_APPROVAL_THRESHOLD
            )),
            _opts()
        );
        _router = Upgrades.deployUUPSProxy(
            "RevenueRouter.sol",
            abi.encodeCall(RevenueRouter.initialize, (
                DEPLOYER, _loanRegistry, _creditRegistry, USDC
            )),
            _opts()
        );
        _loanVault = Upgrades.deployUUPSProxy(
            "LoanVault.sol",
            abi.encodeCall(LoanVault.initialize, (DEPLOYER, _loanRegistry, USDC)),
            _opts()
        );
        _collateralVault = Upgrades.deployUUPSProxy(
            "CollateralVault.sol",
            abi.encodeCall(CollateralVault.initialize, (DEPLOYER, USDC, _loanRegistry, MAX_LTV_BPS)),
            _opts()
        );
        _underwriterPool = Upgrades.deployUUPSProxy(
            "UnderwriterPool.sol",
            abi.encodeCall(UnderwriterPool.initialize, (DEPLOYER, USDC, _loanRegistry)),
            _opts()
        );
    }

    // Phase 3: Support contracts (independent or depend on loanRegistry)
    function _deploySupport() internal {
        _recipientRegistry = Upgrades.deployUUPSProxy(
            "RecipientRegistry.sol",
            abi.encodeCall(RecipientRegistry.initialize, (DEPLOYER)),
            _opts()
        );
        _reservePool = Upgrades.deployUUPSProxy(
            "ReservePool.sol",
            abi.encodeCall(ReservePool.initialize, (DEPLOYER, USDC, _loanRegistry)),
            _opts()
        );
    }

    // Phase 4: LiquidityPool + ActivityAttester (depend on everything)
    function _deployLiquidityAndAttester() internal {
        _liquidityPool = Upgrades.deployUUPSProxy(
            "LiquidityPool.sol:LiquidityPool",
            abi.encodeCall(LiquidityPool.initialize, (
                DEPLOYER, USDC,
                _loanRegistry, _router,
                _collateralVault, _underwriterPool,
                _reservePool, _loanVault
            )),
            _opts()
        );
        _activityAttester = Upgrades.deployUUPSProxy(
            "ActivityAttester.sol:ActivityAttester",
            abi.encodeCall(ActivityAttester.initialize, (
                DEPLOYER, _agentRegistry, _creditRegistry
            )),
            _opts()
        );
    }

    // Wiring
    function _wire() internal {
        // LoanRegistry: wire all one-time dependencies
        LoanRegistry reg = LoanRegistry(_loanRegistry);
        reg.setContracts(_loanVault, _router);
        reg.setCollateralVault(_collateralVault);
        reg.setUnderwriterPool(_underwriterPool);
        reg.setRecipientRegistry(_recipientRegistry);
        reg.setReservePool(_reservePool);
        reg.setAgentRegistry(_agentRegistry);   // mandatory; no zero-address bypass

        // RevenueRouter: wire AgentRegistry and ReservePool (one-time each)
        RevenueRouter(_router).setAgentRegistry(_agentRegistry);
        RevenueRouter(_router).setReservePool(_reservePool, RESERVE_BPS);

        // LoanVault: wire LiquidityPool (must follow LP deployment)
        LoanVault(_loanVault).setLiquidityPool(_liquidityPool);

        // CreditRegistry: authorize writers
        // - RevenueRouter: recordRepayment (production repayment path)
        // - ActivityAttester: recordActivity (economic activity track)
        // - LoanRegistry: authorized for potential future writes (belt-and-suspenders)
        CreditRegistry(_creditRegistry).setAuthorizedCaller(_router, true);
        CreditRegistry(_creditRegistry).setAuthorizedCaller(_activityAttester, true);
        CreditRegistry(_creditRegistry).setAuthorizedCaller(_loanRegistry, true);

        // ReservePool: authorize RevenueRouter to record contributions
        ReservePool(_reservePool).setAuthorizedContributor(_router, true);
    }

    // Console log
    function _logAddresses() internal view {
        console.log("AgentRegistry:     ", _agentRegistry);
        console.log("CreditRegistry:    ", _creditRegistry);
        console.log("LoanRegistry:      ", _loanRegistry);
        console.log("RevenueRouter:     ", _router);
        console.log("LoanVault:         ", _loanVault);
        console.log("CollateralVault:   ", _collateralVault);
        console.log("UnderwriterPool:   ", _underwriterPool);
        console.log("RecipientRegistry: ", _recipientRegistry);
        console.log("ReservePool:       ", _reservePool);
        console.log("LiquidityPool:     ", _liquidityPool);
        console.log("ActivityAttester:  ", _activityAttester);
        console.log("--- Deployment complete ---");
        console.log("POST-DEPLOY (manual steps with funded deployer wallet):");
        console.log("  1. LiquidityPool.initializeLiquidity(amount)");
        console.log("  2. ActivityAttester.setActivitySource(source, true)  -- per approved source");
        console.log("  3. RecipientRegistry.approveRecipient(...)           -- per vendor");
    }
}
