/**
 * GET /collateral/:wallet                          — available balances for USDC + EURC
 * GET /collateral/required?principal=...&asset=... — required collateral for a given loan size
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { CollateralVaultAbi }    from "../abis/CollateralVault.js";
import { USDC_ADDRESS, EURC_ADDRESS } from "../config/contracts.js";
import { readContract }          from "../lib/rpc.js";
import { validateAddress, validateUint, ValidationError, formatUnits6 } from "../lib/format.js";

export async function collateralRoutes(app: FastifyInstance) {

  // ── GET /collateral/required ──────────────────────────────────────────────
  // Must be registered BEFORE /:wallet to avoid route collision.
  app.get<{ Querystring: { principal?: string; asset?: string } }>(
    "/collateral/required",
    async (req, reply) => {
      const { principal: principalStr, asset: assetStr } = req.query;

      if (!principalStr) {
        return reply.code(400).send({ error: "Missing query param: principal (raw uint256, 6 decimals)" });
      }
      if (!assetStr) {
        return reply.code(400).send({ error: "Missing query param: asset (token address)" });
      }

      const principal = validateUint(principalStr, "principal");
      const asset     = validateAddress(assetStr, "asset");

      const required = await readContract({
        address: contracts.collateralVault,
        abi:     CollateralVaultAbi,
        functionName: "requiredCollateral",
        args: [principal, asset],
      }) as bigint;

      const config = await readContract({
        address: contracts.collateralVault,
        abi:     CollateralVaultAbi,
        functionName: "assetConfigs",
        args: [asset],
      }) as readonly [boolean, number, bigint];

      const [approved, decimals, usdPriceE18] = config;

      return {
        asset,
        approved,
        decimals,
        usdPriceE18: usdPriceE18.toString(),
        principal:  { raw: principal.toString(),  formatted: formatUnits6(principal)  },
        required:   { raw: required.toString(),   formatted: formatUnits6(required)   },
      };
    }
  );

  // ── GET /collateral/:wallet ───────────────────────────────────────────────
  app.get<{ Params: { wallet: string } }>("/collateral/:wallet", async (req, reply) => {
    const wallet = validateAddress(req.params.wallet, "wallet");

    const [usdcBalance, eurcBalance] = await Promise.all([
      readContract({
        address: contracts.collateralVault,
        abi:     CollateralVaultAbi,
        functionName: "availableBalance",
        args: [wallet, USDC_ADDRESS],
      }) as Promise<bigint>,
      readContract({
        address: contracts.collateralVault,
        abi:     CollateralVaultAbi,
        functionName: "availableBalance",
        args: [wallet, EURC_ADDRESS],
      }) as Promise<bigint>,
    ]);

    return {
      wallet,
      balances: {
        usdc: { asset: USDC_ADDRESS, raw: usdcBalance.toString(), formatted: formatUnits6(usdcBalance) },
        eurc: { asset: EURC_ADDRESS, raw: eurcBalance.toString(), formatted: formatUnits6(eurcBalance) },
      },
    };
  });
}
