/**
 * GET /recipients/:wallet — RecipientRegistry approval status.
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { RecipientRegistryAbi }  from "../abis/RecipientRegistry.js";
import { readContract }          from "../lib/rpc.js";
import { validateAddress }       from "../lib/format.js";

export async function recipientRoutes(app: FastifyInstance) {

  app.get<{ Params: { wallet: string } }>("/recipients/:wallet", async (req) => {
    const wallet = validateAddress(req.params.wallet, "wallet");

    const data = await readContract({
      address: contracts.recipientRegistry,
      abi:     RecipientRegistryAbi,
      functionName: "recipients",
      args: [wallet],
    }) as readonly [boolean, `0x${string}`, string];

    const [approved, categoryId, label] = data;

    return { wallet, approved, categoryId, label };
  });
}
