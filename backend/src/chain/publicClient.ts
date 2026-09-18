import { createPublicClient, http } from "viem";
import { arcTestnet } from "../config/arc.js";

export const publicClient = createPublicClient({
  chain: arcTestnet,
  transport: http(),
});