/**
 * Startup validation tests — validateDeployment against a stubbed RPC.
 * Covers every mismatch class, the transport/config distinction, and
 * the retry behavior. No network involved.
 */
import { describe, it, expect, vi } from "vitest";
import type { Address } from "viem";
import { ConfigError, type Manifest } from "../config/manifest.js";
import {
  validateDeployment,
  RpcUnavailableError,
  type ValidationRpc,
} from "../config/validate.js";

const addr = (ch: string): Address => `0x${ch.repeat(40)}` as Address;

function fixtureManifest(abiVersion: "V3" | "V4" = "V3"): Manifest {
  const hex = "123456789ab";
  const contracts: Record<string, { address: Address; proxy: boolean; implementation: Address | null }> = {};
  const keys = [
    "agentRegistry", "loanRegistry", "loanVault", "creditRegistry",
    "revenueRouter", "collateralVault", "liquidityPool", "underwriterPool",
    "recipientRegistry", "reservePool", "activityAttester",
  ];
  keys.forEach((key, i) => {
    contracts[key] = { address: addr(hex[i]), proxy: true, implementation: addr("c") };
  });
  return {
    deployment: "fixture",
    chainId: 5042002,
    abiVersion,
    deployer: addr("d"),
    contracts,
    tokens: {
      usdc: { address: addr("e"), decimals: 6 },
      eurc: { address: addr("f"), decimals: 6 },
    },
  };
}

const padSlot = (impl: string): string => `0x${"00".repeat(12)}${impl.slice(2)}`;

/** A fully healthy stub; override per test. */
function healthyStub(m: Manifest): ValidationRpc & {
  calls: { chainId: number };
} {
  const c = m.contracts;
  const wiring = new Map<string, string>([
    [`${c.loanRegistry.address}:owner`, m.deployer],
    [`${c.loanRegistry.address}:vault`, c.loanVault.address],
    [`${c.loanRegistry.address}:router`, c.revenueRouter.address],
    [`${c.loanRegistry.address}:agentRegistry`, c.agentRegistry.address],
    [`${c.loanRegistry.address}:collateralVault`, c.collateralVault.address],
    [`${c.loanRegistry.address}:underwriterPool`, c.underwriterPool.address],
    [`${c.loanRegistry.address}:recipientRegistry`, c.recipientRegistry.address],
    [`${c.loanRegistry.address}:reservePool`, c.reservePool.address],
    [`${c.loanVault.address}:registry`, c.loanRegistry.address],
    [`${c.loanVault.address}:liquidityPool`, c.liquidityPool.address],
    [`${c.liquidityPool.address}:loanVault`, c.loanVault.address],
    [`${c.liquidityPool.address}:loanRegistry`, c.loanRegistry.address],
    [`${c.revenueRouter.address}:registry`, c.loanRegistry.address],
    [`${c.revenueRouter.address}:creditRegistry`, c.creditRegistry.address],
    [`${c.revenueRouter.address}:reservePool`, c.reservePool.address],
    [`${c.revenueRouter.address}:agentRegistry`, c.agentRegistry.address],
    [`${c.activityAttester.address}:agentRegistry`, c.agentRegistry.address],
    [`${c.activityAttester.address}:creditRegistry`, c.creditRegistry.address],
    [`${c.collateralVault.address}:registry`, c.loanRegistry.address],
  ]);
  const calls = { chainId: 0 };
  return {
    calls,
    getChainId: vi.fn(async () => {
      calls.chainId += 1;
      return m.chainId;
    }),
    getBytecode: vi.fn(async () => "0x6080604052" as const),
    getStorageAt: vi.fn(async ({ address }: { address: Address }) => {
      const entry = Object.values(c).find((e) => e.address === address);
      if (!entry?.implementation) throw new Error(`unexpected slot read ${address}`);
      return padSlot(entry.implementation);
    }),
    readContract: vi.fn(async ({ address, functionName }: { address: Address; functionName: string }) => {
      if (functionName === "decimals") return 6;
      if (functionName === "getDirectDisbursement") throw new Error("execution reverted");
      const v = wiring.get(`${address}:${functionName}`);
      if (v === undefined) throw new Error(`unexpected call ${address}:${functionName}`);
      return v;
    }),
  };
}

describe("validateDeployment happy path", () => {
  it("passes a coherent V3 deployment and reports the check count", async () => {
    const m = fixtureManifest("V3");
    const report = await validateDeployment(healthyStub(m), m);
    expect(report).toEqual({ deployment: "fixture", chainId: 5042002, checks: 46 });
  });

  it("passes a V4 deployment when the probe getter exists", async () => {
    const m = fixtureManifest("V4");
    const stub = healthyStub(m);
    const inner = stub.readContract;
    stub.readContract = vi.fn(async (args: { address: Address; functionName: string }) => {
      if (args.functionName === "getDirectDisbursement") return true;
      return (inner as (a: { address: Address; functionName: string }) => Promise<unknown>)(args);
    }) as ValidationRpc["readContract"];
    const report = await validateDeployment(stub, m);
    expect(report.checks).toBe(46);
  });
});

describe("validateDeployment configuration failures", () => {
  it("rejects a chain id mismatch", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    stub.getChainId = vi.fn(async () => 1);
    await expect(validateDeployment(stub, m)).rejects.toThrow(/chain id mismatch/i);
  });

  it("rejects missing contract code", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    stub.getBytecode = vi.fn(async () => undefined);
    await expect(validateDeployment(stub, m)).rejects.toThrow(/no contract code/i);
  });

  it("rejects a proxy with an empty implementation slot", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    stub.getStorageAt = vi.fn(async () => `0x${"00".repeat(32)}`);
    await expect(validateDeployment(stub, m)).rejects.toThrow(/no ERC1967 implementation/i);
  });

  it("rejects implementation drift", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    stub.getStorageAt = vi.fn(async () => padSlot(addr("9")));
    await expect(validateDeployment(stub, m)).rejects.toThrow(/implementation drift/i);
  });

  it("rejects wiring mismatches", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    const inner = stub.readContract;
    stub.readContract = vi.fn(async (args: { address: Address; functionName: string }) => {
      if (args.functionName === "vault") return addr("9");
      return (inner as (a: { address: Address; functionName: string }) => Promise<unknown>)(args);
    }) as ValidationRpc["readContract"];
    await expect(validateDeployment(stub, m)).rejects.toThrow(/wiring mismatch/i);
  });

  it("rejects reverted wiring reads as misconfiguration", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    stub.readContract = vi.fn(async ({ functionName }: { functionName: string }) => {
      if (functionName === "decimals") return 6;
      if (functionName === "getDirectDisbursement") throw new Error("execution reverted");
      throw new Error("execution reverted: bad selector");
    }) as ValidationRpc["readContract"];
    await expect(validateDeployment(stub, m)).rejects.toThrow(/read failed/i);
  });

  it("rejects EURC decimal mismatches", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    const inner = stub.readContract;
    stub.readContract = vi.fn(async (args: { address: Address; functionName: string }) => {
      if (args.functionName === "decimals") return 18;
      return (inner as (a: { address: Address; functionName: string }) => Promise<unknown>)(args);
    }) as ValidationRpc["readContract"];
    await expect(validateDeployment(stub, m)).rejects.toThrow(/decimals mismatch/i);
  });

  it("rejects a V3 manifest when the V4 getter exists", async () => {
    const m = fixtureManifest("V3");
    const stub = healthyStub(m);
    const inner = stub.readContract;
    stub.readContract = vi.fn(async (args: { address: Address; functionName: string }) => {
      if (args.functionName === "getDirectDisbursement") return false;
      return (inner as (a: { address: Address; functionName: string }) => Promise<unknown>)(args);
    }) as ValidationRpc["readContract"];
    await expect(validateDeployment(stub, m)).rejects.toThrow(/abiVersion is V3 but/i);
  });

  it("rejects a V4 manifest when the V4 getter is absent", async () => {
    const m = fixtureManifest("V4");
    const stub = healthyStub(m); // probe reverts, as on V3 code
    await expect(validateDeployment(stub, m)).rejects.toThrow(/abiVersion is V4 but/i);
  });
});

describe("validateDeployment transport handling", () => {
  it("retries once on transport errors, then reports RPC unavailable", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    stub.getChainId = vi.fn(async () => {
      throw new Error("fetch failed");
    });
    await expect(validateDeployment(stub, m)).rejects.toThrow(RpcUnavailableError);
    await expect(validateDeployment(stub, m)).rejects.toThrow(/RPC unavailable/i);
    expect(stub.getChainId).toHaveBeenCalledTimes(4); // 2 attempts x 2 runs
  });

  it("does not retry configuration errors", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    stub.getChainId = vi.fn(async () => 1); // wrong chain: config error, not transport
    await expect(validateDeployment(stub, m)).rejects.toThrow(ConfigError);
    expect(stub.getChainId).toHaveBeenCalledTimes(1);
  });

  it("surfaces mid-run transport failures as RPC unavailable", async () => {
    const m = fixtureManifest();
    const stub = healthyStub(m);
    stub.getBytecode = vi.fn(async () => {
      throw new Error("socket hang up");
    });
    await expect(validateDeployment(stub, m)).rejects.toThrow(RpcUnavailableError);
  });
});
