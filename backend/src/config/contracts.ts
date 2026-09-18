import "dotenv/config";
import type { Address } from "viem";

function requireAddress(envVar: string): Address {
  const value = process.env[envVar];
  if (!value) throw new Error(`Missing required env var: ${envVar}`);
  return value as Address;
}

export const contracts = {
  loanRegistry: requireAddress("LOAN_REGISTRY_ADDRESS"),
  loanVault: requireAddress("LOAN_VAULT_ADDRESS"),
  creditRegistry: requireAddress("CREDIT_REGISTRY_ADDRESS"),
  revenueRouter: requireAddress("REVENUE_ROUTER_ADDRESS"),
  collateralVault: requireAddress("COLLATERAL_VAULT_ADDRESS"),
  underwriterPool: requireAddress("UNDERWRITER_POOL_ADDRESS"),
  recipientRegistry: requireAddress("RECIPIENT_REGISTRY_ADDRESS"),
  reservePool: requireAddress("RESERVE_POOL_ADDRESS"),
} as const;

// Arc Testnet's USDC ERC-20 interface — a system precompile, 6 decimals
// (distinct from the 18-decimal native/gas view used in arc.ts).
export const USDC_ADDRESS: Address = "0x3600000000000000000000000000000000000000";