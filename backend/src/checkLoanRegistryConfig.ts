import { publicClient } from "./chain/publicClient.js";
import { contracts } from "./config/contracts.js";
import { LoanRegistryAbi } from "./abis/LoanRegistry.js";

async function main() {
  const minDuration = await publicClient.readContract({
    address: contracts.loanRegistry,
    abi: LoanRegistryAbi,
    functionName: "minDuration",
  });
  const maxDuration = await publicClient.readContract({
    address: contracts.loanRegistry,
    abi: LoanRegistryAbi,
    functionName: "maxDuration",
  });

  console.log("minDuration:", minDuration, "seconds");
  console.log("maxDuration:", maxDuration, "seconds");
}

main().catch(console.error);