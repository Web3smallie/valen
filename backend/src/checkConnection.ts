import { publicClient } from "./chain/publicClient.js";

const blockNumber = await publicClient.getBlockNumber();
console.log("Current Arc testnet block:", blockNumber);