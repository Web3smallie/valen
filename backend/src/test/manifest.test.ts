/**
 * Canonical manifest tests — pin the verified arc-testnet deployment and
 * detect drift between the manifest and every other address source.
 * Changing the manifest requires updating these pins in the same change.
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadManifest, resolveManifestPath, REQUIRED_CONTRACTS } from "../config/manifest.js";

const here = dirname(fileURLToPath(import.meta.url));
const manifestPath = resolveManifestPath("arc-testnet", here);
const repoRoot = dirname(dirname(manifestPath));

const CANONICAL: Record<string, string> = {
  agentRegistry: "0xeC74944752Fff0f53Af5b727F288f59435C0144e",
  loanRegistry: "0x253B68c7a2D646561387Dc0958A6C176a30a6f8d",
  loanVault: "0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19",
  creditRegistry: "0x258B0678b30E2d32034389cfeCa7f58fE1CeB897",
  revenueRouter: "0xE0B9b39E72f73f2d85D77a1e24a2f319246de822",
  collateralVault: "0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f",
  liquidityPool: "0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061",
  underwriterPool: "0x23307d061dad8335995080518B73A839Ffe69E7A",
  recipientRegistry: "0xf8E069B659CEAf9c68318041D727b5c482Ac6374",
  reservePool: "0xe741d95aa64F125f75cB14E90d4b1cF96618f0fD",
  activityAttester: "0x2660044E4A7316B65263ea1B23b80aAf09841196",
};

const CANONICAL_IMPL: Record<string, string> = {
  agentRegistry: "0x797e0fcc4d05e2c606cc66c484418b602951cced",
  loanRegistry: "0xd47496361e5c485611718bd06065971691d2ba07",
  loanVault: "0xa698d80e5caf0b4b5033cd8091f1a37f98534537",
  creditRegistry: "0xf400dadaf8b01d16f5da65a2769a6b6e60dee1cd",
  revenueRouter: "0x394d9f57f00f27b19b1549e23021efed9cd7be38",
  collateralVault: "0x9c1b6819b32615ca4d28d41be2a10303425b9ba5",
  liquidityPool: "0x828525794b195329e8f1ae501a61d7590df542c1",
  underwriterPool: "0x49b018d11b869d7964c2c560c5dd233e64f2aa32",
  recipientRegistry: "0xe10598c039dd26609e0758bf737a68c9fae15f54",
  reservePool: "0x9d488e961bdcb2fb00bfb7984605d3c00dae7dd7",
  activityAttester: "0x6e119483041ff34b72db722b1c6cd2324b036dd4",
};

describe("canonical arc-testnet manifest", () => {
  it("loads with the verified deployment metadata", () => {
    const m = loadManifest(manifestPath);
    expect(m.deployment).toBe("arc-testnet");
    expect(m.chainId).toBe(5042002);
    expect(m.abiVersion).toBe("V3");
    expect(m.deployer).toBe("0xB0E8Ba6aFe21371AD4001e611224FC200FD10144");
    expect(Object.keys(m.contracts).sort()).toEqual([...REQUIRED_CONTRACTS].sort());
    expect(m.tokens.usdc.address).toBe("0x3600000000000000000000000000000000000000");
    expect(m.tokens.usdc.decimals).toBe(6);
    expect(m.tokens.eurc.address).toBe("0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a");
    expect(m.tokens.eurc.decimals).toBe(6);
  });

  it("pins every verified proxy address", () => {
    const m = loadManifest(manifestPath);
    for (const [key, address] of Object.entries(CANONICAL)) {
      expect(m.contracts[key].address).toBe(address);
      expect(m.contracts[key].proxy).toBe(true);
    }
  });

  it("pins every verified implementation address", () => {
    const m = loadManifest(manifestPath);
    for (const [key, impl] of Object.entries(CANONICAL_IMPL)) {
      expect(m.contracts[key].implementation).toBe(impl);
    }
  });
});

describe("address-source drift detection", () => {
  const manifestAddrs = new Set(
    [
      ...Object.values(CANONICAL),
      ...Object.values(CANONICAL_IMPL),
      "0x3600000000000000000000000000000000000000", // tokens.usdc
      "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a", // tokens.eurc
    ].map((a) => a.toLowerCase())
  );
  const ADDR_RE = /0x[0-9a-fA-F]{40}\b/g;
  const ZERO = "0x0000000000000000000000000000000000000000";

  it("frontend hardcoded addresses are a subset of the manifest", () => {
    for (const rel of [
      "frontend/src/screens/LendingPool.tsx",
      "frontend/src/screens/Integration.tsx",
    ]) {
      const src = readFileSync(join(repoRoot, rel), "utf8");
      const found = src.match(ADDR_RE) ?? [];
      expect(found.length).toBeGreaterThan(0);
      for (const a of found) {
        if (a === ZERO) continue;
        expect(manifestAddrs.has(a.toLowerCase())).toBe(true);
      }
    }
  });

  it(".env.example carries no contract addresses", () => {
    const src = readFileSync(join(repoRoot, "backend", ".env.example"), "utf8");
    const found = (src.match(ADDR_RE) ?? []).filter((a) => a !== ZERO);
    expect(found).toEqual([]);
  });
});
