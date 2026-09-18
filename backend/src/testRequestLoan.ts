import { walletClient } from "./chain/walletClient.js";
import { publicClient } from "./chain/publicClient.js";
import { contracts } from "./config/contracts.js";
import { LoanRegistryAbi } from "./abis/LoanRegistry.js";
import { deployerAccount } from "./chain/walletClient.js";
import { keccak256, toBytes } from "viem";

async function main() {
  const proposal = {
    creditWallet: deployerAccount.address,
    principal: 5_000_000n, // 5 USDC at 6 decimals
    repaymentRateBps: 1500,
    totalRepaymentDue: 5_750_000n, // 15% interest
    duration: 30n * 24n * 60n * 60n, // 30 days in seconds
    purpose: "Backend event-listener test loan",
    budget: [{ categoryId: keccak256(toBytes("COMPUTE")), cap: 5_000_000n }],
    permittedRecipients: [deployerAccount.address], // will fail RecipientRegistry check unless approved first
    milestoneAmounts: [5_000_000n],
    milestoneDescriptions: ["Full release"],
    collateralAmount: 0n,
    underwriter: "0x0000000000000000000000000000000000000000" as const,
    underwriterAmount: 0n,
  };

  console.log("Submitting requestLoan()...");
  const hash = await walletClient.writeContract({
    address: contracts.loanRegistry,
    abi: LoanRegistryAbi,
    functionName: "requestLoan",
    args: [proposal],
  });

  console.log("Transaction hash:", hash);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log("Confirmed in block:", receipt.blockNumber);
}

main().catch(console.error);