// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {RecipientRegistry} from "../src/RecipientRegistry.sol";
import {ReservePool} from "../src/ReservePool.sol";

/// @notice Deploys and wires all eight Valen contracts to Arc testnet.
///         Run with:
///         forge script script/Deploy.s.sol --rpc-url arc_testnet --account valen-deployer --broadcast
contract DeployScript is Script {
    address constant DEPLOYER = 0xB0E8Ba6aFe21371AD4001e611224FC200FD10144;

    // Arc Testnet's USDC ERC-20 interface — a system precompile, not a
    // regular deployed token. 6 decimals via this interface (NOT the
    // 18-decimal native/gas view — see docs.arc.io/arc/references/contract-addresses).
    address constant USDC = 0x3600000000000000000000000000000000000000;

    uint256 constant INITIAL_LIMIT = 5e6;
    uint16 constant GROWTH_BPS = 2500;
    uint16 constant EARLY_BONUS_BPS = 1000;
    uint256 constant MAX_STEP_INCREASE = 2000e6;
    uint16 constant DEFAULT_PENALTY_BPS = 2000;
    uint256 constant APPROVAL_THRESHOLD = 25_000e6;

    uint256 constant MIN_DURATION = 1 days;
    uint256 constant MAX_DURATION = 365 days;
    uint256 constant DEFAULT_GRACE_PERIOD = 3 days;
    uint256 constant COLLATERAL_APPROVAL_THRESHOLD = 10_000e6;

    uint16 constant MAX_LTV_BPS = 6600;
    uint16 constant RESERVE_BPS = 200;

    function run() external {
        vm.startBroadcast();

        // 1. CreditRegistry — no dependencies
        address creditRegistryProxy = Upgrades.deployUUPSProxy(
            "CreditRegistry.sol",
            abi.encodeCall(
                CreditRegistry.initialize,
                (DEPLOYER, INITIAL_LIMIT, GROWTH_BPS, EARLY_BONUS_BPS, MAX_STEP_INCREASE, DEFAULT_PENALTY_BPS, APPROVAL_THRESHOLD)
            )
        );
        CreditRegistry creditRegistry = CreditRegistry(creditRegistryProxy);
        console.log("CreditRegistry:", creditRegistryProxy);

        // 2. LoanRegistry — depends on CreditRegistry
        address loanRegistryProxy = Upgrades.deployUUPSProxy(
            "LoanRegistry.sol",
            abi.encodeCall(
                LoanRegistry.initialize,
                (DEPLOYER, creditRegistryProxy, MIN_DURATION, MAX_DURATION, DEFAULT_GRACE_PERIOD, COLLATERAL_APPROVAL_THRESHOLD)
            )
        );
        LoanRegistry loanRegistry = LoanRegistry(loanRegistryProxy);
        console.log("LoanRegistry:", loanRegistryProxy);

        // 3. RevenueRouter — depends on LoanRegistry, CreditRegistry
        address routerProxy = Upgrades.deployUUPSProxy(
            "RevenueRouter.sol",
            abi.encodeCall(RevenueRouter.initialize, (DEPLOYER, loanRegistryProxy, creditRegistryProxy, USDC))
        );
        RevenueRouter router = RevenueRouter(routerProxy);
        console.log("RevenueRouter:", routerProxy);

        // 4. LoanVault — depends on LoanRegistry
        address loanVaultProxy = Upgrades.deployUUPSProxy(
            "LoanVault.sol",
            abi.encodeCall(LoanVault.initialize, (DEPLOYER, loanRegistryProxy, USDC))
        );
        console.log("LoanVault:", loanVaultProxy);

        // 5. CollateralVault — depends on LoanRegistry
        address collateralVaultProxy = Upgrades.deployUUPSProxy(
            "CollateralVault.sol",
            abi.encodeCall(CollateralVault.initialize, (DEPLOYER, USDC, loanRegistryProxy, MAX_LTV_BPS))
        );
        console.log("CollateralVault:", collateralVaultProxy);

        // 6. UnderwriterPool — depends on LoanRegistry
        address underwriterPoolProxy = Upgrades.deployUUPSProxy(
            "UnderwriterPool.sol",
            abi.encodeCall(UnderwriterPool.initialize, (DEPLOYER, USDC, loanRegistryProxy))
        );
        console.log("UnderwriterPool:", underwriterPoolProxy);

        // 7. RecipientRegistry — no dependencies
        address recipientRegistryProxy = Upgrades.deployUUPSProxy(
            "RecipientRegistry.sol",
            abi.encodeCall(RecipientRegistry.initialize, (DEPLOYER))
        );
        console.log("RecipientRegistry:", recipientRegistryProxy);

        // 8. ReservePool — depends on LoanRegistry
        address reservePoolProxy = Upgrades.deployUUPSProxy(
            "ReservePool.sol",
            abi.encodeCall(ReservePool.initialize, (DEPLOYER, USDC, loanRegistryProxy))
        );
        ReservePool reservePool = ReservePool(reservePoolProxy);
        console.log("ReservePool:", reservePoolProxy);

        // --- Wiring ---
        loanRegistry.setContracts(loanVaultProxy, routerProxy);
        loanRegistry.setCollateralVault(collateralVaultProxy);
        loanRegistry.setUnderwriterPool(underwriterPoolProxy);
        loanRegistry.setRecipientRegistry(recipientRegistryProxy);
        loanRegistry.setReservePool(reservePoolProxy);

        creditRegistry.setAuthorizedCaller(routerProxy, true);
        creditRegistry.setAuthorizedCaller(loanRegistryProxy, true);

        reservePool.setAuthorizedContributor(routerProxy, true);
        router.setReservePool(reservePoolProxy, RESERVE_BPS);

        vm.stopBroadcast();

        console.log("--- Deployment complete ---");
    }
}