import "dotenv/config";
import type { Address } from "viem";
import { getManifest, type Manifest } from "./manifest.js";

/**
 * Contract addresses resolve from the deployment manifest
 * (deployments/<DEPLOYMENT>.json) — the single source of truth.
 * There are no per-address environment overrides by design.
 */
export const manifest: Manifest = getManifest();

export const contracts = {
  agentRegistry:     manifest.contracts.agentRegistry.address,
  loanRegistry:      manifest.contracts.loanRegistry.address,
  loanVault:         manifest.contracts.loanVault.address,
  creditRegistry:    manifest.contracts.creditRegistry.address,
  revenueRouter:     manifest.contracts.revenueRouter.address,
  collateralVault:   manifest.contracts.collateralVault.address,
  liquidityPool:     manifest.contracts.liquidityPool.address,
  underwriterPool:   manifest.contracts.underwriterPool.address,
  recipientRegistry: manifest.contracts.recipientRegistry.address,
  reservePool:       manifest.contracts.reservePool.address,
  activityAttester:  manifest.contracts.activityAttester.address,
} as const;

// Arc Testnet USDC: system precompile, 6 decimals.
// arc-studio-allow-onchain-literal
export const USDC_ADDRESS: Address = manifest.tokens.usdc.address;

// EURC test token — address from the deployment manifest.
export const EURC_ADDRESS: Address = manifest.tokens.eurc.address;

// LoanRegistry ABI target from the deployment manifest.
export const ABI_VERSION = manifest.abiVersion;
