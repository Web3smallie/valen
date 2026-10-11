/**
 * Formatting helpers for amounts and addresses.
 * All BigInt amounts are 6-decimal USDC/EURC unless stated otherwise.
 * We never route through JS floating-point for large uint256 values.
 */

const DECIMALS = 6n;
const SCALE    = 10n ** DECIMALS;

/** Format a raw 6-decimal uint256 to a human-readable string like "10.500000". */
export function formatUnits6(raw: bigint): string {
  const whole = raw / SCALE;
  const frac  = raw % SCALE;
  return `${whole}.${frac.toString().padStart(6, "0")}`;
}

/** Loan status enum (must match ILoanRegistry.LoanStatus order). */
export const LOAN_STATUS: Record<number, string> = {
  0: "Requested",
  1: "PendingApproval",
  2: "Approved",
  3: "Rejected",
  4: "Active",
  5: "Repaid",
  6: "Defaulted",
  7: "Cancelled",
};

export function loanStatusName(status: number): string {
  return LOAN_STATUS[status] ?? `Unknown(${status})`;
}

/** Validate a hex address string. Returns lowercased if valid, throws otherwise. */
export function validateAddress(value: string, field = "address"): `0x${string}` {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new ValidationError(`Invalid ${field}: "${value}"`);
  }
  return value.toLowerCase() as `0x${string}`;
}

/** Validate a non-negative integer string (loanId, agentId). */
export function validateUint(value: string, field = "value"): bigint {
  if (!/^\d+$/.test(value)) throw new ValidationError(`${field} must be a non-negative integer`);
  const n = BigInt(value);
  return n;
}

/** Validate a hex bytes32 string (activityHash). */
export function validateBytes32(value: string, field = "hash"): `0x${string}` {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new ValidationError(`Invalid ${field}: "${value}"`);
  }
  return value.toLowerCase() as `0x${string}`;
}

export class ValidationError extends Error {
  readonly statusCode = 400;
  constructor(msg: string) { super(msg); this.name = "ValidationError"; }
}
