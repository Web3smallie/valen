/**
 * Startup deployment validation — proves the manifest describes the
 * chain the RPC actually serves, before the server accepts traffic.
 *
 * Fail-closed: any mismatch or unreachable RPC exits the process with
 * a message naming the variable, expected and actual values, and the
 * remediation. Transport failures (RPC down) are retried once, then
 * reported distinctly from invalid configuration.
 *
 * Cost: ~47 sequential read-only RPC calls, ~3-6s on a warm testnet
 * RPC (measured: 25 sequential reads ≈ 2.4s; parallel batches were
 * slower against the public endpoint, so calls stay sequential).
 */
import { parseAbi, type Abi, type Address } from "viem";
import { ConfigError, type Manifest } from "./manifest.js";

export class RpcUnavailableError extends Error {
  constructor(msg: string) {
    super(msg);
    this.name = "RpcUnavailableError";
  }
}

/** Minimal RPC surface validation needs — satisfied by viem's publicClient. */
export interface ValidationRpc {
  getChainId(): Promise<number>;
  getBytecode(args: { address: Address }): Promise<string | undefined>;
  getStorageAt(args: { address: Address; slot: string }): Promise<string>;
  readContract(args: {
    address: Address;
    abi: Abi;
    functionName: string;
    args?: readonly unknown[];
  }): Promise<unknown>;
}

export interface ValidationReport {
  deployment: string;
  chainId: number;
  checks: number;
}

const CALL_TIMEOUT_MS = 10_000;
const RETRY_DELAY_MS = 1_000;

const ERC1967_IMPL_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const ZERO_SLOT = "0x" + "00".repeat(32);

const WIRING_ABI = parseAbi([
  "function owner() view returns (address)",
  "function vault() view returns (address)",
  "function router() view returns (address)",
  "function agentRegistry() view returns (address)",
  "function collateralVault() view returns (address)",
  "function underwriterPool() view returns (address)",
  "function recipientRegistry() view returns (address)",
  "function reservePool() view returns (address)",
  "function registry() view returns (address)",
  "function liquidityPool() view returns (address)",
  "function loanVault() view returns (address)",
  "function loanRegistry() view returns (address)",
  "function creditRegistry() view returns (address)",
  "function decimals() view returns (uint8)",
  "function getDirectDisbursement(uint256 loanId) view returns (bool)",
]);

function isTransportError(err: unknown): boolean {
  const msg = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
  return /timeout|timed out|fetch failed|failed to fetch|ECONN|ENOTFOUND|EAI_AGAIN|EPIPE|socket hang up|429|rate limit|network error/i.test(
    msg
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function sameAddress(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

export async function validateDeployment(
  rpc: ValidationRpc,
  manifest: Manifest
): Promise<ValidationReport> {
  const run = async (): Promise<ValidationReport> => {
    let checks = 0;
    const c = manifest.contracts;

    const call = async <T>(what: string, p: Promise<T>): Promise<T> => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        return await Promise.race([
          p,
          new Promise<never>((_, reject) => {
            timer = setTimeout(
              () => reject(new Error(`timed out after ${CALL_TIMEOUT_MS}ms: ${what}`)),
              CALL_TIMEOUT_MS
            );
          }),
        ]);
      } catch (err: unknown) {
        if (isTransportError(err)) {
          const detail = err instanceof Error ? err.message : String(err);
          throw new RpcUnavailableError(
            `RPC unavailable during ${what}: ${detail}. ` +
              `Check ARC_TESTNET_RPC_URL and retry.`
          );
        }
        throw err;
      } finally {
        clearTimeout(timer);
      }
    };

    const config = (msg: string): never => {
      throw new ConfigError(msg);
    };

    // 1. The RPC must serve the manifest's chain.
    const chainId = await call("eth_chainId", rpc.getChainId());
    checks += 1;
    if (chainId !== manifest.chainId) {
      config(
        `Chain id mismatch: RPC reports ${chainId} but manifest ` +
          `"${manifest.deployment}" expects ${manifest.chainId}. ` +
          `Check ARC_TESTNET_RPC_URL and DEPLOYMENT.`
      );
    }

    // 2. Every address must host contract code.
    const coded: Array<[string, Address]> = [
      ...Object.entries(c).map(([k, v]) => [k, v.address] as [string, Address]),
      ["tokens.usdc", manifest.tokens.usdc.address],
      ["tokens.eurc", manifest.tokens.eurc.address],
    ];
    for (const [key, address] of coded) {
      const code = await call(`getCode ${key}`, rpc.getBytecode({ address }));
      checks += 1;
      if (!code || code === "0x") {
        config(
          `No contract code at ${key} (${address}) on chain ${chainId}. ` +
            `The manifest deployment "${manifest.deployment}" does not match the RPC network.`
        );
      }
    }

    // 3. Every proxy must point at its recorded implementation.
    for (const [key, entry] of Object.entries(c)) {
      if (!entry.proxy) continue;
      const slot = await call(
        `ERC1967 slot ${key}`,
        rpc.getStorageAt({ address: entry.address, slot: ERC1967_IMPL_SLOT })
      );
      checks += 1;
      if (!slot || slot.toLowerCase() === ZERO_SLOT) {
        config(
          `${key} at ${entry.address} has no ERC1967 implementation — ` +
            `the manifest expects a proxy. Is this an implementation address? ` +
            `Check deployments/${manifest.deployment}.json.`
        );
      }
      const onChain = `0x${slot.slice(-40)}`;
      const expected = entry.implementation as string;
      if (!sameAddress(onChain, expected)) {
        config(
          `${key} implementation drift: on-chain ${onChain} != manifest ${expected}. ` +
            `If a UUPS upgrade occurred, verify it and update ` +
            `deployments/${manifest.deployment}.json.`
        );
      }
    }

    // 4. Wiring must form one coherent deployment.
    const links: Array<{
      label: string;
      address: Address;
      getter: string;
      expected: string;
    }> = [
      { label: "loanRegistry.owner", address: c.loanRegistry.address, getter: "owner", expected: manifest.deployer },
      { label: "loanRegistry.vault", address: c.loanRegistry.address, getter: "vault", expected: c.loanVault.address },
      { label: "loanRegistry.router", address: c.loanRegistry.address, getter: "router", expected: c.revenueRouter.address },
      { label: "loanRegistry.agentRegistry", address: c.loanRegistry.address, getter: "agentRegistry", expected: c.agentRegistry.address },
      { label: "loanRegistry.collateralVault", address: c.loanRegistry.address, getter: "collateralVault", expected: c.collateralVault.address },
      { label: "loanRegistry.underwriterPool", address: c.loanRegistry.address, getter: "underwriterPool", expected: c.underwriterPool.address },
      { label: "loanRegistry.recipientRegistry", address: c.loanRegistry.address, getter: "recipientRegistry", expected: c.recipientRegistry.address },
      { label: "loanRegistry.reservePool", address: c.loanRegistry.address, getter: "reservePool", expected: c.reservePool.address },
      { label: "loanVault.registry", address: c.loanVault.address, getter: "registry", expected: c.loanRegistry.address },
      { label: "loanVault.liquidityPool", address: c.loanVault.address, getter: "liquidityPool", expected: c.liquidityPool.address },
      { label: "liquidityPool.loanVault", address: c.liquidityPool.address, getter: "loanVault", expected: c.loanVault.address },
      { label: "liquidityPool.loanRegistry", address: c.liquidityPool.address, getter: "loanRegistry", expected: c.loanRegistry.address },
      { label: "revenueRouter.registry", address: c.revenueRouter.address, getter: "registry", expected: c.loanRegistry.address },
      { label: "revenueRouter.creditRegistry", address: c.revenueRouter.address, getter: "creditRegistry", expected: c.creditRegistry.address },
      { label: "revenueRouter.reservePool", address: c.revenueRouter.address, getter: "reservePool", expected: c.reservePool.address },
      { label: "revenueRouter.agentRegistry", address: c.revenueRouter.address, getter: "agentRegistry", expected: c.agentRegistry.address },
      { label: "activityAttester.agentRegistry", address: c.activityAttester.address, getter: "agentRegistry", expected: c.agentRegistry.address },
      { label: "activityAttester.creditRegistry", address: c.activityAttester.address, getter: "creditRegistry", expected: c.creditRegistry.address },
      { label: "collateralVault.registry", address: c.collateralVault.address, getter: "registry", expected: c.loanRegistry.address },
    ];
    for (const link of links) {
      let actual: unknown;
      try {
        actual = await call(
          `wiring ${link.label}`,
          rpc.readContract({
            address: link.address,
            abi: WIRING_ABI,
            functionName: link.getter,
          })
        );
      } catch (err: unknown) {
        if (err instanceof RpcUnavailableError) throw err;
        const detail = err instanceof Error ? err.message : String(err);
        config(
          `${link.label} read failed on ${link.address}: ${detail}. ` +
            `Is the wrong contract deployed at this address?`
        );
      }
      checks += 1;
      if (typeof actual !== "string" || !sameAddress(actual, link.expected)) {
        config(
          `Wiring mismatch at ${link.label}: on-chain ${String(actual)} != ` +
            `manifest ${link.expected}. The configured contracts belong to different deployments.`
        );
      }
    }

    // 5. EURC identity: on-chain decimals must match the manifest.
    const decimals = (await call(
      "eurc.decimals",
      rpc.readContract({
        address: manifest.tokens.eurc.address,
        abi: WIRING_ABI,
        functionName: "decimals",
      })
    )) as number;
    checks += 1;
    if (Number(decimals) !== manifest.tokens.eurc.decimals) {
      config(
        `EURC decimals mismatch: on-chain ${String(decimals)} != ` +
          `manifest ${manifest.tokens.eurc.decimals} at ${manifest.tokens.eurc.address}.`
      );
    }

    // 6. ABI probe: getDirectDisbursement exists only on V4.
    let probeOk = false;
    try {
      await call(
        "abi probe getDirectDisbursement",
        rpc.readContract({
          address: c.loanRegistry.address,
          abi: WIRING_ABI,
          functionName: "getDirectDisbursement",
          args: [0n],
        })
      );
      probeOk = true;
    } catch (err: unknown) {
      if (err instanceof RpcUnavailableError) throw err;
      probeOk = false;
    }
    checks += 1;
    if (manifest.abiVersion === "V3" && probeOk) {
      config(
        `Manifest abiVersion is V3 but ${c.loanRegistry.address} exposes ` +
          `getDirectDisbursement — a V4 upgrade occurred. Verify it and set ` +
          `abiVersion to "V4" in deployments/${manifest.deployment}.json.`
      );
    }
    if (manifest.abiVersion === "V4" && !probeOk) {
      config(
        `Manifest abiVersion is V4 but ${c.loanRegistry.address} has no ` +
          `getDirectDisbursement — the V4 upgrade is not active. Set abiVersion ` +
          `back to "V3" in deployments/${manifest.deployment}.json.`
      );
    }

    return { deployment: manifest.deployment, chainId, checks };
  };

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      return await run();
    } catch (err: unknown) {
      if (err instanceof RpcUnavailableError && attempt === 0) {
        await sleep(RETRY_DELAY_MS);
        continue;
      }
      throw err;
    }
  }
  throw new RpcUnavailableError("unreachable");
}
