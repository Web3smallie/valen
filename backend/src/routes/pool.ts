/**
 * GET /pool — LiquidityPool state.
 *
 * Response shape matches frontend PoolResponse:
 *   idleLedger, idleLedgerFormatted, totalDeployed, totalDeployedFormatted,
 *   activeLoanCount, reserveBalance, reserveBalanceFormatted
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { LiquidityPoolAbi }      from "../abis/LiquidityPool.js";
import { ReservePoolAbi }        from "../abis/ReservePool.js";
import { readContract }          from "../lib/rpc.js";
import { formatUnits6 }          from "../lib/format.js";

export async function poolRoutes(app: FastifyInstance) {

  app.get("/pool", async () => {
    const [
      idleLedger,
      totalDeployed,
      totalAssets,
      sharePrice,
      totalShares,
      activeLoanCount,
      maxActiveLoans,
      initializedLiquidity,
    ] = await Promise.all([
      readContract({ address: contracts.liquidityPool, abi: LiquidityPoolAbi, functionName: "idleLedger"           }) as Promise<bigint>,
      readContract({ address: contracts.liquidityPool, abi: LiquidityPoolAbi, functionName: "totalDeployed"        }) as Promise<bigint>,
      readContract({ address: contracts.liquidityPool, abi: LiquidityPoolAbi, functionName: "totalAssets"          }) as Promise<bigint>,
      readContract({ address: contracts.liquidityPool, abi: LiquidityPoolAbi, functionName: "sharePrice"           }) as Promise<bigint>,
      readContract({ address: contracts.liquidityPool, abi: LiquidityPoolAbi, functionName: "totalShares"          }) as Promise<bigint>,
      readContract({ address: contracts.liquidityPool, abi: LiquidityPoolAbi, functionName: "activeLoanCount"      }) as Promise<bigint>,
      readContract({ address: contracts.liquidityPool, abi: LiquidityPoolAbi, functionName: "maxActiveLoans"       }) as Promise<bigint>,
      readContract({ address: contracts.liquidityPool, abi: LiquidityPoolAbi, functionName: "initializedLiquidity" }) as Promise<boolean>,
    ]);

    // Attempt reserve balance read; fall back to "0" if ReservePool not configured.
    let reserveBalance = 0n;
    try {
      reserveBalance = await readContract({
        address: contracts.reservePool,
        abi: ReservePoolAbi,
        functionName: "totalContributed",
      }) as bigint;
    } catch { /* not critical */ }

    return {
      // Flat fields expected by frontend PoolResponse
      idleLedger:              idleLedger.toString(),
      idleLedgerFormatted:     formatUnits6(idleLedger),
      totalDeployed:           totalDeployed.toString(),
      totalDeployedFormatted:  formatUnits6(totalDeployed),
      activeLoanCount:         activeLoanCount.toString(),
      reserveBalance:          reserveBalance.toString(),
      reserveBalanceFormatted: formatUnits6(reserveBalance),
      // Extended fields for informational use
      totalAssets:             totalAssets.toString(),
      totalAssetsFormatted:    formatUnits6(totalAssets),
      sharePrice:              sharePrice.toString(),
      totalShares:             totalShares.toString(),
      maxActiveLoans:          maxActiveLoans.toString(),
      initializedLiquidity,
      address: contracts.liquidityPool,
    };
  });
}
