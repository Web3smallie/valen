/**
 * Manifest loader tests — deployments/<name>.json is the single source
 * of truth for addresses, so its resolution and structural validation
 * are tested directly against fixture files. No RPC involved.
 */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  loadManifest,
  resolveManifestPath,
  ConfigError,
  REQUIRED_CONTRACTS,
} from "../config/manifest.js";

const addr = (ch: string): string => `0x${ch.repeat(40)}`;

function validManifestJson(): string {
  const contracts: Record<string, unknown> = {};
  for (const [i, key] of REQUIRED_CONTRACTS.entries()) {
    contracts[key] = {
      address: addr(String((i % 9) + 1)),
      proxy: true,
      implementation: addr("a"),
    };
  }
  return JSON.stringify({
    deployment: "fixture",
    chainId: 5042002,
    abiVersion: "V3",
    deployer: addr("b"),
    contracts,
    tokens: {
      usdc: { address: addr("c"), decimals: 6 },
      eurc: { address: addr("d"), decimals: 6 },
    },
  });
}

let dir = "";
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "valen-manifest-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function writeFixture(name: string, content: string): string {
  const deployments = join(dir, "deployments");
  mkdirSync(deployments, { recursive: true });
  const path = join(deployments, `${name}.json`);
  writeFileSync(path, content);
  return path;
}

describe("loadManifest", () => {
  it("loads a valid manifest with all 11 contracts and both tokens", () => {
    const path = writeFixture("ok", validManifestJson());
    const m = loadManifest(path);
    expect(m.deployment).toBe("fixture");
    expect(m.chainId).toBe(5042002);
    expect(m.abiVersion).toBe("V3");
    expect(Object.keys(m.contracts)).toHaveLength(11);
    expect(m.tokens.usdc.decimals).toBe(6);
    expect(m.tokens.eurc.decimals).toBe(6);
  });

  it("rejects a missing file", () => {
    expect(() => loadManifest(join(dir, "deployments", "nope.json"))).toThrowError(
      ConfigError
    );
    expect(() => loadManifest(join(dir, "deployments", "nope.json"))).toThrow(
      /could not read/i
    );
  });

  it("rejects malformed JSON", () => {
    const path = writeFixture("bad", "{not json");
    expect(() => loadManifest(path)).toThrow(/could not parse/i);
  });

  it("rejects a missing contract entry", () => {
    const raw = JSON.parse(validManifestJson()) as Record<string, unknown>;
    const contracts = raw.contracts as Record<string, unknown>;
    delete contracts.loanVault;
    const path = writeFixture("missing", JSON.stringify(raw));
    expect(() => loadManifest(path)).toThrow(/missing contracts\.loanVault/);
  });

  it("rejects a malformed address", () => {
    const raw = JSON.parse(validManifestJson()) as Record<string, unknown>;
    const contracts = raw.contracts as Record<string, Record<string, unknown>>;
    contracts.loanRegistry.address = "0xnotanaddress";
    const path = writeFixture("malformed", JSON.stringify(raw));
    expect(() => loadManifest(path)).toThrow(/not a valid address/);
  });

  it("rejects the zero address", () => {
    const raw = JSON.parse(validManifestJson()) as Record<string, unknown>;
    const contracts = raw.contracts as Record<string, Record<string, unknown>>;
    contracts.reservePool.address = "0x0000000000000000000000000000000000000000";
    const path = writeFixture("zero", JSON.stringify(raw));
    expect(() => loadManifest(path)).toThrow(/zero address/);
  });

  it("rejects a proxy entry without an implementation", () => {
    const raw = JSON.parse(validManifestJson()) as Record<string, unknown>;
    const contracts = raw.contracts as Record<string, Record<string, unknown>>;
    delete contracts.loanVault.implementation;
    const path = writeFixture("noimpl", JSON.stringify(raw));
    expect(() => loadManifest(path)).toThrow(/implementation/);
  });

  it("rejects an invalid chainId", () => {
    for (const chainId of [0, -1, "5042002", null]) {
      const raw = JSON.parse(validManifestJson()) as Record<string, unknown>;
      raw.chainId = chainId;
      const path = writeFixture("chain", JSON.stringify(raw));
      expect(() => loadManifest(path)).toThrow(/invalid chainId/);
    }
  });

  it("rejects an invalid abiVersion", () => {
    const raw = JSON.parse(validManifestJson()) as Record<string, unknown>;
    raw.abiVersion = "V5";
    const path = writeFixture("abi", JSON.stringify(raw));
    expect(() => loadManifest(path)).toThrow(/invalid abiVersion/);
  });

  it("rejects a missing token entry", () => {
    const raw = JSON.parse(validManifestJson()) as Record<string, unknown>;
    const tokens = raw.tokens as Record<string, unknown>;
    delete tokens.eurc;
    const path = writeFixture("token", JSON.stringify(raw));
    expect(() => loadManifest(path)).toThrow(/missing tokens\.eurc/);
  });
});

describe("resolveManifestPath", () => {
  it("finds deployments/ walking up from a nested directory", () => {
    const path = writeFixture("deep", validManifestJson());
    const nested = join(dir, "a", "b", "c");
    mkdirSync(nested, { recursive: true });
    expect(resolveManifestPath("deep", nested)).toBe(path);
  });

  it("rejects traversal and non-slug names", () => {
    for (const bad of ["../x", "..", "a/b", "A", "", "/etc", "arc testnet", "a.json"]) {
      expect(() => resolveManifestPath(bad, dir)).toThrow(/invalid dep/i);
    }
  });

  it("fails clearly when no deployments/ directory exists", () => {
    const lonely = mkdtempSync(join(tmpdir(), "valen-lonely-"));
    try {
      expect(() => resolveManifestPath("arc-testnet", lonely)).toThrow(
        /could not locate a deployments/i
      );
    } finally {
      rmSync(lonely, { recursive: true, force: true });
    }
  });
});
