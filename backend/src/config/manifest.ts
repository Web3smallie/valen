/**
 * Deployment manifest loading — the single authoritative source for
 * Valen contract addresses. There are intentionally no per-address
 * environment overrides: selection is a whole deployment at a time
 * (DEPLOYMENT), validated structurally here and live in validate.ts.
 */
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isAddress, type Address } from "viem";

export class ConfigError extends Error {
  constructor(msg: string) {
    super(msg);
    this.name = "ConfigError";
  }
}

export type AbiVersion = "V3" | "V4";

export interface ManifestContract {
  address: Address;
  proxy: boolean;
  implementation: Address | null;
}

export interface Manifest {
  deployment: string;
  chainId: number;
  abiVersion: AbiVersion;
  deployer: Address;
  contracts: Record<string, ManifestContract>;
  tokens: {
    usdc: { address: Address; decimals: number };
    eurc: { address: Address; decimals: number };
  };
}

export const REQUIRED_CONTRACTS = [
  "agentRegistry",
  "loanRegistry",
  "loanVault",
  "creditRegistry",
  "revenueRouter",
  "collateralVault",
  "liquidityPool",
  "underwriterPool",
  "recipientRegistry",
  "reservePool",
  "activityAttester",
] as const;

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;

/** Deployment names are bare slugs — no paths, no traversal. */
const DEPLOYMENT_NAME_RE = /^[a-z0-9-]+$/;

function fail(msg: string): never {
  throw new ConfigError(msg);
}

/**
 * Resolve deployments/<name>.json by walking up from startDir to the
 * first directory containing a deployments/ folder. CWD-independent,
 * so it works from src/, dist/, and test runners alike.
 */
export function resolveManifestPath(deployment: string, startDir: string): string {
  if (!DEPLOYMENT_NAME_RE.test(deployment)) {
    fail(
      `Invalid DEPLOYMENT "${deployment}" (expected a lowercase slug like "arc-testnet"). ` +
        `Check the DEPLOYMENT env var.`
    );
  }
  let dir = resolve(startDir);
  for (;;) {
    const candidate = join(dir, "deployments");
    if (existsSync(candidate) && statSync(candidate).isDirectory()) {
      return join(candidate, `${deployment}.json`);
    }
    const parent = dirname(dir);
    if (parent === dir) {
      fail(
        `Could not locate a deployments/ directory walking up from "${startDir}". ` +
          `Run from the Valen repository checkout.`
      );
    }
    dir = parent;
  }
}

function asAddress(value: unknown, what: string): Address {
  if (typeof value !== "string" || !isAddress(value)) {
    fail(`Manifest ${what} is not a valid address: ${JSON.stringify(value)}.`);
  }
  if ((value as string).toLowerCase() === ZERO_ADDRESS.toLowerCase()) {
    fail(`Manifest ${what} is the zero address — every entry must be wired.`);
  }
  return value as Address;
}

/** Parse + structurally validate a manifest file. No RPC involved. */
export function loadManifest(path: string): Manifest {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    fail(`Could not read deployment manifest at "${path}".`);
  }
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(raw) as Record<string, unknown>;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    fail(`Could not parse deployment manifest at "${path}": ${msg}.`);
  }

  if (typeof parsed.deployment !== "string" || parsed.deployment.length === 0) {
    fail(`Manifest "${path}" has no deployment name.`);
  }
  if (!Number.isInteger(parsed.chainId) || (parsed.chainId as number) <= 0) {
    fail(`Manifest "${path}" has an invalid chainId: ${JSON.stringify(parsed.chainId)}.`);
  }
  if (parsed.abiVersion !== "V3" && parsed.abiVersion !== "V4") {
    fail(
      `Manifest "${path}" has an invalid abiVersion: ` +
        `${JSON.stringify(parsed.abiVersion)} (expected "V3" or "V4").`
    );
  }
  const deployer = asAddress(parsed.deployer, "deployer");

  const contractsRaw = parsed.contracts as Record<string, Record<string, unknown>> | undefined;
  if (!contractsRaw || typeof contractsRaw !== "object") {
    fail(`Manifest "${path}" has no contracts map.`);
  }
  const contracts: Record<string, ManifestContract> = {};
  for (const key of REQUIRED_CONTRACTS) {
    const entry = contractsRaw[key];
    if (!entry || typeof entry !== "object") {
      fail(`Manifest "${path}" is missing contracts.${key}.`);
    }
    const address = asAddress(entry.address, `contracts.${key}.address`);
    const proxy = entry.proxy === true;
    const implementation = proxy
      ? asAddress(entry.implementation, `contracts.${key}.implementation`)
      : null;
    contracts[key] = { address, proxy, implementation };
  }

  const tokensRaw = parsed.tokens as Record<string, Record<string, unknown>> | undefined;
  if (!tokensRaw || typeof tokensRaw !== "object") {
    fail(`Manifest "${path}" has no tokens map.`);
  }
  const token = (key: string): { address: Address; decimals: number } => {
    const entry = tokensRaw[key];
    if (!entry || typeof entry !== "object") {
      fail(`Manifest "${path}" is missing tokens.${key}.`);
    }
    const address = asAddress(entry.address, `tokens.${key}.address`);
    if (!Number.isInteger(entry.decimals) || (entry.decimals as number) < 0) {
      fail(`Manifest "${path}" has invalid tokens.${key}.decimals.`);
    }
    return { address, decimals: entry.decimals as number };
  };

  return {
    deployment: parsed.deployment as string,
    chainId: parsed.chainId as number,
    abiVersion: parsed.abiVersion as AbiVersion,
    deployer,
    contracts,
    tokens: { usdc: token("usdc"), eurc: token("eurc") },
  };
}

const moduleDir = dirname(fileURLToPath(import.meta.url));

let cached: Manifest | null = null;

/** Load the selected deployment manifest once per process. */
export function getManifest(): Manifest {
  if (!cached) {
    const deployment = process.env.DEPLOYMENT ?? "arc-testnet";
    cached = loadManifest(resolveManifestPath(deployment, moduleDir));
  }
  return cached;
}
