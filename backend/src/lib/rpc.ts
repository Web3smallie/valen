/**
 * Thin wrappers around publicClient.readContract that normalise RPC errors
 * into a consistent shape the route handlers can re-throw.
 */
import { publicClient } from "../chain/publicClient.js";
import type { Abi, ContractFunctionArgs, ContractFunctionName } from "viem";

export class RpcError extends Error {
  readonly statusCode: number;
  constructor(msg: string, statusCode = 502) {
    super(msg);
    this.name    = "RpcError";
    this.statusCode = statusCode;
  }
}

export async function readContract<
  const TAbi extends Abi,
  TFn extends ContractFunctionName<TAbi, "view" | "pure">
>(params: {
  address: `0x${string}`;
  abi:     TAbi;
  functionName: TFn;
  args?:   ContractFunctionArgs<TAbi, "view" | "pure", TFn>;
}) {
  try {
    return await publicClient.readContract(params as Parameters<typeof publicClient.readContract>[0]);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    // Propagate revert-like errors as 404 (record doesn't exist), others as 502
    if (msg.includes("revert") || msg.includes("execution reverted")) {
      throw new RpcError(`Contract read reverted: ${msg}`, 404);
    }
    throw new RpcError(`RPC error: ${msg}`, 502);
  }
}

/** getLogs wrapper with a sensible block range fallback. */
export async function getLogs(params: Parameters<typeof publicClient.getLogs>[0]) {
  try {
    return await publicClient.getLogs(params);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new RpcError(`getLogs error: ${msg}`, 502);
  }
}
