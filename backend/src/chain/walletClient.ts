import { createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arcTestnet } from "../config/arc.js";
import "dotenv/config";

const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
if (!privateKey) throw new Error("Missing DEPLOYER_PRIVATE_KEY in .env");

export const deployerAccount = privateKeyToAccount(privateKey as `0x${string}`);

export const walletClient = createWalletClient({
  account: deployerAccount,
  chain: arcTestnet,
  transport: http(),
});