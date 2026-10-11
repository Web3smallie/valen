/**
 * GET /assets — configured collateral assets (USDC + EURC) with price and LTV.
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { CollateralVaultAbi }    from "../abis/CollateralVault.js";
import { USDC_ADDRESS, EURC_ADDRESS } from "../config/contracts.js";
import { readContract }          from "../lib/rpc.js";

export async function assetRoutes(app: FastifyInstance) {

  app.get("/assets", async () => {
    const [usdcConfig, eurcConfig, maxLTVBps] = await Promise.all([
      readContract({
        address: contracts.collateralVault,
        abi:     CollateralVaultAbi,
        functionName: "assetConfigs",
        args: [USDC_ADDRESS],
      }) as Promise<readonly [boolean, number, bigint]>,
      readContract({
        address: contracts.collateralVault,
        abi:     CollateralVaultAbi,
        functionName: "assetConfigs",
        args: [EURC_ADDRESS],
      }) as Promise<readonly [boolean, number, bigint]>,
      readContract({
        address: contracts.collateralVault,
        abi:     CollateralVaultAbi,
        functionName: "maxLTVBps",
      }) as Promise<number>,
    ]);

    function fmt([approved, decimals, usdPriceE18]: readonly [boolean, number, bigint], address: string) {
      return {
        address,
        approved,
        decimals,
        usdPriceE18: usdPriceE18.toString(),
        // Human-readable price: usdPriceE18 / 1e18
        usdPrice: (Number(usdPriceE18) / 1e18).toFixed(6),
      };
    }

    return {
      maxLTVBps,
      maxLTVPercent: (maxLTVBps / 100).toFixed(2),
      assets: {
        usdc: fmt(usdcConfig, USDC_ADDRESS),
        eurc: fmt(eurcConfig, EURC_ADDRESS),
      },
    };
  });
}
