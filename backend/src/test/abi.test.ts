/**
 * ABI-shape tests — guards against contract drift that mocked route tests
 * cannot see. If any of these fail, a contract changed and the backend's
 * ABIs, event fragments, or enum maps must be regenerated from out/.
 */
import { describe, it, expect, vi } from "vitest";
import { getEventSelector, type AbiEvent } from "viem";

// No env stubbing: contract addresses resolve from the real deployment
// manifest (deployments/arc-testnet.json).

import { LOAN_STATUS } from "../lib/format.js";
import { LoanRegistryAbi } from "../abis/LoanRegistry.js";
import { LoanRegistryDeployedAbi } from "../abis/LoanRegistryDeployed.js";
import { CreditRegistryAbi } from "../abis/CreditRegistry.js";
import { CollateralVaultAbi } from "../abis/CollateralVault.js";

type AbiEntry = {
  type?: string;
  name?: string;
  inputs?: ReadonlyArray<{
    name?: string;
    type?: string;
    indexed?: boolean;
    components?: ReadonlyArray<{ name?: string }>;
  }>;
  outputs?: ReadonlyArray<{ name?: string; type?: string }>;
};

function asEntries(abi: readonly unknown[]): readonly AbiEntry[] {
  return abi as unknown as readonly AbiEntry[];
}

function findFn(abi: readonly unknown[], name: string): AbiEntry {
  const e = asEntries(abi).find((x) => x.type === "function" && x.name === name);
  if (!e) throw new Error(`function ${name} missing from ABI`);
  return e;
}

function findEvent(abi: readonly unknown[], name: string): AbiEntry {
  const e = asEntries(abi).find((x) => x.type === "event" && x.name === name);
  if (!e) throw new Error(`event ${name} missing from ABI`);
  return e;
}

// Canonical LoanRequested per LoanRegistry.sol — note there is NO agentId.
const CANONICAL_LOAN_REQUESTED = [
  { name: "loanId", type: "uint256", indexed: true },
  { name: "borrower", type: "address", indexed: true },
  { name: "principal", type: "uint256", indexed: false },
  { name: "initialStatus", type: "uint8", indexed: false },
];

describe("LoanRequested event fragment", () => {
  it("shared fragment selector matches LoanRegistryAbi", async () => {
    const { LOAN_REQUESTED_EVENT } = await import("../lib/loanEvents.js");
    const fromAbi = findEvent(LoanRegistryAbi, "LoanRequested");
    expect(getEventSelector(LOAN_REQUESTED_EVENT as AbiEvent)).toBe(
      getEventSelector(fromAbi as unknown as AbiEvent)
    );
  });

  it("shared fragment selector matches LoanRegistryDeployedAbi", async () => {
    const { LOAN_REQUESTED_EVENT } = await import("../lib/loanEvents.js");
    const fromAbi = findEvent(LoanRegistryDeployedAbi, "LoanRequested");
    expect(getEventSelector(LOAN_REQUESTED_EVENT as AbiEvent)).toBe(
      getEventSelector(fromAbi as unknown as AbiEvent)
    );
  });

  it("is the canonical (loanId, borrower, principal, initialStatus) shape", async () => {
    const { LOAN_REQUESTED_EVENT } = await import("../lib/loanEvents.js");
    expect(LOAN_REQUESTED_EVENT.inputs).toEqual(CANONICAL_LOAN_REQUESTED);
  });
});

describe("requestLoan proposal versioning", () => {
  it("deployed ABI is 15-field without directDisbursement", () => {
    const fn = findFn(LoanRegistryDeployedAbi, "requestLoan");
    const fields = fn.inputs?.[0]?.components?.map((c) => c.name) ?? [];
    expect(fields).toHaveLength(15);
    expect(fields).not.toContain("directDisbursement");
  });

  it("V4 ABI is 16-field with directDisbursement last", () => {
    const fn = findFn(LoanRegistryAbi, "requestLoan");
    const fields = fn.inputs?.[0]?.components?.map((c) => c.name) ?? [];
    expect(fields).toHaveLength(16);
    expect(fields[15]).toBe("directDisbursement");
  });
});

describe("CreditRegistry ABI", () => {
  it("credits is keyed by uint256 with the 6-field AgentCredit", () => {
    const fn = findFn(CreditRegistryAbi, "credits");
    expect(fn.inputs?.map((i) => i.type)).toEqual(["uint256"]);
    expect(fn.outputs?.map((o) => `${o.name}:${o.type}`)).toEqual([
      "currentLimit:uint256",
      "loansRepaid:uint256",
      "loansDefaulted:uint256",
      "exists:bool",
      "activityLimit:uint256",
      "activityAttested:uint256",
    ]);
  });

  it("getLimit takes uint256 agentId", () => {
    const fn = findFn(CreditRegistryAbi, "getLimit");
    expect(fn.inputs?.map((i) => i.type)).toEqual(["uint256"]);
  });
});

describe("CollateralVault ABI", () => {
  it("exposes the multi-asset reads the routes rely on", () => {
    const sig = (name: string): ReadonlyArray<string | undefined> | undefined =>
      findFn(CollateralVaultAbi, name).inputs?.map((i) => i.type);
    expect(sig("availableBalance")).toEqual(["address", "address"]);
    expect(sig("requiredCollateral")).toEqual(["uint256", "address"]);
    expect(sig("assetConfigs")).toEqual(["address"]);
    expect(sig("reservations")).toEqual(["uint256"]);
  });
});

describe("LOAN_STATUS map", () => {
  it("matches ILoanRegistry.LoanStatus order 0–8", () => {
    expect(LOAN_STATUS).toEqual({
      0: "Requested",
      1: "PendingApproval",
      2: "Approved",
      3: "Funded",
      4: "Active",
      5: "Repaid",
      6: "Defaulted",
      7: "Expired",
      8: "Cancelled",
    });
  });
});
