/**
 * GET /pool — LiquidityPool state: idle liquidity, deployed capital,
 *             total assets, share price, lender share for a wallet.
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { LiquidityPoolAbi }      from "../abis/LiquidityPool.js";
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

    return {
      idleLedger:   { raw: idleLedger.toString(),   formatted: formatUnits6(idleLedger)   },
      totalDeployed:{ raw: totalDeployed.toString(), formatted: formatUnits6(totalDeployed)},
      totalAssets:  { raw: totalAssets.toString(),   formatted: formatUnits6(totalAssets)  },
      // sharePrice is a fixed-point ratio scaled by 1e6; display as raw
      sharePrice:   sharePrice.toString(),
      totalShares:  totalShares.toString(),
      activeLoanCount:    activeLoanCount.toString(),
      maxActiveLoans:     maxActiveLoans.toString(),
      initializedLiquidity,
      address: contracts.liquidityPool,
    };
  });
}
