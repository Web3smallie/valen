/**
 * Deployer wallet — for LOCAL ADMIN SCRIPTS ONLY.
 *
 * This module is intentionally NOT imported by any route handler or the HTTP
 * server. Importing it in a running API process would expose the deployer key
 * to the network. Load it only in standalone scripts (testRequestLoan,
 * approveTestRecipient, etc.) that you run from your terminal.
 */
import { createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arcTestnet } from "../config/arc.js";
import "dotenv/config";

const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
if (!privateKey) {
  throw new Error(
    "DEPLOYER_PRIVATE_KEY is not set. " +
    "This module is for local admin scripts only — do not import it from API routes."
  );
}

export const deployerAccount = privateKeyToAccount(privateKey as `0x${string}`);

export const walletClient = createWalletClient({
  account: deployerAccount,
  chain: arcTestnet,
  transport: http(process.env.ARC_TESTNET_RPC_URL),
});
