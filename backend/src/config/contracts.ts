import "dotenv/config";
import type { Address } from "viem";

function requireAddress(envVar: string): Address {
  const value = process.env[envVar];
  if (!value) throw new Error(`Missing required env var: ${envVar}`);
  return value as Address;
}

function optionalAddress(envVar: string, fallback: string): Address {
  return (process.env[envVar] ?? fallback) as Address;
}

export const contracts = {
  agentRegistry:     requireAddress("AGENT_REGISTRY_ADDRESS"),
  loanRegistry:      requireAddress("LOAN_REGISTRY_ADDRESS"),
  loanVault:         requireAddress("LOAN_VAULT_ADDRESS"),
  creditRegistry:    requireAddress("CREDIT_REGISTRY_ADDRESS"),
  revenueRouter:     requireAddress("REVENUE_ROUTER_ADDRESS"),
  collateralVault:   requireAddress("COLLATERAL_VAULT_ADDRESS"),
  liquidityPool:     requireAddress("LIQUIDITY_POOL_ADDRESS"),
  underwriterPool:   requireAddress("UNDERWRITER_POOL_ADDRESS"),
  recipientRegistry: requireAddress("RECIPIENT_REGISTRY_ADDRESS"),
  reservePool:       requireAddress("RESERVE_POOL_ADDRESS"),
  activityAttester:  requireAddress("ACTIVITY_ATTESTER_ADDRESS"),
} as const;

// Arc Testnet USDC: system precompile, 6 decimals.
// arc-studio-allow-onchain-literal
export const USDC_ADDRESS: Address = "0x3600000000000000000000000000000000000000";

// EURC test token — address read from EURC_ADDRESS env var (see .env.example).
export const EURC_ADDRESS: Address = requireAddress("EURC_ADDRESS");
