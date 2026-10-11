/**
 * GET /activity/:activityHash — check whether an activity hash has been attested.
 *
 * The activityHash is computed off-chain as keccak256(abi.encode(source, jobId)).
 * This endpoint is purely a read — attestation submission is owner-only and is
 * never exposed as a public API endpoint.
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { ActivityAttesterAbi }   from "../abis/ActivityAttester.js";
import { readContract }          from "../lib/rpc.js";
import { validateBytes32 }       from "../lib/format.js";

export async function activityRoutes(app: FastifyInstance) {

  app.get<{ Params: { activityHash: string } }>("/activity/:activityHash", async (req) => {
    const hash = validateBytes32(req.params.activityHash, "activityHash");

    const attested = await readContract({
      address: contracts.activityAttester,
      abi:     ActivityAttesterAbi,
      functionName: "attestedActivity",
      args: [hash],
    }) as boolean;

    return { activityHash: hash, attested };
  });
}
