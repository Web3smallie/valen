/**
 * GET /assets — configured collateral assets (USDC + EURC) with price and LTV.
 *
 * Response shape matches frontend AssetsResponse:
 *   usdc: { address, decimals, price, enabled }
 *   eurc: { address, decimals, price, priceFormatted, enabled }
 */
import type { FastifyInstance } from "fastify";
import { contracts, USDC_ADDRESS, EURC_ADDRESS } from "../config/contracts.js";
import { CollateralVaultAbi }    from "../abis/CollateralVault.js";
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

    // assetConfigs returns (bool enabled, uint8 decimals, uint256 usdPriceE18)
    function fmtAsset(
      [enabled, decimals, usdPriceE18]: readonly [boolean, number, bigint],
      address: string,
    ) {
      // usdPriceE18 is the price scaled by 1e18.
      // Represent as a decimal string to avoid float imprecision on large values.
      const priceFull = usdPriceE18.toString();
      // Human-readable: divide by 1e18 — safe for prices in the $0–$10 range
      const priceFormatted = `$${(Number(usdPriceE18) / 1e18).toFixed(4)}`;
      return { address, decimals, price: priceFull, priceFormatted, enabled };
    }

    return {
      usdc: fmtAsset(usdcConfig, USDC_ADDRESS),
      eurc: fmtAsset(eurcConfig, EURC_ADDRESS),
      maxLTVBps,
      maxLTVPercent: (maxLTVBps / 100).toFixed(2),
    };
  });
}
