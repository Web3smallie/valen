import { walletClient } from "./chain/walletClient.js";
import { publicClient } from "./chain/publicClient.js";
import { contracts } from "./config/contracts.js";
import { RecipientRegistryAbi } from "./abis/RecipientRegistry.js";
import { deployerAccount } from "./chain/walletClient.js";
import { keccak256, toBytes } from "viem";

async function main() {
  const hash = await walletClient.writeContract({
    address: contracts.recipientRegistry,
    abi: RecipientRegistryAbi,
    functionName: "approveRecipient",
    args: [deployerAccount.address, keccak256(toBytes("COMPUTE")), "Test Recipient"],
  });
  console.log("Approval tx:", hash);
  await publicClient.waitForTransactionReceipt({ hash });
  console.log("Approved.");
}

main().catch(console.error);